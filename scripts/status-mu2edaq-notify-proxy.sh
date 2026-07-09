#!/bin/bash
# Show status for the local notify server, SSH reverse tunnel, remote Caddy,
# and public health endpoint.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PUBLIC_URL=${MU2EDAQ_NOTIFY_PUBLIC_URL:-https://notify.andrewnorman.org}
PROXY_USER=${MU2EDAQ_NOTIFY_PROXY_USER:-ec2-user}
PROXY_HOST=${MU2EDAQ_NOTIFY_PROXY_HOST:-54.70.241.171}
PROXY_KEY=${MU2EDAQ_NOTIFY_PROXY_KEY:-data/mu2edaq-notify-proxy.pem}
SERVER_PIDFILE=${MU2EDAQ_NOTIFY_SERVER_PIDFILE:-data/notify-server.pid}
TUNNEL_PIDFILE=${MU2EDAQ_NOTIFY_PROXY_PIDFILE:-data/mu2edaq-notify-proxy-tunnel.pid}

show_pid_status() {
    local name=$1
    local file=$2
    if [ -f "$file" ]; then
        local pid
        pid=$(cat "$file")
        if kill -0 "$pid" 2>/dev/null; then
            echo "$name: running (pid $pid)"
        else
            echo "$name: stale pid file ($file, pid $pid)"
        fi
    else
        echo "$name: no pid file ($file)"
    fi
}

show_pid_status "notify server" "$SERVER_PIDFILE"
show_pid_status "proxy tunnel" "$TUNNEL_PIDFILE"

if [ -f "$PROXY_KEY" ]; then
    remote_status=$(ssh -i "$PROXY_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new \
        "$PROXY_USER@$PROXY_HOST" \
        "systemctl is-active caddy" 2>/dev/null)
    echo "remote caddy: ${remote_status:-unknown}"
else
    echo "remote caddy: unknown; missing SSH key $PROXY_KEY"
fi

if command -v curl >/dev/null 2>&1; then
    http_code=$(curl --max-time 8 -sS -o /dev/null -w "%{http_code}" "$PUBLIC_URL/api/health" 2>/dev/null)
    echo "public health: HTTP ${http_code:-000} ($PUBLIC_URL/api/health)"
fi
