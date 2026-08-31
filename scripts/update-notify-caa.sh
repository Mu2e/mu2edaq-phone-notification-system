#!/bin/bash
# Pin certificate issuance for the proxy's public name to one CA and one ACME
# account, with a CAA record (RFC 8659 + RFC 8657).
#
# Why: the proxy holds no Elastic IP, so a stopped instance returns its public
# address to the AWS pool. Whoever is handed that address next controls ports 80
# and 443 on it and can therefore satisfy an HTTP-01 or TLS-ALPN-01 challenge
# for notify.andrewnorman.org. Teardown retracting the A record closes the
# window (scripts/update-notify-dns.sh --retract); this closes the hole itself,
# by making Let's Encrypt refuse to issue for the name to any ACME account but
# ours -- possession of the address is then not enough, the account key is
# needed too.
#
# The account URI is read off the instance rather than configured, because
# Caddy's account is created by Caddy and a rebuilt instance gets a new one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/notify-proxy-common.sh
. "$ROOT/scripts/notify-proxy-common.sh"

usage() {
    cat <<'USAGE'
Usage: scripts/update-notify-caa.sh [options]

Publish, check or remove the CAA record that binds issuance for the proxy's
public name to one CA and one ACME account.

Options:
      --check              report the live record against the instance's ACME
                           account and change nothing; exit 1 on a mismatch
      --remove             delete the CAA record set. The escape hatch: an
                           over-tight CAA record blocks renewal, and the
                           symptom appears weeks later
      --account-uri URI    use this ACME account URI instead of asking the
                           instance (repeatable)
      --all-accounts       authorize every account URI found on the instance,
                           not just a single one
      --ca DOMAIN          CA identifier (default letsencrypt.org)
      --validation-methods LIST
                           RFC 8657 validationmethods, comma separated
                           (default http-01,tls-alpn-01; "" omits the
                           parameter)
      --no-issuewild       do not add the record that denies wildcard issuance
  -r, --record NAME        record to pin (default notify.andrewnorman.org)
  -z, --zone ID            hosted zone id
  -t, --ttl SECONDS        record TTL (default 300)
  -H, --host HOST          instance address for account discovery
  -u, --user USER          SSH user (default ec2-user)
  -k, --key FILE           SSH private key (default data/mu2edaq-notify-proxy.pem)
      --no-wait            do not poll the change to INSYNC
  -n, --dry-run            print the change batch, submit nothing
  -h, --help               this text

The instance must be running for account discovery. Only the operator ever
writes this record: the instance's own IAM policy is limited to UPSERTing the
A record, and deliberately cannot touch CAA.
USAGE
}

CHECK_ONLY=0
REMOVE=0
DRY_RUN=0
WAIT=1
ALL_ACCOUNTS=0
WITH_ISSUEWILD=1
CA=${MU2EDAQ_NOTIFY_CAA_CA:-letsencrypt.org}
VALIDATION_METHODS=${MU2EDAQ_NOTIFY_CAA_VALIDATION_METHODS-http-01,tls-alpn-01}
TTL=${MU2EDAQ_NOTIFY_CAA_TTL:-300}
RECORD=${MU2EDAQ_NOTIFY_PROXY_DNS_NAME}
ZONE_ID=${MU2EDAQ_NOTIFY_ROUTE53_ZONE_ID}
PROXY_USER=${MU2EDAQ_NOTIFY_PROXY_USER:-ec2-user}
PROXY_KEY=${MU2EDAQ_NOTIFY_PROXY_KEY:-data/mu2edaq-notify-proxy.pem}
HOST=
ACCOUNT_URIS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --check)                CHECK_ONLY=1; shift ;;
        --remove)               REMOVE=1; shift ;;
        --account-uri)          ACCOUNT_URIS+=("${2:?--account-uri needs a value}"); shift 2 ;;
        --all-accounts)         ALL_ACCOUNTS=1; shift ;;
        --ca)                   CA=${2:?--ca needs a value}; shift 2 ;;
        --validation-methods)   VALIDATION_METHODS=${2-}; shift 2 ;;
        --no-issuewild)         WITH_ISSUEWILD=0; shift ;;
        -r|--record)            RECORD=${2:?--record needs a value}; shift 2 ;;
        -z|--zone)              ZONE_ID=${2:?--zone needs a value}; shift 2 ;;
        -t|--ttl)               TTL=${2:?--ttl needs a value}; shift 2 ;;
        -H|--host)              HOST=${2:?--host needs a value}; shift 2 ;;
        -u|--user)              PROXY_USER=${2:?--user needs a value}; shift 2 ;;
        -k|--key)               PROXY_KEY=${2:?--key needs a value}; shift 2 ;;
        --no-wait)              WAIT=0; shift ;;
        -n|--dry-run)           DRY_RUN=1; shift ;;
        -h|--help)              usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

