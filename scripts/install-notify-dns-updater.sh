#!/bin/bash
# Install the self-registering DNS updater and the Caddyfile on the
# mu2edaq-notify proxy.
#
# The repo holds the single copy of the updater, its config, its systemd units
# and the Caddyfile (scripts/aws-notify-dns-update.sh, config/aws/*). This
# script is the only thing that puts them on the instance, in either of two
# ways:
#
#   default            push them over SSH to a running instance and enable them
#   --emit-user-data   print a cloud-init document that installs the same files
#                      plus Caddy, for rebuilding the instance from scratch
#
# Keeping both paths generated from the repo files is deliberate: an updater
# pasted into EC2 user-data by hand drifts from the one under test.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/notify-proxy-common.sh
. "$ROOT/scripts/notify-proxy-common.sh"

usage() {
    cat <<'USAGE'
Usage: scripts/install-notify-dns-updater.sh [options]

Install /usr/local/sbin/mu2edaq-notify-dns-update, /etc/mu2edaq-notify-dns.conf,
mu2edaq-notify-dns.service, mu2edaq-notify-dns.timer, the Caddy ordering
drop-in and /etc/caddy/Caddyfile on the EC2 proxy instance.

Options:
      --emit-user-data  print the equivalent cloud-init document and exit
      --gzip            with --emit-user-data, emit it gzipped (cloud-init
                        accepts that, and it is now the only form that fits
                        EC2's 16 KB user-data limit)
      --no-caddyfile    leave /etc/caddy/Caddyfile alone
  -H, --host HOST       target address (default: the EC2 API's current one)
  -u, --user USER       SSH user (default ec2-user)
  -k, --key FILE        SSH private key (default data/mu2edaq-notify-proxy.pem)
      --no-timer        install the boot unit but not the 5-minute drift timer
      --no-run          install and enable, but do not run the updater now
  -h, --help            this text
USAGE
}

EMIT_USER_DATA=0
GZIP_OUTPUT=0
WITH_TIMER=1
WITH_CADDYFILE=1
RUN_NOW=1
PROXY_USER=${MU2EDAQ_NOTIFY_PROXY_USER:-ec2-user}
PROXY_KEY=${MU2EDAQ_NOTIFY_PROXY_KEY:-data/mu2edaq-notify-proxy.pem}
HOST=

while [ $# -gt 0 ]; do
    case "$1" in
        --emit-user-data) EMIT_USER_DATA=1; shift ;;
        --gzip)           GZIP_OUTPUT=1; shift ;;
        -H|--host)        HOST=${2:?--host needs a value}; shift 2 ;;
        -u|--user)        PROXY_USER=${2:?--user needs a value}; shift 2 ;;
        -k|--key)         PROXY_KEY=${2:?--key needs a value}; shift 2 ;;
        --no-timer)       WITH_TIMER=0; shift ;;
        --no-caddyfile)   WITH_CADDYFILE=0; shift ;;
        --no-run)         RUN_NOW=0; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# The remote-side installer, with the repo's files inlined. Written once and
# used by both the SSH path and the user-data path.
emit_installer() {
    cat <<'PART1'
#!/bin/bash
set -euxo pipefail
exec > >(tee -a /var/log/mu2edaq-notify-dns-install.log) 2>&1

# aws CLI v2 ships in Amazon Linux 2023; install it if this is a leaner image.
if ! command -v aws >/dev/null 2>&1; then
    dnf install -y awscli-2 || dnf install -y awscli
fi

install -d -m 0755 /usr/local/sbin /etc/systemd/system/caddy.service.d
PART1
    if [ "$WITH_CADDYFILE" = "1" ]; then
        cat <<'PART1B'

install -d -m 0755 /etc/caddy
cat > /etc/caddy/Caddyfile.new <<'__MU2EDAQ_CADDYFILE__'
PART1B
        cat config/aws/Caddyfile
        cat <<'PART1C'
__MU2EDAQ_CADDYFILE__
# Validate before replacing: a Caddyfile that does not parse would leave the
# proxy unable to restart, and the failure would only surface at the next boot.
if caddy validate --config /etc/caddy/Caddyfile.new --adapter caddyfile; then
    mv /etc/caddy/Caddyfile.new /etc/caddy/Caddyfile
    chmod 0644 /etc/caddy/Caddyfile
    # Reload rather than restart, so a running proxy keeps its connections. A
    # stopped Caddy stays stopped: starting it is ordered after the DNS update.
    if systemctl is-active --quiet caddy; then
        systemctl reload caddy || systemctl restart caddy
    fi
else
    rm -f /etc/caddy/Caddyfile.new
    echo "Caddyfile from the repo failed validation; left the installed one alone." >&2
    exit 1
fi
PART1C
    fi
    cat <<'PART1D'

cat > /usr/local/sbin/mu2edaq-notify-dns-update <<'__MU2EDAQ_DNS_UPDATER__'
PART1D
    cat scripts/aws-notify-dns-update.sh
    cat <<'PART2'
__MU2EDAQ_DNS_UPDATER__
chmod 0755 /usr/local/sbin/mu2edaq-notify-dns-update

cat > /etc/mu2edaq-notify-dns.conf <<'__MU2EDAQ_DNS_CONF__'
PART2
    cat config/aws/mu2edaq-notify-dns.conf
    cat <<'PART3'
__MU2EDAQ_DNS_CONF__
chmod 0644 /etc/mu2edaq-notify-dns.conf

cat > /etc/systemd/system/mu2edaq-notify-dns.service <<'__MU2EDAQ_DNS_SERVICE__'
PART3
    cat config/aws/mu2edaq-notify-dns.service
    cat <<'PART4'
__MU2EDAQ_DNS_SERVICE__

cat > /etc/systemd/system/mu2edaq-notify-dns.timer <<'__MU2EDAQ_DNS_TIMER__'
PART4
    cat config/aws/mu2edaq-notify-dns.timer
    cat <<'PART5'
__MU2EDAQ_DNS_TIMER__

cat > /etc/systemd/system/caddy.service.d/10-wait-for-dns.conf <<'__MU2EDAQ_CADDY_DROPIN__'
PART5
    cat config/aws/caddy.service.d/10-wait-for-dns.conf
    cat <<'PART6'
__MU2EDAQ_CADDY_DROPIN__

systemctl daemon-reload
systemctl enable mu2edaq-notify-dns.service
PART6
    if [ "$WITH_TIMER" = "1" ]; then
        echo "systemctl enable --now mu2edaq-notify-dns.timer"
    else
        echo "systemctl disable --now mu2edaq-notify-dns.timer 2>/dev/null || true"
    fi
    if [ "$RUN_NOW" = "1" ]; then
        cat <<'PART7'
# Run it once now so the record is correct before anyone waits on a reboot.
/usr/local/sbin/mu2edaq-notify-dns-update
systemctl is-enabled mu2edaq-notify-dns.service
PART7
    fi
}

