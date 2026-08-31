"""Tests for the AWS proxy's self-registering DNS updater.

The proxy holds no Elastic IP, so scripts/aws-notify-dns-update.sh is what
keeps notify.andrewnorman.org pointing at whichever address the instance got
this start. These tests exercise it offline: IMDS is a throwaway HTTP server on
loopback and `aws` is a stub on PATH that records its argv, so nothing here
touches EC2, Route 53 or a real gateway.
"""

import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
UPDATER = REPO / "scripts" / "aws-notify-dns-update.sh"
COMMON = REPO / "scripts" / "notify-proxy-common.sh"

ZONE = "Z0TESTZONEID"
RECORD = "notify.example.test"


class FakeIMDS(BaseHTTPRequestHandler):
    """IMDSv2: a token has to be PUT before any metadata GET is answered."""

    public_ipv4 = "203.0.113.7"
    token = "fake-imds-token"

    def do_PUT(self):
        if self.path == "/latest/api/token":
            self._respond(200, self.token)
        else:
            self._respond(404, "")

    def do_GET(self):
        if self.headers.get("X-aws-ec2-metadata-token") != self.token:
            self._respond(401, "")
            return
        if self.path == "/latest/meta-data/public-ipv4":
            if self.public_ipv4 is None:
                self._respond(404, "")
            else:
                self._respond(200, self.public_ipv4)
        elif self.path == "/latest/meta-data/placement/region":
            self._respond(200, "us-west-2")
        elif self.path == "/latest/meta-data/instance-id":
            self._respond(200, "i-0testinstance")
        else:
            self._respond(404, "")

    def _respond(self, code, body):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):  # keep pytest output clean
        pass


@pytest.fixture
def imds():
    handler = type("Handler", (FakeIMDS,), {})
    server = HTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield handler, "http://127.0.0.1:%d" % server.server_port
    server.shutdown()
    server.server_close()


AWS_STUB = r"""#!/bin/bash
# Stand-in for the aws CLI: canned reads, every call logged, and the change
# batch it is handed copied out so the test can inspect what would be sent.
printf '%s\n' "$*" >> "$STUB_LOG"
case "$2" in
  list-resource-record-sets)
    prev=
    query=
    for arg in "$@"; do
      if [ "$prev" = "--query" ]; then query=$arg; fi
      prev=$arg
    done
    case "$query" in
      *TTL*) printf '%s\n' "@@TTL@@" ;;
      *)     printf '%s\n' "@@VALUE@@" ;;
    esac
    ;;
  describe-instances)
    prev=
    query=
    for arg in "$@"; do
      if [ "$prev" = "--query" ]; then query=$arg; fi
      prev=$arg
    done
    case "$query" in
      *State.Name*)      printf '%s\n' "@@STATE@@" ;;
      *PublicIpAddress*) printf '%s\n' "@@APIIP@@" ;;
      *) printf 'None\n' ;;
    esac
    ;;
  change-resource-record-sets)
    for arg in "$@"; do
      case "$arg" in file://*) cp "${arg#file://}" "$STUB_BATCH" ;; esac
    done
    printf '/change/C0FAKECHANGE\n'
    ;;
  *) : ;;
esac
"""


def write_stub_aws(tmp_path, current_value="198.51.100.20", current_ttl="60",
                   state="running", api_ip="None"):
    """Put the aws stub on PATH with the values this test wants read back."""
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    stub = bindir / "aws"
    stub.write_text(
        AWS_STUB.replace("@@TTL@@", current_ttl)
                .replace("@@VALUE@@", current_value)
                .replace("@@STATE@@", state)
                .replace("@@APIIP@@", api_ip)
    )
    stub.chmod(0o755)
    # dig is stubbed too: no test may depend on real DNS.
    dig = bindir / "dig"
    dig.write_text("#!/bin/bash\nprintf '%s\\n' \"${STUB_DIG:-}\"\n")
    dig.chmod(0o755)
    return bindir


