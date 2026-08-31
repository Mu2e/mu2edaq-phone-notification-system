"""Tests for scripts/restore-mu2edaq-notify-tunnel.sh.

The tunnel has no supervisor by design, so this script is what puts it back.
Everything here is offline: `ssh`, `aws`, `dig` and `curl` are stubs on PATH
that record their arguments, and the pidfile and log are redirected into the
test's tmp_path so a run can never touch a real tunnel.
"""

import os
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
RESTORE = REPO / "scripts" / "restore-mu2edaq-notify-tunnel.sh"

ADDRESS = "203.0.113.7"

SSH_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "$STUB_SSH_LOG"

# `ssh -N -R ...` is the tunnel itself: stay alive like the real thing, and
# mark the forward as working from now on.
for a in "$@"; do
  if [ "$a" = "-N" ]; then
    touch "$STUB_HEALTHY"
    exec sleep 30
  fi
done

last=${!#}
case "$last" in
  *api/health*)
    [ -f "$STUB_HEALTHY" ] && exit 0 || exit 1
    ;;
  *ss\ -ltnpH*|*sport*)
    cat "$STUB_LISTENER_PID" 2>/dev/null
    exit 0
    ;;
  *cmdline*)
    cat "$STUB_KILL_VERDICT" 2>/dev/null || echo gone
    exit 0
    ;;
  *) exit 0 ;;
esac
"""

AWS_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "$STUB_AWS_LOG"
case "$*" in
  *PublicIpAddress*) printf '%s\n' "@@ADDRESS@@" ;;
  *) printf 'None\n' ;;
esac
"""

CURL_STUB = r"""#!/bin/bash
# The local notify server: healthy unless the test says otherwise.
[ -f "$STUB_LOCAL_DOWN" ] && exit 7
exit 0
"""


def build_env(tmp_path, address=ADDRESS, healthy=False, listener_pid="",
              kill_verdict="gone", local_down=False):
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    for name, body in (("ssh", SSH_STUB),
                       ("aws", AWS_STUB.replace("@@ADDRESS@@", address)),
                       ("curl", CURL_STUB)):
        path = bindir / name
        path.write_text(body)
        path.chmod(0o755)
    dig = bindir / "dig"
    # "None" means the API has no address for the instance; DNS must come back
    # empty too, or the fallback hides the failure the test is checking.
    answer = "" if address in ("None", "") else address
    dig.write_text("#!/bin/bash\nprintf '%s' '" + answer + "'\n")
    dig.chmod(0o755)

    key = tmp_path / "fake.pem"
    key.write_text("not a real key\n")
    key.chmod(0o600)

    healthy_flag = tmp_path / "healthy"
    if healthy:
        healthy_flag.write_text("")
    listener = tmp_path / "listener_pid"
    listener.write_text(listener_pid)
    verdict = tmp_path / "kill_verdict"
    verdict.write_text(kill_verdict)
    local_flag = tmp_path / "local_down"
    if local_down:
        local_flag.write_text("")

    env = dict(os.environ)
    env.update(
        PATH="%s:%s" % (bindir, env["PATH"]),
        STUB_SSH_LOG=str(tmp_path / "ssh.log"),
        STUB_AWS_LOG=str(tmp_path / "aws.log"),
        STUB_HEALTHY=str(healthy_flag),
        STUB_LISTENER_PID=str(listener),
        STUB_KILL_VERDICT=str(verdict),
        STUB_LOCAL_DOWN=str(local_flag),
        # Never let a test write the real tunnel's pidfile or log.
        MU2EDAQ_NOTIFY_PROXY_PIDFILE=str(tmp_path / "tunnel.pid"),
        MU2EDAQ_NOTIFY_PROXY_LOGFILE=str(tmp_path / "tunnel.log"),
        MU2EDAQ_NOTIFY_PROXY_KEY=str(key),
        MU2EDAQ_NOTIFY_PROXY_DNS_NAME="notify.example.test",
    )
    env.pop("MU2EDAQ_NOTIFY_PROXY_HOST", None)
    return env


def run_restore(tmp_path, args=(), **kwargs):
    env = build_env(tmp_path, **kwargs)
    proc = subprocess.run([str(RESTORE), *args], capture_output=True,
                          text=True, env=env, timeout=120)
    ssh_log = tmp_path / "ssh.log"
    calls = ssh_log.read_text().splitlines() if ssh_log.exists() else []
    return proc, calls


