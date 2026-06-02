#!/usr/bin/env bash
set -euo pipefail

# ============ Logging ============

# Colors (disabled if not tty)
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  CYAN=''
  NC=''
fi

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_debug() { echo -e "${CYAN}[DEBUG]${NC} $*"; }
die()       { log_error "$@"; exit 1; }

# ============ Utils ============

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

need_kernel_cmds() {
  need_cmd ip
  need_cmd iptables
}

urldecode() {
  printf '%b' "${1//%/\\x}"
}

# ============ Defaults ============

init_defaults() {
  DATA_DIR="${DATA_DIR:-/data}"
  XRAY_CONFIG="${XRAY_CONFIG:-/tmp/config.json}"
  TEMPLATE_DIR="${TEMPLATE_DIR:-/app/templates}"

  WG_PORT="${WG_PORT:-51820}"
  WG_SERVER_IP="${WG_SERVER_IP:-10.66.66.1}"
  WG_CLIENT_IP="${WG_CLIENT_IP:-10.66.66.2}"
  WG_SUBNET_CIDR="${WG_SUBNET_CIDR:-10.66.66.0/24}"
  WG_MTU="${WG_MTU:-1420}"
  WG_DNS="${WG_DNS:-1.1.1.1,8.8.8.8}"
  WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-0.0.0.0/0,::/0}"
  WG_PEER_ALLOWED_IPS="${WG_PEER_ALLOWED_IPS:-${WG_CLIENT_IP}/32}"
  WG_ENDPOINT="${WG_ENDPOINT:-}"
  WG_INTERFACE="${WG_INTERFACE:-wg0}"

  TPROXY_PORT="${TPROXY_PORT:-12345}"
  TPROXY_EXCLUDE_CIDRS="${TPROXY_EXCLUDE_CIDRS:-0.0.0.0/8,10.0.0.0/8,127.0.0.0/8,169.254.0.0/16,172.16.0.0/12,192.168.0.0/16,224.0.0.0/4,240.0.0.0/4,255.255.255.255/32}"
  KERNEL_DNS_BYPASS="${KERNEL_DNS_BYPASS:-1}"
  WG2VLESS_DRY_RUN="${WG2VLESS_DRY_RUN:-0}"

  XRAY_LOGLEVEL="${XRAY_LOGLEVEL:-warning}"

  # VLESS defaults
  VLESS_HOST="${VLESS_HOST:-}"
  VLESS_PORT="${VLESS_PORT:-}"
  VLESS_UUID="${VLESS_UUID:-}"
  VLESS_SECURITY="${VLESS_SECURITY:-reality}"
  VLESS_SNI="${VLESS_SNI:-}"
  VLESS_FLOW="${VLESS_FLOW:-xtls-rprx-vision}"
  VLESS_FP="${VLESS_FP:-chrome}"
  VLESS_PBK="${VLESS_PBK:-}"
  VLESS_SID="${VLESS_SID:-}"
  VLESS_SPIDERX="${VLESS_SPIDERX:-/}"
  VLESS_TRANSPORT="${VLESS_TRANSPORT:-tcp}"
  VLESS_PACKET_ENCODING="${VLESS_PACKET_ENCODING:-xudp}"

  # Key file paths
  mkdir -p "${DATA_DIR}"
  SERVER_PRIV="${DATA_DIR}/server_private.key"
  SERVER_PUB="${DATA_DIR}/server_public.key"
  CLIENT_PRIV="${DATA_DIR}/client_private.key"
  CLIENT_PUB="${DATA_DIR}/client_public.key"
}

# ============ WireGuard Keys ============

gen_wg_keypair() {
  wg genkey | tee "$1" | wg pubkey > "$2"
}