def run_updater(tmp_path, imds_base, args=(), env=None, aws_current="198.51.100.20",
                aws_ttl="60"):
    bindir = write_stub_aws(tmp_path, aws_current, aws_ttl)
    log = tmp_path / "calls.log"
    batch = tmp_path / "batch.json"
    environ = dict(os.environ)
    environ.update(
        PATH="%s:%s" % (bindir, environ["PATH"]),
        STUB_LOG=str(log),
        STUB_BATCH=str(batch),
        MU2EDAQ_NOTIFY_IMDS_BASE=imds_base,
        MU2EDAQ_NOTIFY_ROUTE53_ZONE_ID=ZONE,
        MU2EDAQ_NOTIFY_DNS_RECORD=RECORD,
        MU2EDAQ_NOTIFY_DNS_LOGFILE="",
        MU2EDAQ_NOTIFY_DNS_CONFIG=str(tmp_path / "absent.conf"),
        MU2EDAQ_NOTIFY_DNS_WAIT="0",
    )
    if env:
        environ.update(env)
    proc = subprocess.run(
        ["bash", str(UPDATER), *args],
        capture_output=True, text=True, env=environ, cwd=str(tmp_path),
    )
    calls = log.read_text().splitlines() if log.exists() else []
    submitted = json.loads(batch.read_text()) if batch.exists() else None
    return proc, calls, submitted


def changes(calls):
    return [c for c in calls if "change-resource-record-sets" in c]


def test_stale_record_is_upserted_to_the_imds_address(tmp_path, imds):
    handler, base = imds
    proc, calls, submitted = run_updater(tmp_path, base)
    assert proc.returncode == 0, proc.stderr
    assert len(changes(calls)) == 1
    change = submitted["Changes"][0]
    assert change["Action"] == "UPSERT"
    assert change["ResourceRecordSet"]["Name"] == RECORD + "."
    assert change["ResourceRecordSet"]["Type"] == "A"
    assert change["ResourceRecordSet"]["TTL"] == 60
    assert change["ResourceRecordSet"]["ResourceRecords"][0]["Value"] == handler.public_ipv4
    assert "C0FAKECHANGE" in proc.stdout


def test_correct_record_costs_no_write(tmp_path, imds):
    handler, base = imds
    proc, calls, submitted = run_updater(tmp_path, base, aws_current=handler.public_ipv4)
    assert proc.returncode == 0, proc.stderr
    assert changes(calls) == []
    assert submitted is None


def test_matching_address_but_wrong_ttl_is_still_rewritten(tmp_path, imds):
    handler, base = imds
    proc, calls, _ = run_updater(
        tmp_path, base, aws_current=handler.public_ipv4, aws_ttl="300"
    )
    assert proc.returncode == 0, proc.stderr
    assert len(changes(calls)) == 1


def test_dry_run_submits_nothing(tmp_path, imds):
    _, base = imds
    proc, calls, submitted = run_updater(tmp_path, base, args=["--dry-run"])
    assert proc.returncode == 0, proc.stderr
    assert changes(calls) == []
    assert submitted is None
    assert "dry run" in proc.stdout


def test_no_public_address_fails_loudly(tmp_path, imds):
    handler, base = imds
    handler.public_ipv4 = None
    proc, calls, submitted = run_updater(
        tmp_path, base, args=["--tries", "2", "--delay", "0"]
    )
    assert proc.returncode == 1
    assert "no public IPv4" in proc.stderr
    assert changes(calls) == []
    assert submitted is None


def test_no_imds_token_fails_before_touching_route53(tmp_path):
    # Port 1 is closed; the point is that a broken IMDS is not mistaken for
    # "nothing to do".
    proc, calls, _ = run_updater(tmp_path, "http://127.0.0.1:1")
    assert proc.returncode == 1
    assert "IMDSv2" in proc.stderr
    assert calls == []


