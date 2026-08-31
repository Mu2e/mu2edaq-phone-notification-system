#!/bin/bash
# Restore the SSH reverse tunnel that publishes the local notification server
# through the AWS proxy.
#
# There is deliberately no supervision of this tunnel: ExitOnForwardFailure
# plus ServerAlive keepalives make a broken one die promptly and visibly rather
# than linger as a zombie. This script is the other half of that bargain -- it
# works out which part is broken and puts it back.
#
# The tunnel has three failure modes, and only the first is obvious:
#
#   1. the local ssh process is gone;
#   2. the local process is alive but the remote listener is not, because the
#      connection dropped without either end noticing yet;
#   3. the local process is gone but sshd on the proxy still holds
#      127.0.0.1:18095 from the dead session. This is the one that makes a
#      naive restart fail: ExitOnForwardFailure=yes means the new tunnel
#      refuses to start while the stale listener is there, and the error --
#      "remote port forwarding failed" -- names the symptom, not the cause.
#
# So health is judged end to end, by asking the proxy to reach the local server
# through the tunnel, and a restart clears a stranded remote listener first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/notify-proxy-common.sh
. "$ROOT/scripts/notify-proxy-common.sh"

usage() {
    cat <<'USAGE'
Usage: scripts/restore-mu2edaq-notify-tunnel.sh [options]

Check the SSH reverse tunnel end to end and rebuild it if it is broken.

Options:
      --check         report what is broken, change nothing; exit 1 if the
                      tunnel is not carrying traffic
      --force         rebuild even if the tunnel is healthy
      --watch         keep checking, restoring whenever it breaks
      --interval SEC  seconds between checks under --watch (default 30)
      --max-restarts N
                      give up after N restores in one --watch run, so a
                      persistent fault does not become a restart loop
                      (default 20; 0 = no limit)
      --timeout SEC   per-ssh-command timeout (default 8)
  -h, --help          this text

Exit status: 0 tunnel carrying traffic, 1 could not restore it, 2 usage error.
USAGE
}

CHECK_ONLY=0
FORCE=0
WATCH=0
INTERVAL=${MU2EDAQ_NOTIFY_TUNNEL_INTERVAL:-30}
MAX_RESTARTS=${MU2EDAQ_NOTIFY_TUNNEL_MAX_RESTARTS:-20}
SSH_TIMEOUT=${MU2EDAQ_NOTIFY_TUNNEL_SSH_TIMEOUT:-8}

while [ $# -gt 0 ]; do
    case "$1" in
        --check)         CHECK_ONLY=1; shift ;;
        --force)         FORCE=1; shift ;;
        --watch)         WATCH=1; shift ;;
        --interval)      INTERVAL=${2:?--interval needs a value}; shift 2 ;;
        --max-restarts)  MAX_RESTARTS=${2:?--max-restarts needs a value}; shift 2 ;;
        --timeout)       SSH_TIMEOUT=${2:?--timeout needs a value}; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

PROXY_USER=${MU2EDAQ_NOTIFY_PROXY_USER:-ec2-user}
PROXY_KEY=${MU2EDAQ_NOTIFY_PROXY_KEY:-data/mu2edaq-notify-proxy.pem}
REMOTE_BIND=${MU2EDAQ_NOTIFY_PROXY_REMOTE_BIND:-127.0.0.1:18095}
LOCAL_TARGET=${MU2EDAQ_NOTIFY_PROXY_LOCAL_TARGET:-127.0.0.1:8095}
LOCAL_HEALTH_URL=${MU2EDAQ_NOTIFY_LOCAL_HEALTH_URL:-https://127.0.0.1:8095/api/health}
PIDFILE=${MU2EDAQ_NOTIFY_PROXY_PIDFILE:-data/mu2edaq-notify-proxy-tunnel.pid}
LOGFILE=${MU2EDAQ_NOTIFY_PROXY_LOGFILE:-data/mu2edaq-notify-proxy-tunnel.log}
REMOTE_PORT=${REMOTE_BIND##*:}

mkdir -p data

ts()  { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*"; }

PROXY_HOST=""

resolve_host() {
    PROXY_HOST=$(notify_proxy_resolve_host)
    [ -n "$PROXY_HOST" ]
}

# shellcheck disable=SC2207
ssh_proxy() {
    local opts=($(notify_proxy_ssh_opts))
    ssh -i "$PROXY_KEY" "${opts[@]}" -o ConnectTimeout="$SSH_TIMEOUT" \
        "$PROXY_USER@$PROXY_HOST" "$@"
}

local_pid() {
    [ -f "$PIDFILE" ] || return 1
    local pid
    pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
    printf '%s\n' "$pid"
}

# The only check that means anything: can the proxy actually reach the local
# server through the forward? A listening socket on either end proves nothing
# about the path between them.
tunnel_carries_traffic() {
    ssh_proxy "curl -kfsS --max-time $SSH_TIMEOUT https://$REMOTE_BIND/api/health" \
        >/dev/null 2>&1
}

remote_listener_pid() {
    # ss prints users:(("sshd",pid=1234,fd=9)); take the pid of whatever holds
    # the forwarded port.
    ssh_proxy "ss -ltnpH 'sport = :$REMOTE_PORT' 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2" \
        2>/dev/null | tr -d '[:space:]'
}

# Kill a listener left behind by a dead session, and nothing else. PIDs are
# recycled and our own session is also an sshd, so both are checked before the
# kill: the command line must be sshd, and it must not be the sshd serving this
# very connection.
clear_stranded_listener() {
    local pid
    pid=$(remote_listener_pid || true)
    if [ -z "$pid" ]; then
        return 0
    fi
    log "Proxy still holds $REMOTE_BIND (pid $pid); checking whether it is stale."
    local verdict
    verdict=$(ssh_proxy "
        target=$pid
        mine=\$(ps -o ppid= -p \$\$ 2>/dev/null | tr -d ' ')
        cmd=\$(tr '\\0' ' ' < /proc/\$target/cmdline 2>/dev/null)
        if [ -z \"\$cmd\" ]; then
            echo 'gone'
        elif [ \"\$target\" = \"\$mine\" ]; then
            echo 'self'
        elif echo \"\$cmd\" | grep -q sshd; then
            kill \$target 2>/dev/null && echo 'killed' || echo 'kill-failed'
        else
            echo \"not-sshd:\$cmd\"
        fi" 2>/dev/null | tr -d '\r')
    case "$verdict" in
        killed)  log "Cleared the stale listener." ;;
        gone)    log "It had already exited." ;;
        self)    log "It belongs to this ssh session; not touching it." ;;
        not-sshd:*) log "WARNING: $REMOTE_BIND is held by something that is not sshd: ${verdict#not-sshd:}"
                    log "Leaving it alone; the tunnel cannot bind until it is gone." ;;
        *)       log "Could not determine what holds the port (verdict: ${verdict:-none})." ;;
    esac
}

stop_local_tunnel() {
    local pid
    if pid=$(local_pid); then
        log "Stopping the local tunnel process (pid $pid)."
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 10); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$pid" 2>/dev/null; then
            log "It did not exit; sending SIGKILL."
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi
    rm -f "$PIDFILE"
}

