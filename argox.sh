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

# Keep our own version in a dedicated name: detect_os sources /etc/os-release,
# which sets VERSION to something like "12 (bookworm)" on Debian and would
# otherwise leak into the menu title and the saved state.
ARGOX_VERSION='3.0.0 (2026.10.24)'

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

# GitHub acceleration mirrors, tried in order (plain path prefixes).
# Override with:  SINGBOX_MIRRORS='https://my.mirror/'  before running.
# Verified reachable from CN: ghfast.top, gh-proxy.com, ghproxy.lvedong, accel.cloudflare
GH_PROXIES=(
  'https://ghfast.top/'
  'https://gh-proxy.com/'
  'https://ghproxy.lvedong.eu.org/'
  'https://accel.cloudflare.nyc.mn/'
)
[ -n "${SINGBOX_MIRRORS:-}" ] && read -r -a GH_PROXIES <<< "$SINGBOX_MIRRORS"

# Language (C=Chinese, E=English). Defaults to Chinese for the primary audience.
LANG_TAG='C'

# Script-wide state
IS_INSTALLED='no'
SINGBOX_VER=''
SERVICE_NAME='sing-box'
NGINX_SERVICE='argox-nginx'

# Cloudflare Argo Tunnel (optional, disabled by default)
IS_ARGO='yes'
IS_ARGO_EXPLICIT='no'
ARGO_SERVICE='cloudflared'
CLOUDFLARED_MIN_VERSION='2024.3.0'

# Quick tunnel: no credentials needed, cloudflared hands out a random
# *.trycloudflare.com hostname. This is the historical ArgoX default mode.
ARGO_METRICS_PORT='20241'
ARGO_QUICK_HOST=''        # discovered hostname, cached so restarts can reuse it

# Resolved path of the real nginx binary (packages install it outside $WORK_DIR)
NGINX_BIN=''

# Where TLS terminates: auto = edge (Cloudflare) in tunnel mode, local nginx
# otherwise. Force with 'yes' (nginx does TLS) or 'no' (plain HTTP, edge does it).
NGINX_TLS='auto'

# Outbound egress facts, filled in by check_egress(). An IPv6-only box can run
# the tunnel fine but can only reach IPv6 destinations.
HAS_V4=''
HAS_V6=''
# auto = prefer IPv6 when the box has no IPv4 egress.
DOMAIN_STRATEGY='auto'

# VMess authenticates with a timestamp; the server and client clocks must agree
# within roughly 90 seconds or every request is rejected even though TCP, TLS
# and the WebSocket handshake all look perfectly healthy.
TIME_TOLERANCE='30'
TIME_OFFSET=''

# Argo tunnel parameters — all optional, all overridable so you can drive your
# own pre-created Cloudflare tunnel instead of the script's defaults.
ARGO_DOMAIN=''            # hostname clients connect to (own domain)
ARGO_AUTH=''              # credentials JSON (with TunnelSecret) or tunnel token
ARGO_TUNNEL_ID=''         # override the TunnelID found in ARGO_AUTH
ARGO_TUNNEL_NAME=''       # tunnel name, used when no ID/JSON is available
ARGO_CRED_FILE=''         # reuse an existing tunnel credentials .json
ARGO_INGRESS_SERVICE=''   # local target, default http://127.0.0.1:$NGINX_PORT
ARGO_EXTRA_HOSTS=''       # space separated extra hostnames on the same tunnel
ARGO_CF_ARGS=''           # extra args appended to the cloudflared command

# Own domain for the node. When set it wins over CDN_DOMAIN and the public
# CDN hint list, so you can point the node at your own zone.
OWN_DOMAIN=''

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
  NGINX_BIN=$(nginx_bin) || die "nginx binary not found"
}

# Locate the system nginx. The systemd unit must ExecStart the real binary —
# earlier versions pointed at $WORK_DIR/nginx, which never existed, so the
# service died with 203/EXEC.
nginx_bin() {
  local b
  if [ -n "${NGINX_BIN:-}" ] && [ -x "$NGINX_BIN" ]; then echo "$NGINX_BIN"; return 0; fi
  b=$(command -v nginx 2>/dev/null) || true
  if [ -n "$b" ] && [ -x "$b" ]; then echo "$b"; return 0; fi
  for b in /usr/sbin/nginx /usr/bin/nginx /sbin/nginx /usr/local/nginx/sbin/nginx /usr/local/sbin/nginx; do
    [ -x "$b" ] && { echo "$b"; return 0; }
  done
  return 1
}

# Probe outbound egress. Plenty of cheap VPS are IPv6-only: the tunnel and the
# WebSocket handshake all look healthy, yet every proxied request dies because
# the destination only has an A record and there is no IPv4 route. Detect that
# up front instead of leaving the user with a node that "connects but is dead".
check_egress() {
  HAS_V4='no'; HAS_V6='no'
  curl -4 -s -o /dev/null --max-time 6 http://1.1.1.1 2>/dev/null && HAS_V4='yes'
  curl -6 -s -o /dev/null --max-time 6 https://[2606:4700:4700::1111] 2>/dev/null && HAS_V6='yes'

  if [ "$HAS_V4" = 'yes' ]; then
    info "$(t 'Egress: IPv4 OK, IPv6 ' "出网: IPv4 正常，IPv6 ")$([ "$HAS_V6" = 'yes' ] && t 'OK' '正常' || t 'unavailable' '不可用')"
    return 0
  fi

  warning "$(t 'No IPv4 egress detected!' '检测不到 IPv4 出网！')"
  if [ "$HAS_V6" = 'yes' ]; then
    hint "$(t 'This box is IPv6-only. The tunnel will connect, but most sites (IPv4-only) will fail.' \
              '本机是纯 IPv6。隧道能连上，但绝大多数网站只有 IPv4，会连接失败。')"
    hint "$(t 'Domain resolution will be switched to prefer IPv6 so dual-stack sites still work.' \
              '已自动切换为优先解析 IPv6，双栈站点仍可正常访问。')"
    hint "$(t 'Real fix: ask your provider for an IPv4 address or IPv4 NAT.' \
              '根本解法：向服务商申请 IPv4 地址或 IPv4 NAT 出口。')"
  else
    warning "$(t 'Neither IPv4 nor IPv6 egress works — this box cannot proxy anything.' \
                 'IPv4 和 IPv6 出网都不通 —— 本机无法代理任何流量。')"
  fi
  return 1
}

# ============================================================
# Clock: VMess is timestamp authenticated
# ============================================================
# Read the real time from an HTTPS Date header. Works over IPv6 and needs no
# NTP port, which matters on boxes where outbound UDP/123 is filtered.
remote_epoch() {
  local u h
  for u in https://www.cloudflare.com https://www.google.com https://api.github.com; do
    h=$(curl -sI --max-time 8 "$u" 2>/dev/null \
        | sed -n 's/^[Dd]ate: *//p' | tr -d '\r' | head -1)
    [ -z "$h" ] && continue
    LC_ALL=C date -u -d "$h" +%s 2>/dev/null && return 0
  done
  return 1
}

# Echo (local - real) in seconds, or return 1 when no time source is reachable.
time_offset() {
  local re le
  re=$(remote_epoch) || return 1
  le=$(date -u +%s)
  echo $((le - re))
}

