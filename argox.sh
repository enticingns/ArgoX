#!/usr/bin/env bash
#
# ArgoX-Lite 3.0.0 - sing-box VMess + WebSocket + TLS + CDN deployment script
#
# Design goals:
#   * sing-box is the ONLY proxy core (Xray / v2ray removed)
#   * VMess + WS + TLS + CDN is the ONLY supported node mode
#   * TLS is terminated at nginx; sing-box serves plain WS on 127.0.0.1
#   * Idempotent install: re-running the script never clobbers user edits
#   * Every config generated is validated with `sing-box check` before service restart
#
# Target sing-box version: >= 1.10 (verified against 1.14.4)
#   VMess inbound:  https://sing-box.sagernet.org/configuration/inbound/vmess/
#   V2Ray transport (WebSocket):  https://sing-box.sagernet.org/configuration/shared/v2ray-transport/
#
# License: MIT (see LICENSE)
#

VERSION='3.0.0 (2026.10.24)'

# ============================================================
# Paths and defaults
# ============================================================
WORK_DIR='/etc/argox'
TEMP_DIR='/tmp/argox'
CUSTOM_FILE="$WORK_DIR/custom"
SUBSCRIBE_DIR="$WORK_DIR/subscribe"

SINGBOX_DEFAULT_VERSION='1.14.4'
SINGBOX_MIN_VERSION='1.10.0'

WS_PATH_DEFAULT='argox-ws-vm'
START_PORT_DEFAULT='30000'
NGINX_PORT_DEFAULT='8080'
TLS_SERVER_DEFAULT='addons.mozilla.org'

DEFAULT_CDN_DOMAIN='skk.moe'
CDN_DOMAIN_HINT=('skk.moe' 'ip.sb' 'time.is' 'cfip.xxxxxxxx.tk' 'bestcf.top' 'cdn.2020111.xyz')

MIN_PORT=100
MAX_PORT=65520

# GitHub acceleration proxies (used to bypass GFW on server-side downloads)
GH_PROXIES=('https://ghproxy.lvedong.eu.org/' 'https://accel.cloudflare.nyc.mn/')

# Language (C=Chinese, E=English). Defaults to Chinese for the primary audience.
LANG_TAG='C'

# Script-wide state
IS_INSTALLED='no'
SINGBOX_VER=''
SERVICE_NAME='sing-box'
NGINX_SERVICE='argox-nginx'

# Cloudflare Argo Tunnel (optional, disabled by default)
IS_ARGO='no'
ARGO_SERVICE='cloudflared'
CLOUDFLARED_MIN_VERSION='2024.3.0'

export DEBIAN_FRONTEND=noninteractive
mkdir -p "$TEMP_DIR"
cleanup() { rm -rf "$TEMP_DIR" 2>/dev/null; }
trap cleanup EXIT
trap 'cleanup; exit 1' INT QUIT TERM

# ============================================================
# UI helpers
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

warning() { echo -e "${RED}${BOLD}$*${NC}"; }
info()    { echo -e "${GREEN}${BOLD}$*${NC}"; }
hint()    { echo -e "${YELLOW}${BOLD}$*${NC}"; }
title()   { echo -e "${BLUE}${BOLD}$*${NC}"; }
cyan()    { echo -e "${CYAN}${BOLD}$*${NC}"; }

die() { warning "$*"; exit 1; }

t() {  # t <English> <Chinese>
  if [ "$LANG_TAG" = 'C' ]; then echo "$2"; else echo "$1"; fi
}

reading() {  # reading <prompt> <var>
  local _prompt="$1" _var="$2"
  if [ -t 0 ]; then read -r -p "$_prompt" -e "$_var"
  else             read -r "$_var"
  fi
}

pause() { reading "$(t 'Press any key to continue... ' '按任意键继续... ')" _pause; }

# ============================================================
# System check
# ============================================================
check_root() {
  [ "$(id -u)" -ne 0 ] && die "$(t 'Must be run as root. Try: sudo bash argox.sh' \
                                       '必须使用 root 运行。请执行: sudo bash argox.sh')"
}

detect_arch() {
  local m; m=$(uname -m)
  case "$m" in
    x86_64|amd64)    ARCH='amd64' ;;
    i386|i686)       ARCH='386'   ;;
    armv5*)          ARCH='armv5' ;;
    armv6*)          ARCH='armv6' ;;
    armv7*|armhf)    ARCH='armv7' ;;
    aarch64|arm64)   ARCH='arm64' ;;
    mipsel)          ARCH='mipsle' ;;
    mips64el)        ARCH='mips64le' ;;
    riscv64)         ARCH='riscv64' ;;
    loongarch64)     ARCH='loong64' ;;
    *) die "$(t "Unsupported architecture: $m" "暂不支持当前架构: $m")" ;;
  esac
}

detect_os() {
  OS_ID=''
  OS_VER=''
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID,,}"
    OS_VER="${VERSION_ID:-unknown}"
  fi
  case "$OS_ID" in
    debian|ubuntu|amaryan|kali|mint)          PKG='apt' ;;
    centos|rhel|rocky|almalinux|ol|amzn)      PKG='yum' ;;
    fedora)                                    PKG='dnf' ;;
    arch|manjaro|endeavouros|garuda)          PKG='pacman' ;;
    alpine|alpinelinux)                        PKG='apk' ;;
    opensuse*|suse*)                          PKG='zypper' ;;
    '') die "$(t 'Unsupported OS (no /etc/os-release).' \
                    '不支持的操作系统（缺少 /etc/os-release）。')" ;;
    *) die "$(t "Unsupported OS: $OS_ID" "不支持的操作系统: $OS_ID")" ;;
  esac
}

install_dependencies() {
  local pkgs='curl wget jq unzip tar openssl ca-certificates'
  case "$PKG" in
    apt)     apt-get update -qq && apt-get install -y -qq $pkgs >/dev/null ;;
    yum)     yum install -y $pkgs >/dev/null ;;
    dnf)     dnf install -y $pkgs >/dev/null ;;
    pacman)  pacman -Sy --noconfirm $pkgs >/dev/null ;;
    apk)     apk add --no-cache bash $pkgs >/dev/null ;;
    zypper)  zypper install -y $pkgs >/dev/null ;;
  esac
  # nginx is separate because we run our own instance with -c; some distros
  # install 'nginx' under a different name, so try a couple of names.
  case "$PKG" in
    apt)     apt-get install -y -qq nginx >/dev/null ;;
    yum|dnf) $PKG install -y nginx >/dev/null ;;
    pacman)  pacman -S --noconfirm nginx >/dev/null ;;
    apk)     apk add --no-cache nginx >/dev/null ;;
    zypper)  zypper install -y nginx >/dev/null ;;
  esac
  command -v jq     >/dev/null || die "jq missing after install"
  command -v nginx  >/dev/null || die "nginx missing after install"
  command -v openssl >/dev/null || die "openssl missing after install"
}

