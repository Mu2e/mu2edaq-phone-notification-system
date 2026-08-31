# Shared settings and helpers for the operator-side AWS proxy scripts.
# Sourced, never executed:  . "$(dirname "$0")/notify-proxy-common.sh"
#
# The proxy no longer carries an Elastic IP. It gets a fresh public IPv4 every
# time it starts and publishes that address itself (see
# scripts/aws-notify-dns-update.sh), so nothing on this side may hardcode an
# address: it is either asked of the EC2 API or resolved from DNS.

MU2EDAQ_NOTIFY_PROXY_INSTANCE_ID=${MU2EDAQ_NOTIFY_PROXY_INSTANCE_ID:-i-000ee813ecd9a47b3}
MU2EDAQ_NOTIFY_PROXY_REGION=${MU2EDAQ_NOTIFY_PROXY_REGION:-us-west-2}
MU2EDAQ_NOTIFY_PROXY_DNS_NAME=${MU2EDAQ_NOTIFY_PROXY_DNS_NAME:-notify.andrewnorman.org}
MU2EDAQ_NOTIFY_ROUTE53_ZONE_ID=${MU2EDAQ_NOTIFY_ROUTE53_ZONE_ID:-Z2OL4WKH228GKD}
MU2EDAQ_NOTIFY_DNS_TTL=${MU2EDAQ_NOTIFY_DNS_TTL:-60}
MU2EDAQ_NOTIFY_DNS_WAIT_TRIES=${MU2EDAQ_NOTIFY_DNS_WAIT_TRIES:-12}
MU2EDAQ_NOTIFY_DNS_WAIT_DELAY=${MU2EDAQ_NOTIFY_DNS_WAIT_DELAY:-5}
MU2EDAQ_NOTIFY_RECORD_WAIT_TRIES=${MU2EDAQ_NOTIFY_RECORD_WAIT_TRIES:-6}
MU2EDAQ_NOTIFY_RECORD_WAIT_DELAY=${MU2EDAQ_NOTIFY_RECORD_WAIT_DELAY:-5}

# Every aws call in these scripts targets the region the proxy lives in, unless
# the caller has already pinned one.
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-$MU2EDAQ_NOTIFY_PROXY_REGION}

# Current public IPv4 of the proxy instance according to the EC2 API, or empty
# if the instance is stopped or has no address. The API is authoritative and
# immediate; DNS is a cache of it.
notify_proxy_api_ip() {
    local ip
    ip=$(aws ec2 describe-instances \
            --instance-ids "$MU2EDAQ_NOTIFY_PROXY_INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text 2>/dev/null) || return 0
    case "${ip:-}" in
        ""|None|null) return 0 ;;
    esac
    printf '%s\n' "$ip"
}

# What Route 53 actually holds for the public name. This is the authoritative
# answer and it is immediate: resolvers cache the old value for up to the TTL,
# so a stale caching resolver must never be mistaken for an unpublished record.
notify_proxy_record_ip() {
    local ip
    ip=$(aws route53 list-resource-record-sets \
            --hosted-zone-id "$MU2EDAQ_NOTIFY_ROUTE53_ZONE_ID" \
            --start-record-name "$MU2EDAQ_NOTIFY_PROXY_DNS_NAME." \
            --start-record-type A \
            --query "ResourceRecordSets[?Name=='$MU2EDAQ_NOTIFY_PROXY_DNS_NAME.' && Type=='A'].ResourceRecords[0].Value" \
            --output text 2>/dev/null) || return 0
    case "${ip:-}" in
        ""|None|null) return 0 ;;
    esac
    printf '%s\n' "$ip"
}

# Allocation id of an Elastic IP associated with the proxy, or empty. While one
# is attached the address survives a stop, so the record cannot come to point at
# an address someone else holds -- which is the only reason to retract it.
notify_proxy_elastic_ip_allocation() {
    local alloc
    alloc=$(aws ec2 describe-addresses \
            --filters "Name=instance-id,Values=$MU2EDAQ_NOTIFY_PROXY_INSTANCE_ID" \
            --query 'Addresses[0].AllocationId' --output text 2>/dev/null) || return 0
    case "${alloc:-}" in
        ""|None|null) return 0 ;;
    esac
    printf '%s\n' "$alloc"
}