# 0 = clock is within tolerance, 1 = drifted, 2 = could not measure
check_time() {
  local off abs
  if ! off=$(time_offset); then
    warning "$(t 'Could not read the real time (no HTTPS source reachable).' \
                 '无法获取真实时间（HTTPS 时间源均不可达）。')"
    TIME_OFFSET=''
    return 2
  fi
  TIME_OFFSET="$off"
  abs=${off#-}
  if [ "$abs" -le "$TIME_TOLERANCE" ]; then
    info "$(t "Clock OK (offset ${off}s)." "时间正常（偏差 ${off} 秒）。")"
    return 0
  fi
  warning "$(t "Clock is off by ${off}s. VMess rejects requests beyond ~90s of skew." \
               "本机时间偏差 ${off} 秒。VMess 超过约 90 秒就会认证失败。")"
  return 1
}

# Bring the clock back in line. NTP first, then a direct set from HTTPS.
fix_time() {
  local off epoch
  info "$(t 'Trying NTP first...' '先尝试 NTP 校时...')"
  if command -v timedatectl >/dev/null 2>&1; then
    systemctl enable --now systemd-timesyncd 2>/dev/null || true
    timedatectl set-ntp true 2>/dev/null || true
    sleep 4
  fi
  if off=$(time_offset) && [ "${off#-}" -le 5 ]; then
    info "$(t "Clock corrected via NTP (offset ${off}s)." "NTP 校时成功（偏差 ${off} 秒）。")"
    return 0
  fi

  info "$(t 'NTP did not converge; setting the clock from an HTTPS Date header.' \
           'NTP 未能收敛；改用 HTTPS 响应头直接校时。')"
  epoch=$(remote_epoch) || {
    warning "$(t 'No time source reachable; cannot fix the clock.' \
                 '没有可达的时间源，无法校时。')"
    return 1
  }
  if date -u -s "@${epoch}" >/dev/null 2>&1; then
    hwclock --systohc 2>/dev/null || true
    off=$(time_offset) || off='?'
    info "$(t "Clock set from HTTPS, new offset ${off}s." "已用 HTTPS 校时，新偏差 ${off} 秒。")"
    TIME_OFFSET="$off"
    return 0
  fi
  warning "$(t 'date -s failed (container without CAP_SYS_TIME?).' \
               'date -s 失败（容器可能没有 CAP_SYS_TIME 权限）。')"
  return 1
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
  # NOTE: `local a=$1 b=$a` does NOT work — bash expands every word before the
  # assignment runs, so $a is still empty there. Assign on separate lines.
  local start="${1:-$START_PORT_DEFAULT}" port i
  start="${start:-30000}"
  port="$start"
  for i in $(seq 0 500); do
    # Match the numeric port exactly: ":30000" must not be read as "[30000]".
    if ! ss -lntu 2>/dev/null | grep -qE ":${port}([[:space:]]|$)"; then
      echo "$port"; return 0
    fi
    port=$((port+1))
    [ "$port" -gt "$MAX_PORT" ] && return 1
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
  local ver="$1" pkg url proxy found
  pkg="sing-box-${ver}-linux-${ARCH}"
  mkdir -p "$WORK_DIR"
  cd "$WORK_DIR" || die "cannot cd $WORK_DIR"

  # Backup previous binary before swap (allows rollback on start failure)
  [ -x sing-box ] && mv sing-box "sing-box.$(date +%s).bak" 2>/dev/null

  url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/${pkg}.tar.gz"

  # Try each GitHub mirror, then direct. Mirrors are plain path prefixes.
  for proxy in "${GH_PROXIES[@]}" ''; do
    [ -z "$proxy" ] && info "Downloading sing-box v${ver} (${ARCH}) ... direct" \
                    || info "Downloading sing-box v${ver} (${ARCH}) ... ${proxy}"
    rm -f "${pkg}.tar.gz"
    # 31 MB payload: generous timeout, retries, and a resume-friendly range request
    if ! curl -fL --max-time 300 --retry 3 --retry-delay 2 --connect-timeout 15 \
         "${proxy}${url}" -o "${pkg}.tar.gz" 2>/dev/null; then
      continue
    fi
    [ -s "${pkg}.tar.gz" ] || continue
    # Reject HTML error pages saved by a mirror
    if ! gzip -t "${pkg}.tar.gz" 2>/dev/null; then
      warning "  mirror returned a non-gzip payload; trying next"
      rm -f "${pkg}.tar.gz"
      continue
    fi

    # The release tarball unpacks into <pkg>/ — pull the binary out of it.
    rm -rf "${pkg}"
    if ! tar -xzf "${pkg}.tar.gz" 2>/dev/null; then
      rm -f "${pkg}.tar.gz"
      continue
    fi
    rm -f "${pkg}.tar.gz"

    found=''
    if   [ -f "${pkg}/sing-box" ];  then found="${pkg}/sing-box"
    elif [ -f "./sing-box" ];       then found='./sing-box'
    else found=$(find . -maxdepth 3 -type f -name sing-box 2>/dev/null | head -1)
    fi

    if [ -n "$found" ] && [ -s "$found" ]; then
      [ "$found" = './sing-box' ] || mv -f "$found" ./sing-box
      chmod +x sing-box 2>/dev/null
      rm -rf "${pkg}"
      if singbox_version_of ./sing-box >/dev/null 2>&1 && [ -x sing-box ]; then
        info "sing-box v${ver} installed"
        return 0
      fi
    fi
    rm -rf "${pkg}"
  done

  # All sources failed — restore the newest backup so the box keeps working.
  local bak
  bak=$(ls -1t sing-box.*.bak 2>/dev/null | head -1)
  if [ -n "$bak" ]; then
    mv -f "$bak" sing-box
    warning "$(t "Download failed; restored previous sing-box from ${bak}." "下载失败，已回滚到旧的 sing-box（${bak}）。")"
  fi
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
  #
  # Schema notes (verified against sing-box 1.14.4):
  #   * log.keep_days does not exist -> "unknown field" hard error.
  #   * No dns block: this box only accepts inbound connections and dials out
  #     through `direct`, which falls back to the system resolver. The legacy
  #     dns.servers[].address form was deprecated in 1.12 and removed in 1.14,
  #     so leaving DNS out keeps the config valid across versions.
  #   * outbound.domain_strategy is gone in 1.14; the supported way to steer
  #     address selection is a route rule with action=resolve + strategy.

  local strategy="${DOMAIN_STRATEGY:-auto}"
  if [ "$strategy" = 'auto' ]; then
    if [ "${HAS_V4:-yes}" = 'no' ]; then strategy='prefer_ipv6'; else strategy=''; fi
  fi
  [ "$strategy" = 'none' ] && strategy=''

  local route_block=''
  if [ -n "$strategy" ]; then
    route_block=",
  \"route\": {
    \"rules\": [
      { \"action\": \"resolve\", \"strategy\": \"${strategy}\" }
    ]
  }"
  fi

  cat > "$WORK_DIR/config.json" <<EOF
{
  "log": {
    "level": "warning",
    "output": "${WORK_DIR}/sing-box.log",
    "timestamp": true
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
  ]${route_block}
}
EOF
}

write_nginx_config() {
  local ws_path=$1 port=$2 uuid=$3 mime=''
  # The mime.types path differs between distros and is absent on some minimal
  # images; nginx -t fails hard on a missing include, so only add it when real.
  local m
  for m in /etc/nginx/mime.types /usr/local/nginx/conf/mime.types /usr/share/nginx/mime.types; do
    [ -s "$m" ] && { mime="include       $m;"; break; }
  done

  # TLS placement matters:
  #   Cloudflare (tunnel or proxied CDN) terminates TLS at its edge and forwards
  #   PLAIN HTTP to the origin. If nginx listens with `ssl` there, it answers
  #   400 "plain HTTP request was sent to HTTPS port" for every tunnel request.
  #   So TLS is only enabled when nothing sits in front of nginx.
  local tls="${NGINX_TLS:-auto}"
  case "$tls" in
    auto) if [ "${IS_ARGO:-yes}" = 'yes' ]; then tls='no'; else tls='yes'; fi ;;
  esac

  # Listen on both stacks. cloudflared resolves `localhost` to ::1 on hosts where
  # /etc/hosts has no IPv4 entry for it, and an IPv4-only listener then answers
  # "connection refused" to every tunnel request. Only add :: when IPv6 exists.
  local v6='no'
  [ -f /proc/net/if_inet6 ] && v6='yes'

  local listen_line http2_line ssl_block
  if [ "$tls" = 'yes' ]; then
    listen_line="listen ${NGINX_PORT} ssl;"
    [ "$v6" = 'yes' ] && listen_line="listen ${NGINX_PORT} ssl;
    listen [::]:${NGINX_PORT} ssl;"
    http2_line='http2 on;'
    ssl_block="ssl_certificate     ${WORK_DIR}/cert.pem;
    ssl_certificate_key ${WORK_DIR}/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;"
  else
    listen_line="listen ${NGINX_PORT};"
    [ "$v6" = 'yes' ] && listen_line="listen ${NGINX_PORT};
    listen [::]:${NGINX_PORT};"
    http2_line=''
    ssl_block=''
  fi

  cat > "$WORK_DIR/nginx.conf" <<EOF