def test_command_line_overrides_environment_and_file(tmp_path, imds):
    _, base = imds
    conf = tmp_path / "dns.conf"
    conf.write_text(
        "MU2EDAQ_NOTIFY_ROUTE53_ZONE_ID=ZFROMFILE\n"
        "MU2EDAQ_NOTIFY_DNS_RECORD=file.example.test\n"
        "MU2EDAQ_NOTIFY_DNS_TTL=900\n"
    )
    # Config file only: nothing in the environment for these three.
    proc, calls, submitted = run_updater(
        tmp_path, base,
        args=["--config", str(conf)],
        env={"MU2EDAQ_NOTIFY_ROUTE53_ZONE_ID": "", "MU2EDAQ_NOTIFY_DNS_RECORD": ""},
    )
    assert proc.returncode == 0, proc.stderr
    assert submitted["Changes"][0]["ResourceRecordSet"]["Name"] == "file.example.test."
    assert submitted["Changes"][0]["ResourceRecordSet"]["TTL"] == 900
    assert any("ZFROMFILE" in c for c in changes(calls))

    # Environment beats the file.
    proc, calls, submitted = run_updater(
        tmp_path, base,
        args=["--config", str(conf)],
        env={"MU2EDAQ_NOTIFY_DNS_RECORD": "env.example.test"},
    )
    assert submitted["Changes"][0]["ResourceRecordSet"]["Name"] == "env.example.test."

    # Command line beats both.
    proc, calls, submitted = run_updater(
        tmp_path, base,
        args=["--config", str(conf), "--record", "cli.example.test", "--ttl", "30"],
        env={"MU2EDAQ_NOTIFY_DNS_RECORD": "env.example.test"},
    )
    assert submitted["Changes"][0]["ResourceRecordSet"]["Name"] == "cli.example.test."
    assert submitted["Changes"][0]["ResourceRecordSet"]["TTL"] == 30


def test_trailing_dot_in_record_is_tolerated(tmp_path, imds):
    _, base = imds
    _, _, submitted = run_updater(
        tmp_path, base, args=["--record", "dotted.example.test."]
    )
    assert submitted["Changes"][0]["ResourceRecordSet"]["Name"] == "dotted.example.test."


def test_explicit_ip_bypasses_imds(tmp_path, imds):
    handler, base = imds
    handler.public_ipv4 = None          # IMDS has nothing to offer
    proc, _, submitted = run_updater(tmp_path, base, args=["--ip", "192.0.2.55"])
    assert proc.returncode == 0, proc.stderr
    assert submitted["Changes"][0]["ResourceRecordSet"]["ResourceRecords"][0]["Value"] \
        == "192.0.2.55"


@pytest.mark.parametrize("bad", ["not-an-ip", "1.2.3", "1.2.3.4.5", "300.1.1.1", ""])
def test_bad_explicit_ip_is_rejected(tmp_path, imds, bad):
    _, base = imds
    proc, calls, _ = run_updater(tmp_path, base, args=["--ip", bad])
    assert proc.returncode != 0
    assert changes(calls) == []


# --------------------------------------------------------- operator-side helper

def source_common(tmp_path, snippet, public_ip="203.0.113.9"):
    """Run a snippet with notify-proxy-common.sh sourced and `aws` stubbed."""
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    stub = bindir / "aws"
    stub.write_text("#!/bin/bash\nprintf '%s\\n' '" + public_ip + "'\n")
    stub.chmod(0o755)
    environ = dict(os.environ)
    environ["PATH"] = "%s:%s" % (bindir, environ["PATH"])
    environ.pop("MU2EDAQ_NOTIFY_PROXY_HOST", None)
    return subprocess.run(
        ["bash", "-c", ". %s\n%s" % (COMMON, snippet)],
        capture_output=True, text=True, env=environ,
    )


def test_resolve_host_prefers_the_ec2_api(tmp_path):
    proc = source_common(tmp_path, "notify_proxy_resolve_host")
    assert proc.stdout.strip() == "203.0.113.9", proc.stderr


def test_resolve_host_honours_an_explicit_override(tmp_path):
    proc = source_common(
        tmp_path,
        'MU2EDAQ_NOTIFY_PROXY_HOST=192.0.2.1 notify_proxy_resolve_host',
    )
    assert proc.stdout.strip() == "192.0.2.1", proc.stderr


def test_api_ip_treats_none_as_absent(tmp_path):
    # A stopped instance makes describe-instances print the string "None".
    proc = source_common(tmp_path, "notify_proxy_api_ip", public_ip="None")
    assert proc.stdout.strip() == ""


