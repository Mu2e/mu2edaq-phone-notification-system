#!/bin/bash
# Publish this EC2 instance's current public IPv4 into Route 53.
#
# Runs *on* the mu2edaq-notify proxy instance, installed as
# /usr/local/sbin/mu2edaq-notify-dns-update and driven by
# mu2edaq-notify-dns.service at every boot (plus mu2edaq-notify-dns.timer as a
# drift guard). It replaces the Elastic IP the proxy used to carry: the
# instance is normally stopped, so it gets a different public IPv4 every time
# it starts, and notify.andrewnorman.org has to follow it.
#
# Option precedence: command line > environment > config file > defaults.
set -euo pipefail

PROGRAM=$(basename "$0")

DEFAULT_CONFIG=/etc/mu2edaq-notify-dns.conf
DEFAULT_ZONE_ID=Z2OL4WKH228GKD
DEFAULT_RECORD=notify.andrewnorman.org
DEFAULT_TTL=60
DEFAULT_WAIT=1
DEFAULT_LOGFILE=/var/log/mu2edaq-notify-dns.log
DEFAULT_IP_TRIES=30
DEFAULT_IP_DELAY=2
IMDS=${MU2EDAQ_NOTIFY_IMDS_BASE:-http://169.254.169.254}

usage() {
    cat <<'USAGE'
Usage: mu2edaq-notify-dns-update [options]

Upsert the proxy's Route 53 A record to this instance's current public IPv4.

Options:
  -c, --config FILE     configuration file (default /etc/mu2edaq-notify-dns.conf)
  -z, --zone ID         Route 53 hosted zone id
  -r, --record NAME     record name to maintain (no trailing dot needed)
  -t, --ttl SECONDS     record TTL
  -i, --ip ADDRESS      use this IPv4 instead of asking IMDS
      --tries N         IMDS public-ipv4 attempts before giving up
      --delay SECONDS   delay between IMDS attempts
      --wait            wait for the change to reach INSYNC (default)
      --no-wait         return as soon as the change is submitted
      --log FILE        append output here as well as stdout ("" disables)
  -n, --dry-run         report what would change, submit nothing
  -q, --quiet           only report changes and errors
  -h, --help            this text

Exit status: 0 record correct or updated, 1 failure, 2 usage error.
USAGE
}

# --- environment snapshot, taken before the config file can overwrite it -----
ENV_CONFIG=${MU2EDAQ_NOTIFY_DNS_CONFIG:-}
ENV_ZONE_ID=${MU2EDAQ_NOTIFY_ROUTE53_ZONE_ID:-}
ENV_RECORD=${MU2EDAQ_NOTIFY_DNS_RECORD:-}
ENV_TTL=${MU2EDAQ_NOTIFY_DNS_TTL:-}
ENV_WAIT=${MU2EDAQ_NOTIFY_DNS_WAIT:-}
ENV_LOGFILE=${MU2EDAQ_NOTIFY_DNS_LOGFILE:-}
ENV_TRIES=${MU2EDAQ_NOTIFY_DNS_IP_TRIES:-}
ENV_DELAY=${MU2EDAQ_NOTIFY_DNS_IP_DELAY:-}

CLI_CONFIG=
CLI_ZONE_ID=
CLI_RECORD=
CLI_TTL=
CLI_WAIT=
CLI_LOGFILE=
CLI_TRIES=
CLI_DELAY=
CLI_IP=
DRY_RUN=0
QUIET=0
LOGFILE_SET=0

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--config)  CLI_CONFIG=${2:?--config needs a value}; shift 2 ;;
        -z|--zone)    CLI_ZONE_ID=${2:?--zone needs a value}; shift 2 ;;
        -r|--record)  CLI_RECORD=${2:?--record needs a value}; shift 2 ;;
        -t|--ttl)     CLI_TTL=${2:?--ttl needs a value}; shift 2 ;;
        -i|--ip)      CLI_IP=${2:?--ip needs a value}; shift 2 ;;
        --tries)      CLI_TRIES=${2:?--tries needs a value}; shift 2 ;;
        --delay)      CLI_DELAY=${2:?--delay needs a value}; shift 2 ;;
        --wait)       CLI_WAIT=1; shift ;;
        --no-wait)    CLI_WAIT=0; shift ;;
        --log)        CLI_LOGFILE=${2-}; LOGFILE_SET=1; shift 2 ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -q|--quiet)   QUIET=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "$PROGRAM: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