RECORD=${RECORD%.}
command -v aws >/dev/null 2>&1 || { echo "aws CLI not found on PATH" >&2; exit 1; }

# A CAA record at the zone apex would apply to every name under it that has no
# CAA record of its own. Other names in andrewnorman.org are served by
# CloudFront with ACM certificates, which this record would forbid, and the
# breakage would only appear at their next renewal. Refuse outright.
apex=$(aws route53 get-hosted-zone --id "$ZONE_ID" \
    --query 'HostedZone.Name' --output text 2>/dev/null || true)
apex=${apex%.}
if [ -n "$apex" ] && [ "$RECORD" = "$apex" ]; then
    echo "Refusing to write CAA at the zone apex $apex." >&2
    echo "It would apply to every name in the zone that has no CAA of its own," >&2
    echo "including ones served by ACM certificates. Pin the subdomain instead." >&2
    exit 1
fi

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

live_values() {
    aws route53 list-resource-record-sets \
        --hosted-zone-id "$ZONE_ID" \
        --start-record-name "$RECORD." --start-record-type CAA \
        --query "ResourceRecordSets[?Name=='${RECORD}.' && Type=='CAA'].ResourceRecords[].Value" \
        --output text 2>/dev/null || true
}

live_ttl() {
    aws route53 list-resource-record-sets \
        --hosted-zone-id "$ZONE_ID" \
        --start-record-name "$RECORD." --start-record-type CAA \
        --query "ResourceRecordSets[?Name=='${RECORD}.' && Type=='CAA'].TTL" \
        --output text 2>/dev/null || true
}

# Read the ACME account URI(s) Caddy registered, off the instance. Searched
# rather than read from a fixed path: the account directory is named after the
# contact address, and Caddy's storage root moves with the service user.
discover_accounts() {
    if [ -z "$HOST" ]; then
        HOST=$(notify_proxy_resolve_host)
    fi
    if [ -z "$HOST" ]; then
        echo "The proxy has no reachable address, so its ACME account cannot be read." >&2
        echo "Start it with scripts/start-mu2edaq-notify-chain.sh, or pass --account-uri." >&2
        return 1
    fi
    if [ ! -f "$PROXY_KEY" ]; then
        echo "Missing SSH key: $PROXY_KEY" >&2
        return 1
    fi
    chmod 600 "$PROXY_KEY"
    # shellcheck disable=SC2207
    local opts=($(notify_proxy_ssh_opts))
    local remote='sudo find /var/lib/caddy /root/.local/share/caddy /home/*/.local/share/caddy -maxdepth 10 -type f -name "*.json" -path "*acme*" -exec grep -ho "https://acme[^\"]*/acme/acct/[0-9][0-9]*" {} + 2>/dev/null | grep -v staging | sort -u'
    ssh -i "$PROXY_KEY" "${opts[@]}" "$PROXY_USER@$HOST" "$remote" 2>/dev/null || true
}

if [ "${#ACCOUNT_URIS[@]}" -eq 0 ] && [ "$REMOVE" = "0" ]; then
    echo "Reading the ACME account from the instance ..."
    found=$(discover_accounts) || exit 1
    if [ -z "$found" ]; then
        echo "No Let's Encrypt account found on the instance." >&2
        echo "Caddy registers one the first time it obtains a certificate; start it," >&2
        echo "let it issue, then re-run. Or pass --account-uri explicitly." >&2
        exit 1
    fi
    while IFS= read -r line; do
        [ -n "$line" ] && ACCOUNT_URIS+=("$line")
    done <<< "$found"
    if [ "${#ACCOUNT_URIS[@]}" -gt 1 ] && [ "$ALL_ACCOUNTS" = "0" ]; then
        echo "The instance has more than one ACME account:" >&2
        printf '  %s\n' "${ACCOUNT_URIS[@]}" >&2
        echo "Pinning one and guessing wrong blocks renewal. Re-run with" >&2
        echo "--all-accounts to authorize all of them, or --account-uri to choose." >&2
        exit 1
    fi
