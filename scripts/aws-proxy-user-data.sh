#!/bin/bash
# Package half of the EC2 bootstrap for the Mu2e Notify public reverse proxy.
#
# Installs Caddy; it does not configure it and does not start it. The Caddyfile
# lives in config/aws/Caddyfile and the instance also has to publish its own
# public IPv4 into Route 53 (it no longer carries an Elastic IP), so the
# complete first-boot document is generated:
#
#     scripts/install-notify-dns-updater.sh --emit-user-data
#
# which appends the Caddyfile, the DNS updater, and finally the Caddy start, in
# that order.
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

# Enabled but deliberately not started here, and not configured here either.
# Caddy answers the Let's Encrypt HTTP-01 challenge on this host's public
# address, so it must not start until notify.andrewnorman.org has been moved to
# that address; a failed validation costs a rate-limit penalty. The generated
# user-data installs the Caddyfile, updates DNS, and only then starts Caddy;
# the caddy.service.d drop-in enforces the same order on later boots. Running
# this file on its own leaves Caddy installed, unconfigured and stopped.
systemctl enable caddy