user  root;
worker_processes auto;
pid ${WORK_DIR}/nginx.pid;
error_log  ${WORK_DIR}/nginx-error.log warn;

events {
  worker_connections 4096;
}

http {
  ${mime}
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
    ${listen_line}
    ${http2_line}
    server_name _;

    ${ssl_block}

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
    # The capture group is required: without it $1 is empty, alias points at the
    # directory itself and nginx answers 301 instead of the file.
    location ~^/${uuid}/subscribe/(.+)\$ {
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
  local ng
  ng=$(nginx_bin) || die "$(t 'nginx binary not found; install nginx first.' '找不到 nginx 二进制，请先安装 nginx。')"
  cat > /etc/systemd/system/${NGINX_SERVICE}.service <<EOF
[Unit]
Description=ArgoX-Lite nginx (TLS termination + WS reverse proxy)
After=network-online.target ${SERVICE_NAME}.service
Wants=${SERVICE_NAME}.service

[Service]
Type=forking
User=root
PIDFile=${WORK_DIR}/nginx.pid
ExecStartPre=${ng} -c ${WORK_DIR}/nginx.conf -t
ExecStart=${ng} -c ${WORK_DIR}/nginx.conf
ExecStop=${ng} -c ${WORK_DIR}/nginx.conf -s quit
ExecReload=${ng} -c ${WORK_DIR}/nginx.conf -s reload
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

# sing-box has no built-in log rotation (log.keep_days does not exist), so give
# the logfile a logrotate drop-in to stop it growing without bound.
write_logrotate_config() {
  [ -d /etc/logrotate.d ] || return 0
  cat > /etc/logrotate.d/argox-sing-box <<EOF
${WORK_DIR}/sing-box.log {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    copytruncate
}
EOF
}

# cloudflared ships raw binaries (no tarball), and the `latest/download` path is
# not handled by every GitHub mirror — ghfast.top answers it with a 9-byte
# "Not Found" body while still returning HTTP 200 to curl. So resolve the real
# tag first, and validate the payload before trusting it.
latest_cloudflared_version() {
  local p url tag
  for p in "${GH_PROXIES[@]}" ''; do
    url="${p}https://api.github.com/repos/cloudflare/cloudflared/releases/latest"
    tag=$(curl -fsL --max-time 15 "$url" 2>/dev/null \
          | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 \
          | sed 's/.*"\([^"]*\)"$/\1/')
    [ -n "$tag" ] && { echo "$tag"; return 0; }
  done
  return 1
}

# Real ELF check: the first four bytes must be 7f 45 4c 46.
is_elf_file() {
  [ -s "$1" ] || return 1
  [ "$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = '7f454c46' ]
}

download_cloudflared() {
  local ver="${1:-}"
  local arch pkg tag
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
  [ -f cloudflared ] && mv cloudflared "cloudflared.$(date +%s).bak" 2>/dev/null

  # Prefer an explicit version, then the real latest tag, then the moving path.
  local urls=()
  [ -n "$ver" ] && [ "$ver" != 'latest' ] && \
    urls+=("https://github.com/cloudflare/cloudflared/releases/download/${ver}/${pkg}")
  tag=$(latest_cloudflared_version) && [ -n "$tag" ] && \
    urls+=("https://github.com/cloudflare/cloudflared/releases/download/${tag}/${pkg}")
  urls+=("https://github.com/cloudflare/cloudflared/releases/latest/download/${pkg}")

  local proxy url tmp="${pkg}.tmp"
  for proxy in "${GH_PROXIES[@]}" ''; do
    for url in "${urls[@]}"; do
      if [ -n "$proxy" ]; then
        info "Downloading cloudflared ... ${proxy}${url}"
      else
        info "Downloading cloudflared ... ${url}"
      fi
      rm -f "$tmp"
      if ! curl -fL --max-time 180 --retry 2 --retry-delay 2 --connect-timeout 15 \
           "${proxy}${url}" -o "$tmp" 2>/dev/null; then
        continue
      fi
      if ! is_elf_file "$tmp"; then
        warning "  not an ELF binary ($(wc -c < "$tmp" 2>/dev/null) bytes), trying next"
        rm -f "$tmp"
        continue
      fi
      mv "$tmp" cloudflared
      chmod +x cloudflared
      # Last gate: it must actually run.
      if "$WORK_DIR/cloudflared" --version >/dev/null 2>&1; then
        return 0
      fi
      warning "  downloaded cloudflared will not execute, trying next"
      rm -f cloudflared
    done
  done

  local bak
  bak=$(ls -1t cloudflared.*.bak 2>/dev/null | head -1)
  [ -n "$bak" ] && mv -f "$bak" cloudflared
  die "$(t 'failed to download cloudflared' '下载 cloudflared 失败')"
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
  local domain="${1:-$ARGO_DOMAIN}"
  local port="${2:-$NGINX_PORT}"
  local creds="${ARGO_CRED_FILE:-$WORK_DIR/tunnel.json}"
  local service="${ARGO_INGRESS_SERVICE:-http://127.0.0.1:${port}}"
  local tunnel_id="${ARGO_TUNNEL_ID:-}" h

  # Tunnel identifier resolution order:
  #   ARGO_TUNNEL_ID  ->  TunnelID inside ARGO_AUTH JSON  ->  ARGO_TUNNEL_NAME
  if [ -z "$tunnel_id" ] && [ -n "$ARGO_JSON" ]; then
    tunnel_id=$(grep -oE '"TunnelID"[[:space:]]*:[[:space:]]*"[^"]+"' <<< "$ARGO_JSON" \
                | sed 's/.*"\([^"]*\)"$/\1/')
  fi
  [ -z "$tunnel_id" ] && tunnel_id="$ARGO_TUNNEL_NAME"
  if [ -z "$tunnel_id" ]; then
    warning "$(t 'No tunnel id: set ARGO_TUNNEL_ID, ARGO_TUNNEL_NAME, or an ARGO_AUTH JSON containing TunnelID.' \
                 '缺少隧道标识：请设置 ARGO_TUNNEL_ID、ARGO_TUNNEL_NAME，或提供含 TunnelID 的 ARGO_AUTH JSON。')"
    return 1
  fi
  if [ -z "$domain" ]; then
    warning "$(t 'No tunnel hostname: set ARGO_DOMAIN (your own domain).' \
                 '缺少隧道域名：请设置 ARGO_DOMAIN（你自己的域名）。')"
    return 1
  fi

  {
    printf 'tunnel: %s\n' "$tunnel_id"
    printf 'credentials-file: %s\n' "$creds"
    printf '\ningress:\n'
    printf '  - hostname: %s\n    service: %s\n' "$domain" "$service"
    for h in $ARGO_EXTRA_HOSTS; do
      [ -n "$h" ] && printf '  - hostname: %s\n    service: %s\n' "$h" "$service"
    done
    printf '\n  - service: http_status:404\n'
  } > "$WORK_DIR/tunnel.yml"

  ARGO_TUNNEL_ID="$tunnel_id"
  return 0
}

write_cloudflared_service() {
  local cf="$WORK_DIR/cloudflared"
  local runs='' extra="${ARGO_CF_ARGS:-}"
  local target="${ARGO_INGRESS_SERVICE:-http://127.0.0.1:${NGINX_PORT}}"

  if [ -n "${ARGO_TOKEN:-}" ]; then
    # Token mode: the tunnel is fully described by the token.
    runs="$cf tunnel --no-autoupdate run --token ${ARGO_TOKEN}${extra:+ $extra}"
  elif [ -s "$WORK_DIR/tunnel.yml" ]; then
    # Named tunnel driven by our generated tunnel.yml + credentials file.
    runs="$cf tunnel --no-autoupdate --config $WORK_DIR/tunnel.yml run${extra:+ $extra}"
  elif [ -n "${ARGO_TUNNEL_NAME:-}" ]; then
    # Fall back to a locally-registered tunnel (cert.pem based).
    runs="$cf tunnel --no-autoupdate run ${ARGO_TUNNEL_NAME}${extra:+ $extra}"
  else
    # Quick tunnel: no account, no credentials. Cloudflare hands out a random
    # *.trycloudflare.com hostname, which we read back from the metrics API.
    # This is the historical ArgoX default mode.
    runs="$cf tunnel --no-autoupdate --url ${target} --metrics 127.0.0.1:${ARGO_METRICS_PORT}${extra:+ $extra}"
    info "$(t 'Quick tunnel mode (no credentials): random *.trycloudflare.com hostname' \
             '快速隧道模式（无需凭据）：使用随机 *.trycloudflare.com 域名')"
  fi

  # Type=simple already tracks the cloudflared process, so no PID file and no
  # ExecStop juggling is needed. (The old ExecStartPost used `$$`, which systemd
  # collapses to a literal `$`, so the pid file was never written anyway.)
  cat > /etc/systemd/system/${ARGO_SERVICE}.service <<EOF
[Unit]
Description=ArgoX-Lite Cloudflare Tunnel (cloudflared)
After=network-online.target ${NGINX_SERVICE}.service
Wants=${NGINX_SERVICE}.service

[Service]
Type=simple
User=root
ExecStart=${runs}
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

  # 2. Work out which mode we are in.
  #    Credentials present  -> named tunnel (your own tunnel + your own domain)
  #    Nothing configured   -> quick tunnel (*.trycloudflare.com, no account)
  if [ -z "$ARGO_AUTH" ] && [ -n "${ARGO_CRED_FILE:-}" ] && [ -s "$ARGO_CRED_FILE" ]; then
    ARGO_AUTH=$(tr -d '\n' < "$ARGO_CRED_FILE")
    info "$(t "Using existing credentials: ${ARGO_CRED_FILE}" "使用已有凭据文件: ${ARGO_CRED_FILE}")"
  fi
  if [ -z "$ARGO_AUTH" ] && [ -s "$WORK_DIR/tunnel.json" ]; then
    ARGO_AUTH=$(tr -d '\n' < "$WORK_DIR/tunnel.json")
  fi
  if [ -n "$ARGO_AUTH" ]; then
    parse_argo_auth "$ARGO_AUTH" || die "$(t 'ARGO_AUTH parse failed. Provide JSON with TunnelSecret, or a 120-250 char token.' \
                                              'ARGO_AUTH 解析失败。需提供含 TunnelSecret 的 JSON，或 120-250 字符 Token。')"
  fi

  local has_creds='no' quick='no'
  if [ -n "$ARGO_AUTH" ] || [ -n "${ARGO_TOKEN:-}" ] || [ -n "${ARGO_TUNNEL_NAME:-}" ] \
     || [ -n "${ARGO_TUNNEL_ID:-}" ] || [ -n "${ARGO_CRED_FILE:-}" ]; then
    has_creds='yes'
  fi
  [ "$has_creds" = 'no' ] && quick='yes'

  # 3. Hostname. Named tunnels need one; quick tunnels get it from Cloudflare.
  if [ "$quick" = 'no' ]; then
    if [ -z "$ARGO_DOMAIN" ] && [ -n "${OWN_DOMAIN:-}" ]; then
      ARGO_DOMAIN="$OWN_DOMAIN"
    fi
    if [ -z "$ARGO_DOMAIN" ] && [ -s "$WORK_DIR/tunnel.yml" ]; then
      ARGO_DOMAIN=$(awk '/^[[:space:]]*- hostname:/{print $3; exit}' "$WORK_DIR/tunnel.yml")
    fi
    if [ -z "$ARGO_DOMAIN" ] && [ -n "${ARGO_TOKEN:-}" ]; then
      info "$(t 'Token mode: hostname comes from the Cloudflare tunnel config.' \
               'Token 模式：域名由 Cloudflare 侧隧道配置决定。')"
      hint "$(t "Make sure the tunnel's Public Hostname points at http://127.0.0.1:${NGINX_PORT} — a mismatch shows up as HTTP 502." \
                "请确认 Cloudflare 控制台里该隧道的 Public Hostname 指向 http://127.0.0.1:${NGINX_PORT} —— 不一致会表现为 HTTP 502。")"
    elif [ -z "$ARGO_DOMAIN" ]; then
      warning "$(t 'Named tunnel needs a hostname: set ARGO_DOMAIN or OWN_DOMAIN.' \
                   '命名隧道需要域名：请设置 ARGO_DOMAIN 或 OWN_DOMAIN。')"
      return 1
    fi

    # 4. Write credentials + tunnel.yml (skipped in token mode)
    if [ -z "${ARGO_TOKEN:-}" ] && [ -n "$ARGO_DOMAIN" ]; then
      if [ -n "$ARGO_JSON" ] && [ -z "${ARGO_CRED_FILE:-}" ]; then
        write_cloudflared_credentials
      fi
      write_tunnel_yml "$ARGO_DOMAIN" "$NGINX_PORT" \
        || die "$(t 'Failed to write tunnel.yml.' '写入 tunnel.yml 失败。')"
      info "$(t "tunnel.yml: tunnel=${ARGO_TUNNEL_ID} host=${ARGO_DOMAIN} -> ${ARGO_INGRESS_SERVICE:-http://127.0.0.1:${NGINX_PORT}}" \
               "tunnel.yml: 隧道=${ARGO_TUNNEL_ID} 域名=${ARGO_DOMAIN} -> ${ARGO_INGRESS_SERVICE:-http://127.0.0.1:${NGINX_PORT}}")"
    fi
  else
    # Quick tunnel: drop any stale tunnel.yml so the service picks the quick path.
    rm -f "$WORK_DIR/tunnel.yml"
  fi

  # 5. Write service
  write_cloudflared_service || die "$(t 'Failed to write cloudflared service.' '写入 cloudflared 服务失败。')"

  # 6. Install & start
  systemctl daemon-reload
  systemctl enable "$ARGO_SERVICE" 2>/dev/null
  systemctl restart "$ARGO_SERVICE" 2>/dev/null
  sleep 2
  if ! systemctl is-active --quiet "$ARGO_SERVICE"; then
    warning "$(t "cloudflared failed to start. Last log lines:" "cloudflared 启动失败，最近日志:")"
    journalctl -u "$ARGO_SERVICE" -n 20 --no-pager 2>/dev/null
    return 1
  fi

  # 7. Quick tunnel: read back the hostname Cloudflare assigned us.
  if [ "$quick" = 'yes' ]; then
    info "$(t 'Waiting for the quick tunnel hostname...' '等待快速隧道分配域名...')"
    local host
    host=$(discover_quick_tunnel_host) || host=''
    if [ -z "$host" ]; then
      warning "$(t 'Could not read the quick tunnel hostname. Check: journalctl -u cloudflared -n 50' \
                   '未能获取快速隧道域名。请查看: journalctl -u cloudflared -n 50')"
      return 1
    fi
    ARGO_DOMAIN="$host"
    ARGO_QUICK_HOST="$host"
    info "$(t "Quick tunnel hostname: ${ARGO_DOMAIN}" "快速隧道域名: ${ARGO_DOMAIN}")"
  fi

  # 8. Node address changed, so refresh the subscription files and state.
  if [ -n "${UUID:-}" ] && [ -n "${WS_PATH:-}" ]; then
    write_subscriptions "$UUID" "$WS_PATH" || true
  fi
  save_state

  info "$(t "Argo Tunnel enabled. Tunnel domain: ${ARGO_DOMAIN}" "Argo 隧道已启用。隧道域名: ${ARGO_DOMAIN}")"
  return 0
}

# Poll cloudflared's metrics endpoint for the quick-tunnel hostname, falling
# back to scraping the service journal.
discover_quick_tunnel_host() {
  local i host
  for i in $(seq 1 30); do
    host=$(curl -s --max-time 3 "http://127.0.0.1:${ARGO_METRICS_PORT}/quicktunnel" 2>/dev/null \
           | sed -n 's/.*"hostname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ -n "$host" ] && { echo "$host"; return 0; }
    host=$(journalctl -u "$ARGO_SERVICE" -n 200 --no-pager 2>/dev/null \
           | grep -oE '[a-z0-9][a-z0-9-]*\.trycloudflare\.com' | head -1)
    [ -n "$host" ] && { echo "$host"; return 0; }
    sleep 2
  done
  return 1
}

disable_argo() {
  systemctl stop "$ARGO_SERVICE" 2>/dev/null || true
  systemctl disable "$ARGO_SERVICE" 2>/dev/null || true
  rm -f /etc/systemd/system/${ARGO_SERVICE}.service
  systemctl daemon-reload
  info "$(t 'Argo Tunnel disabled.' 'Argo 隧道已禁用。')"
}

show_argo_config() {
  title "$(t 'Argo tunnel configuration' 'Argo 隧道配置')"
  info "  $(t 'Enabled     ' '启用状态    '): ${IS_ARGO}"
  info "  $(t 'Domain      ' '域名        '): ${ARGO_DOMAIN:-$(t '(unset)' '(未设置)')}"
  info "  $(t 'Tunnel ID   ' '隧道 ID     '): ${ARGO_TUNNEL_ID:-$(t '(from credentials)' '(取自凭据)')}"
  info "  $(t 'Tunnel name ' '隧道名称    '): ${ARGO_TUNNEL_NAME:-$(t '(unset)' '(未设置)')}"
  info "  $(t 'Credentials ' '凭据文件    '): ${ARGO_CRED_FILE:-$WORK_DIR/tunnel.json}"
  info "  $(t 'Ingress     ' '本地转发    '): ${ARGO_INGRESS_SERVICE:-http://127.0.0.1:${NGINX_PORT:-8080}}"
  info "  $(t 'Extra hosts ' '额外域名    '): ${ARGO_EXTRA_HOSTS:-$(t '(none)' '(无)')}"
  info "  $(t 'Extra args  ' '额外参数    '): ${ARGO_CF_ARGS:-$(t '(none)' '(无)')}"
  if [ -n "$ARGO_AUTH" ]; then
    info "  $(t 'Auth        ' '认证方式    '): $(t 'set' '已设置') ($(printf '%s' "$ARGO_AUTH" | wc -c) bytes)"
  else
    info "  $(t 'Auth        ' '认证方式    '): $(t '(unset)' '(未设置)')"
  fi
  [ -s "$WORK_DIR/tunnel.yml" ] && {
    echo
    hint "$WORK_DIR/tunnel.yml:"
    sed 's/^/    /' "$WORK_DIR/tunnel.yml"
  }
  return 0
}

# Interactive editor for every Argo field. Empty input keeps the current value.
collect_argo_params() {
  local _in
  title "$(t 'Argo tunnel parameters — Enter keeps the current value' \
            'Argo 隧道参数 —— 回车保留当前值')"

  hint "$(t "Own domain (hostname clients connect to) [${ARGO_DOMAIN:-unset}]: " \
            "自有域名（客户端连接的域名）[${ARGO_DOMAIN:-未设置}]: ")"
  reading "  > " _in
  if [ -n "$_in" ]; then
    if is_domain "$_in"; then ARGO_DOMAIN="$_in"
    else warning "$(t 'Invalid domain, ignored.' '域名格式非法，已忽略。')"
    fi
  fi

  hint "$(t "Tunnel ID (blank = take from credentials) [${ARGO_TUNNEL_ID:-auto}]: " \
            "隧道 ID（留空 = 从凭据中读取）[${ARGO_TUNNEL_ID:-自动}]: ")"
  reading "  > " _in
  [ -n "$_in" ] && ARGO_TUNNEL_ID="$_in"

  hint "$(t "Tunnel name (used when no ID/credentials) [${ARGO_TUNNEL_NAME:-unset}]: " \
            "隧道名称（无 ID/凭据时使用）[${ARGO_TUNNEL_NAME:-未设置}]: ")"
  reading "  > " _in
  [ -n "$_in" ] && ARGO_TUNNEL_NAME="$_in"

  hint "$(t "Credentials JSON path [${ARGO_CRED_FILE:-default}] : " \
            "凭据 JSON 路径 [${ARGO_CRED_FILE:-默认}]: ")"
  reading "  > " _in
  if [ -n "$_in" ]; then
    if [ -s "$_in" ]; then ARGO_CRED_FILE="$_in"
    else warning "$(t 'File not found, ignored.' '文件不存在，已忽略。')"
    fi
  fi

  hint "$(t "ARGO_AUTH: credentials JSON or tunnel token [Enter to keep]: " \
            "ARGO_AUTH：凭据 JSON 或隧道 Token [回车保留]: ")"
  reading "  > " _in
  [ -n "$_in" ] && ARGO_AUTH="$_in"

  hint "$(t "Local ingress service [${ARGO_INGRESS_SERVICE:-http://127.0.0.1:${NGINX_PORT:-8080}}]: " \
            "本地转发地址 [${ARGO_INGRESS_SERVICE:-http://127.0.0.1:${NGINX_PORT:-8080}}]: ")"
  reading "  > " _in
  [ -n "$_in" ] && ARGO_INGRESS_SERVICE="$_in"

  hint "$(t "Extra hostnames, space separated [${ARGO_EXTRA_HOSTS:-none}]: " \
            "额外域名，空格分隔 [${ARGO_EXTRA_HOSTS:-无}]: ")"
  reading "  > " _in
  [ -n "$_in" ] && ARGO_EXTRA_HOSTS="$_in"

  hint "$(t "Extra cloudflared args [${ARGO_CF_ARGS:-none}]: " \
            "额外 cloudflared 参数 [${ARGO_CF_ARGS:-无}]: ")"
  reading "  > " _in
  [ -n "$_in" ] && ARGO_CF_ARGS="$_in"

  save_state
  info "$(t 'Argo parameters saved.' 'Argo 参数已保存。')"
}

argo_menu() {
  while :; do
    clear
    title "=============== $(t 'Argo Tunnel' 'Argo 隧道') ==============="
    info "  $(t 'State' '状态'): ${IS_ARGO}"
    [ -n "$ARGO_DOMAIN" ] && info "  $(t 'Domain' '域名'): ${ARGO_DOMAIN}"
    echo
    cat <<'ARGOMENU'
   [1] 启用 Argo 隧道   (Enable)
   [2] 禁用 Argo 隧道   (Disable)
   [3] 编辑隧道参数     (Edit tunnel parameters)
   [4] 查看当前配置     (Show config)
   [0] 返回             (Back)
ARGOMENU
    reading "  $(t 'Choose: ' '请选择: ')" _ac
    case "${_ac:-}" in
      1) IS_ARGO='yes'; save_state
         enable_argo || true
         pause ;;
      2) IS_ARGO='no'; save_state
         disable_argo
         pause ;;
      3) collect_argo_params; pause ;;
      4) show_argo_config; pause ;;
      0) return ;;
      *) warning "$(t 'Invalid choice.' '非法输入。')"; pause ;;
    esac
  done
}

