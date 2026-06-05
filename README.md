# wg2vless

Docker bridge that accepts WireGuard connections and forwards traffic through a VLESS proxy. Connect any WireGuard client to route traffic via your Xray server. Ideal for routers that only support WireGuard.

## Features

- Standard WireGuard protocol on client side
- Kernel WireGuard inside the container for better throughput
- VLESS outbound with REALITY or TLS
- Auto-generates WireGuard keypairs
- Config via URL or individual variables
- Multi-arch support (amd64, arm64, armv7)

## Configuration

Pass VLESS URL via environment variable or use individual variables:

```bash
VLESS_URL="vless://uuid@host:443?type=tcp&security=reality&pbk=...&sni=example.com&sid=abc&fp=chrome&flow=xtls-rprx-vision"
```

## Usage

wg2vless uses Linux kernel WireGuard in the container, so the container needs `NET_ADMIN` and `/dev/net/tun`:

```bash
docker run -d \
  --cap-add NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  -p 51820:51820/udp \
  -v ./data:/data \
  -e VLESS_URL="vless://..." \
  -e WG_ENDPOINT="your-server-ip" \
  spinogrizz/wg2vless:latest
```

Or with docker-compose - edit `docker-compose.yml` and run:

```bash
docker-compose up -d
```

Client config is generated at `./data/client.conf` - import it into any WireGuard app.

## How it works

WireGuard packets are decrypted by the Linux kernel inside the container. Traffic from the WireGuard interface is then redirected to Xray (`nat REDIRECT`), which sends it through the configured VLESS outbound.

- **TCP** keeps its original destination via `SO_ORIGINAL_DST` and is proxied through VLESS.
- **DNS** (port 53) is redirected to a dedicated Xray inbound with a fixed resolver (the first `WG_DNS` entry) and proxied through VLESS, so there is **no DNS leak** and no original-destination problem.
- **Other UDP** (notably QUIC / HTTP/3 on UDP 443) cannot be transparently proxied with `nat REDIRECT` because the original destination is lost for UDP. By default it is **rejected** (`REJECT_NON_DNS_UDP=1`) so clients fall back to TCP/HTTP2 instantly instead of hanging on timeouts.

> `nat REDIRECT` is used instead of Linux TPROXY because TPROXY does not reliably deliver to the proxy socket inside Docker containers on many kernels. The container needs `NET_ADMIN` and `/dev/net/tun`.

## Environment

#### VLESS

| Variable | Example | Description |
|----------|---------|-------------|
| `VLESS_URL` | `vless://uuid@host:443?...` | Full URL (alternative to individual vars) |
| `VLESS_HOST` | `1.2.3.4` | Server address |
| `VLESS_PORT` | `443` | Server port |
| `VLESS_UUID` | `a1b2c3d4-...` | Client UUID |
| `VLESS_SECURITY` | `reality` | `reality`, `tls`, or `none` |
| `VLESS_SNI` | `yahoo.com` | Server name for TLS/REALITY |
| `VLESS_PBK` | `abc123...` | REALITY public key |
| `VLESS_SID` | `aabbcc` | REALITY short ID |
| `VLESS_FP` | `chrome` | Browser fingerprint |
| `VLESS_FLOW` | `xtls-rprx-vision` | Flow control |
| `VLESS_PACKET_ENCODING` | `xudp` | UDP packet encoding for VLESS outbound |
| `VLESS_TRANSPORT` | `tcp` | Transport type |

#### WireGuard

| Variable | Example | Description |
|----------|---------|-------------|
| `WG_PORT` | `51820` | Listen port |
| `WG_ENDPOINT` | `vpn.example.com` | Server address for client config |
| `WG_SERVER_IP` | `10.66.66.1` | Server tunnel IP |
| `WG_CLIENT_IP` | `10.66.66.2` | Client tunnel IP |
| `WG_SUBNET_CIDR` | `10.66.66.0/24` | WireGuard tunnel subnet |
| `WG_MTU` | `1420` | MTU size |
| `WG_DNS` | `1.1.1.1,8.8.8.8` | DNS servers |
| `WG_ALLOWED_IPS` | `0.0.0.0/0,::/0` | Client-side routed prefixes |
| `WG_PEER_ALLOWED_IPS` | `10.66.66.2/32` | Server-side peer allowed IPs; add routed LAN subnets here if your router does not NAT tunnel clients |
| `WG_INTERFACE` | `wg0` | WireGuard interface name inside the container |
| `REDIRECT_PORT` | `12345` | Local port Xray listens on for redirected TCP |
| `DNS_REDIRECT_PORT` | `12346` | Local port Xray listens on for redirected DNS |
| `BYPASS_CIDRS` | `10.0.0.0/8,...` | Comma-separated destinations bypassed by the proxy |
| `REJECT_NON_DNS_UDP` | `1` | `1` rejects non-DNS UDP (QUIC) so clients fall back to TCP; `0` lets it pass untunnelled |
| `KERNEL_DNS_BYPASS` | `0` | `1` sends DNS directly from the container (DNS leak) instead of through VLESS |

#### Other

| Variable | Example | Description |
|----------|---------|-------------|
| `XRAY_LOGLEVEL` | `warning` | `debug`, `info`, `warning`, `error` |
| `DATA_DIR` | `/data` | Keys storage path |
| `WG2VLESS_DRY_RUN` | `1` | Generate and validate config, then exit before runtime setup |

## License

MIT
