#!/bin/bash
# EC2 bootstrap script for the Mu2e Notify public reverse proxy.
#
# Review before use. Package repositories and install steps can change across
# Amazon Linux releases.
set -euxo pipefail
exec > >(tee -a /var/log/mu2edaq-notify-proxy-bootstrap.log) 2>&1

dnf update -y
dnf install -y dnf-plugins-core
if ! command -v caddy >/dev/null 2>&1; then
    dnf copr enable @caddy/caddy -y
    dnf install -y caddy
fi

cat > /etc/caddy/Caddyfile <<'CADDY'
notify.andrewnorman.org {
    encode gzip
    reverse_proxy https://127.0.0.1:18095 {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
CADDY

systemctl enable --now caddy