fi

# Build the record set. Multiple CAA values live in one RRset; any matching
# issue record permits issuance, so several accounts can be authorized.
params=""
if [ -n "$VALIDATION_METHODS" ]; then
    params=";validationmethods=$VALIDATION_METHODS"
fi
VALUES=()
for uri in ${ACCOUNT_URIS[@]+"${ACCOUNT_URIS[@]}"}; do
    VALUES+=("0 issue \"${CA};accounturi=${uri}${params}\"")
done
if [ "$WITH_ISSUEWILD" = "1" ]; then
    # This name never needs a wildcard, and a wildcard certificate is the one
    # an attacker would most want.
    VALUES+=('0 issuewild ";"')
fi

current=$(live_values)
current_ttl=$(live_ttl)

echo "record:       $RECORD (zone $ZONE_ID)"
echo "live CAA:     ${current:-none}"
if [ "$REMOVE" = "0" ]; then
    printf 'wanted CAA:   %s\n' "${VALUES[0]}"
    for v in "${VALUES[@]:1}"; do printf '              %s\n' "$v"; done
fi

if [ "$CHECK_ONLY" = "1" ]; then
    if [ -z "$current" ]; then
        echo "verdict:      no CAA record; issuance for this name is unrestricted"
        exit 1
    fi
    missing=0
    for uri in ${ACCOUNT_URIS[@]+"${ACCOUNT_URIS[@]}"}; do
        case "$current" in
            *"accounturi=$uri"*) ;;
            *) echo "verdict:      the instance's account $uri is NOT authorized" >&2; missing=1 ;;
        esac
    done
    if [ "$missing" = "1" ]; then
        echo "              renewal will fail. Re-run without --check to republish." >&2
        exit 1
    fi
    echo "verdict:      CAA authorizes the instance's ACME account (ttl ${current_ttl:-unset})"
    exit 0
fi

if [ "$REMOVE" = "1" ]; then
    if [ -z "$current" ]; then
        echo "No CAA record to remove."
        exit 0
    fi
    ACTION=DELETE
    # A DELETE has to name the record exactly as it exists, so rebuild the set
    # from what is live rather than from what this run would have written.
    VALUES=()
    while IFS= read -r v; do
        [ -n "$v" ] && VALUES+=("$v")
    done <<< "$(printf '%s\n' "$current" | tr '\t' '\n')"
    TTL=${current_ttl:-$TTL}
else
    ACTION=UPSERT
fi

BATCH=$(mktemp "${TMPDIR:-/tmp}/mu2edaq-notify-caa.XXXXXX")
trap 'rm -f "$BATCH"' EXIT
{
    printf '{\n  "Comment": "Bind certificate issuance for %s to one CA and ACME account",\n' "$RECORD"
    printf '  "Changes": [\n    {\n      "Action": "%s",\n' "$ACTION"
    printf '      "ResourceRecordSet": {\n'
    printf '        "Name": "%s.",\n        "Type": "CAA",\n        "TTL": %s,\n' "$RECORD" "$TTL"
    printf '        "ResourceRecords": [\n'
    first=1
    for v in "${VALUES[@]}"; do
        if [ "$first" = "1" ]; then first=0; else printf ',\n'; fi
        printf '          {"Value": "%s"}' "$(json_escape "$v")"
    done
    printf '\n        ]\n      }\n    }\n  ]\n}\n'
} > "$BATCH"

if [ "$DRY_RUN" = "1" ]; then
    echo "dry run; change batch would be:"
    cat "$BATCH"
    exit 0
fi

change_id=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --change-batch "file://$BATCH" \
    --query 'ChangeInfo.Id' --output text)
echo "submitted:    $change_id ($ACTION)"

if [ "$WAIT" = "1" ]; then
    aws route53 wait resource-record-sets-changed --id "$change_id"
    echo "status:       INSYNC"
fi

if [ "$ACTION" = "UPSERT" ]; then
    echo
    echo "Renewal now needs both the address and this ACME account key. If the"
    echo "instance is ever rebuilt, Caddy registers a new account and this record"
    echo "must be republished before the certificate next renews (Caddy renews at"
    echo "two thirds of the 90-day lifetime, so the failure would surface weeks"
    echo "later): scripts/update-notify-caa.sh"
fi
