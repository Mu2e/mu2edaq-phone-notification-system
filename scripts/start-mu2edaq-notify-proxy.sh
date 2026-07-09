#!/bin/bash
# Start the Mu2e notification public access chain:
#   local notify server -> SSH reverse tunnel -> EC2 Caddy reverse proxy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PUBLIC_URL=${MU2EDAQ_NOTIFY_PUBLIC_URL:-https://notify.andrewnorman.org}
LOCAL_HEALTH_URL=${MU2EDAQ_NOTIFY_LOCAL_HEALTH_URL:-https://127.0.0.1:8095/api/health}
PROXY_USER=${MU2EDAQ_NOTIFY_PROXY_USER:-ec2-user}
PROXY_HOST=${MU2EDAQ_NOTIFY_PROXY_HOST:-54.70.241.171}
PROXY_KEY=${MU2EDAQ_NOTIFY_PROXY_KEY:-data/mu2edaq-notify-proxy.pem}
REMOTE_BIND=${MU2EDAQ_NOTIFY_PROXY_REMOTE_BIND:-127.0.0.1:18095}
LOCAL_TARGET=${MU2EDAQ_NOTIFY_PROXY_LOCAL_TARGET:-127.0.0.1:8095}
PIDFILE=${MU2EDAQ_NOTIFY_PROXY_PIDFILE:-data/mu2edaq-notify-proxy-tunnel.pid}
LOGFILE=${MU2EDAQ_NOTIFY_PROXY_LOGFILE:-data/mu2edaq-notify-proxy-tunnel.log}

mkdir -p data

if [ -f "$PIDFILE" ] && ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "Removing stale proxy tunnel pid file."
    rm -f "$PIDFILE"
fi

if [ ! -f "$PROXY_KEY" ]; then
    echo "Missing SSH key: $PROXY_KEY" >&2
    exit 1
fi
chmod 600 "$PROXY_KEY"

if [ "${MU2EDAQ_NOTIFY_SKIP_SERVER:-0}" != "1" ]; then
    if command -v curl >/dev/null 2>&1 && curl -kfsS "$LOCAL_HEALTH_URL" >/dev/null 2>&1; then
        echo "Local notify server is already healthy at $LOCAL_HEALTH_URL."
    else
        ./start-mu2edaq-notify-server.sh --no-discovery
    fi
fi

if command -v curl >/dev/null 2>&1 && curl -fsS "$PUBLIC_URL/api/health" >/dev/null 2>&1; then
    echo "Mu2e Notify proxy chain is already available at $PUBLIC_URL"
    exit 0
fi

if [ "${MU2EDAQ_NOTIFY_SKIP_REMOTE_CADDY:-0}" != "1" ]; then
    ssh -i "$PROXY_KEY" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        "$PROXY_USER@$PROXY_HOST" \
        "sudo systemctl start caddy"
fi

if command -v curl >/dev/null 2>&1 && curl -fsS "$PUBLIC_URL/api/health" >/dev/null 2>&1; then
    echo "Mu2e Notify proxy chain is available at $PUBLIC_URL"
    exit 0
fi

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "Proxy tunnel already running (pid $(cat "$PIDFILE"))."
else
    nohup ssh -i "$PROXY_KEY" \
        -N \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -o StrictHostKeyChecking=accept-new \
        -R "$REMOTE_BIND:$LOCAL_TARGET" \
        "$PROXY_USER@$PROXY_HOST" \
        >> "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 1

    if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "Started proxy tunnel (pid $(cat "$PIDFILE"), log $LOGFILE)."
    else
        echo "Proxy tunnel failed to start; last log lines:" >&2
        tail -n 20 "$LOGFILE" >&2 || true
        rm -f "$PIDFILE"
        exit 1
    fi
fi

if command -v curl >/dev/null 2>&1; then
    echo "Checking $PUBLIC_URL/api/health ..."
    curl -fsS "$PUBLIC_URL/api/health" >/dev/null
fi

echo "Mu2e Notify proxy chain is available at $PUBLIC_URL"