def test_ssh_opts_pin_the_host_key_to_the_stable_name(tmp_path):
    # Without HostKeyAlias, a new address on every start would either pile up
    # known_hosts entries or trip host key warnings.
    proc = source_common(tmp_path, "notify_proxy_ssh_opts")
    assert "HostKeyAlias=notify.andrewnorman.org" in proc.stdout
    assert "BatchMode=yes" in proc.stdout


# ------------------------------------------------- operator-side update / retract

OPERATOR = REPO / "scripts" / "update-notify-dns.sh"


def run_operator(tmp_path, args=(), state="running", api_ip="203.0.113.7",
                 current_value="198.51.100.20", dig_answer=""):
    bindir = write_stub_aws(tmp_path, current_value, "60", state, api_ip)
    log = tmp_path / "calls.log"
    batch = tmp_path / "batch.json"
    environ = dict(os.environ)
    environ.update(
        PATH="%s:%s" % (bindir, environ["PATH"]),
        STUB_LOG=str(log),
        STUB_BATCH=str(batch),
        STUB_DIG=dig_answer,
        MU2EDAQ_NOTIFY_ROUTE53_ZONE_ID=ZONE,
        MU2EDAQ_NOTIFY_PROXY_DNS_NAME=RECORD,
    )
    environ.pop("MU2EDAQ_NOTIFY_PROXY_HOST", None)
    proc = subprocess.run(
        ["bash", str(OPERATOR), *args],
        capture_output=True, text=True, env=environ,
    )
    calls = log.read_text().splitlines() if log.exists() else []
    submitted = json.loads(batch.read_text()) if batch.exists() else None
    return proc, calls, submitted


def test_operator_publishes_the_api_address(tmp_path):
    proc, calls, submitted = run_operator(tmp_path)
    assert proc.returncode == 0, proc.stderr
    assert submitted["Changes"][0]["ResourceRecordSet"]["ResourceRecords"][0]["Value"] \
        == "203.0.113.7"


def test_operator_check_mode_flags_a_stale_record(tmp_path):
    proc, calls, submitted = run_operator(tmp_path, args=["--check"])
    assert proc.returncode == 1               # usable as a probe
    assert "stale" in proc.stdout
    assert changes(calls) == []
    assert submitted is None


def test_operator_check_mode_is_quiet_when_correct(tmp_path):
    proc, calls, _ = run_operator(
        tmp_path, args=["--check"], current_value="203.0.113.7"
    )
    assert proc.returncode == 0
    assert changes(calls) == []


def test_retract_parks_the_record_on_an_unroutable_address(tmp_path):
    # A stopped instance has no address to publish, which is exactly when the
    # record must not be left pointing at the released one.
    proc, calls, submitted = run_operator(
        tmp_path, args=["--retract"], state="stopped", api_ip="None"
    )
    assert proc.returncode == 0, proc.stderr
    record = submitted["Changes"][0]["ResourceRecordSet"]
    assert record["ResourceRecords"][0]["Value"] == "192.0.2.1"
    assert submitted["Changes"][0]["Action"] == "UPSERT"   # never a DELETE


def test_retract_honours_a_custom_sink(tmp_path):
    proc, _, submitted = run_operator(
        tmp_path, args=["--retract", "--sink", "192.0.2.99"], state="stopped",
        api_ip="None",
    )
    assert proc.returncode == 0, proc.stderr
    assert submitted["Changes"][0]["ResourceRecordSet"]["ResourceRecords"][0]["Value"] \
        == "192.0.2.99"


def test_stopped_instance_without_retract_refuses_to_guess(tmp_path):
    proc, calls, submitted = run_operator(tmp_path, state="stopped", api_ip="None")
    assert proc.returncode == 1
    assert changes(calls) == []
    assert submitted is None


# ------------------------------------------------------------------ CAA pinning

CAA = REPO / "scripts" / "update-notify-caa.sh"
ACCT = "https://acme-v02.api.letsencrypt.org/acme/acct/1234567890"

