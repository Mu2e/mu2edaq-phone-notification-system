#!/bin/bash
# Show status for the local notify server, SSH reverse tunnel, remote Caddy,
# and public health endpoint.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/notify-proxy-common.sh
. "$ROOT/scripts/notify-proxy-common.sh"

PUBLIC_URL=${MU2EDAQ_NOTIFY_PUBLIC_URL:-https://$MU2EDAQ_NOTIFY_PROXY_DNS_NAME}
PROXY_USER=${MU2EDAQ_NOTIFY_PROXY_USER:-ec2-user}
PROXY_HOST=$(notify_proxy_resolve_host)
API_IP=$(notify_proxy_api_ip)
DNS_IP=$(notify_proxy_dns_ip)
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

# With no Elastic IP, "does DNS agree with the running instance" is a first
# class piece of status: a mismatch is the failure mode this design introduces.
echo "ec2 address: ${API_IP:-none (instance stopped or no public IPv4)}"
if [ -n "$API_IP" ] && [ "$API_IP" = "$DNS_IP" ]; then
    echo "dns record:  $MU2EDAQ_NOTIFY_PROXY_DNS_NAME -> $DNS_IP (matches)"
elif [ -n "$API_IP" ]; then
    echo "dns record:  $MU2EDAQ_NOTIFY_PROXY_DNS_NAME -> ${DNS_IP:-nxdomain} (STALE, want $API_IP)"
else
    echo "dns record:  $MU2EDAQ_NOTIFY_PROXY_DNS_NAME -> ${DNS_IP:-nxdomain}"
fi

# CAA pins issuance to one ACME account, so its absence is a real finding: it
# is what stops the next holder of a released address from getting a
# certificate for this name.
caa=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$MU2EDAQ_NOTIFY_ROUTE53_ZONE_ID" \
    --start-record-name "$MU2EDAQ_NOTIFY_PROXY_DNS_NAME." --start-record-type CAA \
    --query "ResourceRecordSets[?Name=='$MU2EDAQ_NOTIFY_PROXY_DNS_NAME.' && Type=='CAA'].ResourceRecords[].Value" \
    --output text 2>/dev/null)
case "${caa:-}" in
    "")            echo "caa pin:     none (issuance for this name is unrestricted)" ;;
    *accounturi=*) echo "caa pin:     $(printf '%s' "$caa" | sed -n 's/.*accounturi=\([^;\"]*\).*/\1/p')" ;;
    *)             echo "caa pin:     present, but no accounturi" ;;
esac

if [ -z "$PROXY_HOST" ]; then
    echo "remote caddy: unreachable; the proxy has no current address"
elif [ -f "$PROXY_KEY" ]; then
    # shellcheck disable=SC2207
    SSH_OPTS=($(notify_proxy_ssh_opts))
    remote_status=$(ssh -i "$PROXY_KEY" "${SSH_OPTS[@]}" \
        "$PROXY_USER@$PROXY_HOST" \
        "systemctl is-active caddy || true; systemctl is-active mu2edaq-notify-dns.timer || true" \
        2>/dev/null)
    caddy_state=$(printf '%s\n' "$remote_status" | sed -n 1p)
    timer_state=$(printf '%s\n' "$remote_status" | sed -n 2p)
    echo "remote caddy: ${caddy_state:-unreachable}"
    echo "remote dns timer: ${timer_state:-unreachable}"
else
    echo "remote caddy: unknown; missing SSH key $PROXY_KEY"
fi

if command -v curl >/dev/null 2>&1; then
    http_code=$(curl --max-time 8 -sS -o /dev/null -w "%{http_code}" "$PUBLIC_URL/api/health" 2>/dev/null)
    echo "public health: HTTP ${http_code:-000} ($PUBLIC_URL/api/health)"
fi