# Validate sing-box config before enabling service
validate_singbox_config() {
  local bin="$WORK_DIR/sing-box" cfg="$WORK_DIR/config.json"
  if [ ! -x "$bin" ]; then die "sing-box binary not found at $bin"; fi
  if [ ! -s "$cfg" ]; then die "config not found at $cfg"; fi

  # `sing-box check` exists since 1.11. There is no `test` subcommand — the
  # old fallback only ever produced "unknown command test" noise, so it is gone.
  if ! "$bin" check --help >/dev/null 2>&1; then
    warning "$(t "This sing-box has no 'check' subcommand; skipping validation." "当前 sing-box 没有 check 子命令，跳过配置校验。")"
    return 0
  fi

  local out
  if out=$("$bin" check -c "$cfg" 2>&1); then
    info "$(t 'sing-box config OK' 'sing-box 配置校验通过')"
    return 0
  fi
  warning "$(t 'sing-box config check FAILED:' 'sing-box 配置校验失败:')"
  printf '%s\n' "$out"
  return 1
}

validate_nginx_config() {
  local bin
  bin=$(nginx_bin) || die "nginx binary missing"
  NGINX_BIN="$bin"
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

# The single source of truth for "what hostname do clients dial".
# In tunnel mode that is the tunnel hostname, never the CDN placeholder.
node_host() {
  if [ "${IS_ARGO:-no}" = 'yes' ] && [ -n "${ARGO_DOMAIN:-}" ]; then
    printf '%s' "$ARGO_DOMAIN"
  else
    printf '%s' "${CDN_DOMAIN:-}"
  fi
}

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
  local uuid=$1 ws_path=$2 domain="${3:-$(node_host)}"
  [ -z "$domain" ] && { warning "write_subscriptions: empty hostname"; return 1; }
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
  # %q shell-escapes every value, so ARGO_AUTH (a JSON blob with spaces and
  # quotes) survives being sourced back by load_state.
  {
    printf 'UUID=%q\n'                 "${UUID:-}"
    printf 'WS_PATH=%q\n'              "${WS_PATH:-}"
    printf 'CDN_DOMAIN=%q\n'           "${CDN_DOMAIN:-}"
    printf 'OWN_DOMAIN=%q\n'           "${OWN_DOMAIN:-}"
    printf 'TLS_SERVER=%q\n'           "${TLS_SERVER:-}"
    printf 'SINGBOX_PORT=%q\n'         "${SINGBOX_PORT:-}"
    printf 'NGINX_PORT=%q\n'           "${NGINX_PORT:-}"
    printf 'NODE_NAME=%q\n'            "${NODE_NAME:-}"
    printf 'SCRIPT_VERSION=%q\n'       "${ARGOX_VERSION:-}"
    printf 'IS_ARGO=%q\n'              "${IS_ARGO:-no}"
    printf 'ARGO_DOMAIN=%q\n'          "${ARGO_DOMAIN:-}"
    printf 'ARGO_AUTH=%q\n'            "${ARGO_AUTH:-}"
    printf 'ARGO_TUNNEL_ID=%q\n'       "${ARGO_TUNNEL_ID:-}"
    printf 'ARGO_TUNNEL_NAME=%q\n'     "${ARGO_TUNNEL_NAME:-}"
    printf 'ARGO_CRED_FILE=%q\n'       "${ARGO_CRED_FILE:-}"
    printf 'ARGO_INGRESS_SERVICE=%q\n' "${ARGO_INGRESS_SERVICE:-}"
    printf 'ARGO_EXTRA_HOSTS=%q\n'     "${ARGO_EXTRA_HOSTS:-}"
    printf 'ARGO_CF_ARGS=%q\n'         "${ARGO_CF_ARGS:-}"
    printf 'ARGO_QUICK_HOST=%q\n'      "${ARGO_QUICK_HOST:-}"
    printf 'ARGO_METRICS_PORT=%q\n'    "${ARGO_METRICS_PORT:-20241}"
    printf 'NGINX_TLS=%q\n'            "${NGINX_TLS:-auto}"
    printf 'DOMAIN_STRATEGY=%q\n'      "${DOMAIN_STRATEGY:-auto}"
  } > "$f"
}

