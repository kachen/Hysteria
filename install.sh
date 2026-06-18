#!/usr/bin/env bash
#
# Hysteria 2 一鍵安裝腳本
# 用法: sudo bash install.sh [install|upgrade|uninstall|status]
#

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

EXECUTABLE_PATH="/usr/local/bin/hysteria"
CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SYSTEMD_SERVICE="/etc/systemd/system/hysteria-server.service"
SYSTEMD_TEMPLATE="/etc/systemd/system/hysteria-server@.service"
INIT_SCRIPT="/etc/init.d/hysteria-server"

IS_OPENWRT=0
IS_EL7=0
LEGACY_SYSTEMD=0

REPO_URL="https://github.com/apernet/hysteria"
HY2_API_URL="https://api.hy2.io/v1/update"
DOWNLOAD_BASE="https://download.hysteria.network/app/latest"

HYSTERIA_USER="${HYSTERIA_USER:-hysteria}"
LISTEN_PORT="${LISTEN_PORT:-443}"
OPERATION="${1:-install}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}${BOLD}==>${NC} $*"; }

die() {
  log_error "$1"
  exit "${2:-1}"
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "請使用 root 權限執行: sudo bash $SCRIPT_NAME"
  fi
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "缺少必要命令: $cmd"
  fi
}

detect_openwrt() {
  if [[ -f /etc/openwrt_release ]] || [[ -n "${OPENWRT_BOARD:-}" ]]; then
    IS_OPENWRT=1
    log_info "偵測到 OpenWrt 系統"
  fi
}

detect_el7() {
  if [[ -f /etc/redhat-release ]] && grep -qE '(CentOS|Red Hat|Oracle|Rocky|Alma|Scientific|CloudLinux).*(release|Linux release) 7(\.| |$)' /etc/redhat-release; then
    IS_EL7=1
    return 0
  fi
  if [[ -f /etc/os-release ]] && grep -qE '^VERSION_ID="?7(\.|"|$)' /etc/os-release; then
    IS_EL7=1
  fi
}

detect_systemd_features() {
  local ver
  ver=$(systemctl --version 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1 || true)
  if [[ -n "$ver" && "$ver" -lt 229 ]]; then
    LEGACY_SYSTEMD=1
  fi
}

detect_os() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    die "此腳本僅支援 Linux 系統"
  fi
  detect_openwrt
  detect_el7
  if [[ "$IS_OPENWRT" != "1" ]]; then
    detect_systemd_features
  fi
  if [[ "$IS_EL7" == "1" ]]; then
    log_info "偵測到 CentOS/RHEL 7，使用相容模式"
  fi
}

detect_mips_softfloat() {
  if command -v readelf >/dev/null 2>&1; then
    local probe="/bin/busybox"
    [[ -x "$probe" ]] || probe="/bin/sh"
    readelf -A "$probe" 2>/dev/null | grep -q "Tag_ABI_FP_numeric_abi: Soft-float"
    return $?
  fi
  if [[ -f /etc/openwrt_release ]]; then
    grep -q "mips" /etc/openwrt_release
    return $?
  fi
  return 1
}

detect_arch() {
  local machine
  machine="$(uname -m)"

  if [[ "$IS_OPENWRT" == "1" ]] && [[ -f /etc/openwrt_release ]]; then
    local owrt_arch
    owrt_arch=$(grep -oE "DISTRIB_ARCH='[^']+'" /etc/openwrt_release 2>/dev/null | cut -d"'" -f2 || true)
    case "${owrt_arch%%_*}" in
      aarch64) machine="aarch64" ;;
      arm)     machine="armv7l" ;;
      mips|mipsel)
        if detect_mips_softfloat; then
          ARCH="mipsle-sf"
          return 0
        fi
        machine="mipsle"
        ;;
      x86_64)  machine="x86_64" ;;
    esac
  fi

  case "$machine" in
    i386|i686)       ARCH="386" ;;
    x86_64|amd64)  ARCH="amd64" ;;
    armv7l|armv7)  ARCH="arm" ;;
    aarch64|arm64) ARCH="arm64" ;;
    mips|mipsle)
      if detect_mips_softfloat; then
        ARCH="mipsle-sf"
      else
        ARCH="mipsle"
      fi
      ;;
    s390x)         ARCH="s390x" ;;
    loongarch64)   ARCH="loong64" ;;
    riscv64)       ARCH="riscv64" ;;
    *)
      die "不支援的架構: $(uname -m)"
      ;;
  esac
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_INSTALL="apt-get install -y"
    PKG_UPDATE="apt-get update -qq"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_INSTALL="dnf install -y"
    PKG_UPDATE="dnf makecache -q"
  elif command -v yum >/dev/null 2>&1; then
    PKG_INSTALL="yum install -y"
    PKG_UPDATE="yum makecache -q"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_INSTALL="zypper install -y --no-recommends"
    PKG_UPDATE="zypper refresh -q"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_INSTALL="pacman -S --noconfirm"
    PKG_UPDATE="pacman -Sy --noconfirm"
  elif command -v opkg >/dev/null 2>&1; then
    PKG_INSTALL="opkg install"
    PKG_UPDATE="opkg update"
  else
    PKG_INSTALL=""
    PKG_UPDATE=""
  fi
}