emit_user_data() {
    echo "#!/bin/bash"
    echo "# Generated by scripts/install-notify-dns-updater.sh --emit-user-data."
    echo "# Do not edit here; edit the repo files and regenerate."
    echo "set -euxo pipefail"
    echo 'exec > >(tee -a /var/log/mu2edaq-notify-proxy-bootstrap.log) 2>&1'
    echo
    # Caddy is installed first: its unit has to exist before the drop-in that
    # orders it after the DNS update can be dropped in.
    sed -e '1{/^#!/d;}' -e '/^set -euxo pipefail$/d' -e '/^exec > >(tee/d' \
        scripts/aws-proxy-user-data.sh
    echo
    emit_installer | sed -e '1{/^#!/d;}' -e '/^set -euxo pipefail$/d' \
                         -e '/^exec > >(tee -a \/var\/log\/mu2edaq-notify-dns-install.log)/d'
    echo
    echo "# The A record now points at this instance, so Caddy can start and pass"
    echo "# ACME validation. Later boots get the same order from the drop-in above."
    echo "systemctl start caddy"
}

USER_DATA_LIMIT=16384

if [ "$EMIT_USER_DATA" = "1" ]; then
    DOC=$(mktemp "${TMPDIR:-/tmp}/mu2edaq-user-data.XXXXXX")
    trap 'rm -f "$DOC" "$DOC.gz"' EXIT
    emit_user_data > "$DOC"
    raw=$(wc -c < "$DOC" | tr -d ' ')
    if [ "$GZIP_OUTPUT" = "1" ]; then
        gzip -9 -c "$DOC" > "$DOC.gz"
        packed=$(wc -c < "$DOC.gz" | tr -d ' ')
        cat "$DOC.gz"
        echo "user-data: $raw bytes raw, $packed gzipped (EC2 limit $USER_DATA_LIMIT)." >&2
        echo "Pass it to EC2 as fileb:// so the gzip stays binary; review it with gunzip -c." >&2
    else
        cat "$DOC"
        if [ "$raw" -gt "$USER_DATA_LIMIT" ]; then
            echo "WARNING: this document is $raw bytes and EC2 refuses user-data over" >&2
            echo "$USER_DATA_LIMIT. Re-run with --gzip (cloud-init decompresses it):" >&2
            echo "  scripts/install-notify-dns-updater.sh --emit-user-data --gzip > user-data.gz" >&2
        fi
    fi
    exit 0
fi

if [ -z "$HOST" ]; then
    HOST=$(notify_proxy_resolve_host)
fi
if [ -z "$HOST" ]; then
    echo "Cannot find an address for $MU2EDAQ_NOTIFY_PROXY_INSTANCE_ID." >&2
    echo "Start the instance first, or pass --host." >&2
    exit 1
fi
if [ ! -f "$PROXY_KEY" ]; then
    echo "Missing SSH key: $PROXY_KEY" >&2
    exit 1
fi
chmod 600 "$PROXY_KEY"

echo "Installing the DNS updater and Caddyfile on $PROXY_USER@$HOST ..."
# shellcheck disable=SC2207
SSH_OPTS=($(notify_proxy_ssh_opts))
emit_installer | ssh -i "$PROXY_KEY" "${SSH_OPTS[@]}" "$PROXY_USER@$HOST" \
    "sudo bash -s"
echo "Installed. Unit and timer state:"
ssh -i "$PROXY_KEY" "${SSH_OPTS[@]}" "$PROXY_USER@$HOST" \
    "systemctl is-enabled mu2edaq-notify-dns.service; systemctl list-timers mu2edaq-notify-dns.timer --no-pager || true"