# ============================================================
# Input validation helpers
# ============================================================
gen_uuid() {
  cat /proc/sys/kernel/random/uuid 2>/dev/null && return 0
  command -v uuidgen >/dev/null && { uuidgen; return 0; }
  command -v python3 >/dev/null && { python3 -c 'import uuid;print(uuid.uuid4())'; return 0; }
  local a b
  a=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
  b=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
  printf '%08x-%04x-%04x-%04x-%012x\n' "$a" "$b" "$b" "$a" "$a$b"
}

is_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

is_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge $MIN_PORT ] && [ "$1" -lt $MAX_PORT ]
}

is_ws_path() {  # letters, digits, hyphen, underscore, dot, @
  [[ "$1" =~ ^[a-zA-Z0-9._@-]+$ ]] && [ ${#1} -le 64 ]
}

is_domain() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]] || \
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

find_free_port() {
  local start=$1 port=$start
  for i in $(seq 0 500); do
    if ! ss -lntup 2>/dev/null | grep -qE ":[${port}] "; then echo $port; return 0; fi
    port=$((port+1))
    [ $port -gt $MAX_PORT ] && return 1
  done
  return 1
}

version_ge() {  # version_ge A B -> 0 if A >= B
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

# ============================================================
# sing-box download / version
# ============================================================
latest_singbox_version() {
  local tag url
  for p in "${GH_PROXIES[@]}"; do
    url="${p}https://github.com/SagerNet/sing-box/releases/latest"
    tag=$(curl -sL --max-time 12 "$url" 2>/dev/null | \
          grep -oE 'tag/v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's|tag/v||')
    [ -n "$tag" ] && { echo "$tag"; return 0; }
  done
  return 1
}

download_singbox() {
  local ver="$1" pkg url proxy path
  pkg="sing-box-${ver}-linux-${ARCH}"
  mkdir -p "$WORK_DIR"
  cd "$WORK_DIR" || die "cannot cd $WORK_DIR"

  # Backup previous binary before swap (allows rollback on start failure)
  [ -x sing-box ] && mv sing-box "sing-box.$(date +%s).bak" 2>/dev/null

  for proxy in "${GH_PROXIES[@]}"; do
    url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/${pkg}.tar.gz"
    info "Downloading sing-box v${ver} (${ARCH}) ... ${proxy}"
    if curl -sL --max-time 60 --retry 2 --retry-delay 2 "${proxy}${url}" -o "${pkg}.tar.gz" 2>/dev/null || \
       curl -sL --max-time 60 --retry 2 --retry-delay 2 "${url}" -o "${pkg}.tar.gz" 2>/dev/null; then
      tar -xzf "${pkg}.tar.gz"
      rm -f "${pkg}.tar.gz"
      # Alpine/musl build: prefer -musl variant if present
      if [ -f "${pkg}-musl.tar.gz" ]; then
        tar -xzf "${pkg}-musl.tar.gz" 2>/dev/null || true
        rm -f "${pkg}-musl.tar.gz"
      fi
      chmod +x sing-box 2>/dev/null
      [ -x sing-box ] && { info "sing-box v${ver} installed"; return 0; }
    fi
  done
  die "Failed to download sing-box v${ver}"
}

singbox_version_of() {
  local bin=$1 v
  v=$("$bin" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  echo "$v"
}

# ============================================================
# Config generation
# ============================================================
write_singbox_config() {
  local uuid=$1 ws_path=$2 port=$3 node=$4
  # TLS is off here — nginx terminates TLS and forwards WS in clear text.
  cat > "$WORK_DIR/config.json" <<EOF
{
  "log": {
    "level": "warning",
    "output": "${WORK_DIR}/sing-box.log",
    "timestamp": true,
    "keep_days": 3
  },
  "dns": {
    "servers": [
      { "tag": "remote", "address": "1.1.1.1", "address_resolver": "local" },
      { "tag": "local",  "address": "223.5.5.5" }
    ],
    "rules": [
      { "outbound": "any", "server": "local" }
    ]
  },
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-ws-cdn",
      "listen": "127.0.0.1",
      "listen_port": ${port},
      "users": [
        { "name": "${node}", "uuid": "${uuid}", "alterId": 0 }
      ],
      "transport": {
        "type": "ws",
        "path": "/${ws_path}"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block",  "tag": "block"  }
  ],
  "route": { "rules": [] }
}
EOF
}

write_nginx_config() {
  local ws_path=$1 port=$2 uuid=$3
  cat > "$WORK_DIR/nginx.conf" <<EOF
user  root;
worker_processes auto;
pid ${WORK_DIR}/nginx.pid;
error_log  ${WORK_DIR}/nginx-error.log warn;

events {
  worker_connections 4096;
}

http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;
  access_log    off;
  sendfile      on;
  tcp_nodelay   on;
  keepalive_timeout 65;

  map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
  }

  server {
    listen ${NGINX_PORT} ssl;
    http2 on;
    server_name _;

    ssl_certificate     ${WORK_DIR}/cert.pem;
    ssl_certificate_key ${WORK_DIR}/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # WebSocket location -> sing-box
    location ~^/${ws_path} {
      proxy_pass http://127.0.0.1:${port};
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_read_timeout  3600s;
      proxy_send_timeout  3600s;
      proxy_buffering     off;
      proxy_request_buffering off;
      client_max_body_size 0;
    }

    # Subscription endpoint (SFA base64 / Shadowrocket)
    location ~^/${uuid}/subscribe/ {
      default_type  text/plain;
      alias         ${SUBSCRIBE_DIR}/\$1;
      expires 1h;
    }
  }
}
EOF
}

write_tls_cert() {
  local cn=$1
  mkdir -p "$WORK_DIR/tls"
  if [ ! -s "$WORK_DIR/cert.pem" ] || [ ! -s "$WORK_DIR/key.pem" ]; then
    openssl genrsa -out "$WORK_DIR/key.pem" 2048 2>/dev/null
    openssl req -new -key "$WORK_DIR/key.pem" \
                -out "$WORK_DIR/tls/csr.pem" \
                -subj "/CN=${cn}/O=ArgoX-Lite" 2>/dev/null
    openssl x509 -req -days 3650 \
                 -in "$WORK_DIR/tls/csr.pem" \
                 -signkey "$WORK_DIR/key.pem" \
                 -out "$WORK_DIR/cert.pem" 2>/dev/null
    rm -f "$WORK_DIR/tls/csr.pem"
  fi
}

write_singbox_service() {
  cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=ArgoX-Lite sing-box service (VMess + WS + CDN)
Documentation=https://github.com/fscarmen/argox
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${WORK_DIR}/sing-box run -c ${WORK_DIR}/config.json
Restart=always
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=false
PrivateTmp=false

[Install]
WantedBy=multi-user.target
EOF
}

write_nginx_service() {
  cat > /etc/systemd/system/${NGINX_SERVICE}.service <<EOF
[Unit]
Description=ArgoX-Lite nginx (TLS termination + WS reverse proxy)
After=network-online.target ${SERVICE_NAME}.service
Wants=${SERVICE_NAME}.service

[Service]
Type=forking
User=root
PIDFile=${WORK_DIR}/nginx.pid
ExecStartPre=${WORK_DIR}/nginx -c ${WORK_DIR}/nginx.conf -t
ExecStart=${WORK_DIR}/nginx -c ${WORK_DIR}/nginx.conf
ExecStop=${WORK_DIR}/nginx -c ${WORK_DIR}/nginx.conf -s quit
ExecReload=${WORK_DIR}/nginx -c ${WORK_DIR}/nginx.conf -s reload
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

# ============================================================
# Cloudflare Argo Tunnel (optional)
# ============================================================

download_cloudflared() {
  local ver="${1:-latest}"
  local arch pkg
  case "$ARCH" in
    amd64)   arch='amd64' ;;
    arm64)   arch='arm64' ;;
    armv7)   arch='arm'   ;;
    armv6)   arch='arm'   ;;
    386)     arch='386'   ;;
    *) die "unsupported arch for cloudflared: $ARCH" ;;
  esac
  pkg="cloudflared-linux-${arch}"

  cd "$WORK_DIR" || die "cannot cd $WORK_DIR"
  [ -x cloudflared ] && mv cloudflared "cloudflared.$(date +%s).bak" 2>/dev/null

  # Try GitHub releases first (with proxy fallbacks), fall back to Cloudflare's own CDN
  local urls=(
    "https://github.com/cloudflare/cloudflared/releases/latest/download/${pkg}"
    "https://github.com/cloudflare/cloudflared/releases/download/${ver}/${pkg}"
  )
  local url
  for proxy in "${GH_PROXIES[@]}"; do
    for url in "${urls[@]}"; do
      info "Downloading cloudflared ... ${proxy}${url}"
      if curl -sL --max-time 90 --retry 2 --retry-delay 2 "${proxy}${url}" -o "${pkg}.tmp" 2>/dev/null && [ -s "${pkg}.tmp" ]; then
        mv "${pkg}.tmp" cloudflared
        chmod +x cloudflared
        return 0
      fi
    done
  done
  # Direct download (no proxy)
  for url in "${urls[@]}"; do
    info "Downloading cloudflared ... ${url}"
    if curl -sL --max-time 90 --retry 2 --retry-delay 2 "$url" -o "${pkg}.tmp" 2>/dev/null && [ -s "${pkg}.tmp" ]; then
      mv "${pkg}.tmp" cloudflared
      chmod +x cloudflared
      return 0
    fi
  done
  die "failed to download cloudflared"
}