ensure_wg_keys() {
  if [[ ! -s "$SERVER_PRIV" || ! -s "$SERVER_PUB" ]]; then
    log_info "Generating server WireGuard keypair..."
    gen_wg_keypair "$SERVER_PRIV" "$SERVER_PUB"
  fi

  if [[ ! -s "$CLIENT_PRIV" || ! -s "$CLIENT_PUB" ]]; then
    log_info "Generating client WireGuard keypair..."
    gen_wg_keypair "$CLIENT_PRIV" "$CLIENT_PUB"
  fi

  SERVER_PRIVATE_KEY="$(cat "$SERVER_PRIV")"
  SERVER_PUBLIC_KEY="$(cat "$SERVER_PUB")"
  CLIENT_PRIVATE_KEY="$(cat "$CLIENT_PRIV")"
  CLIENT_PUBLIC_KEY="$(cat "$CLIENT_PUB")"

  log_info "WireGuard keys loaded"
}

# ============ VLESS Parsing ============

parse_vless_url() {
  local url="$1" base query hostport userinfo

  url="${url#vless://}"
  base="${url%%\?*}"
  query=""
  if [[ "$url" == *\?* ]]; then
    query="${url#*\?}"
    query="${query%%#*}"
  fi

  userinfo="${base%@*}"
  hostport="${base#*@}"

  VLESS_UUID="$userinfo"
  VLESS_HOST="${hostport%:*}"
  VLESS_PORT="${hostport##*:}"

  IFS='&' read -ra pairs <<< "$query"
  for pair in "${pairs[@]}"; do
    key="${pair%%=*}"
    val="$(urldecode "${pair#*=}")"
    case "$key" in
      security) VLESS_SECURITY="$val" ;;
      sni) VLESS_SNI="$val" ;;
      flow) VLESS_FLOW="$val" ;;
      fp) VLESS_FP="$val" ;;
      pbk) VLESS_PBK="$val" ;;
      sid) VLESS_SID="$val" ;;
      spiderX|spx) VLESS_SPIDERX="$val" ;;
      type) VLESS_TRANSPORT="$val" ;;
      packetEncoding|packet_encoding) VLESS_PACKET_ENCODING="$val" ;;
    esac
  done

  log_info "Parsed VLESS URL for ${VLESS_HOST}:${VLESS_PORT}"
}

parse_vless_config() {
  if [[ -n "${VLESS_URL:-}" ]]; then
    log_info "Parsing VLESS configuration from URL..."
    parse_vless_url "$VLESS_URL"
  else
    log_info "Using VLESS configuration from environment variables"
  fi
}

validate_vless_config() {
  [[ -n "$VLESS_HOST" ]] || die "VLESS_HOST or VLESS_URL is required"
  [[ -n "$VLESS_PORT" ]] || die "VLESS_PORT or VLESS_URL is required"
  [[ -n "$VLESS_UUID" ]] || die "VLESS_UUID or VLESS_URL is required"

  if [[ "$VLESS_SECURITY" == "reality" ]]; then
    [[ -n "$VLESS_SNI" ]] || die "VLESS_SNI or VLESS_URL with sni= is required for REALITY"
    [[ -n "$VLESS_PBK" ]] || die "VLESS_PBK or VLESS_URL with pbk= is required for REALITY"
  elif [[ "$VLESS_SECURITY" == "tls" ]]; then
    [[ -n "$VLESS_SNI" ]] || die "VLESS_SNI or VLESS_URL with sni= is required for TLS"
  fi

  log_info "VLESS config validated: ${VLESS_HOST}:${VLESS_PORT} (security: ${VLESS_SECURITY})"
}

# ============ Config Generation ============

build_stream_settings() {
  local stream_settings

  if [[ "$VLESS_SECURITY" == "reality" ]]; then
    stream_settings="$(jq -nc \
      --arg network "$VLESS_TRANSPORT" \
      --arg serverName "$VLESS_SNI" \
      --arg fingerprint "$VLESS_FP" \
      --arg publicKey "$VLESS_PBK" \
      --arg shortId "$VLESS_SID" \
      --arg spiderX "$VLESS_SPIDERX" \
      '{
        network: $network,
        security: "reality",
        realitySettings: {
          serverName: $serverName,
          fingerprint: $fingerprint,
          publicKey: $publicKey,
          shortId: $shortId,
          spiderX: $spiderX
        }
      }')"
  elif [[ "$VLESS_SECURITY" == "tls" ]]; then
    stream_settings="$(jq -nc \
      --arg network "$VLESS_TRANSPORT" \
      --arg serverName "$VLESS_SNI" \
      --arg fingerprint "$VLESS_FP" \
      '{
        network: $network,
        security: "tls",
        tlsSettings: {
          serverName: $serverName,
          fingerprint: $fingerprint
        }
      }')"
  else
    stream_settings="$(jq -nc \
      --arg network "$VLESS_TRANSPORT" \
      '{network: $network}')"
  fi

  echo "$stream_settings"
}

