#!/bin/bash
# Start the Mu2e DAQ notification server (bootstraps the venv first if
# needed). Extra arguments are passed through to mu2edaq-notify-server,
# e.g.:  ./start-mu2edaq-notify-server.sh --port 9000 --no-zmq
set -euo pipefail
cd "$(dirname "$0")"

PIDFILE=data/notify-server.pid
LOGFILE=data/notify-server.log

if [ ! -x venv/bin/mu2edaq-notify-server ]; then
    ./bootstrap.sh
fi

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "Server already running (pid $(cat "$PIDFILE"))."
    exit 0
fi

mkdir -p data
CONFIG=${MU2EDAQ_NOTIFY_CONFIG:-config/notify-server.yaml}
nohup venv/bin/mu2edaq-notify-server --config "$CONFIG" "$@" \
    >> "$LOGFILE" 2>&1 &
echo $! > "$PIDFILE"
sleep 1
if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "Started mu2edaq-notify-server (pid $(cat "$PIDFILE"), log $LOGFILE)."
else
    echo "Server failed to start; last log lines:" >&2
    tail -n 20 "$LOGFILE" >&2
    rm -f "$PIDFILE"
    exit 1
fi