# Should the public record be retracted before the instance is stopped?
#
# Retraction exists to stop a record dangling at an address AWS has taken back.
# It is wrong -- and breaks the chain until something republishes -- when there
# is nothing to dangle, or when the record is not ours. Prints a verdict token
# plus detail, returns 0 to retract and 1 to leave the record alone.
#
#   retract
#   skip disabled
#   skip elastic-ip <allocation-id>
#   skip no-address
#   skip not-ours <record-value> <instance-address>
notify_proxy_retract_decision() {
    if [ "${MU2EDAQ_NOTIFY_DNS_RETRACT:-1}" != "1" ]; then
        printf 'skip disabled\n'
        return 1
    fi
    local alloc address record
    alloc=$(notify_proxy_elastic_ip_allocation)
    if [ -n "$alloc" ]; then
        printf 'skip elastic-ip %s\n' "$alloc"
        return 1
    fi
    address=$(notify_proxy_api_ip)
    if [ -z "$address" ]; then
        printf 'skip no-address\n'
        return 1
    fi
    record=$(notify_proxy_record_ip)
    if [ -n "$record" ] && [ "$record" != "$address" ]; then
        printf 'skip not-ours %s %s\n' "$record" "$address"
        return 1
    fi
    printf 'retract\n'
    return 0
}

# What DNS currently hands out for the public name.
notify_proxy_dns_ip() {
    local ip
    if command -v dig >/dev/null 2>&1; then
        ip=$(dig +short +time=3 +tries=1 "$MU2EDAQ_NOTIFY_PROXY_DNS_NAME" A 2>/dev/null | tail -n 1)
    else
        ip=$(getent hosts "$MU2EDAQ_NOTIFY_PROXY_DNS_NAME" 2>/dev/null | awk '{print $1; exit}')
    fi
    printf '%s\n' "${ip:-}"
}

# The address to SSH to. An explicit MU2EDAQ_NOTIFY_PROXY_HOST wins (manual
# override, e.g. a rebuilt instance not in DNS yet), then the EC2 API, then the
# public name. Prints nothing if the instance has no public address at all,
# which callers must treat as "proxy is not up".
notify_proxy_resolve_host() {
    if [ -n "${MU2EDAQ_NOTIFY_PROXY_HOST:-}" ]; then
        printf '%s\n' "$MU2EDAQ_NOTIFY_PROXY_HOST"
        return 0
    fi
    local ip
    ip=$(notify_proxy_api_ip)
    if [ -n "$ip" ]; then
        printf '%s\n' "$ip"
        return 0
    fi
    ip=$(notify_proxy_dns_ip)
    if [ -n "$ip" ]; then
        printf '%s\n' "$ip"
        return 0
    fi
    return 0
}

# SSH options every call shares. HostKeyAlias is the point of this function:
# the host key is pinned to the stable public name, so a new public IPv4 on
# each start does not add a known_hosts entry per address, and a changed key
# still trips the normal warning.
notify_proxy_ssh_opts() {
    printf '%s\n' \
        -o BatchMode=yes \
        -o ConnectTimeout=8 \
        -o StrictHostKeyChecking=accept-new \
        -o "HostKeyAlias=$MU2EDAQ_NOTIFY_PROXY_DNS_NAME"
}

# Wait until Route 53 itself holds $1, giving the instance-side updater a chance
# to publish it. Returns 1 on timeout, which means the updater did not run,
# failed, or is not installed.
notify_proxy_wait_for_record() {
    local want=$1
    local tries=${2:-$MU2EDAQ_NOTIFY_RECORD_WAIT_TRIES}
    local delay=${3:-$MU2EDAQ_NOTIFY_RECORD_WAIT_DELAY}
    local attempt got
    for attempt in $(seq 1 "$tries"); do
        got=$(notify_proxy_record_ip)
        if [ "$got" = "$want" ]; then
            printf '%s\n' "Route 53 holds $MU2EDAQ_NOTIFY_PROXY_DNS_NAME -> $got"
            return 0
        fi
        printf '%s\n' "Route 53 holds $MU2EDAQ_NOTIFY_PROXY_DNS_NAME -> ${got:-none}, want $want ($attempt/$tries)"
        sleep "$delay"
    done
    return 1
}

# Wait until the public name resolves to $1 through the local resolver. A
# failure here is not the same fault as the record being wrong: the record can
# be correct while a resolver still caches the previous value for up to the TTL.
notify_proxy_wait_for_dns() {
    local want=$1
    local tries=${2:-$MU2EDAQ_NOTIFY_DNS_WAIT_TRIES}
    local delay=${3:-$MU2EDAQ_NOTIFY_DNS_WAIT_DELAY}
    local attempt got
    for attempt in $(seq 1 "$tries"); do
        got=$(notify_proxy_dns_ip)
        if [ "$got" = "$want" ]; then
            printf '%s\n' "DNS $MU2EDAQ_NOTIFY_PROXY_DNS_NAME -> $got"
            return 0
        fi
        printf '%s\n' "DNS $MU2EDAQ_NOTIFY_PROXY_DNS_NAME -> ${got:-nxdomain}, want $want ($attempt/$tries)"
        sleep "$delay"
    done
    return 1
}