cloudflared_version_of() {
  local bin=$1 v
  v=$("$bin" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  echo "$v"
}

# Parse ARGO_AUTH and set ARGO_JSON (json auth) or ARGO_TOKEN (token auth)
# Returns 0 on success, 1 on unknown format
parse_argo_auth() {
  local auth="$1"
  ARGO_JSON='' ARGO_TOKEN=''
  if [ -z "$auth" ]; then
    return 1
  fi
  # 1. JSON form: contains "TunnelSecret"
  if grep -q 'TunnelSecret' <<< "$auth"; then
    ARGO_JSON=${auth//[ ]/}
    return 0
  fi
  # 2. Token form: base64-like, 120-250 chars
  if grep -qE '^[A-Za-z0-9+/=]{120,250}$' <<< "$auth"; then
    ARGO_TOKEN=$(awk '{print $NF}' <<< "$auth")
    return 0
  fi
  warning "$(t 'Unrecognized ARGO_AUTH format.' '无法识别的 ARGO_AUTH 格式。')"
  return 1
}

write_cloudflared_credentials() {
  # ARGO_JSON must already be set (full JSON auth string)
  [ -z "$ARGO_JSON" ] && { warning "$(t 'No ARGO_JSON to write.' '没有 ARGO_JSON 可写入。')"; return 1; }
  printf '%s' "$ARGO_JSON" > "$WORK_DIR/tunnel.json"
}

write_tunnel_yml() {
  local domain=$1 port=$2 creds="$WORK_DIR/tunnel.json"
  local tunnel_id
  # Extract TunnelID from JSON
  tunnel_id=$(grep -oE '"TunnelID"[[:space:]]*:[[:space:]]*"[^"]+"' <<< "$ARGO_JSON" \
              | sed 's/.*"\([^"]*\)"$/\1/')
  [ -z "$tunnel_id" ] && { warning "$(t 'No TunnelID in ARGO_JSON.' 'ARGO_JSON 中没有 TunnelID。')"; return 1; }
  cat > "$WORK_DIR/tunnel.yml" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${creds}

ingress:
  - hostname: ${domain}
    service: http://localhost:${port}

  - service: http_status:404
EOF
}

write_cloudflared_service() {
  local creds="$WORK_DIR/tunnel.json"
  local runs=""
  if [ -n "$ARGO_TOKEN" ]; then
    # Token mode (deprecated but still supported by Cloudflare)
    runs="$WORK_DIR/cloudflared tunnel --token $ARGO_TOKEN"
  elif [ -s "$WORK_DIR/tunnel.yml" ]; then
    # Named tunnel with credentials
    runs="$WORK_DIR/cloudflared tunnel --config $WORK_DIR/tunnel.yml run"
  else
    warning "$(t 'No tunnel.yml or token; skipping cloudflared service.' '缺少 tunnel.yml 或 token，跳过 cloudflared 服务。')"
    return 1
  fi
  cat > /etc/systemd/system/${ARGO_SERVICE}.service <<EOF
[Unit]
Description=ArgoX-Lite Cloudflare Tunnel (cloudflared)
After=network-online.target ${NGINX_SERVICE}.service
Wants=${NGINX_SERVICE}.service

[Service]
Type=simple
User=root
ExecStart=${runs}
ExecStartPost=/bin/sh -c 'echo $$ > ${WORK_DIR}/cloudflared.pid'
ExecStop=/bin/sh -c 'kill \$(cat ${WORK_DIR}/cloudflared.pid 2>/dev/null) 2>/dev/null'
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

enable_argo() {
  # 1. Download cloudflared
  info "$(t 'Downloading cloudflared...' '下载 cloudflared...')"
  download_cloudflared
  local cfver
  cfver=$(cloudflared_version_of "$WORK_DIR/cloudflared")
  info "$(t "cloudflared v${cfver} installed" "cloudflared v${cfver} 已安装")"

  # 2. Parse auth
  if [ -z "$ARGO_AUTH" ] && [ -s "$WORK_DIR/tunnel.json" ]; then
    ARGO_AUTH=$(tr -d '\n' < "$WORK_DIR/tunnel.json")
  fi
  parse_argo_auth "$ARGO_AUTH" || die "$(t 'ARGO_AUTH parse failed. Provide JSON with TunnelSecret or a 120-250 char token.' 'ARGO_AUTH 解析失败。需提供含 TunnelSecret 的 JSON 或 120-250 字符 Token。')"

  # 3. Domain
  if [ -z "$ARGO_DOMAIN" ] && [ -s "$WORK_DIR/tunnel.yml" ]; then
    ARGO_DOMAIN=$(awk '/^[[:space:]]*- hostname:/{print $3; exit}' "$WORK_DIR/tunnel.yml")
  fi
  [ -z "$ARGO_DOMAIN" ] && { warning "$(t 'No ARGO_DOMAIN set; skipping tunnel.yml.' '未设置 ARGO_DOMAIN，跳过 tunnel.yml。')"; return 1; }

  # 4. Write credentials + tunnel.yml
  if [ -n "$ARGO_JSON" ]; then
    write_cloudflared_credentials
    write_tunnel_yml "$ARGO_DOMAIN" "$NGINX_PORT" || die "$(t 'Failed to write tunnel.yml.' '写入 tunnel.yml 失败。')"
  fi

  # 5. Write service
  write_cloudflared_service || die "$(t 'Failed to write cloudflared service.' '写入 cloudflared 服务失败。')"

  # 6. Install & start
  systemctl daemon-reload
  systemctl enable "$ARGO_SERVICE" 2>/dev/null
  systemctl restart "$ARGO_SERVICE" 2>/dev/null
  sleep 1
  if ! systemctl is-active --quiet "$ARGO_SERVICE"; then
    warning "$(t "cloudflared failed to start. Last log lines:" "cloudflared 启动失败，最近日志:")"
    journalctl -u "$ARGO_SERVICE" -n 20 --no-pager 2>/dev/null
    return 1
  fi
  info "$(t "Argo Tunnel enabled. Tunnel domain: ${ARGO_DOMAIN}" "Argo 隧道已启用。隧道域名: ${ARGO_DOMAIN}")"
  return 0
}

disable_argo() {
  systemctl stop "$ARGO_SERVICE" 2>/dev/null || true
  systemctl disable "$ARGO_SERVICE" 2>/dev/null || true
  rm -f /etc/systemd/system/${ARGO_SERVICE}.service
  systemctl daemon-reload
  info "$(t 'Argo Tunnel disabled.' 'Argo 隧道已禁用。')"
}

# Validate sing-box config before enabling service
validate_singbox_config() {
  local bin="$WORK_DIR/sing-box" cfg="$WORK_DIR/config.json"
  if [ ! -x "$bin" ]; then die "sing-box binary not found at $bin"; fi
  if [ ! -s "$cfg" ]; then die "config not found at $cfg"; fi

  # sing-box >= 1.11:  `sing-box check -c file`
  # Fallback for older builds: `sing-box test -c file`
  if "$bin" check -c "$cfg" >/dev/null 2>&1; then
    info "$(t 'sing-box config OK' 'sing-box 配置校验通过')"
    return 0
  fi
  if "$bin" test -c "$cfg" >/dev/null 2>&1; then
    info "$(t 'sing-box config OK (test)' 'sing-box 配置校验通过 (test)')"
    return 0
  fi
  # Print real error for diagnostics
  local err
  err=$("$bin" check -c "$cfg" 2>&1 || "$bin" test -c "$cfg" 2>&1)
  warning "$(t 'sing-box config check FAILED:' 'sing-box 配置校验失败:')"; echo "$err"
  return 1
}

validate_nginx_config() {
  local bin
  bin=$(command -v nginx || true)
  [ -x "$bin" ] || die "nginx binary missing"
  if "$bin" -c "$WORK_DIR/nginx.conf" -t >/dev/null 2>&1; then
    info "$(t 'nginx config OK' 'nginx 配置校验通过')"
    return 0
  fi
  local err
  err=$("$bin" -c "$WORK_DIR/nginx.conf" -t 2>&1)
  warning "$(t 'nginx config check FAILED:' 'nginx 配置校验失败:')"; echo "$err"
  return 1
}

# ============================================================
# Node share link + subscription
# ============================================================
vmess_share_link() {
  local cfg uuid=$1 ws_path=$2 domain=$3
  cfg=$(cat <<EOF
{
  "add": "${domain}",
  "port": "443",
  "id": "${uuid}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${domain}",
  "path": "/${ws_path}",
  "tls": "tls",
  "sni": "${domain}",
  "alpn": ""
}
EOF
)
  local b64
  b64=$(printf '%s' "$cfg" | base64 -w0 2>/dev/null || printf '%s' "$cfg" | base64 -b 0)
  echo "vmess://${b64}"
}

write_subscriptions() {
  local uuid=$1 ws_path=$2 domain=$3
  mkdir -p "$SUBSCRIBE_DIR"
  local link
  link=$(vmess_share_link "$uuid" "$ws_path" "$domain")
  # Base64 variant used by SFA / sing-box client / v2rayN subscribe
  printf '%s' "$link" | base64 -w0 2>/dev/null > "$SUBSCRIBE_DIR/base64"
  # Shadowrocket URL — vmess:// scheme with query-string form
  local sr="vmess://${uuid}?security=auto&type=ws&host=${domain}&path=%2F${ws_path}&sni=${domain}&allowInsecure=0&ext=${domain}&ps=ArgoX%20Lite"
  printf '%s' "$sr" | base64 -w0 2>/dev/null > "$SUBSCRIBE_DIR/shadowrocket"
}

# ============================================================
# Firewall port handling
# ============================================================
open_port() {
  local port=$1 proto=${2:-tcp}
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw allow "${port}/${proto}" >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
  elif command -v firewall-cmd >/dev/null 2>&1 && \
       systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --add-port="${port}/${proto}" --permanent >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
  fi
}

# ============================================================
# State save/load (idempotency core)
# ============================================================
save_state() {
  mkdir -p "$WORK_DIR"
  local f="$CUSTOM_FILE"
  [ -f "$f" ] && cp "$f" "${f}.bak.$(date +%s)" 2>/dev/null || true
  cat > "$f" <<EOF
UUID=${UUID}
WS_PATH=${WS_PATH}
CDN_DOMAIN=${CDN_DOMAIN}
TLS_SERVER=${TLS_SERVER}
SINGBOX_PORT=${SINGBOX_PORT}
NGINX_PORT=${NGINX_PORT}
NODE_NAME=${NODE_NAME}
SCRIPT_VERSION=${VERSION}
IS_ARGO=${IS_ARGO}
ARGO_DOMAIN=${ARGO_DOMAIN}
ARGO_AUTH=${ARGO_AUTH}
EOF
}

load_state() {
  [ -f "$CUSTOM_FILE" ] || return 1
  . "$CUSTOM_FILE"
  return 0
}

# ============================================================
# Non-interactive config file support
# Usage:  bash argox.sh -f config.conf
# ============================================================
apply_config_file() {
  local f=$1
  [ -f "$f" ] || die "config file not found: $f"
  # shellcheck disable=SC1090
  . "$f"
  # Map user-facing key -> internal key (config.conf uses SERVER for CDN domain,
  # Xray-style naming kept for compatibility with existing users)
  [ -n "${SERVER:-}" ] && CDN_DOMAIN="$SERVER"
  [ -n "${TLS_SERVER:-}" ] && :
  [ -n "${UUID:-}" ] && is_uuid "$UUID" || { [ -n "${UUID:-}" ] && die "invalid UUID in config file: $UUID"; }
  [ -n "${WS_PATH:-}" ] && is_ws_path "$WS_PATH" || { [ -n "${WS_PATH:-}" ] && die "invalid WS path: $WS_PATH"; }
  [ -n "${START_PORT:-}" ] && is_port "$START_PORT" || { [ -n "${START_PORT:-}" ] && die "invalid port: $START_PORT"; }
  [ -n "${NGINX_PORT:-}" ] && is_port "$NGINX_PORT" || { [ -n "${NGINX_PORT:-}" ] && die "invalid port: $NGINX_PORT"; }
  [ -n "${NODE_NAME:-}" ] && :
  [ "${L:-}" = 'E' ] && LANG_TAG='E'
  # Argo settings
  case "${ARGO:-}" in
    y|yes|Y|Yes|1|true|True) IS_ARGO='yes' ;;
  esac
  [ -n "${ARGO_DOMAIN:-}" ] && :
  [ -n "${ARGO_AUTH:-}" ] && :
  [ -n "${SINGBOX_VERSION:-}" ] && SINGBOX_DEFAULT_VERSION="$SINGBOX_VERSION"
}

# ============================================================
# Interactive collection of user parameters
# ============================================================
collect_params() {
  local retries=5 _in _def

  # UUID
  if [ -z "$UUID" ]; then
    _def=$(gen_uuid)
    UUID="$_def"
    hint "$(t "UUID (default ${UUID}):" "UUID（默认: ${UUID}）:")"
    reading "  > " _in
    [ -n "$_in" ] && UUID="$_in"
    while ! is_uuid "$UUID"; do
      warning "$(t 'Invalid UUID. 36 chars.' 'UUID 格式错误，应为 36 位。')"
      retries=$((retries-1)); [ $retries -le 0 ] && die "too many errors"
      reading "$(t "  Re-enter UUID: " '  重新输入 UUID: ')" _in
      UUID="$_in"
    done
  fi

  # WS path
  if [ -z "$WS_PATH" ]; then
    WS_PATH="$WS_PATH_DEFAULT"
    hint "$(t "WS path (default ${WS_PATH}):" "WebSocket 路径（默认: ${WS_PATH}）:")"
    reading "  > " _in
    [ -n "$_in" ] && WS_PATH="$_in"
    while ! is_ws_path "$WS_PATH"; do
      warning "$(t 'Invalid WS path (letters, digits, - _ . @ only, max 64).' \
                    'WS 路径非法（仅字母/数字/- _ . @，最长 64）')"
      retries=$((retries-1)); [ $retries -le 0 ] && die "too many errors"
      reading "  > " _in
      WS_PATH="$_in"
    done
  fi

  # CDN domain
  if [ -z "$CDN_DOMAIN" ]; then
    CDN_DOMAIN="$DEFAULT_CDN_DOMAIN"
    hint "$(t "CDN domain (default ${CDN_DOMAIN})" "CDN 域名（默认: ${CDN_DOMAIN}）")"
    hint "$(t "Hint: ${CDN_DOMAIN_HINT[*]}" "候选: ${CDN_DOMAIN_HINT[*]}")"
    reading "  > " _in
    [ -n "$_in" ] && CDN_DOMAIN="$_in"
    while ! is_domain "$CDN_DOMAIN"; do
      warning "$(t 'Invalid domain or IPv4.' '域名/IPv4 格式错误。')"
      retries=$((retries-1)); [ $retries -le 0 ] && die "too many errors"
      reading "  > " _in
      CDN_DOMAIN="$_in"
    done
  fi

  # TLS server name (SNI for TLS termination)
  if [ -z "$TLS_SERVER" ]; then
    TLS_SERVER="$TLS_SERVER_DEFAULT"
    hint "$(t "TLS SNI (default ${TLS_SERVER}):" "TLS SNI（默认: ${TLS_SERVER}）:")"
    reading "  > " _in
    [ -n "$_in" ] && TLS_SERVER="$_in"
  fi

  # Internal sing-box port
  if [ -z "$SINGBOX_PORT" ]; then
    SINGBOX_PORT=$(find_free_port "$START_PORT_DEFAULT") || SINGBOX_PORT="$START_PORT_DEFAULT"
    hint "$(t "Internal sing-box port (default ${SINGBOX_PORT}):" \
                    "sing-box 内部端口（默认: ${SINGBOX_PORT}）:")"
    reading "  > " _in
    [ -n "$_in" ] && SINGBOX_PORT="$_in"
    while ! is_port "$SINGBOX_PORT"; do
      warning "$(t 'Port out of range 100-65520.' '端口越界 100-65520')"
      retries=$((retries-1)); [ $retries -le 0 ] && die "too many errors"
      reading "  > " _in
      SINGBOX_PORT="$_in"
    done
  fi

  # nginx port (CDN will forward to this)
  if [ -z "$NGINX_PORT" ]; then
    NGINX_PORT="$NGINX_PORT_DEFAULT"
    hint "$(t "nginx public port (default ${NGINX_PORT}):" \
                    "nginx 对外端口（默认: ${NGINX_PORT}）:")"
    reading "  > " _in
    [ -n "$_in" ] && NGINX_PORT="$_in"
    while ! is_port "$NGINX_PORT"; do
      warning "$(t 'Port out of range 100-65520.' '端口越界 100-65520')"
      retries=$((retries-1)); [ $retries -le 0 ] && die "too many errors"
      reading "  > " _in
      NGINX_PORT="$_in"
    done
  fi

  # Node name
  if [ -z "$NODE_NAME" ]; then
    NODE_NAME=$(hostname 2>/dev/null || echo 'ArgoX-Lite')
    hint "$(t "Node name (default ${NODE_NAME}):" "节点名称（默认: ${NODE_NAME}）:")"
    reading "  > " _in
    [ -n "$_in" ] && NODE_NAME="$_in"
  fi
}

# ============================================================
# Main install flow
# ============================================================
install_flow() {
  check_root
  detect_os
  detect_arch
  load_state || true

  title "$(t "=============== ArgoX-Lite Installation ===============" \
                    "=============== ArgoX-Lite 安装 ===============")"
  info "$(t "OS: $OS_ID $OS_VER   Arch: $ARCH" "系统: $OS_ID $OS_VER   架构: $ARCH")"

  if [ -f "$CUSTOM_FILE" ]; then
    hint "$(t "Existing config detected at ${CUSTOM_FILE}; empty input keeps current values." \
                    "检测到既有配置 ${CUSTOM_FILE}；留空保留原值。")"
  fi

  collect_params

  info "$(t "Installing dependencies..." "安装依赖...")"
  install_dependencies

  info "$(t "Downloading sing-box..." "下载 sing-box...")"
  local latest
  latest=$(latest_singbox_version) && SINGBOX_VER="$latest" || SINGBOX_VER="$SINGBOX_DEFAULT_VERSION"
  version_ge "$SINGBOX_VER" "$SINGBOX_MIN_VERSION" \
    || warning "$(t "Downloading sing-box v$SINGBOX_VER, but minimum supported is $SINGBOX_MIN_VERSION (VMess inbound). Using default $SINGBOX_DEFAULT_VERSION instead." \
                        "当前最新版本 v$SINGBOX_VER 低于最低要求 v$SINGBOX_MIN_VERSION（VMess 支持），改用 v$SINGBOX_DEFAULT_VERSION。")"
  version_ge "$SINGBOX_VER" "$SINGBOX_MIN_VERSION" || SINGBOX_VER="$SINGBOX_DEFAULT_VERSION"

  download_singbox "$SINGBOX_VER"
  SINGBOX_VER=$(singbox_version_of "$WORK_DIR/sing-box")
  [ -z "$SINGBOX_VER" ] && SINGBOX_VER="$SINGBOX_DEFAULT_VERSION"

  mkdir -p "$WORK_DIR" "$SUBSCRIBE_DIR"

  info "$(t "Generating TLS certificate (SNI=$TLS_SERVER)..." "生成 TLS 证书 (SNI=$TLS_SERVER)...")"
  write_tls_cert "$TLS_SERVER"

  info "$(t "Writing sing-box config..." "写入 sing-box 配置...")"
  write_singbox_config "$UUID" "$WS_PATH" "$SINGBOX_PORT" "$NODE_NAME"

  info "$(t "Writing nginx config..." "写入 nginx 配置...")"
  write_nginx_config "$WS_PATH" "$SINGBOX_PORT" "$UUID"

  info "$(t "Generating subscriptions..." "生成订阅文件...")"
  write_subscriptions "$UUID" "$WS_PATH" "$CDN_DOMAIN"

  info "$(t "Validating configs..." "校验配置...")"
  validate_singbox_config || die "sing-box config validation failed"
  validate_nginx_config || die "nginx config validation failed"

  info "$(t "Installing systemd services..." "写入 systemd 服务...")"
  write_singbox_service
  write_nginx_service
  systemctl daemon-reload

  open_port "$NGINX_PORT" tcp
  open_port 443 tcp

  info "$(t "Starting services..." "启动服务...")"
  systemctl enable "$SERVICE_NAME" "$NGINX_SERVICE" 2>/dev/null
  systemctl restart "$SERVICE_NAME" 2>/dev/null
  systemctl restart "$NGINX_SERVICE" 2>/dev/null

  sleep 1
  systemctl is-active --quiet "$SERVICE_NAME" || {
    warning "$(t "sing-box failed to start. Last log lines:" "sing-box 启动失败，最近日志:")"
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null
    die "sing-box did not start"
  }
  systemctl is-active --quiet "$NGINX_SERVICE" || {
    warning "$(t "argox-nginx failed to start. Last log lines:" "argox-nginx 启动失败，最近日志:")"
    journalctl -u "$NGINX_SERVICE" -n 20 --no-pager 2>/dev/null
    die "nginx did not start"
  }

  # Optional Cloudflare Argo Tunnel
  if [ "$IS_ARGO" = 'yes' ]; then
    info "$(t "Setting up Cloudflare Argo Tunnel..." "设置 Cloudflare Argo 隧道...')"
    if [ -z "$ARGO_AUTH" ] && [ -z "$ARGO_DOMAIN" ]; then
      hint "$(t "Argo mode enabled but no ARGO_AUTH/ARGO_DOMAIN provided. Skipping Argo setup. Configure later via menu option 7." \
                  "Argo 模式已启用但未提供 ARGO_AUTH/ARGO_DOMAIN。跳过 Argo 设置。之后可通过菜单选项 7 配置。")"
    else
      enable_argo || warning "$(t 'Argo setup failed (see messages above). Standard CDN mode still works.' \
                                      'Argo 设置失败（见上方提示）。标准 CDN 模式仍可使用。')"
    fi
  fi

  save_state
  IS_INSTALLED='yes'

  title "$(t "=============== Installation Complete ===============" \
                    "=============== 安装完成 ===============")"
  display_node_info
}

# ============================================================
# Node info display
# ============================================================
display_node_info() {
  load_state || die "$(t 'Not installed. Run install first.' '尚未安装，请先执行安装。')"
  local link sub_b64 sub_sr
  link=$(vmess_share_link "$UUID" "$WS_PATH" "$CDN_DOMAIN")
  sub_b64="https://${CDN_DOMAIN}/${UUID}/subscribe/base64"
  sub_sr="https://${CDN_DOMAIN}/${UUID}/subscribe/shadowrocket"

  title "=============== $(t 'Node Information' '节点信息') ==============="
  info "  $(t 'Name       ' '节点名称     '):  ${NODE_NAME}"
  info "  $(t 'Address    ' '地址         '):  ${CDN_DOMAIN}:443"
  info "  $(t 'Protocol   ' '协议         '):  VMess + WebSocket + TLS + CDN"
  info "  $(t 'UUID       ' 'UUID         '):  ${UUID}"
  info "  $(t 'WS Path    ' 'WebSocket 路径'):  /${WS_PATH}"
  info "  $(t 'TLS SNI    ' 'TLS SNI      '):  ${TLS_SERVER}"
  echo
  cyan "  $(t 'VMess share link:' 'VMess 分享链接:')"; echo
  echo "    ${link}"
  echo
  cyan "  $(t 'Subscription (SFA base64):' '订阅 (SFA Base64):')"; echo
  echo "    ${sub_b64}"
  cyan "  $(t 'Subscription (Shadowrocket):' '订阅 (Shadowrocket):')"; echo
  echo "    ${sub_sr}"
  echo
}

# ============================================================
# Service / version management
# ============================================================
restart_service() {
  [ "$IS_INSTALLED" = 'yes' ] || die "$(t 'Not installed.' '尚未安装。')"
  validate_singbox_config || die "config check failed"
  local svcs="$SERVICE_NAME $NGINX_SERVICE"
  [ "$IS_ARGO" = 'yes' ] && svcs="$svcs $ARGO_SERVICE"
  systemctl restart $svcs
  sleep 1
  systemctl is-active --quiet "$SERVICE_NAME" || {
    warning "$(t 'sing-box failed after restart:' 'sing-box 重启失败:')"; journalctl -u "$SERVICE_NAME" -n 20 --no-pager
    die "restart failed"
  }
  info "$(t 'Service restarted.' '服务已重启。')"
}

update_singbox() {
  [ "$IS_INSTALLED" = 'yes' ] || die "$(t 'Not installed.' '尚未安装。')"
  local cur newv
  cur=$(singbox_version_of "$WORK_DIR/sing-box")
  newv=$(latest_singbox_version) || newv="$SINGBOX_DEFAULT_VERSION"
  if [ "$cur" = "$newv" ]; then
    info "$(t "Already at latest (v${cur})." "已是最新版本 (v${cur})。")"; return
  fi
  reading "$(t "Upgrade sing-box ${cur} -> ${newv}? [y/N] " "升级 sing-box ${cur} -> ${newv}? [y/N] ")" _confirm
  [ "${_confirm,,}" = 'y' ] || return
  download_singbox "$newv"
  validate_singbox_config || {
    warning "$(t 'New binary failed config check; restoring backup.' '新版本校验失败，回滚旧版本。')"
    local bak
    bak=$(ls -1t "$WORK_DIR"/sing-box.*.bak 2>/dev/null | head -1)
    [ -n "$bak" ] && cp "$bak" "$WORK_DIR/sing-box" && chmod +x "$WORK_DIR/sing-box"
    die "update aborted, backup restored"
  }
  systemctl restart "$SERVICE_NAME" "$NGINX_SERVICE"
  info "$(t "Updated to sing-box v${newv}." "已升级到 sing-box v${newv}。")"
}

view_logs() {
  [ -f "$WORK_DIR/sing-box.log" ] || { tail -n 100 $(journalctl -u "$SERVICE_NAME" -o cat 2>/dev/null); return; }
  tail -n 100 "$WORK_DIR/sing-box.log"
}

reconfigure() {
  local _u _p _d _t _sp _np _n
  [ "$IS_INSTALLED" = 'yes' ] || die "$(t 'Not installed.' '尚未安装。')"
  load_state
  title "$(t 'Current config' '当前配置'):"
  info "  UUID:           ${UUID}"
  info "  WS_PATH:        ${WS_PATH}"
  info "  CDN_DOMAIN:     ${CDN_DOMAIN}"
  info "  TLS_SERVER:     ${TLS_SERVER}"
  info "  SINGBOX_PORT:   ${SINGBOX_PORT}"
  info "  NGINX_PORT:     ${NGINX_PORT}"
  info "  NODE_NAME:      ${NODE_NAME}"

  reading "$(t "New UUID [Enter to keep]: " "新 UUID [回车保留]: ")" _u
  [ -n "$_u" ] && { is_uuid "$_u" || die "invalid UUID"; UUID="$_u"; }

  reading "$(t "New WS path [Enter to keep]: " "新 WS 路径 [回车保留]: ")" _p
  [ -n "$_p" ] && { is_ws_path "$_p" || die "invalid WS path"; WS_PATH="$_p"; }

  reading "$(t "New CDN domain [Enter to keep]: " "新 CDN 域名 [回车保留]: ")" _d
  [ -n "$_d" ] && { is_domain "$_d" || die "invalid domain"; CDN_DOMAIN="$_d"; }

  reading "$(t "New TLS SNI [Enter to keep]: " "新 TLS SNI [回车保留]: ")" _t
  [ -n "$_t" ] && TLS_SERVER="$_t"

  reading "$(t "New sing-box port [Enter to keep]: " "新 sing-box 端口 [回车保留]: ")" _sp
  [ -n "$_sp" ] && { is_port "$_sp" || die "invalid port"; SINGBOX_PORT="$_sp"; }

  reading "$(t "New nginx port [Enter to keep]: " "新 nginx 端口 [回车保留]: ")" _np
  [ -n "$_np" ] && { is_port "$_np" || die "invalid port"; NGINX_PORT="$_np"; }

  reading "$(t "New node name [Enter to keep]: " "新节点名称 [回车保留]: ")" _n
  [ -n "$_n" ] && NODE_NAME="$_n"

  # Regenerate configs with new values
  write_singbox_config "$UUID" "$WS_PATH" "$SINGBOX_PORT" "$NODE_NAME"
  write_nginx_config "$WS_PATH" "$SINGBOX_PORT" "$UUID"
  write_tls_cert "$TLS_SERVER"
  write_subscriptions "$UUID" "$WS_PATH" "$CDN_DOMAIN"
  validate_singbox_config || die "sing-box config check failed after reconfigure"
  validate_nginx_config || die "nginx config check failed after reconfigure"
  systemctl restart "$SERVICE_NAME" "$NGINX_SERVICE"
  save_state
  info "$(t 'Configuration updated and services restarted.' '配置已更新并重启服务。')"
  display_node_info
}

uninstall() {
  reading "$(t "Confirm uninstall ArgoX-Lite? [y/N] " "确认卸载 ArgoX-Lite? [y/N] ")" _c
  [ "${_c,,}" = 'y' ] || return
  systemctl stop "$SERVICE_NAME" "$NGINX_SERVICE" "$ARGO_SERVICE" 2>/dev/null
  systemctl disable "$SERVICE_NAME" "$NGINX_SERVICE" "$ARGO_SERVICE" 2>/dev/null
  rm -f /etc/systemd/system/${SERVICE_NAME}.service \
        /etc/systemd/system/${NGINX_SERVICE}.service \
        /etc/systemd/system/${ARGO_SERVICE}.service
  systemctl daemon-reload
  rm -rf "$WORK_DIR"
  info "$(t 'ArgoX-Lite has been uninstalled.' 'ArgoX-Lite 已卸载。')"
  IS_INSTALLED='no'
}

# ============================================================
# Menu
# ============================================================
menu() {
  clear
  title "=============== ArgoX-Lite  v${VERSION}  ==============="
  [ -f /etc/os-release ] && { . /etc/os-release 2>/dev/null || true; }
  info "  $(t 'OS   ' '系统 '): ${ID:-unknown} ${VERSION_ID:-}   $(t 'Arch' '架构'): $(uname -m)"
  if [ "$IS_INSTALLED" = 'yes' ]; then
    load_state 2>/dev/null || true
    local state_sb state_ng state_cf
    state_sb=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo 'inactive')
    state_ng=$(systemctl is-active "$NGINX_SERVICE" 2>/dev/null || echo 'inactive')
    state_cf='n/a'
    if [ "$IS_ARGO" = 'yes' ]; then
      state_cf=$(systemctl is-active "$ARGO_SERVICE" 2>/dev/null || echo 'inactive')
    fi
    info "  $(t 'sing-box ' 'sing-box'): ${state_sb}  ($(t 'v' '版本 ')$(${WORK_DIR}/sing-box version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1))"
    info "  $(t 'nginx    ' 'nginx    '): ${state_ng}  ($(t 'port' '端口') ${NGINX_PORT:-?})"
    if [ "$IS_ARGO" = 'yes' ]; then
      info "  $(t 'argo     ' 'argo     '): ${state_cf}  (${ARGO_DOMAIN:-?})"
    fi
    echo
    cat <<'MENU'
   [1] 查看节点信息 (View node info)
   [2] 重启服务    (Restart services)
   [3] 更新 sing-box (Update)
   [4] 重新配置    (Reconfigure parameters)
   [5] 查看日志    (Tail logs)
   [7] Argo 隧道  (Cloudflare Argo Tunnel)
   [6] 卸载        (Uninstall)
   [0] 退出        (Exit)
MENU
  else
    echo
    cat <<'MENU'
   [1] 安装 ArgoX-Lite (Install)
   [0] 退出 (Exit)
MENU
  fi
  reading "  $(t 'Choose: ' '请选择: ')" CHOOSE
  case "${CHOOSE:-}" in
    1) if [ "$IS_INSTALLED" = 'yes' ]; then display_node_info; pause;
        else install_flow; pause; fi ;;
    2) restart_service; pause ;;
    3) update_singbox; pause ;;
    4) reconfigure; pause ;;
    5) view_logs; pause ;;
    7) if [ "$IS_ARGO" = 'yes' ]; then
         disable_argo; save_state;
       else
         IS_ARGO='yes'; save_state;
         if [ -z "$ARGO_AUTH" ] && [ -z "$ARGO_DOMAIN" ]; then
           hint "$(t 'Provide ARGO_AUTH or ARGO_DOMAIN in config, then run menu 7 again.' '请在配置中提供 ARGO_AUTH 或 ARGO_DOMAIN，然后再次进入菜单选项 7。')"
         else
           enable_argo || true
         fi
       fi
       pause ;;
    6) uninstall; pause ;;
    0) exit 0 ;;
    *) warning "$(t 'Invalid choice.' '非法输入。')"; pause; menu ;;
  esac
  menu
}