generate_xray_config() {
  log_info "Generating Xray configuration..."

  # Build computed values and export for envsubst
  export STREAM_SETTINGS="$(build_stream_settings)"

  # Build DNS array from comma-separated list
  IFS=',' read -ra DNS_ARR <<< "$WG_DNS"
  export DNS_JSON="$(printf '%s\n' "${DNS_ARR[@]}" | jq -R . | jq -s .)"

  IFS=',' read -ra PEER_ALLOWED_IPS_ARR <<< "$WG_PEER_ALLOWED_IPS"
  export WG_PEER_ALLOWED_IPS_JSON="$(printf '%s\n' "${PEER_ALLOWED_IPS_ARR[@]}" | jq -R 'gsub("^\\s+|\\s+$"; "") | select(length > 0)' | jq -s .)"

  # Export all variables needed by template
  export XRAY_LOGLEVEL WG_PORT SERVER_PRIVATE_KEY WG_MTU
  export CLIENT_PUBLIC_KEY WG_CLIENT_IP WG_PEER_ALLOWED_IPS_JSON
  export VLESS_HOST VLESS_PORT VLESS_UUID VLESS_FLOW VLESS_PACKET_ENCODING
  export TPROXY_PORT

  envsubst < "${TEMPLATE_DIR}/xray.json.tmpl" > "$XRAY_CONFIG"

  log_info "Xray config written to ${XRAY_CONFIG}"
}

validate_xray_config() {
  if ! jq empty "$XRAY_CONFIG" 2>/dev/null; then
    log_error "Generated Xray config is invalid JSON:"
    cat "$XRAY_CONFIG" >&2
    exit 1
  fi
  log_info "Xray config validated successfully"
}

generate_wg_client_config() {
  local wg_client_conf="${DATA_DIR}/client.conf"

  log_info "Generating WireGuard client configuration..."

  # Export variables for envsubst (set default for endpoint)
  export WG_ENDPOINT="${WG_ENDPOINT:-<YOUR_SERVER_IP>}"
  export CLIENT_PRIVATE_KEY WG_CLIENT_IP WG_DNS
  export SERVER_PUBLIC_KEY WG_PORT WG_ALLOWED_IPS WG_MTU

  envsubst < "${TEMPLATE_DIR}/client.conf.tmpl" > "$wg_client_conf"

  log_info "WireGuard client config saved to ${wg_client_conf}"

  # Print config for easy copying
  echo ""
  echo "========== WireGuard Client Config =========="
  cat "$wg_client_conf"
  echo "============================================="
  echo ""
}

# ============ Kernel WireGuard Backend ============

iptables_delete() {
  iptables "$@" >/dev/null 2>&1 || true
}

cleanup_kernel_backend() {
  iptables_delete -t nat -D POSTROUTING -o eth0 -p tcp --dport 53 -j MASQUERADE
  iptables_delete -t nat -D POSTROUTING -o eth0 -p udp --dport 53 -j MASQUERADE

  iptables_delete -t nat -D PREROUTING -i "$WG_INTERFACE" -p tcp -j WG2VLESS
  iptables_delete -t nat -D PREROUTING -i "$WG_INTERFACE" -p udp -j WG2VLESS
  iptables_delete -t nat -F WG2VLESS
  iptables_delete -t nat -X WG2VLESS

  ip link delete "$WG_INTERFACE" >/dev/null 2>&1 || true
}

