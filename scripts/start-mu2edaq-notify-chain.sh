#!/bin/bash
# Start the full Mu2e Notify public application chain:
#   EC2 proxy -> remote Caddy -> SSH reverse tunnel -> local notify server.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/notify-proxy-common.sh
. "$ROOT/scripts/notify-proxy-common.sh"

INSTANCE_ID=$MU2EDAQ_NOTIFY_PROXY_INSTANCE_ID
PUBLIC_URL=${MU2EDAQ_NOTIFY_PUBLIC_URL:-https://$MU2EDAQ_NOTIFY_PROXY_DNS_NAME}
LOCAL_HEALTH_URL=${MU2EDAQ_NOTIFY_LOCAL_HEALTH_URL:-https://127.0.0.1:8095/api/health}
PROXY_USER=${MU2EDAQ_NOTIFY_PROXY_USER:-ec2-user}
# Filled in after the instance is running: there is no Elastic IP any more, so
# the address is only known once EC2 has assigned one for this start.
PROXY_HOST=
PROXY_KEY=${MU2EDAQ_NOTIFY_PROXY_KEY:-data/mu2edaq-notify-proxy.pem}
REMOTE_BIND=${MU2EDAQ_NOTIFY_PROXY_REMOTE_BIND:-127.0.0.1:18095}
LOCAL_TARGET=${MU2EDAQ_NOTIFY_PROXY_LOCAL_TARGET:-127.0.0.1:8095}
PIDFILE=${MU2EDAQ_NOTIFY_PROXY_PIDFILE:-data/mu2edaq-notify-proxy-tunnel.pid}
LOGFILE=${MU2EDAQ_NOTIFY_PROXY_LOGFILE:-data/mu2edaq-notify-proxy-tunnel.log}
SSH_WAIT_TRIES=${MU2EDAQ_NOTIFY_SSH_WAIT_TRIES:-36}
DEBUG=${MU2EDAQ_NOTIFY_DEBUG:-0}

mkdir -p data

if [ "$DEBUG" = "1" ]; then
    set -x
fi

ts() {
    date "+%Y-%m-%d %H:%M:%S"
}

log() {
    echo "[$(ts)] $*"
}

fail() {
    echo "[$(ts)] ERROR: $*" >&2
    print_diagnostics >&2 || true
    exit 1
}

run() {
    log "+ $*"
    "$@"
}

aws_state() {
    aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' --output text
}

aws_status() {
    aws ec2 describe-instance-status --instance-ids "$INSTANCE_ID" \
        --include-all-instances \
        --query 'InstanceStatuses[0].{InstanceState:InstanceState.Name,SystemStatus:SystemStatus.Status,InstanceStatus:InstanceStatus.Status}' \
        --output json
}

security_group_ids() {
    aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' \
        --output text
}

print_security_group_ingress() {
    local groups
    groups=$(security_group_ids 2>/dev/null || true)
    if [ -z "$groups" ]; then
        echo "Security group diagnostics unavailable."
        return 0
    fi
    echo "Security group ingress for $groups:"
    aws ec2 describe-security-groups --group-ids $groups \
        --query 'SecurityGroups[].IpPermissions[].{Protocol:IpProtocol,From:FromPort,To:ToPort,IPv4:IpRanges[].CidrIp,IPv6:Ipv6Ranges[].CidrIpv6}' \
        --output json || true
}

# shellcheck disable=SC2207
SSH_OPTS=($(notify_proxy_ssh_opts))

ssh_proxy() {
    ssh -i "$PROXY_KEY" "${SSH_OPTS[@]}" "$PROXY_USER@$PROXY_HOST" "$@"
}

remote_tunnel_bound() {
    ssh_proxy "ss -ltn | grep -q '127.0.0.1:18095'" >/dev/null 2>&1
}

curl_health() {
    local url=$1
    local insecure=${2:-0}
    # Truncate first: on a connection timeout curl writes nothing, and a body
    # left over from the previous call reads as though this one had answered.
    : > /tmp/mu2edaq-notify-health.out
    : > /tmp/mu2edaq-notify-health.err
    local args=(--max-time 8 -sS -o /tmp/mu2edaq-notify-health.out -w "%{http_code}")
    if [ "$insecure" = "1" ]; then
        args=(-k "${args[@]}")
    fi
    curl "${args[@]}" "$url" 2>/tmp/mu2edaq-notify-health.err
}

wait_for_ssh() {
    local tries=${1:-36}
    local delay=${2:-5}
    local attempt errfile
    errfile=/tmp/mu2edaq-notify-ssh.err
    for attempt in $(seq 1 "$tries"); do
        if ssh_proxy "true" >/dev/null 2>"$errfile"; then
            log "SSH reachable on $PROXY_HOST."
            return 0
        fi
        log "SSH not ready yet ($attempt/$tries); waiting ${delay}s ..."
        if [ -s "$errfile" ]; then
            sed 's/^/[ssh] /' "$errfile"
        fi
        sleep "$delay"
    done
    return 1
}

wait_for_health() {
    local label=$1
    local url=$2
    local insecure=${3:-0}
    local tries=${4:-20}
    local delay=${5:-2}
    local attempt code
    for attempt in $(seq 1 "$tries"); do
        code=$(curl_health "$url" "$insecure" || true)
        if [ "$code" = "200" ]; then
            log "$label healthy: HTTP 200 ($url)"
            return 0
        fi
        log "$label not healthy yet ($attempt/$tries): HTTP ${code:-curl-failed}"
        if [ -s /tmp/mu2edaq-notify-health.err ]; then
            sed 's/^/[curl] /' /tmp/mu2edaq-notify-health.err
        fi
        if [ -s /tmp/mu2edaq-notify-health.out ]; then
            sed 's/^/[body] /' /tmp/mu2edaq-notify-health.out
        fi
        sleep "$delay"
    done
    return 1
}

print_remote_diagnostics() {
    if [ ! -f "$PROXY_KEY" ]; then
        echo "Remote diagnostics skipped: missing $PROXY_KEY"
        return 0
    fi
    echo "Remote diagnostics:"
    ssh_proxy "printf 'caddy='; systemctl is-active caddy || true; printf 'listeners='; ss -ltn | grep -E ':(80|443|18095)' || true; sudo journalctl -u caddy -n 20 --no-pager || true" || true
}

print_diagnostics() {
    echo "Diagnostics:"
    echo "repo=$ROOT"
    echo "instance=$INSTANCE_ID"
    echo "aws_state=$(aws_state 2>/dev/null || echo unknown)"
    echo "aws_status=$(aws_status 2>/dev/null || echo unknown)"
    echo "api_address=$(notify_proxy_api_ip 2>/dev/null || true)"
    echo "dns_answer=$(notify_proxy_dns_ip 2>/dev/null || true)"
    echo "proxy_host=${PROXY_HOST:-unresolved}"
    print_security_group_ingress
    echo "local_8095_listeners:"
    lsof -nP -iTCP:8095 -sTCP:LISTEN 2>/dev/null || true
    echo "pidfiles:"
    for f in data/notify-server.pid "$PIDFILE"; do
        if [ -f "$f" ]; then
            printf "%s=" "$f"
            cat "$f"
        else
            echo "$f=missing"
        fi
    done
    echo "last tunnel log lines:"
    tail -n 30 "$LOGFILE" 2>/dev/null || true
    print_remote_diagnostics
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

log "Starting Mu2e Notify chain from $ROOT"
log "Configuration:"
log "  EC2 instance: $INSTANCE_ID ($MU2EDAQ_NOTIFY_PROXY_REGION)"
log "  public name:  $MU2EDAQ_NOTIFY_PROXY_DNS_NAME (zone $MU2EDAQ_NOTIFY_ROUTE53_ZONE_ID)"
log "  proxy host:   resolved after start; no Elastic IP"
log "  public URL:   $PUBLIC_URL"
log "  local health: $LOCAL_HEALTH_URL"
log "  tunnel:       EC2 $REMOTE_BIND -> local $LOCAL_TARGET"

require_command aws
require_command ssh
require_command curl
require_command lsof

if [ ! -f "$PROXY_KEY" ]; then
    fail "Missing SSH key: $PROXY_KEY"
fi
chmod 600 "$PROXY_KEY"

log "Step 1/8: start EC2 instance if needed."
state=$(aws_state)
log "EC2 state before start: $state"
if [ "$state" = "stopping" ]; then
    log "Instance is stopping; waiting for stopped state."
    run aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
    state="stopped"
fi
if [ "$state" = "stopped" ]; then
    run aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
else
    log "No start needed for state: $state"
fi
run aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
run aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"
log "AWS status after start: $(aws_status)"
print_security_group_ingress | sed 's/^/[aws] /'

log "Step 2/8: resolve this start's public address and confirm DNS registration."
PROXY_HOST=$(notify_proxy_api_ip)
if [ -z "$PROXY_HOST" ]; then
    if [ -n "${MU2EDAQ_NOTIFY_PROXY_HOST:-}" ]; then
        PROXY_HOST=$MU2EDAQ_NOTIFY_PROXY_HOST
        log "EC2 reports no public address; using the override $PROXY_HOST."
    else
        fail "Instance $INSTANCE_ID is running with no public IPv4. Its subnet must auto-assign one (MapPublicIpOnLaunch) or an address must be attached to eth0."
    fi
fi
log "Public address for this start: $PROXY_HOST"

# The instance publishes its own A record at boot (mu2edaq-notify-dns.service),
# but this script must not depend on that: it is what stops the chain, and
# stopping can retract the record, so it has to be able to put it back.
#
# Route 53 is asked directly rather than a resolver. A resolver caches the
# previous value for up to the TTL, so polling one cannot distinguish "not
# published yet" from "published, still cached" -- and waiting on that was
# worth two and a half minutes of nothing.
record=$(notify_proxy_record_ip)
if [ "$record" = "$PROXY_HOST" ]; then
    log "Route 53 already holds $MU2EDAQ_NOTIFY_PROXY_DNS_NAME -> $record."
else
    log "Route 53 holds $MU2EDAQ_NOTIFY_PROXY_DNS_NAME -> ${record:-none}, want $PROXY_HOST."
    if notify_proxy_wait_for_record "$PROXY_HOST" | sed 's/^/[record] /'; then
        log "The instance published it itself."
    elif [ "${MU2EDAQ_NOTIFY_DNS_LOCAL_FALLBACK:-1}" = "1" ]; then
        log "Publishing it from here (MU2EDAQ_NOTIFY_DNS_LOCAL_FALLBACK=0 to disable)."
        log "If the instance-side updater is installed, it did not run; check:"
        log "  systemctl status mu2edaq-notify-dns.service"
        run scripts/update-notify-dns.sh --ip "$PROXY_HOST"
    else
        log "WARNING: record left stale; MU2EDAQ_NOTIFY_DNS_LOCAL_FALLBACK=0."
        log "The public endpoint will not work until it is published."
    fi
fi

# Resolver convergence is a separate, softer matter: the record can be right
# while this host still caches the old answer for up to the TTL. The tunnel and
# Caddy do not need DNS at all -- only phones do -- so this warns rather than
# failing, and step 8 is where a genuine problem shows up.
if notify_proxy_wait_for_dns "$PROXY_HOST" | sed 's/^/[dns] /'; then
    log "DNS registration confirmed."
else
    log "WARNING: this host still resolves $MU2EDAQ_NOTIFY_PROXY_DNS_NAME to"
    log "$(notify_proxy_dns_ip) rather than $PROXY_HOST. If Route 53 is correct"
    log "(above), it is a cached answer and will expire within the 60s TTL."
fi

log "Step 3/8: verify SSH access to EC2."
wait_for_ssh "$SSH_WAIT_TRIES" 5 || fail "Timed out waiting for SSH on $PROXY_HOST"

log "Step 4/8: start and verify remote Caddy."
run ssh_proxy "sudo systemctl start caddy"
remote_caddy=$(ssh_proxy "systemctl is-active caddy" || true)
log "Remote Caddy status: $remote_caddy"
if [ "$remote_caddy" != "active" ]; then
    fail "Remote Caddy is not active."
fi
ssh_proxy "ss -ltn | grep -E ':(80|443)' || true" | sed 's/^/[remote-listener] /'

log "Step 5/8: start or verify SSH reverse tunnel."
if [ -f "$PIDFILE" ] && ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    log "Removing stale proxy tunnel pid file $PIDFILE."
    rm -f "$PIDFILE"
fi

if remote_tunnel_bound; then
    log "SSH reverse tunnel is already bound on EC2 $REMOTE_BIND."
elif [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    log "SSH reverse tunnel process already running (pid $(cat "$PIDFILE"))."
else
    log "Starting SSH reverse tunnel in background."
    log "Tunnel log: $LOGFILE"
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
    log "Tunnel PID: $(cat "$PIDFILE")"
    sleep 2
    if ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        fail "Proxy tunnel process exited immediately."
    fi
fi

remote_tunnel_bound || fail "Remote tunnel bind $REMOTE_BIND was not found."
ssh_proxy "ss -ltn | grep '127.0.0.1:18095'" | sed 's/^/[remote-tunnel] /'

log "Step 6/8: start or verify local notify server."
code=$(curl_health "$LOCAL_HEALTH_URL" 1 || true)
if [ "$code" = "200" ]; then
    log "Local notify server is already healthy."
else
    log "Local health before start: HTTP ${code:-curl-failed}"
    log "Starting local notify server."
    ./start-mu2edaq-notify-server.sh
fi
wait_for_health "local notify server" "$LOCAL_HEALTH_URL" 1 20 2 || fail "Local notify server did not become healthy."

log "Step 7/8: verify EC2 can reach local server through tunnel."
ssh_proxy "curl -kfsS --max-time 8 https://$REMOTE_BIND/api/health" | sed 's/^/[remote-health] /' || fail "EC2 could not reach local health endpoint through tunnel."

log "Step 8/8: verify public endpoint."
wait_for_health "public endpoint" "$PUBLIC_URL/api/health" 0 20 2 || fail "Public endpoint did not become healthy."

log "Mu2e Notify chain is running: $PUBLIC_URL"