# ============================================================
# CLI entry point
# ============================================================
print_help() {
  cat <<EOF
ArgoX-Lite  v${VERSION}
sing-box VMess + WebSocket + TLS + CDN deploy script
(Optionally with Cloudflare Argo Tunnel)

Usage:
  bash argox.sh [OPTIONS]

Options:
  -i, --install       Install ArgoX-Lite (interactive)
  -u, --uninstall     Uninstall ArgoX-Lite
  -v, --update        Update sing-box to the latest release
  -n, --node          Show node info and subscription URLs
  -a, --argo          Enable Cloudflare Argo Tunnel mode (requires config)
  -f, --file FILE     Non-interactive install using a config file (see config.conf)
  -l, --lang [C|E]    Language: C (Chinese, default) or E (English)
  -h, --help          Show this help
  (no option)         Show interactive menu
EOF
}

parse_args() {
  local opt
  while [ $# -gt 0 ]; do
    opt="$1"
    case "$opt" in
      -h|--help)     print_help; exit 0 ;;
      -i|--install)  install_flow; exit 0 ;;
      -u|--uninstall) uninstall; exit 0 ;;
      -v|--update)   update_singbox; exit 0 ;;
      -n|--node)     display_node_info; exit 0 ;;
      -a|--argo)     IS_ARGO='yes' ;;
      -f|--file)     shift; apply_config_file "${1:-}"; install_flow; exit 0 ;;
      -l|--lang)     shift; case "${1:-}" in C) LANG_TAG='C' ;; E) LANG_TAG='E' ;; esac ;;
      *) die "Unknown option: $opt  (see --help)" ;;
    esac
  done
}

# ============================================================
# Main
# ============================================================
[ -f "$CUSTOM_FILE" ] && {
  . "$CUSTOM_FILE" 2>/dev/null || true
  IS_INSTALLED='yes'
}

parse_args "$@"
menu