CAA_AWS_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  "route53 get-hosted-zone")
    printf '%s\n' '@@APEX@@.'
    ;;
  "route53 list-resource-record-sets")
    prev=
    query=
    for arg in "$@"; do
      if [ "$prev" = "--query" ]; then query=$arg; fi
      prev=$arg
    done
    case "$query" in
      *TTL*) printf '%s\n' '@@CAATTL@@' ;;
      *)     printf '%s\n' '@@CAAVALUES@@' ;;
    esac
    ;;
  "route53 change-resource-record-sets")
    for arg in "$@"; do
      case "$arg" in file://*) cp "${arg#file://}" "$STUB_BATCH" ;; esac
    done
    printf '/change/C0FAKECAA\n'
    ;;
  *) : ;;
esac
"""


def run_caa(tmp_path, args=(), live_values="", live_ttl="", apex="andrewnorman.org"):
    """Run the CAA script with aws stubbed. Discovery over SSH is never exercised
    here: every call passes --account-uri, so no test needs a running instance."""
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    stub = bindir / "aws"
    stub.write_text(
        CAA_AWS_STUB.replace("@@APEX@@", apex)
                    .replace("@@CAAVALUES@@", live_values)
                    .replace("@@CAATTL@@", live_ttl)
    )
    stub.chmod(0o755)
    log = tmp_path / "calls.log"
    batch = tmp_path / "batch.json"
    environ = dict(os.environ)
    environ.update(
        PATH="%s:%s" % (bindir, environ["PATH"]),
        STUB_LOG=str(log),
        STUB_BATCH=str(batch),
        MU2EDAQ_NOTIFY_ROUTE53_ZONE_ID=ZONE,
        MU2EDAQ_NOTIFY_PROXY_DNS_NAME=RECORD,
    )
    proc = subprocess.run(
        ["bash", str(CAA), *args], capture_output=True, text=True, env=environ,
    )
    calls = log.read_text().splitlines() if log.exists() else []
    submitted = json.loads(batch.read_text()) if batch.exists() else None
    return proc, calls, submitted


def caa_values(submitted):
    return [r["Value"] for r in submitted["Changes"][0]["ResourceRecordSet"]["ResourceRecords"]]


def test_caa_record_pins_the_account_and_denies_wildcards(tmp_path):
    proc, _, submitted = run_caa(tmp_path, args=["--account-uri", ACCT])
    assert proc.returncode == 0, proc.stderr
    values = caa_values(submitted)
    assert values[0] == (
        '0 issue "letsencrypt.org;accounturi=%s;validationmethods=http-01,tls-alpn-01"' % ACCT
    )
    assert values[1] == '0 issuewild ";"'
    assert submitted["Changes"][0]["ResourceRecordSet"]["Type"] == "CAA"
    assert submitted["Changes"][0]["Action"] == "UPSERT"


def test_caa_batch_is_valid_json_with_escaped_quotes(tmp_path):
    # The values carry embedded double quotes; a hand-built batch is the easiest
    # place in this change to emit malformed JSON.
    _, _, submitted = run_caa(tmp_path, args=["--account-uri", ACCT])
    assert submitted is not None            # json.loads already succeeded
    assert submitted["Changes"][0]["ResourceRecordSet"]["TTL"] == 300


def test_caa_omits_validationmethods_when_asked(tmp_path):
    _, _, submitted = run_caa(
        tmp_path, args=["--account-uri", ACCT, "--validation-methods", ""]
    )
    assert caa_values(submitted)[0] == '0 issue "letsencrypt.org;accounturi=%s"' % ACCT


def test_caa_authorizes_several_accounts(tmp_path):
    second = "https://acme-v02.api.letsencrypt.org/acme/acct/999"
    _, _, submitted = run_caa(
        tmp_path,
        args=["--account-uri", ACCT, "--account-uri", second, "--no-issuewild"],
    )
    values = caa_values(submitted)
    assert len(values) == 2
    assert ACCT in values[0] and second in values[1]


def test_caa_refuses_the_zone_apex(tmp_path):
    # Other names in this zone use ACM certificates; an apex CAA naming only
    # letsencrypt.org would break their renewals.
    proc, calls, submitted = run_caa(
        tmp_path, args=["--record", "andrewnorman.org", "--account-uri", ACCT]
    )
    assert proc.returncode == 1
    assert "apex" in proc.stderr
    assert [c for c in calls if "change-resource-record-sets" in c] == []
    assert submitted is None


def test_caa_check_fails_when_no_record_exists(tmp_path):
    proc, calls, _ = run_caa(tmp_path, args=["--check", "--account-uri", ACCT])
    assert proc.returncode == 1
    assert "unrestricted" in proc.stdout
    assert [c for c in calls if "change-resource-record-sets" in c] == []


def test_caa_check_fails_when_a_different_account_is_pinned(tmp_path):
    # This is the state a rebuilt instance lands in: Caddy has a new account,
    # the record still names the old one, and renewal will fail weeks later.
    live = '0 issue "letsencrypt.org;accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/1"'
    proc, _, _ = run_caa(tmp_path, args=["--check", "--account-uri", ACCT], live_values=live)
    assert proc.returncode == 1
    assert "NOT authorized" in proc.stderr


def test_caa_check_passes_when_the_account_is_authorized(tmp_path):
    live = '0 issue "letsencrypt.org;accounturi=%s;validationmethods=http-01,tls-alpn-01"' % ACCT
    proc, calls, _ = run_caa(
        tmp_path, args=["--check", "--account-uri", ACCT], live_values=live, live_ttl="300"
    )
    assert proc.returncode == 0, proc.stderr
    assert "authorizes the instance's ACME account" in proc.stdout
    assert [c for c in calls if "change-resource-record-sets" in c] == []


def test_caa_remove_deletes_the_live_values_verbatim(tmp_path):
    # Route 53 rejects a DELETE that does not match the existing set exactly, so
    # the batch has to be rebuilt from what is live, not from what would be written.
    live = '0 issue "letsencrypt.org;accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/7"\t0 issuewild ";"'
    proc, _, submitted = run_caa(tmp_path, args=["--remove"], live_values=live, live_ttl="900")
    assert proc.returncode == 0, proc.stderr
    assert submitted["Changes"][0]["Action"] == "DELETE"
    assert submitted["Changes"][0]["ResourceRecordSet"]["TTL"] == 900
    assert caa_values(submitted) == [
        '0 issue "letsencrypt.org;accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/7"',
        '0 issuewild ";"',
    ]


def test_caa_remove_is_a_no_op_without_a_record(tmp_path):
    proc, calls, submitted = run_caa(tmp_path, args=["--remove"])
    assert proc.returncode == 0
    assert submitted is None
    assert [c for c in calls if "change-resource-record-sets" in c] == []


def test_caa_dry_run_submits_nothing(tmp_path):
    proc, calls, submitted = run_caa(tmp_path, args=["--account-uri", ACCT, "--dry-run"])
    assert proc.returncode == 0, proc.stderr
    assert submitted is None
    assert [c for c in calls if "change-resource-record-sets" in c] == []
    assert '0 issue "letsencrypt.org;accounturi=' in proc.stdout


def test_caddyfile_issuer_matches_the_caa_ca():
    # The CAA record names letsencrypt.org, so Caddy must not be left free to
    # fall back to another CA that CAA would refuse.
    caddyfile = (REPO / "config" / "aws" / "Caddyfile").read_text()
    assert "acme_ca https://acme-v02.api.letsencrypt.org/directory" in caddyfile
    default_ca = "letsencrypt.org"
    assert default_ca in CAA.read_text()


# ------------------------------------------- retraction decision (regression)
#
# Retracting the public record on teardown once broke the chain: with an
# Elastic IP still attached the address never leaves the account, so there is
# nothing to dangle, but the record was parked on the sink anyway -- and the
# republish depended on an instance-side updater that was not installed. The
# next start then found notify.andrewnorman.org -> 192.0.2.1 and no way back.

COMMON_AWS_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  "ec2 describe-instances")
    prev=
    query=
    for arg in "$@"; do
      if [ "$prev" = "--query" ]; then query=$arg; fi
      prev=$arg
    done
    case "$query" in
      *State.Name*)      printf '%s\n' '@@STATE@@' ;;
      *PublicIpAddress*) printf '%s\n' '@@APIIP@@' ;;
      *) printf 'None\n' ;;
    esac
    ;;
  "ec2 describe-addresses")
    printf '%s\n' '@@EIPALLOC@@'
    ;;
  "route53 list-resource-record-sets")
    printf '%s\n' '@@RECORD@@'
    ;;
  *) : ;;
esac
"""