start_local_tunnel() {
    log "Opening the tunnel: proxy $REMOTE_BIND -> local $LOCAL_TARGET."
    # shellcheck disable=SC2207
    local opts=($(notify_proxy_ssh_opts))
    nohup ssh -i "$PROXY_KEY" \
        -N \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        "${opts[@]}" \
        -R "$REMOTE_BIND:$LOCAL_TARGET" \
        "$PROXY_USER@$PROXY_HOST" \
        >> "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 2
    if ! local_pid >/dev/null; then
        log "The tunnel process exited immediately. Last log lines:"
        tail -n 10 "$LOGFILE" >&2 || true
        rm -f "$PIDFILE"
        return 1
    fi
    log "Tunnel process running (pid $(cat "$PIDFILE"), log $LOGFILE)."
}

report_state() {
    local pid=${1:-} carrying=${2:-}
    log "local process: ${pid:-none}"
    log "proxy address: ${PROXY_HOST:-unresolved}"
    log "end to end:    $carrying"
}

# One pass. Returns 0 when the tunnel is carrying traffic afterwards.
restore_once() {
    if ! resolve_host; then
        log "The proxy has no reachable address: it is stopped, or has no public"
        log "IPv4 and $MU2EDAQ_NOTIFY_PROXY_DNS_NAME does not resolve."
        log "Start it first: scripts/start-mu2edaq-notify-chain.sh"
        return 1
    fi

    local pid=""
    pid=$(local_pid || true)

    if [ "$FORCE" = "0" ] && tunnel_carries_traffic; then
        report_state "$pid" "healthy"
        return 0
    fi

    if [ "$FORCE" = "1" ]; then
        log "Rebuilding on request (--force)."
    else
        report_state "$pid" "NOT carrying traffic"
        if [ -n "$pid" ]; then
            log "The local process is alive but the forward is dead, so the"
            log "connection dropped without ssh noticing. Rebuilding."
        fi
    fi

    if [ "$CHECK_ONLY" = "1" ]; then
        return 1
    fi

    # The tunnel can be restored without the local server, but it will only
    # carry 502s, so say so rather than reporting a false success later.
    if command -v curl >/dev/null 2>&1 \
       && ! curl -kfsS --max-time 5 "$LOCAL_HEALTH_URL" >/dev/null 2>&1; then
        log "WARNING: the local notify server is not answering on $LOCAL_HEALTH_URL."
        log "Start it with ./start-mu2edaq-notify-server.sh, or the public"
        log "endpoint will return 502 through a perfectly good tunnel."
    fi

    stop_local_tunnel
    clear_stranded_listener
    start_local_tunnel || return 1

    local attempt
    for attempt in 1 2 3 4 5; do
        if tunnel_carries_traffic; then
            log "Restored: the proxy reaches the local server through the tunnel."
            return 0
        fi
        log "Not carrying traffic yet ($attempt/5); waiting."
        sleep 2
    done

    log "The tunnel process is running but the proxy still cannot reach the"
    log "local server through it. Last log lines:"
    tail -n 10 "$LOGFILE" >&2 || true
    return 1
}

if [ ! -f "$PROXY_KEY" ]; then
    echo "Missing SSH key: $PROXY_KEY" >&2
    exit 1
fi
chmod 600 "$PROXY_KEY"

if [ "$WATCH" = "0" ]; then
    restore_once
    exit $?
fi

log "Watching the tunnel every ${INTERVAL}s (max-restarts $MAX_RESTARTS)."
restarts=0
while true; do
    if resolve_host && tunnel_carries_traffic; then
        sleep "$INTERVAL"
        continue
    fi
    if [ "$MAX_RESTARTS" != "0" ] && [ "$restarts" -ge "$MAX_RESTARTS" ]; then
        log "Reached $MAX_RESTARTS restores without the tunnel staying up."
        log "Something else is wrong; stopping rather than looping."
        exit 1
    fi
    restarts=$((restarts + 1))
    log "Restore attempt $restarts."
    if restore_once; then
        log "Tunnel is back."
    else
        log "Restore failed; will try again in ${INTERVAL}s."
    fi
    sleep "$INTERVAL"
done
