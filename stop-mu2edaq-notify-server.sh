#!/bin/bash
# Stop the Mu2e DAQ notification server cleanly (SIGTERM, then SIGKILL
# after a grace period) and clean up the pid file.
set -euo pipefail
cd "$(dirname "$0")"

PIDFILE=data/notify-server.pid

if [ ! -f "$PIDFILE" ]; then
    echo "No pid file; server not running (or started by hand)."
    exit 0
fi

PID=$(cat "$PIDFILE")
if ! kill -0 "$PID" 2>/dev/null; then
    echo "Stale pid file removed."
    rm -f "$PIDFILE"
    exit 0
fi

kill "$PID"
for _ in $(seq 1 10); do
    if ! kill -0 "$PID" 2>/dev/null; then
        rm -f "$PIDFILE"
        echo "Server stopped."
        exit 0
    fi
    sleep 0.5
done

echo "Server did not exit; sending SIGKILL."
kill -9 "$PID" 2>/dev/null || true
rm -f "$PIDFILE"
echo "Server killed."