load_state() {
  [ -f "$CUSTOM_FILE" ] || return 1
  . "$CUSTOM_FILE"
  # A saved state already decided the run mode; don't re-ask on reinstall.
  IS_ARGO_EXPLICIT='yes'
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

  # Own domain wins over the shared public CDN default.
  [ -n "${OWN_DOMAIN:-}" ] && CDN_DOMAIN="$OWN_DOMAIN"
  # SERVER is the historical ArgoX key for the node address.
  [ -n "${SERVER:-}" ] && CDN_DOMAIN="$SERVER"

  [ -n "${UUID:-}" ] && is_uuid "$UUID" || { [ -n "${UUID:-}" ] && die "invalid UUID in config file: $UUID"; }
  [ -n "${WS_PATH:-}" ] && is_ws_path "$WS_PATH" || { [ -n "${WS_PATH:-}" ] && die "invalid WS path: $WS_PATH"; }
  [ -n "${START_PORT:-}" ] && is_port "$START_PORT" || { [ -n "${START_PORT:-}" ] && die "invalid port: $START_PORT"; }
  [ -n "${NGINX_PORT:-}" ] && is_port "$NGINX_PORT" || { [ -n "${NGINX_PORT:-}" ] && die "invalid port: $NGINX_PORT"; }
  [ "${L:-}" = 'E' ] && LANG_TAG='E'

  case "${ARGO:-}" in
    y|yes|Y|Yes|1|true|True) IS_ARGO='yes'; IS_ARGO_EXPLICIT='yes' ;;
    n|no|N|No|0|false|False)  IS_ARGO='no';  IS_ARGO_EXPLICIT='yes' ;;
  esac

  # Argo tunnel parameters (all optional)
  [ -n "${ARGO_DOMAIN:-}" ]          && :
  [ -n "${ARGO_AUTH:-}" ]            && :
  [ -n "${ARGO_TUNNEL_ID:-}" ]       && :
  [ -n "${ARGO_TUNNEL_NAME:-}" ]     && :
  [ -n "${ARGO_INGRESS_SERVICE:-}" ] && :
  [ -n "${ARGO_EXTRA_HOSTS:-}" ]     && :
  [ -n "${ARGO_CF_ARGS:-}" ]         && :
  if [ -n "${ARGO_CRED_FILE:-}" ]; then
    [ -s "$ARGO_CRED_FILE" ] || warning "$(t "ARGO_CRED_FILE does not exist: ${ARGO_CRED_FILE}" "ARGO_CRED_FILE 不存在: ${ARGO_CRED_FILE}")"
  fi

  [ -n "${SINGBOX_VERSION:-}" ] && SINGBOX_DEFAULT_VERSION="$SINGBOX_VERSION"
  return 0
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

  # Node address: own domain takes priority, then CDN_DOMAIN, then public default
  [ -z "$CDN_DOMAIN" ] && [ -n "$OWN_DOMAIN" ] && CDN_DOMAIN="$OWN_DOMAIN"
  if [ -z "$CDN_DOMAIN" ]; then
    CDN_DOMAIN="$DEFAULT_CDN_DOMAIN"
    hint "$(t "Node domain — your own domain (e.g. node.example.com) or a public CDN" \
              "节点域名 —— 你自己的域名（如 node.example.com）或公共 CDN")"
    hint "$(t "Public CDN examples: ${CDN_DOMAIN_HINT[*]}" "公共 CDN 示例: ${CDN_DOMAIN_HINT[*]}")"
    hint "$(t "Press Enter to accept the default: ${CDN_DOMAIN}" "回车接受默认值: ${CDN_DOMAIN}")"
    reading "  > " _in
    [ -n "$_in" ] && CDN_DOMAIN="$_in"
    while ! is_domain "$CDN_DOMAIN"; do
      warning "$(t 'Invalid domain or IPv4.' '域名/IPv4 格式错误。')"
      retries=$((retries-1)); [ $retries -le 0 ] && die "too many errors"
      reading "  > " _in
      CDN_DOMAIN="$_in"
    done
  fi
  OWN_DOMAIN="$CDN_DOMAIN"

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

  # ---- Run mode -------------------------------------------------------
  # Tunnel is the default (matches classic ArgoX). Direct CDN stays available.
  if [ "${IS_ARGO_EXPLICIT:-no}" != 'yes' ]; then
    echo
    hint "$(t 'Run mode:' '运行模式:')"
    hint "$(t '  [1] Cloudflare Argo tunnel  (default, no public IP needed)' \
              '  [1] Cloudflare Argo 隧道（默认，无需公网 IP）')"
    hint "$(t '  [2] Direct CDN (point your own domain at this server)' \
              '  [2] 直连 CDN（把你的域名解析到本机）')"
    hint "$(t 'Choose [1]: ' '请选择 [1]: ')"
    reading "  > " _in
    case "${_in:-1}" in
      2) IS_ARGO='no' ;;
      *) IS_ARGO='yes' ;;
    esac
  fi

  # ---- Tunnel parameters (only when tunnel mode is on) ----------------
  if [ "$IS_ARGO" = 'yes' ]; then
    echo
    info "$(t 'Tunnel configuration — leave blank to use a quick tunnel (*.trycloudflare.com)' \
             '隧道配置 —— 留空则使用快速隧道（*.trycloudflare.com）')"

    if [ -z "$ARGO_DOMAIN" ]; then
      hint "$(t "Tunnel hostname, your own domain [blank = quick tunnel]: " \
                "隧道域名，你自己的域名 [留空 = 快速隧道]: ")"
      reading "  > " _in
      if [ -n "$_in" ]; then
        if is_domain "$_in"; then ARGO_DOMAIN="$_in"
        else warning "$(t 'Invalid domain, ignored.' '域名格式非法，已忽略。')"
        fi
      fi
    fi

    if [ -n "$ARGO_DOMAIN" ] && [ -z "$ARGO_AUTH" ] && [ -z "${ARGO_CRED_FILE:-}" ] \
       && [ -z "${ARGO_TUNNEL_NAME:-}" ]; then
      hint "$(t "Tunnel credentials JSON or token [blank = set later via menu 7]: " \
                "隧道凭据 JSON 或 Token [留空 = 稍后用菜单 7 配置]: ")"
      reading "  > " _in
      [ -n "$_in" ] && ARGO_AUTH="$_in"
    fi

    if [ -n "$ARGO_DOMAIN" ] && [ -z "$ARGO_AUTH" ] && [ -z "${ARGO_CRED_FILE:-}" ] \
       && [ -z "${ARGO_TUNNEL_NAME:-}" ]; then
      hint "$(t "Tunnel ID (optional) [blank = skip]: " "隧道 ID（可选）[留空 = 跳过]: ")"
      reading "  > " _in
      [ -n "$_in" ] && ARGO_TUNNEL_ID="$_in"
    fi
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

  info "$(t "Checking outbound connectivity..." "检测出网连通性...")"
  check_egress || true

  info "$(t "Checking system clock..." "检测系统时间...")"
  if ! check_time; then
    fix_time || warning "$(t 'Clock still off — VMess will fail until it is corrected.' \
                               '时间仍未校准 —— 在校准前 VMess 无法工作。')"
  fi

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

  info "$(t "Validating configs..." "校验配置...")"
  validate_singbox_config || die "sing-box config validation failed"
  validate_nginx_config || die "nginx config validation failed"

  info "$(t "Installing systemd services..." "写入 systemd 服务...")"
  write_singbox_service
  write_nginx_service
  write_logrotate_config
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

  # Optional Cloudflare Argo Tunnel (default run mode)
  if [ "$IS_ARGO" = 'yes' ]; then
    info "$(t 'Setting up Cloudflare Argo Tunnel...' '设置 Cloudflare Argo 隧道...')"
    enable_argo || warning "$(t 'Argo setup failed (see messages above). Direct CDN mode still works.' \
                                    'Argo 设置失败（见上方提示）。直连 CDN 模式仍可使用。')"
  fi

  # Subscriptions are written only now, once the tunnel hostname is known.
  # Generating them earlier baked in the CDN placeholder even in tunnel mode.
  info "$(t "Generating subscriptions..." "生成订阅文件...")"
  write_subscriptions "$UUID" "$WS_PATH"

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
  local link sub_b64 sub_sr host mode
  # In Argo mode the client dials the tunnel hostname, not the CDN domain.
  host=$(node_host)
  mode="VMess + WebSocket + TLS + CDN"
  [ "$IS_ARGO" = 'yes' ] && [ -n "$ARGO_DOMAIN" ] && mode="VMess + WebSocket + TLS + Argo Tunnel"

  link=$(vmess_share_link "$UUID" "$WS_PATH" "$host")
  sub_b64="https://${host}/${UUID}/subscribe/base64"
  sub_sr="https://${host}/${UUID}/subscribe/shadowrocket"

  title "=============== $(t 'Node Information' '节点信息') ==============="
  info "  $(t 'Name       ' '节点名称     '):  ${NODE_NAME}"
  info "  $(t 'Address    ' '地址         '):  ${host}:443"
  info "  $(t 'Protocol   ' '协议         '):  ${mode}"
  info "  $(t 'UUID       ' 'UUID         '):  ${UUID}"
  info "  $(t 'WS Path    ' 'WebSocket 路径'):  /${WS_PATH}"
  info "  $(t 'TLS SNI    ' 'TLS SNI      '):  ${TLS_SERVER}"
  [ "$IS_ARGO" = 'yes' ] && info "  $(t 'Argo tunnel' 'Argo 隧道    '):  ${ARGO_DOMAIN:-$(t 'not configured' '未配置')}"
  if [ "$IS_ARGO" = 'yes' ]; then
    info "  $(t 'TLS ends at' 'TLS 终止于   '):  Cloudflare $(t 'edge (origin is plain HTTP)' '边缘（回源为明文 HTTP）')"
  else
    info "  $(t 'TLS ends at' 'TLS 终止于   '):  $(t 'local nginx' '本机 nginx')"
  fi
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