def opened_tunnel(calls):
    return [c for c in calls if " -N " in " %s " % c and "-R" in c]


def test_healthy_tunnel_is_left_alone(tmp_path):
    proc, calls = run_restore(tmp_path, healthy=True)
    assert proc.returncode == 0, proc.stderr
    assert "healthy" in proc.stdout
    assert opened_tunnel(calls) == []


def test_broken_tunnel_is_rebuilt(tmp_path):
    proc, calls = run_restore(tmp_path, healthy=False)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "Restored" in proc.stdout
    assert len(opened_tunnel(calls)) == 1


def test_rebuild_forwards_the_configured_ports(tmp_path):
    _, calls = run_restore(tmp_path, healthy=False)
    assert "-R 127.0.0.1:18095:127.0.0.1:8095" in opened_tunnel(calls)[0]


def test_rebuild_pins_the_host_key_to_the_stable_name(tmp_path):
    # The proxy's address changes on every start; without HostKeyAlias the
    # tunnel would accumulate a known_hosts entry per address.
    _, calls = run_restore(tmp_path, healthy=False)
    assert "HostKeyAlias=notify.example.test" in opened_tunnel(calls)[0]


def test_rebuild_keeps_exit_on_forward_failure(tmp_path):
    # Without it a tunnel whose forward was refused sits there looking alive.
    _, calls = run_restore(tmp_path, healthy=False)
    assert "ExitOnForwardFailure=yes" in opened_tunnel(calls)[0]


def test_force_rebuilds_a_healthy_tunnel(tmp_path):
    proc, calls = run_restore(tmp_path, args=["--force"], healthy=True)
    assert proc.returncode == 0, proc.stderr
    assert "Rebuilding on request" in proc.stdout
    assert len(opened_tunnel(calls)) == 1


def test_check_reports_without_touching_anything(tmp_path):
    proc, calls = run_restore(tmp_path, args=["--check"], healthy=False)
    assert proc.returncode == 1              # usable as a probe
    assert opened_tunnel(calls) == []


def test_check_is_quiet_when_healthy(tmp_path):
    proc, calls = run_restore(tmp_path, args=["--check"], healthy=True)
    assert proc.returncode == 0
    assert opened_tunnel(calls) == []


def test_no_reachable_address_fails_with_a_pointer(tmp_path):
    proc, calls = run_restore(tmp_path, healthy=False, address="None")
    assert proc.returncode == 1
    assert "no reachable address" in proc.stdout
    assert "start-mu2edaq-notify-chain.sh" in proc.stdout
    assert opened_tunnel(calls) == []


def test_a_down_local_server_is_called_out(tmp_path):
    # The tunnel can be rebuilt without it, but it would only carry 502s.
    proc, _ = run_restore(tmp_path, healthy=False, local_down=True)
    assert "local notify server is not answering" in proc.stdout
    assert "502" in proc.stdout


# --------------------------------------------------- the stranded listener
#
# When a session dies uncleanly, sshd on the proxy can keep holding the
# forwarded port. ExitOnForwardFailure=yes then makes every new tunnel refuse
# to start, and the error names the symptom rather than the cause.

def test_stale_listener_is_killed_before_rebuilding(tmp_path):
    proc, calls = run_restore(tmp_path, healthy=False, listener_pid="4242",
                              kill_verdict="killed")
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "still holds" in proc.stdout
    assert "Cleared the stale listener" in proc.stdout
    assert len(opened_tunnel(calls)) == 1


def test_listener_belonging_to_this_session_is_not_killed(tmp_path):
    # PIDs are recycled and our own connection is an sshd too.
    proc, _ = run_restore(tmp_path, healthy=False, listener_pid="4242",
                          kill_verdict="self")
    assert "not touching it" in proc.stdout


def test_listener_held_by_something_else_is_reported_not_killed(tmp_path):
    proc, _ = run_restore(tmp_path, healthy=False, listener_pid="4242",
                          kill_verdict="not-sshd:/usr/bin/python3 something")
    assert "is not sshd" in proc.stdout
    assert "python3" in proc.stdout


def test_no_listener_means_no_kill_attempt(tmp_path):
    proc, _ = run_restore(tmp_path, healthy=False, listener_pid="")
    assert "still holds" not in proc.stdout
