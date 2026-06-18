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

detect_os() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    die "此腳本僅支援 Linux 系統"
  fi
}

detect_arch() {
  case "$(uname -m)" in
    i386|i686)       ARCH="386" ;;
    x86_64|amd64)  ARCH="amd64" ;;
    armv7l|armv7)  ARCH="arm" ;;
    aarch64|arm64) ARCH="arm64" ;;
    mips|mipsle)   ARCH="mipsle" ;;
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
  else
    PKG_INSTALL=""
    PKG_UPDATE=""
  fi
}

install_dependencies() {
  detect_package_manager
  require_command curl

  if [[ -n "$PKG_INSTALL" ]]; then
    log_step "安裝依賴套件..."
    $PKG_UPDATE 2>/dev/null || true
    $PKG_INSTALL curl ca-certificates openssl 2>/dev/null || true
  fi

  if ! command -v grep >/dev/null 2>&1; then
    die "需要 grep 命令，請手動安裝後重試"
  fi
}

check_systemd() {
  if [[ ! -d /run/systemd/system ]] && ! grep -q systemd <(ls -l /sbin/init 2>/dev/null || echo ""); then
    die "此腳本需要 systemd 支援的 Linux 發行版"
  fi
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
    "$EXECUTABLE_PATH" version 2>/dev/null | grep -oP 'v[\d.]+' | head -1 || true
  fi
}

get_latest_version() {
  local api_url="${HY2_API_URL}?cver=installscript&plat=linux&arch=${ARCH}&chan=release&side=server"
  local version
  version=$(curl -fsSL "$api_url" | grep -oP '"lver":\s*"\K[^"]+' | head -1 || true)
  if [[ -z "$version" ]]; then
    version=$(curl -fsSL "${REPO_URL}/releases/latest" | grep -oP 'tag/[^"]+' | head -1 | cut -d/ -f2 || true)
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
  installed=$("$EXECUTABLE_PATH" version 2>/dev/null | grep -oP 'v[\d.]+' | head -1 || true)
  log_info "已安裝版本: ${installed:-unknown}"
}

create_user() {
  if id "$HYSTERIA_USER" >/dev/null 2>&1; then
    return 0
  fi
  log_step "建立系統使用者 ${HYSTERIA_USER}..."
  useradd -r -m -d "/var/lib/${HYSTERIA_USER}" -s /usr/sbin/nologin "$HYSTERIA_USER"
}

write_systemd_service() {
  log_step "設定 systemd 服務..."

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
Environment=HYSTERIA_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
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
Environment=HYSTERIA_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
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

  chown -R "${HYSTERIA_USER}:${HYSTERIA_USER}" "$CONFIG_DIR"
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

configure_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    log_step "開放 UFW 防火牆埠 ${LISTEN_PORT}/udp..."
    ufw allow "${LISTEN_PORT}/udp" >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    log_step "開放 firewalld 防火牆埠 ${LISTEN_PORT}/udp..."
    firewall-cmd --permanent --add-port="${LISTEN_PORT}/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

enable_bbr() {
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

start_service() {
  log_step "啟動 Hysteria 服務..."
  systemctl enable hysteria-server.service
  systemctl restart hysteria-server.service
  sleep 2

  if systemctl is-active --quiet hysteria-server.service; then
    log_info "Hysteria 服務已成功啟動"
  else
    log_warn "服務啟動失敗，請檢查設定檔與日誌:"
    log_warn "  journalctl -u hysteria-server.service -e --no-pager"
  fi
}

do_install() {
  log_step "開始安裝 Hysteria 2"
  install_binary
  create_user
  write_systemd_service

  if [[ ! -f "$CONFIG_FILE" ]]; then
    interactive_config
  else
    log_warn "設定檔已存在 (${CONFIG_FILE})，跳過互動式設定"
    log_warn "若要重新設定，請先刪除設定檔後重新執行安裝"
  fi

  configure_firewall
  enable_bbr
  start_service

  echo ""
  log_info "安裝完成！"
  echo -e "  編輯設定: ${BLUE}nano ${CONFIG_FILE}${NC}"
  echo -e "  重啟服務: ${BLUE}systemctl restart hysteria-server.service${NC}"
  echo -e "  查看狀態: ${BLUE}systemctl status hysteria-server.service${NC}"
  echo -e "  查看日誌: ${BLUE}journalctl -u hysteria-server.service -e --no-pager${NC}"
}

do_upgrade() {
  log_step "升級 Hysteria 2"
  local current latest
  current=$(get_installed_version)
  latest=$(get_latest_version)

  log_info "目前版本: ${current:-未安裝}"
  log_info "最新版本: ${latest}"

  install_binary "$latest"

  if systemctl is-enabled hysteria-server.service >/dev/null 2>&1; then
    systemctl restart hysteria-server.service
    log_info "服務已重啟"
  fi
}

do_uninstall() {
  log_step "解除安裝 Hysteria 2"

  if systemctl is-active hysteria-server.service >/dev/null 2>&1; then
    systemctl stop hysteria-server.service
  fi
  systemctl disable hysteria-server.service 2>/dev/null || true

  rm -f "$SYSTEMD_SERVICE" "$SYSTEMD_TEMPLATE" "$EXECUTABLE_PATH"
  systemctl daemon-reload

  read -r -p "是否刪除設定檔目錄 ${CONFIG_DIR}? [y/N]: " confirm
  if [[ "${confirm,,}" == "y" ]]; then
    rm -rf "$CONFIG_DIR"
    log_info "已刪除 ${CONFIG_DIR}"
  fi

  read -r -p "是否刪除使用者 ${HYSTERIA_USER}? [y/N]: " confirm
  if [[ "${confirm,,}" == "y" ]]; then
    userdel -r "$HYSTERIA_USER" 2>/dev/null || userdel "$HYSTERIA_USER" 2>/dev/null || true
    log_info "已刪除使用者 ${HYSTERIA_USER}"
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

  if systemctl is-active hysteria-server.service >/dev/null 2>&1; then
    echo -e "服務:     ${GREEN}運行中${NC}"
  elif systemctl is-enabled hysteria-server.service >/dev/null 2>&1; then
    echo -e "服務:     ${YELLOW}已啟用但未運行${NC}"
  else
    echo -e "服務:     ${RED}未安裝或未啟用${NC}"
  fi

  echo ""
  systemctl status hysteria-server.service --no-pager 2>/dev/null || true
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
  - 需要 root 權限與 systemd
  - 需要已解析至伺服器的網域名稱（ACME 自動申請憑證）
  - 建議使用 Debian 11+、Ubuntu 22.04+、Rocky Linux 8+

EOF
}

main() {
  case "$OPERATION" in
    install)
      require_root
      detect_os
      detect_arch
      check_systemd
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
      do_uninstall
      ;;
    status)
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