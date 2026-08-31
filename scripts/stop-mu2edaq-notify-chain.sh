#!/bin/bash
# Stop the full Mu2e Notify public application chain:
#   local notify server, SSH reverse tunnel, remote Caddy, and EC2 instance.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/notify-proxy-common.sh
. "$ROOT/scripts/notify-proxy-common.sh"

INSTANCE_ID=$MU2EDAQ_NOTIFY_PROXY_INSTANCE_ID
PROXY_USER=${MU2EDAQ_NOTIFY_PROXY_USER:-ec2-user}
# The address this start happened to get; empty once the instance is stopped,
# at which point there is nothing left to reach anyway.
PROXY_HOST=$(notify_proxy_resolve_host)
PROXY_KEY=${MU2EDAQ_NOTIFY_PROXY_KEY:-data/mu2edaq-notify-proxy.pem}
TUNNEL_PIDFILE=${MU2EDAQ_NOTIFY_PROXY_PIDFILE:-data/mu2edaq-notify-proxy-tunnel.pid}
SERVER_LAUNCH_AGENT=${MU2EDAQ_NOTIFY_SERVER_LAUNCH_AGENT:-$HOME/Library/LaunchAgents/org.mu2edaq.notify-server.plist}
TUNNEL_LAUNCH_AGENT=${MU2EDAQ_NOTIFY_TUNNEL_LAUNCH_AGENT:-$HOME/Library/LaunchAgents/org.mu2edaq.notify-proxy-tunnel.plist}
DEBUG=${MU2EDAQ_NOTIFY_DEBUG:-0}

if [ "$DEBUG" = "1" ]; then
    set -x
fi

ts() {
    date "+%Y-%m-%d %H:%M:%S"
}

log() {
    echo "[$(ts)] $*"
}

run() {
    log "+ $*"
    "$@"
}

aws_state() {
    aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' --output text
}

# shellcheck disable=SC2207
SSH_OPTS=($(notify_proxy_ssh_opts))

ssh_proxy() {
    ssh -i "$PROXY_KEY" "${SSH_OPTS[@]}" "$PROXY_USER@$PROXY_HOST" "$@"
}

launchd_bootout_if_loaded() {
    local label=$1
    local plist=$2
    if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
        log "Unloading LaunchAgent $label ..."
        run launchctl bootout "gui/$(id -u)" "$plist" || true
    else
        log "LaunchAgent $label is not loaded."
    fi
}

stop_pidfile_process() {
    local name=$1
    local pidfile=$2
    if [ ! -f "$pidfile" ]; then
        log "$name pidfile missing: $pidfile"
        return 0
    fi
    local pid
    pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
        log "Stopping $name (pid $pid)."
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 10); do
            if ! kill -0 "$pid" 2>/dev/null; then
                rm -f "$pidfile"
                log "$name stopped."
                return 0
            fi
            sleep 0.5
        done
        log "$name did not exit; sending SIGKILL."
        kill -9 "$pid" 2>/dev/null || true
    else
        log "$name pidfile was stale: $pidfile -> $pid"
    fi
    rm -f "$pidfile"
}

log "Stopping Mu2e Notify chain from $ROOT"

log "Step 1/5: stop local notify server."
launchd_bootout_if_loaded "org.mu2edaq.notify-server" "$SERVER_LAUNCH_AGENT"
./stop-mu2edaq-notify-server.sh || true
if lsof -nP -iTCP:8095 -sTCP:LISTEN >/dev/null 2>&1; then
    log "Warning: something is still listening on port 8095:"
    lsof -nP -iTCP:8095 -sTCP:LISTEN || true
else
    log "Verified: no listener on local port 8095."
fi

log "Step 2/5: stop SSH reverse tunnel."
launchd_bootout_if_loaded "org.mu2edaq.notify-proxy-tunnel" "$TUNNEL_LAUNCH_AGENT"
stop_pidfile_process "proxy tunnel" "$TUNNEL_PIDFILE"
if [ -z "$PROXY_HOST" ]; then
    log "Proxy has no current address; skipping the stray-connection check."
elif lsof -nP -iTCP | grep -q "$PROXY_HOST:22"; then
    log "Warning: an SSH connection to $PROXY_HOST:22 is still present:"
    lsof -nP -iTCP | grep "$PROXY_HOST:22" || true
else
    log "Verified: no SSH TCP connection to $PROXY_HOST:22."
fi

log "Step 3/5: stop remote Caddy if EC2 is running."
state=$(aws_state)
log "EC2 state before stop: $state"
if [ "$state" = "running" ] && [ -z "$PROXY_HOST" ]; then
    log "Skipping remote Caddy stop: EC2 is running but has no reachable address."
elif [ "$state" = "running" ]; then
    if [ -f "$PROXY_KEY" ]; then
        ssh_proxy "printf 'before='; systemctl is-active caddy || true" || true
        run ssh_proxy "sudo systemctl stop caddy" || true
        ssh_proxy "printf 'after='; systemctl is-active caddy || true" || true
    else
        log "Skipping remote Caddy stop: missing SSH key $PROXY_KEY"
    fi
else
    log "Skipping remote Caddy stop because EC2 is $state."
fi

log "Step 4/5: retract the public DNS record if it would dangle."
# Stopping releases an auto-assigned public IPv4, and a record left pointing at
# a released address is a dangling record: whoever AWS hands that address to
# next can answer an ACME HTTP-01 challenge for notify.andrewnorman.org and
# serve trusted TLS under our name. Parking the record on an unroutable address
# while the address is still ours closes that window.
#
# But retraction is only correct when there is something to dangle, and only
# for a record that is ours. Retracting unconditionally breaks the chain in two
# cases -- an Elastic IP that never leaves the account, and a record deliberately
# pointed somewhere else -- and the record then stays broken until something
# republishes it.
# shellcheck disable=SC2207
decision=($(notify_proxy_retract_decision))
case "${decision[0]}:${decision[1]:-}" in
    retract:)
        run scripts/update-notify-dns.sh --retract || \
            log "WARNING: could not retract $MU2EDAQ_NOTIFY_PROXY_DNS_NAME; it still points at a released address."
        ;;
    skip:disabled)
        log "MU2EDAQ_NOTIFY_DNS_RETRACT=0; leaving the record as it is."
        ;;
    skip:elastic-ip)
        log "Elastic IP ${decision[2]} stays associated across the stop, so the"
        log "address is not released and the record cannot dangle. Leaving it."
        ;;
    skip:no-address)
        log "Instance has no public address to release; leaving the record alone."
        ;;
    skip:not-ours)
        log "Record points at ${decision[2]}, not this instance's ${decision[3]};"
        log "it is not ours to retract. Leaving it alone."
        ;;
    *)
        log "Unexpected retraction verdict '${decision[*]}'; leaving the record alone."
        ;;
esac

log "Step 5/5: stop EC2 proxy instance."
if [ "$state" = "running" ] || [ "$state" = "pending" ]; then
    run aws ec2 stop-instances --instance-ids "$INSTANCE_ID" >/dev/null
    run aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
elif [ "$state" = "stopping" ]; then
    run aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
else
    log "EC2 proxy instance is already $state."
fi
log "EC2 final state: $(aws_state)"

log "Mu2e Notify chain is stopped."