def retract_decision(tmp_path, api_ip="203.0.113.7", record="203.0.113.7",
                     eip_alloc="None", env=None):
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    stub = bindir / "aws"
    stub.write_text(
        COMMON_AWS_STUB.replace("@@APIIP@@", api_ip)
                       .replace("@@RECORD@@", record)
                       .replace("@@EIPALLOC@@", eip_alloc)
                       .replace("@@STATE@@", "running")
    )
    stub.chmod(0o755)
    environ = dict(os.environ)
    environ.update(PATH="%s:%s" % (bindir, environ["PATH"]),
                   STUB_LOG=str(tmp_path / "calls.log"))
    environ.pop("MU2EDAQ_NOTIFY_PROXY_HOST", None)
    environ.update(env or {})
    proc = subprocess.run(
        ["bash", "-c", ". %s\nnotify_proxy_retract_decision" % COMMON],
        capture_output=True, text=True, env=environ,
    )
    return proc.stdout.strip(), proc.returncode


def test_elastic_ip_means_no_retraction(tmp_path):
    # The regression: an attached Elastic IP survives the stop, so the record
    # is still correct when the instance comes back.
    verdict, rc = retract_decision(tmp_path, eip_alloc="eipalloc-0abc")
    assert verdict == "skip elastic-ip eipalloc-0abc"
    assert rc == 1


