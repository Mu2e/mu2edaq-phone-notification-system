#!/bin/bash
# Stop the SSH reverse tunnel used by the public Mu2e notification proxy.
# By default this leaves the local notify server and remote Caddy service up.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROXY_USER=${MU2EDAQ_NOTIFY_PROXY_USER:-ec2-user}
PROXY_HOST=${MU2EDAQ_NOTIFY_PROXY_HOST:-54.70.241.171}
PROXY_KEY=${MU2EDAQ_NOTIFY_PROXY_KEY:-data/mu2edaq-notify-proxy.pem}
PIDFILE=${MU2EDAQ_NOTIFY_PROXY_PIDFILE:-data/mu2edaq-notify-proxy-tunnel.pid}

if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE")
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
        for _ in $(seq 1 10); do
            if ! kill -0 "$PID" 2>/dev/null; then
                rm -f "$PIDFILE"
                echo "Proxy tunnel stopped."
                break
            fi
            sleep 0.5
        done
        if kill -0 "$PID" 2>/dev/null; then
            echo "Proxy tunnel did not exit; sending SIGKILL."
            kill -9 "$PID" 2>/dev/null || true
            rm -f "$PIDFILE"
            echo "Proxy tunnel killed."
        fi
    else
        echo "Removed stale proxy tunnel pid file."
        rm -f "$PIDFILE"
    fi
else
    echo "No proxy tunnel pid file; tunnel is not running from this script."
fi

if [ "${MU2EDAQ_NOTIFY_STOP_SERVER:-0}" = "1" ]; then
    ./stop-mu2edaq-notify-server.sh
fi

if [ "${MU2EDAQ_NOTIFY_STOP_REMOTE_CADDY:-0}" = "1" ]; then
    if [ ! -f "$PROXY_KEY" ]; then
        echo "Cannot stop remote Caddy; missing SSH key: $PROXY_KEY" >&2
        exit 1
    fi
    ssh -i "$PROXY_KEY" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        "$PROXY_USER@$PROXY_HOST" \
        "sudo systemctl stop caddy"
    echo "Remote Caddy stopped."
fi
