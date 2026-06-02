FROM alpine:3.21

ARG XRAY_VERSION=26.2.6

RUN apk add --no-cache \
    bash \
    curl \
    unzip \
    jq \
    gettext \
    openssl \
    ca-certificates \
    iproute2 \
    iptables \
    wireguard-tools

RUN ARCH="$(apk --print-arch)" && \
    case "$ARCH" in \
      x86_64) XRAY_ARCH="64" ;; \
      aarch64) XRAY_ARCH="arm64-v8a" ;; \
      armv7) XRAY_ARCH="arm32-v7a" ;; \
      *) echo "Unsupported arch: $ARCH" && exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/xray.zip \
      "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip" && \
    unzip /tmp/xray.zip -d /tmp/xray && \
    install -m 0755 /tmp/xray/xray /usr/local/bin/xray && \
    rm -rf /tmp/xray /tmp/xray.zip

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY templates /app/templates
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/data"]
EXPOSE 51820/udp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