def test_auto_assigned_address_is_retracted(tmp_path):
    verdict, rc = retract_decision(tmp_path)
    assert verdict == "retract"
    assert rc == 0


def test_a_record_pointing_elsewhere_is_left_alone(tmp_path):
    # e.g. the name was deliberately repointed at the OKD proxy.
    verdict, rc = retract_decision(tmp_path, record="131.225.169.63")
    assert verdict == "skip not-ours 131.225.169.63 203.0.113.7"
    assert rc == 1


def test_no_public_address_means_nothing_to_dangle(tmp_path):
    verdict, rc = retract_decision(tmp_path, api_ip="None")
    assert verdict == "skip no-address"
    assert rc == 1


def test_retraction_can_be_disabled_outright(tmp_path):
    verdict, rc = retract_decision(tmp_path, env={"MU2EDAQ_NOTIFY_DNS_RETRACT": "0"})
    assert verdict == "skip disabled"
    assert rc == 1


def test_disabled_retraction_makes_no_aws_calls(tmp_path):
    retract_decision(tmp_path, env={"MU2EDAQ_NOTIFY_DNS_RETRACT": "0"})
    log = tmp_path / "calls.log"
    assert not log.exists() or log.read_text().strip() == ""


def test_record_ip_reads_route53_not_a_resolver(tmp_path):
    # Route 53 is authoritative and immediate; a resolver caches the previous
    # value for up to the TTL, and polling one cannot tell "not published" from
    # "published, still cached".
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    stub = bindir / "aws"
    stub.write_text(COMMON_AWS_STUB.replace("@@RECORD@@", "198.51.100.9")
                                   .replace("@@APIIP@@", "203.0.113.7")
                                   .replace("@@EIPALLOC@@", "None")
                                   .replace("@@STATE@@", "running"))
    stub.chmod(0o755)
    log = tmp_path / "calls.log"
    environ = dict(os.environ)
    environ.update(PATH="%s:%s" % (bindir, environ["PATH"]), STUB_LOG=str(log))
    proc = subprocess.run(
        ["bash", "-c", ". %s\nnotify_proxy_record_ip" % COMMON],
        capture_output=True, text=True, env=environ,
    )
    assert proc.stdout.strip() == "198.51.100.9"
    assert "list-resource-record-sets" in log.read_text()