CONFIG=${CLI_CONFIG:-${ENV_CONFIG:-$DEFAULT_CONFIG}}
if [ -n "$CONFIG" ] && [ -f "$CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG"
fi

ZONE_ID=${CLI_ZONE_ID:-${ENV_ZONE_ID:-${MU2EDAQ_NOTIFY_ROUTE53_ZONE_ID:-$DEFAULT_ZONE_ID}}}
RECORD=${CLI_RECORD:-${ENV_RECORD:-${MU2EDAQ_NOTIFY_DNS_RECORD:-$DEFAULT_RECORD}}}
TTL=${CLI_TTL:-${ENV_TTL:-${MU2EDAQ_NOTIFY_DNS_TTL:-$DEFAULT_TTL}}}
WAIT=${CLI_WAIT:-${ENV_WAIT:-${MU2EDAQ_NOTIFY_DNS_WAIT:-$DEFAULT_WAIT}}}
IP_TRIES=${CLI_TRIES:-${ENV_TRIES:-${MU2EDAQ_NOTIFY_DNS_IP_TRIES:-$DEFAULT_IP_TRIES}}}
IP_DELAY=${CLI_DELAY:-${ENV_DELAY:-${MU2EDAQ_NOTIFY_DNS_IP_DELAY:-$DEFAULT_IP_DELAY}}}
if [ "$LOGFILE_SET" = "1" ]; then
    LOGFILE=$CLI_LOGFILE
else
    LOGFILE=${ENV_LOGFILE:-${MU2EDAQ_NOTIFY_DNS_LOGFILE:-$DEFAULT_LOGFILE}}
fi

RECORD=${RECORD%.}

if [ -n "$LOGFILE" ]; then
    if : >> "$LOGFILE" 2>/dev/null; then
        exec > >(tee -a "$LOGFILE") 2>&1
    else
        echo "$PROGRAM: cannot append to $LOGFILE; logging to stdout only" >&2
    fi
fi

ts()  { date -u "+%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(ts)] $*"; }
info() { [ "$QUIET" = "1" ] || log "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

is_ipv4() {
    local addr=$1 octet
    case "$addr" in
        *[!0-9.]*|"") return 1 ;;
    esac
    local IFS=.
    # shellcheck disable=SC2086
    set -- $addr
    [ $# -eq 4 ] || return 1
    for octet in "$@"; do
        [ -n "$octet" ] || return 1
        [ "$octet" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

imds_token() {
    curl -fsS --max-time 5 -X PUT "$IMDS/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null
}

imds_get() {
    local path=$1
    curl -fsS --max-time 5 -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
        "$IMDS/latest/meta-data/$path" 2>/dev/null
}

command -v aws  >/dev/null 2>&1 || fail "aws CLI not found on PATH"
command -v curl >/dev/null 2>&1 || fail "curl not found on PATH"

IMDS_TOKEN=$(imds_token) || true
[ -n "${IMDS_TOKEN:-}" ] || fail "no IMDSv2 token from $IMDS (this host requires IMDSv2; check the hop limit if running in a container)"

REGION=$(imds_get placement/region || true)
if [ -n "$REGION" ]; then
    export AWS_DEFAULT_REGION=$REGION
fi
INSTANCE_ID=$(imds_get instance-id || true)

if [ -n "$CLI_IP" ]; then
    is_ipv4 "$CLI_IP" || fail "--ip is not an IPv4 address: $CLI_IP"
    PUBLIC_IP=$CLI_IP
    info "using operator-supplied address $PUBLIC_IP"
else
    PUBLIC_IP=
    attempt=1
    while [ "$attempt" -le "$IP_TRIES" ]; do
        candidate=$(imds_get public-ipv4 || true)
        if is_ipv4 "${candidate:-}"; then
            PUBLIC_IP=$candidate
            break
        fi
        info "no public-ipv4 in IMDS yet ($attempt/$IP_TRIES); waiting ${IP_DELAY}s"
        sleep "$IP_DELAY"
        attempt=$((attempt + 1))
        IMDS_TOKEN=$(imds_token) || true
    done
    [ -n "$PUBLIC_IP" ] || fail "instance ${INSTANCE_ID:-unknown} has no public IPv4. The subnet must auto-assign one (MapPublicIpOnLaunch) or an address must be attached; nothing to publish."
fi

info "instance=${INSTANCE_ID:-unknown} region=${REGION:-unset} zone=$ZONE_ID record=$RECORD ttl=$TTL ip=$PUBLIC_IP"

current_value() {
    aws route53 list-resource-record-sets \
        --hosted-zone-id "$ZONE_ID" \
        --start-record-name "$RECORD." \
        --start-record-type A \
        --query "ResourceRecordSets[?Name=='${RECORD}.' && Type=='A'].ResourceRecords[].Value" \
        --output text 2>/dev/null
}

current_ttl() {
    aws route53 list-resource-record-sets \
        --hosted-zone-id "$ZONE_ID" \
        --start-record-name "$RECORD." \
        --start-record-type A \
        --query "ResourceRecordSets[?Name=='${RECORD}.' && Type=='A'].TTL" \
        --output text 2>/dev/null
}

CURRENT=$(current_value || true)
CURRENT_TTL=$(current_ttl || true)
CURRENT=${CURRENT:-none}
CURRENT_TTL=${CURRENT_TTL:-none}
info "current record: $RECORD A $CURRENT (ttl $CURRENT_TTL)"

if [ "$CURRENT" = "$PUBLIC_IP" ] && [ "$CURRENT_TTL" = "$TTL" ]; then
    info "record already correct; no Route 53 write"
    exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
    log "dry run: would UPSERT $RECORD A $PUBLIC_IP (ttl $TTL) in zone $ZONE_ID"
    exit 0
fi

BATCH=$(mktemp "${TMPDIR:-/tmp}/mu2edaq-notify-dns.XXXXXX")
trap 'rm -f "$BATCH"' EXIT
cat > "$BATCH" <<JSON
{
  "Comment": "mu2edaq-notify proxy ${INSTANCE_ID:-unknown} self-registration",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${RECORD}.",
        "Type": "A",
        "TTL": ${TTL},
        "ResourceRecords": [{"Value": "${PUBLIC_IP}"}]
      }
    }
  ]
}
JSON

CHANGE_ID=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --change-batch "file://$BATCH" \
    --query 'ChangeInfo.Id' --output text) \
    || fail "Route 53 UPSERT failed for $RECORD -> $PUBLIC_IP"

log "UPSERT $RECORD A $PUBLIC_IP (ttl $TTL) submitted as $CHANGE_ID (was $CURRENT)"

if [ "$WAIT" = "1" ]; then
    aws route53 wait resource-record-sets-changed --id "$CHANGE_ID" \
        || fail "change $CHANGE_ID did not reach INSYNC"
    log "change $CHANGE_ID is INSYNC"
fi
