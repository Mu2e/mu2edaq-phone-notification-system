#!/bin/bash
# Start the Mu2e notification public access chain:
#   local notify server -> SSH reverse tunnel -> EC2 Caddy reverse proxy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/notify-proxy-common.sh
. "$ROOT/scripts/notify-proxy-common.sh"

PUBLIC_URL=${MU2EDAQ_NOTIFY_PUBLIC_URL:-https://$MU2EDAQ_NOTIFY_PROXY_DNS_NAME}
LOCAL_HEALTH_URL=${MU2EDAQ_NOTIFY_LOCAL_HEALTH_URL:-https://127.0.0.1:8095/api/health}
PROXY_USER=${MU2EDAQ_NOTIFY_PROXY_USER:-ec2-user}
# No Elastic IP: ask the EC2 API for the address this start was given, and
# fall back to whatever the public name resolves to.
PROXY_HOST=$(notify_proxy_resolve_host)
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

if [ -z "$PROXY_HOST" ]; then
    echo "No address for $MU2EDAQ_NOTIFY_PROXY_INSTANCE_ID: it is not running, or has no" >&2
    echo "public IPv4 and $MU2EDAQ_NOTIFY_PROXY_DNS_NAME does not resolve." >&2
    echo "Use scripts/start-mu2edaq-notify-chain.sh to start the instance first." >&2
    exit 1
fi
echo "Proxy address: $PROXY_HOST ($MU2EDAQ_NOTIFY_PROXY_DNS_NAME)"

if [ ! -f "$PROXY_KEY" ]; then
    echo "Missing SSH key: $PROXY_KEY" >&2
    exit 1
fi
chmod 600 "$PROXY_KEY"

# shellcheck disable=SC2207
SSH_OPTS=($(notify_proxy_ssh_opts))

if [ "${MU2EDAQ_NOTIFY_SKIP_SERVER:-0}" != "1" ]; then
    if command -v curl >/dev/null 2>&1 && curl -kfsS "$LOCAL_HEALTH_URL" >/dev/null 2>&1; then
        echo "Local notify server is already healthy at $LOCAL_HEALTH_URL."
    else
        ./start-mu2edaq-notify-server.sh
    fi
fi

if command -v curl >/dev/null 2>&1 && curl -fsS "$PUBLIC_URL/api/health" >/dev/null 2>&1; then
    echo "Mu2e Notify proxy chain is already available at $PUBLIC_URL"
    exit 0
fi

if [ "${MU2EDAQ_NOTIFY_SKIP_REMOTE_CADDY:-0}" != "1" ]; then
    ssh -i "$PROXY_KEY" "${SSH_OPTS[@]}" \
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
        "${SSH_OPTS[@]}" \
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
