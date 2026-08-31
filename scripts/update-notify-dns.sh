#!/bin/bash
# Operator-side view and repair of the proxy's public A record.
#
# The instance normally does this for itself at boot
# (scripts/aws-notify-dns-update.sh via mu2edaq-notify-dns.service). This is
# the break-glass path for the two cases where it cannot:
#
#   * the instance profile is not attached yet (first cutover from the
#     Elastic IP, or a rebuilt instance),
#   * the instance-side updater failed and the record is stale.
#
# It asks the EC2 API for the instance's current public IPv4 rather than
# trusting any stored address.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/notify-proxy-common.sh
. "$ROOT/scripts/notify-proxy-common.sh"

usage() {
    cat <<'USAGE'
Usage: scripts/update-notify-dns.sh [options]

Point the proxy's public A record at the instance's current public IPv4.

Options:
      --check          report API address vs DNS address, change nothing
      --retract        park the record on an unroutable sink address, for when
                       the instance is stopping and releasing its address
      --sink ADDRESS   address --retract parks on (default 192.0.2.1)
  -i, --ip ADDRESS     publish this address instead of asking the EC2 API
      --instance ID    EC2 instance to read the address from
  -z, --zone ID        Route 53 hosted zone id
  -r, --record NAME    record to maintain
  -t, --ttl SECONDS    record TTL
      --no-wait        do not wait for the change to reach INSYNC
  -n, --dry-run        print the change batch, submit nothing
  -h, --help           this text

Environment: MU2EDAQ_NOTIFY_PROXY_INSTANCE_ID, MU2EDAQ_NOTIFY_PROXY_DNS_NAME,
MU2EDAQ_NOTIFY_ROUTE53_ZONE_ID, MU2EDAQ_NOTIFY_DNS_TTL, MU2EDAQ_NOTIFY_PROXY_REGION.
USAGE
}

CHECK_ONLY=0
RETRACT=0
DRY_RUN=0
WAIT=1
IP=
# RFC 5737 TEST-NET-1: guaranteed never routed, so a retracted name resolves
# somewhere harmless instead of to an address AWS has since handed out.
SINK=${MU2EDAQ_NOTIFY_DNS_SINK:-192.0.2.1}

while [ $# -gt 0 ]; do
    case "$1" in
        --check)        CHECK_ONLY=1; shift ;;
        --retract)      RETRACT=1; shift ;;
        --sink)         SINK=${2:?--sink needs a value}; shift 2 ;;
        -i|--ip)        IP=${2:?--ip needs a value}; shift 2 ;;
        --instance)     MU2EDAQ_NOTIFY_PROXY_INSTANCE_ID=${2:?--instance needs a value}; shift 2 ;;
        -z|--zone)      MU2EDAQ_NOTIFY_ROUTE53_ZONE_ID=${2:?--zone needs a value}; shift 2 ;;
        -r|--record)    MU2EDAQ_NOTIFY_PROXY_DNS_NAME=${2:?--record needs a value}; shift 2 ;;
        -t|--ttl)       MU2EDAQ_NOTIFY_DNS_TTL=${2:?--ttl needs a value}; shift 2 ;;
        --no-wait)      WAIT=0; shift ;;
        -n|--dry-run)   DRY_RUN=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

RECORD=${MU2EDAQ_NOTIFY_PROXY_DNS_NAME%.}
ZONE_ID=$MU2EDAQ_NOTIFY_ROUTE53_ZONE_ID
TTL=$MU2EDAQ_NOTIFY_DNS_TTL

command -v aws >/dev/null 2>&1 || { echo "aws CLI not found on PATH" >&2; exit 1; }

state=$(aws ec2 describe-instances \
    --instance-ids "$MU2EDAQ_NOTIFY_PROXY_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo unknown)

if [ "$RETRACT" = "1" ]; then
    # Deliberately an UPSERT to a sink, not a DELETE: the name keeps resolving,
    # so the failure is legible, and there is nothing left for anyone to claim.
    IP=$SINK
elif [ -z "$IP" ]; then
    IP=$(notify_proxy_api_ip)
fi

dns_ip=$(notify_proxy_dns_ip)

current=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --start-record-name "$RECORD." --start-record-type A \
    --query "ResourceRecordSets[?Name=='${RECORD}.' && Type=='A'].ResourceRecords[].Value" \
    --output text 2>/dev/null || true)

echo "instance:     $MU2EDAQ_NOTIFY_PROXY_INSTANCE_ID ($state)"
if [ "$RETRACT" = "1" ]; then
    echo "retract to:   $IP (unroutable sink)"
else
    echo "api address:  ${IP:-none}"
fi
echo "route53:      $RECORD A ${current:-none}"
echo "dns answer:   ${dns_ip:-nxdomain}"

if [ "$CHECK_ONLY" = "1" ]; then
    if [ -n "$IP" ] && [ "$current" = "$IP" ]; then
        echo "verdict:      record matches the EC2 API address"
        exit 0
    fi
    if [ -z "$IP" ]; then
        echo "verdict:      instance has no public address; record left as is"
        exit 0
    fi
    echo "verdict:      record is stale"
    exit 1
fi

if [ -z "$IP" ]; then
    echo "The instance has no public IPv4 (state: $state); nothing to publish." >&2
    echo "Start it first, pass --ip, or use --retract to park the record." >&2
    exit 1
fi

if [ "$current" = "$IP" ]; then
    echo "Record already correct; no Route 53 write."
    exit 0
fi

BATCH=$(mktemp "${TMPDIR:-/tmp}/mu2edaq-notify-dns.XXXXXX")
trap 'rm -f "$BATCH"' EXIT
sed -e "s/__PUBLIC_IP__/$IP/g" \
    -e "s/__RECORD_NAME__/$RECORD/g" \
    -e "s/__RECORD_TTL__/$TTL/g" \
    config/aws/route53-notify-upsert.json.in > "$BATCH"

if [ "$DRY_RUN" = "1" ]; then
    echo "dry run; change batch would be:"
    cat "$BATCH"
    exit 0
fi

change_id=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --change-batch "file://$BATCH" \
    --query 'ChangeInfo.Id' --output text)
echo "submitted:    $change_id ($RECORD A ${current:-none} -> $IP)"

if [ "$WAIT" = "1" ]; then
    aws route53 wait resource-record-sets-changed --id "$change_id"
    echo "status:       INSYNC"
fi