setup_kernel_backend() {
  log_info "Setting up kernel WireGuard backend on ${WG_INTERFACE}..."
  need_kernel_cmds

  local peer_allowed_ips wg_prefix
  peer_allowed_ips="${WG_PEER_ALLOWED_IPS//[[:space:]]/}"
  wg_prefix="${WG_SUBNET_CIDR#*/}"
  [[ "$wg_prefix" =~ ^[0-9]+$ ]] || die "WG_SUBNET_CIDR must include a prefix length, for example 10.66.66.0/24"

  cleanup_kernel_backend

  ip link add dev "$WG_INTERFACE" type wireguard
  ip address add "${WG_SERVER_IP}/${wg_prefix}" dev "$WG_INTERFACE"
  ip link set mtu "$WG_MTU" up dev "$WG_INTERFACE"
  wg set "$WG_INTERFACE" \
    private-key "$SERVER_PRIV" \
    listen-port "$WG_PORT" \
    peer "$CLIENT_PUBLIC_KEY" \
    allowed-ips "$peer_allowed_ips"

  IFS=',' read -ra PEER_ROUTES <<< "$peer_allowed_ips"
  for cidr in "${PEER_ROUTES[@]}"; do
    [[ -z "$cidr" ]] && continue
    if [[ "$cidr" == "0.0.0.0/0" || "$cidr" == "::/0" ]]; then
      log_warn "Skipping default peer route ${cidr}; it would capture the container's own outbound traffic."
      continue
    fi
    if [[ "$cidr" == *":"* ]]; then
      log_warn "Skipping IPv6 peer route ${cidr}; kernel backend currently configures IPv4 transparent proxying only."
      continue
    fi
    ip route add "$cidr" dev "$WG_INTERFACE" >/dev/null 2>&1 || true
  done

  iptables -t nat -N WG2VLESS
  if [[ "$KERNEL_DNS_BYPASS" == "1" ]]; then
    log_info "DNS bypass is enabled; DNS requests from WireGuard clients will leave the container directly."
    iptables -t nat -A WG2VLESS -p tcp --dport 53 -j RETURN
    iptables -t nat -A WG2VLESS -p udp --dport 53 -j RETURN
    iptables -t nat -A POSTROUTING -o eth0 -p tcp --dport 53 -j MASQUERADE
    iptables -t nat -A POSTROUTING -o eth0 -p udp --dport 53 -j MASQUERADE
  fi

  IFS=',' read -ra EXCLUDES <<< "$TPROXY_EXCLUDE_CIDRS"
  for cidr in "${EXCLUDES[@]}"; do
    cidr="${cidr//[[:space:]]/}"
    [[ -z "$cidr" ]] && continue
    iptables -t nat -A WG2VLESS -d "$cidr" -j RETURN
  done
  iptables -t nat -A WG2VLESS -p tcp -j REDIRECT --to-ports "$TPROXY_PORT"
  iptables -t nat -A WG2VLESS -p udp -j REDIRECT --to-ports "$TPROXY_PORT"
  iptables -t nat -A PREROUTING -i "$WG_INTERFACE" -p tcp -j WG2VLESS
  iptables -t nat -A PREROUTING -i "$WG_INTERFACE" -p udp -j WG2VLESS

  log_info "Kernel WireGuard backend is ready"
}

# ============ Main ============

main() {
  log_info "Starting wg2vless bridge..."

  # Check required commands
  need_cmd xray
  need_cmd wg
  need_cmd jq
  need_cmd envsubst

  # Initialize
  init_defaults
  ensure_wg_keys

  # Parse and validate VLESS config
  parse_vless_config
  validate_vless_config

  if [[ "$WG_ALLOWED_IPS" == *"::"* ]]; then
    log_warn "Kernel WireGuard backend currently configures IPv4 transparent proxying only; IPv6 routes in WG_ALLOWED_IPS may not be proxied."
  fi

  # Generate configs
  generate_xray_config
  validate_xray_config
  generate_wg_client_config

  if [[ "$WG2VLESS_DRY_RUN" == "1" ]]; then
    log_info "WG2VLESS_DRY_RUN=1 set; exiting before runtime setup"
    exit 0
  fi

  setup_kernel_backend

  # Run Xray
  log_info "Starting Xray..."
  exec xray run -config "$XRAY_CONFIG"
}

main "$@"