# One-shot health check. Answers the question "it connects, but nothing works":
# separates "the tunnel/nginx/sing-box chain is fine" from "this box cannot
# reach the destination", which is the usual culprit on cheap VPS.
doctor() {
  load_state 2>/dev/null || true
  local host ng sp problems=0
  host=$(node_host); ng="${NGINX_PORT:-8080}"; sp="${SINGBOX_PORT:-30000}"

  title "=============== $(t 'ArgoX-Lite doctor' 'ArgoX-Lite 自检') ==============="

  # --- services
  echo; cyan "$(t 'Services' '服务')"
  local s st
  for s in "$SERVICE_NAME" "$NGINX_SERVICE" "$ARGO_SERVICE"; do
    [ "$s" = "$ARGO_SERVICE" ] && [ "$IS_ARGO" != 'yes' ] && continue
    st=$(systemctl is-active "$s" 2>/dev/null || echo inactive)
    if [ "$st" = 'active' ]; then info "  ${s}: ${st}"; else warning "  ${s}: ${st}"; problems=$((problems+1)); fi
  done

  # --- listeners
  echo; cyan "$(t 'Listeners' '监听端口')"
  for p in "$sp" "$ng"; do
    if ss -lnt 2>/dev/null | grep -qE ":${p}([[:space:]]|$)"; then
      info "  port ${p}: $(t 'listening' '已监听')"
    else
      warning "  port ${p}: $(t 'NOT listening' '未监听')"; problems=$((problems+1))
    fi
  done

  # --- egress
  echo; cyan "$(t 'Outbound egress' '出网连通性')"
  local v4='no' v6='no'
  curl -4 -s -o /dev/null --max-time 6 http://1.1.1.1 2>/dev/null && v4='yes'
  curl -6 -s -o /dev/null --max-time 6 https://[2606:4700:4700::1111] 2>/dev/null && v6='yes'
  [ "$v4" = 'yes' ] && info "  IPv4: OK" || warning "  IPv4: $(t 'DEAD' '不通')"
  [ "$v6" = 'yes' ] && info "  IPv6: OK" || warning "  IPv6: $(t 'DEAD' '不通')"
  if [ "$v4" = 'no' ]; then
    problems=$((problems+1))
    hint "$(t '  -> IPv6-only box: the tunnel will connect but most sites are IPv4-only.' \
              '  -> 纯 IPv6 机器：隧道能连上，但绝大多数网站只有 IPv4，会连不上。')"
    hint "$(t '  -> Ask your provider for IPv4, or set DOMAIN_STRATEGY=prefer_ipv6 for dual-stack only.' \
              '  -> 向服务商申请 IPv4；或设 DOMAIN_STRATEGY=prefer_ipv6 只保证双栈站点可用。')"
  fi
  [ "$v4" = 'no' ] && [ "$v6" = 'no' ] && { warning "$(t '  -> no egress at all, nothing can be proxied' '  -> 完全无出网，无法代理任何流量')"; }

  # --- clock (VMess is timestamp authenticated)
  echo; cyan "$(t 'System clock' '系统时间')"
  local off
  if off=$(time_offset); then
    info "  $(t 'local UTC' '本机 UTC'): $(date -u '+%Y-%m-%d %H:%M:%S')"
    if [ "${off#-}" -le "$TIME_TOLERANCE" ]; then
      info "  $(t "offset ${off}s — within tolerance" "偏差 ${off} 秒 —— 在容差内")"
    else
      warning "  $(t "offset ${off}s — TOO FAR, VMess auth will fail" "偏差 ${off} 秒 —— 超差，VMess 认证会失败")"
      hint "$(t '  -> run: bash argox.sh -t   (or menu [8] shows it, -t fixes it)' \
                '  -> 执行: bash argox.sh -t   （菜单 [8] 可查看，-t 修复）')"
      problems=$((problems+1))
    fi
  else
    warning "  $(t 'cannot read real time (no HTTPS source)' '无法获取真实时间（无 HTTPS 时间源）')"
  fi
  local ts
  ts=$(systemctl is-active systemd-timesyncd 2>/dev/null || echo inactive)
  [ "$ts" = 'active' ] && info "  NTP: systemd-timesyncd active" \
                       || hint "  $(t 'NTP: not running (clock will drift)' 'NTP: 未运行（时间会漂移）')"

  # --- configs
  echo; cyan "$(t 'Config validity' '配置有效性')"
  if [ -x "$WORK_DIR/sing-box" ] && [ -s "$WORK_DIR/config.json" ]; then
    if "$WORK_DIR/sing-box" check -c "$WORK_DIR/config.json" >/dev/null 2>&1; then
      info "  sing-box config: OK"
    else
      warning "  sing-box config: $(t 'INVALID' '无效')"; problems=$((problems+1))
    fi
  fi
  local nb
  if nb=$(nginx_bin) && [ -s "$WORK_DIR/nginx.conf" ]; then
    if "$nb" -c "$WORK_DIR/nginx.conf" -t >/dev/null 2>&1; then
      info "  nginx config: OK"
    else
      warning "  nginx config: $(t 'INVALID' '无效')"; problems=$((problems+1))
    fi
  fi

  # --- end-to-end probes
  echo; cyan "$(t 'End-to-end probes' '端到端探测')"
  local ws="/${WS_PATH:-argox-ws-vm}" code
  code=$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 8 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "http://127.0.0.1:${sp}${ws}" 2>/dev/null)
  [ "$code" = '101' ] && info "  sing-box WS: 101" || { warning "  sing-box WS: ${code}"; problems=$((problems+1)); }

  code=$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 8 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    -H "Host: ${host}" "http://127.0.0.1:${ng}${ws}" 2>/dev/null)
  [ "$code" = '101' ] && info "  nginx WS: 101" || { warning "  nginx WS: ${code}"; problems=$((problems+1)); }

  if [ "$IS_ARGO" = 'yes' ] && [ -n "$ARGO_DOMAIN" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 25 \
      -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
      -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
      "https://${ARGO_DOMAIN}${ws}" 2>/dev/null)
    [ "$code" = '101' ] && info "  tunnel WS: 101" || { warning "  tunnel WS: ${code}"; problems=$((problems+1)); }
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 \
      "https://${ARGO_DOMAIN}/${UUID}/subscribe/base64" 2>/dev/null)
    [ "$code" = '200' ] && info "  subscription via tunnel: 200" || { warning "  subscription via tunnel: ${code}"; problems=$((problems+1)); }
  fi

  # --- recent proxy errors
  echo; cyan "$(t 'Recent proxy errors (last 5)' '最近代理错误（最后 5 条）')"
  if [ -f "$WORK_DIR/sing-box.log" ]; then
    # OpenVZ containers make sing-box's interface monitor log this every second;
    # it is harmless noise that would otherwise bury the real failures.
    local real
    real=$(grep 'ERROR' "$WORK_DIR/sing-box.log" 2>/dev/null | grep -v 'check interface' | tail -5)
    if [ -n "$real" ]; then printf '%s\n' "$real" | sed 's/^/  /'; else info "  $(t 'none' '无')"; fi
    local to
    to=$(grep 'ERROR' "$WORK_DIR/sing-box.log" 2>/dev/null | grep -c 'i/o timeout' || echo 0)
    [ "$to" -gt 0 ] && hint "$(t "  -> ${to} dial timeouts: destinations unreachable from this box" \
                               "  -> ${to} 条拨号超时：本机到目标不可达")"
    local noise
    noise=$(grep -c 'check interface' "$WORK_DIR/sing-box.log" 2>/dev/null || echo 0)
    [ "$noise" -gt 0 ] && hint "$(t "  (${noise} 'check interface' lines ignored — OpenVZ netlink noise)" \
                                   "  （已忽略 ${noise} 条 'check interface' —— OpenVZ netlink 噪声）")"
  fi

  # --- verdict
  echo
  if [ "$problems" -eq 0 ]; then
    info "$(t 'VERDICT: all checks passed.' '结论：全部检查通过。')"
  else
    warning "$(t "VERDICT: ${problems} problem(s) found, see above." "结论：发现 ${problems} 个问题，见上。")"
  fi
  echo
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
  write_subscriptions "$UUID" "$WS_PATH"
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
        /etc/systemd/system/${ARGO_SERVICE}.service \
        /etc/logrotate.d/argox-sing-box
  systemctl daemon-reload
  rm -rf "$WORK_DIR"
  info "$(t 'ArgoX-Lite has been uninstalled.' 'ArgoX-Lite 已卸载。')"
  IS_INSTALLED='no'
}