install_dependencies() {
  detect_package_manager
  require_command curl

  if [[ "$IS_OPENWRT" == "1" ]]; then
    if [[ -z "${BASH_VERSION:-}" ]]; then
      die "OpenWrt 需要 bash，請執行: opkg update && opkg install bash"
    fi
    if [[ -n "$PKG_INSTALL" ]]; then
      log_step "安裝 OpenWrt 依賴套件..."
      $PKG_UPDATE 2>/dev/null || true
      $PKG_INSTALL bash curl ca-bundle openssl-util 2>/dev/null || true
    fi
  elif [[ -n "$PKG_INSTALL" ]]; then
    log_step "安裝依賴套件..."
    $PKG_UPDATE 2>/dev/null || true
    local pkgs=(curl ca-certificates openssl)
    if [[ "$LEGACY_SYSTEMD" == "1" ]]; then
      pkgs+=(libcap)
    fi
    $PKG_INSTALL "${pkgs[@]}" 2>/dev/null || true
  fi

  if ! command -v grep >/dev/null 2>&1; then
    die "需要 grep 命令，請手動安裝後重試"
  fi
}

check_init_system() {
  if [[ "$IS_OPENWRT" == "1" ]]; then
    return 0
  fi
  if [[ ! -d /run/systemd/system ]] && ! grep -q systemd <(ls -l /sbin/init 2>/dev/null || echo ""); then
    die "此腳本需要 systemd 支援的 Linux 發行版"
  fi
}

extract_version() {
  sed -n 's/.*\(v[0-9][0-9.]*\).*/\1/p' | head -1
}

generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 18 | tr -d '/+=' | head -c 24
  else
    dd if=/dev/urandom bs=18 count=1 status=none 2>/dev/null | base64 | tr -d '/+=' | head -c 24
  fi
}

get_installed_version() {
  if [[ -x "$EXECUTABLE_PATH" ]]; then
    "$EXECUTABLE_PATH" version 2>/dev/null | extract_version || true
  fi
}