# ============================================================
# Menu
# ============================================================
menu() {
  # Non-interactive stdin (EOF) would loop forever on `read`; bail out instead.
  if [ ! -t 0 ]; then
    print_help
    exit 0
  fi
  clear
  title "=============== ArgoX-Lite  v${ARGOX_VERSION}  ==============="
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
   [8] 自检诊断    (Doctor / health check)
   [6] 卸载        (Uninstall)
   [7] Argo 隧道  (Cloudflare Argo Tunnel)
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
    7) argo_menu ;;
    8) doctor; pause ;;
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
ArgoX-Lite  v${ARGOX_VERSION}
sing-box VMess + WebSocket + TLS + CDN deploy script
(Optionally with Cloudflare Argo Tunnel)

Usage:
  bash argox.sh [OPTIONS]

Options:
  -i, --install       Install ArgoX-Lite (interactive)
  -u, --uninstall     Uninstall ArgoX-Lite
  -v, --update        Update sing-box to the latest release
  -n, --node          Show node info and subscription URLs
  -d, --doctor        Run a health check (services, egress, clock, probes)
  -t, --time          Check the system clock and correct it if it has drifted
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
    shift
    case "$opt" in
      -h|--help)      print_help; exit 0 ;;
      -i|--install)   install_flow; exit 0 ;;
      -u|--uninstall) uninstall; exit 0 ;;
      -v|--update)    update_singbox; exit 0 ;;
      -n|--node)      display_node_info; exit 0 ;;
      -d|--doctor)    doctor; exit 0 ;;
      -t|--time)      check_time || fix_time; exit $? ;;
      -a|--argo)      IS_ARGO='yes' ;;
      -f|--file)      apply_config_file "${1:-}"; shift 2>/dev/null || true; install_flow; exit 0 ;;
      -l|--lang)      case "${1:-}" in C|c) LANG_TAG='C' ;; E|e) LANG_TAG='E' ;; esac; shift 2>/dev/null || true ;;
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