get_latest_version() {
  local api_url="${HY2_API_URL}?cver=installscript&plat=linux&arch=${ARCH}&chan=release&side=server"
  local version
  version=$(curl -fsSL "$api_url" | sed -n 's/.*"lver"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)
  if [[ -z "$version" ]]; then
    version=$(curl -fsSL "${REPO_URL}/releases/latest" | sed -n 's/.*tag\/\([^"]*\)".*/\1/p' | head -1 || true)
  fi
  [[ -n "$version" ]] || die "無法取得最新版本，請檢查網路連線"
  echo "$version"
}

download_binary() {
  local version="$1"
  local tmpfile
  tmpfile=$(mktemp /tmp/hysteria.XXXXXX)

  local urls=(
    "${REPO_URL}/releases/download/app/${version}/hysteria-linux-${ARCH}"
    "${DOWNLOAD_BASE}/hysteria-linux-${ARCH}"
  )

  log_step "下載 Hysteria ${version} (${ARCH})..."
  for url in "${urls[@]}"; do
    if curl -fsSL --retry 3 --retry-delay 2 -o "$tmpfile" "$url"; then
      chmod +x "$tmpfile"
      echo "$tmpfile"
      return 0
    fi
    log_warn "下載失敗，嘗試下一個來源: $url"
  done

  rm -f "$tmpfile"
  die "下載 Hysteria 二進位檔失敗"
}

install_binary() {
  local version="${1:-}"
  [[ -n "$version" ]] || version=$(get_latest_version)

  local tmpfile
  tmpfile=$(download_binary "$version")

  log_step "安裝執行檔至 ${EXECUTABLE_PATH}..."
  install -Dm755 "$tmpfile" "$EXECUTABLE_PATH"
  rm -f "$tmpfile"

  local installed
  installed=$("$EXECUTABLE_PATH" version 2>/dev/null | extract_version || true)
  log_info "已安裝版本: ${installed:-unknown}"
}

apply_binary_capabilities() {
  if [[ "$LEGACY_SYSTEMD" != "1" ]]; then
    return 0
  fi
  if ! command -v setcap >/dev/null 2>&1; then
    log_warn "未安裝 setcap（libcap），監聽 1024 以下埠號可能無法啟動"
    return 0
  fi
  log_step "設定執行檔網路權限（相容舊版 systemd）..."
  if ! setcap 'cap_net_bind_service,cap_net_admin,cap_net_raw=+ep' "$EXECUTABLE_PATH" 2>/dev/null; then
    log_warn "setcap 失敗，若使用 1024 以下埠號請改用較高端口或手動設定權限"
  fi
}

remove_binary_capabilities() {
  if [[ -x "$EXECUTABLE_PATH" ]] && command -v setcap >/dev/null 2>&1; then
    setcap -r "$EXECUTABLE_PATH" 2>/dev/null || true
  fi
}

create_user() {
  if [[ "$IS_OPENWRT" == "1" ]]; then
    HYSTERIA_USER="root"
    return 0
  fi
  if id "$HYSTERIA_USER" >/dev/null 2>&1; then
    return 0
  fi
  log_step "建立系統使用者 ${HYSTERIA_USER}..."
  useradd -r -m -d "/var/lib/${HYSTERIA_USER}" -s /usr/sbin/nologin "$HYSTERIA_USER"
}

write_systemd_service() {
  log_step "設定 systemd 服務..."

  local capability_block=""
  if [[ "$LEGACY_SYSTEMD" != "1" ]]; then
    capability_block="
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true"
  fi

  cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Hysteria Server Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${EXECUTABLE_PATH} server --config ${CONFIG_FILE}
WorkingDirectory=/var/lib/${HYSTERIA_USER}
User=${HYSTERIA_USER}
Group=${HYSTERIA_USER}
Environment=HYSTERIA_LOG_LEVEL=info${capability_block}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  cat > "$SYSTEMD_TEMPLATE" <<EOF
[Unit]
Description=Hysteria Server Service (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${EXECUTABLE_PATH} server --config ${CONFIG_DIR}/%i.yaml
WorkingDirectory=/var/lib/${HYSTERIA_USER}
User=${HYSTERIA_USER}
Group=${HYSTERIA_USER}
Environment=HYSTERIA_LOG_LEVEL=info${capability_block}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

write_procd_service() {
  log_step "設定 procd 服務..."

  cat > "$INIT_SCRIPT" <<EOF
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

start_service() {
  procd_open_instance
  procd_set_param command ${EXECUTABLE_PATH} server --config ${CONFIG_FILE}
  procd_set_param respawn
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
EOF

  chmod +x "$INIT_SCRIPT"
}

write_service() {
  if [[ "$IS_OPENWRT" == "1" ]]; then
    write_procd_service
  else
    write_systemd_service
  fi
}

prompt_input() {
  local prompt="$1"
  local default="${2:-}"
  local value

  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " value
    echo "${value:-$default}"
  else
    read -r -p "${prompt}: " value
    echo "$value"
  fi
}

write_config() {
  local domain="$1"
  local email="$2"
  local password="$3"
  local port="$4"
  local masquerade_url="${5:-https://www.bing.com/}"

  mkdir -p "$CONFIG_DIR"

  cat > "$CONFIG_FILE" <<EOF
listen: :${port}

acme:
  domains:
    - ${domain}
  email: ${email}

auth:
  type: password
  password: ${password}

masquerade:
  type: proxy
  proxy:
    url: ${masquerade_url}
    rewriteHost: true
EOF

  if [[ "$IS_OPENWRT" != "1" ]]; then
    chown -R "${HYSTERIA_USER}:${HYSTERIA_USER}" "$CONFIG_DIR"
  fi
  chmod 600 "$CONFIG_FILE"
  log_info "設定檔已寫入: ${CONFIG_FILE}"
}

interactive_config() {
  log_step "互動式設定 Hysteria 伺服器"

  local domain email password port masquerade_url

  domain=$(prompt_input "請輸入網域名稱 (需已解析至本機 IP)")
  [[ -n "$domain" ]] || die "網域名稱不可為空"

  email=$(prompt_input "請輸入 ACME 憑證信箱")
  [[ -n "$email" ]] || die "信箱不可為空"

  port=$(prompt_input "監聽埠號" "$LISTEN_PORT")
  password=$(generate_password)
  log_info "已自動產生密碼: ${password}"

  masquerade_url=$(prompt_input "偽裝網站 URL" "https://www.bing.com/")

  write_config "$domain" "$email" "$password" "$port" "$masquerade_url"

  echo ""
  echo -e "${GREEN}${BOLD}=== 客戶端連線資訊 ===${NC}"
  echo -e "網域:     ${BOLD}${domain}${NC}"
  echo -e "埠號:     ${BOLD}${port}${NC}"
  echo -e "密碼:     ${BOLD}${password}${NC}"
  echo -e "連線 URI: ${BOLD}hysteria2://${password}@${domain}:${port}/?insecure=0&sni=${domain}#Hysteria2${NC}"
  echo ""
}

configure_openwrt_firewall() {
  local port="$1"
  command -v uci >/dev/null 2>&1 || return 0

  if uci show firewall 2>/dev/null | grep -q "name='Allow-Hysteria'"; then
    return 0
  fi

  log_step "開放 OpenWrt 防火牆埠 ${port}/udp..."
  uci add firewall rule >/dev/null
  uci set firewall.@rule[-1].name='Allow-Hysteria'
  uci set firewall.@rule[-1].src='wan'
  uci set firewall.@rule[-1].dest='*'
  uci set firewall.@rule[-1].dest_port="${port}"
  uci set firewall.@rule[-1].proto='udp'
  uci set firewall.@rule[-1].target='ACCEPT'
  uci commit firewall
  /etc/init.d/firewall reload >/dev/null 2>&1 || true
}

configure_firewall() {
  local port="${1:-$LISTEN_PORT}"

  if [[ "$IS_OPENWRT" == "1" ]]; then
    configure_openwrt_firewall "$port"
    return 0
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    log_step "開放 UFW 防火牆埠 ${port}/udp..."
    ufw allow "${port}/udp" >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    log_step "開放 firewalld 防火牆埠 ${port}/udp..."
    firewall-cmd --permanent --add-port="${port}/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

enable_bbr() {
  if [[ "$IS_EL7" == "1" ]] && ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    log_warn "CentOS 7 預設核心不支援 BBR，已跳過（可透過 elrepo 核心啟用）"
    return 0
  fi
  if [[ -f /proc/sys/net/ipv4/tcp_congestion_control ]] && \
     grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    local current
    current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [[ "$current" != "bbr" ]]; then
      log_step "啟用 BBR 拥塞控制..."
      cat > /etc/sysctl.d/99-hysteria-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
      sysctl -p /etc/sysctl.d/99-hysteria-bbr.conf >/dev/null 2>&1 || true
    fi
  fi
}

service_is_active() {
  if [[ "$IS_OPENWRT" == "1" ]]; then
    pgrep -f "${EXECUTABLE_PATH} server" >/dev/null 2>&1
    return $?
  fi
  systemctl is-active --quiet hysteria-server.service
}

start_service() {
  log_step "啟動 Hysteria 服務..."

  if [[ "$IS_OPENWRT" == "1" ]]; then
    /etc/init.d/hysteria-server enable
    /etc/init.d/hysteria-server restart
    sleep 2
    if service_is_active; then
      log_info "Hysteria 服務已成功啟動"
    else
      log_warn "服務啟動失敗，請檢查設定檔與日誌:"
      log_warn "  logread -e hysteria"
    fi
    return 0
  fi

  systemctl enable hysteria-server.service
  systemctl restart hysteria-server.service
  sleep 2

  if service_is_active; then
    log_info "Hysteria 服務已成功啟動"
  else
    log_warn "服務啟動失敗，請檢查設定檔與日誌:"
    log_warn "  journalctl -u hysteria-server.service -e --no-pager"
  fi
}

get_listen_port_from_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    sed -n 's/^listen:[[:space:]]*:\([0-9]*\).*/\1/p' "$CONFIG_FILE" | head -1
  fi
}

do_install() {
  log_step "開始安裝 Hysteria 2"
  install_binary
  apply_binary_capabilities
  create_user
  write_service

  if [[ ! -f "$CONFIG_FILE" ]]; then
    interactive_config
  else
    log_warn "設定檔已存在 (${CONFIG_FILE})，跳過互動式設定"
    log_warn "若要重新設定，請先刪除設定檔後重新執行安裝"
  fi

  local fw_port
  fw_port=$(get_listen_port_from_config)
  configure_firewall "${fw_port:-$LISTEN_PORT}"
  enable_bbr
  start_service

  echo ""
  log_info "安裝完成！"
  echo -e "  編輯設定: ${BLUE}vi ${CONFIG_FILE}${NC}"
  if [[ "$IS_OPENWRT" == "1" ]]; then
    echo -e "  重啟服務: ${BLUE}/etc/init.d/hysteria-server restart${NC}"
    echo -e "  查看狀態: ${BLUE}/etc/init.d/hysteria-server status${NC}"
    echo -e "  查看日誌: ${BLUE}logread -e hysteria${NC}"
  else
    echo -e "  重啟服務: ${BLUE}systemctl restart hysteria-server.service${NC}"
    echo -e "  查看狀態: ${BLUE}systemctl status hysteria-server.service${NC}"
    echo -e "  查看日誌: ${BLUE}journalctl -u hysteria-server.service -e --no-pager${NC}"
  fi
}

do_upgrade() {
  log_step "升級 Hysteria 2"
  local current latest
  current=$(get_installed_version)
  latest=$(get_latest_version)

  log_info "目前版本: ${current:-未安裝}"
  log_info "最新版本: ${latest}"

  install_binary "$latest"
  apply_binary_capabilities

  if [[ "$IS_OPENWRT" == "1" ]]; then
    if [[ -x "$INIT_SCRIPT" ]]; then
      /etc/init.d/hysteria-server restart
      log_info "服務已重啟"
    fi
  elif systemctl is-enabled hysteria-server.service >/dev/null 2>&1; then
    systemctl restart hysteria-server.service
    log_info "服務已重啟"
  fi
}

confirm_yes() {
  local answer
  answer=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$answer" == "y" ]]
}

do_uninstall() {
  log_step "解除安裝 Hysteria 2"

  if [[ "$IS_OPENWRT" == "1" ]]; then
    /etc/init.d/hysteria-server stop 2>/dev/null || true
    /etc/init.d/hysteria-server disable 2>/dev/null || true
    rm -f "$INIT_SCRIPT" "$EXECUTABLE_PATH"

    if command -v uci >/dev/null 2>&1; then
      local rules idx removed=0
      rules=$(uci show firewall 2>/dev/null | grep -E "firewall\.@rule\[[0-9]+\]\.name='Allow-Hysteria'" | cut -d'[' -f2 | cut -d']' -f1 || true)
      for idx in $rules; do
        uci delete "firewall.@rule[${idx}]"
        removed=1
      done
      if [[ "$removed" == "1" ]]; then
        uci commit firewall
        /etc/init.d/firewall reload >/dev/null 2>&1 || true
      fi
    fi
  else
    if systemctl is-active hysteria-server.service >/dev/null 2>&1; then
      systemctl stop hysteria-server.service
    fi
    systemctl disable hysteria-server.service 2>/dev/null || true
    remove_binary_capabilities
    rm -f "$SYSTEMD_SERVICE" "$SYSTEMD_TEMPLATE" "$EXECUTABLE_PATH"
    systemctl daemon-reload
  fi

  read -r -p "是否刪除設定檔目錄 ${CONFIG_DIR}? [y/N]: " confirm
  if confirm_yes "$confirm"; then
    rm -rf "$CONFIG_DIR"
    log_info "已刪除 ${CONFIG_DIR}"
  fi

  if [[ "$IS_OPENWRT" != "1" ]]; then
    read -r -p "是否刪除使用者 ${HYSTERIA_USER}? [y/N]: " confirm
    if confirm_yes "$confirm"; then
      userdel -r "$HYSTERIA_USER" 2>/dev/null || userdel "$HYSTERIA_USER" 2>/dev/null || true
      log_info "已刪除使用者 ${HYSTERIA_USER}"
    fi
  fi

  log_info "解除安裝完成"
}

do_status() {
  echo -e "${BOLD}Hysteria 2 狀態${NC}"
  echo "─────────────────────────────"

  if [[ -x "$EXECUTABLE_PATH" ]]; then
    echo -e "版本:     $("$EXECUTABLE_PATH" version 2>/dev/null | head -1 || echo unknown)"
  else
    echo "版本:     未安裝"
  fi

  if [[ -f "$CONFIG_FILE" ]]; then
    echo "設定檔:   ${CONFIG_FILE} (存在)"
  else
    echo "設定檔:   不存在"
  fi

  if [[ "$IS_OPENWRT" == "1" ]]; then
    if service_is_active; then
      echo -e "服務:     ${GREEN}運行中${NC}"
    elif [[ -x "$INIT_SCRIPT" ]] && ls /etc/rc.d/S*hysteria-server >/dev/null 2>&1; then
      echo -e "服務:     ${YELLOW}已啟用但未運行${NC}"
    else
      echo -e "服務:     ${RED}未安裝或未啟用${NC}"
    fi
    echo ""
    /etc/init.d/hysteria-server status 2>/dev/null || true
  else
    if systemctl is-active hysteria-server.service >/dev/null 2>&1; then
      echo -e "服務:     ${GREEN}運行中${NC}"
    elif systemctl is-enabled hysteria-server.service >/dev/null 2>&1; then
      echo -e "服務:     ${YELLOW}已啟用但未運行${NC}"
    else
      echo -e "服務:     ${RED}未安裝或未啟用${NC}"
    fi
    echo ""
    systemctl status hysteria-server.service --no-pager 2>/dev/null || true
  fi
}

show_help() {
  cat <<EOF

${BOLD}Hysteria 2 一鍵安裝腳本${NC}

用法:
  sudo bash ${SCRIPT_NAME} [命令]

命令:
  install     安裝 Hysteria 2（預設）
  upgrade     升級至最新版本
  uninstall   解除安裝
  status      查看服務狀態
  help        顯示此說明

環境變數:
  HYSTERIA_USER   執行服務的使用者（預設: hysteria）
  LISTEN_PORT     預設監聽埠（預設: 443）

範例:
  sudo bash ${SCRIPT_NAME}
  sudo bash ${SCRIPT_NAME} upgrade
  sudo bash ${SCRIPT_NAME} uninstall

注意:
  - 需要 root 權限
  - 一般 Linux 發行版需要 systemd；OpenWrt 使用 procd
  - 需要已解析至伺服器的網域名稱（ACME 自動申請憑證）
  - 建議使用 Debian 11+、Ubuntu 22.04+、Rocky Linux 8+、CentOS 7+、OpenWrt 21.02+

EOF
}

main() {
  case "$OPERATION" in
    install)
      require_root
      detect_os
      detect_arch
      check_init_system
      install_dependencies
      do_install
      ;;
    upgrade|update)
      require_root
      detect_os
      detect_arch
      install_dependencies
      do_upgrade
      ;;
    uninstall|remove)
      require_root
      detect_os
      do_uninstall
      ;;
    status)
      detect_os
      do_status
      ;;
    help|-h|--help)
      show_help
      ;;
    *)
      die "未知命令: $OPERATION，使用 '$SCRIPT_NAME help' 查看說明"
      ;;
  esac
}

main "$@"