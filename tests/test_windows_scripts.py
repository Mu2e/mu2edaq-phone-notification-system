"""Windows PowerShell launch-script coverage.

Added in the windows-compat sweep. The notify server's control scripts have
PowerShell ports for Windows hosts; these tests lock in the parity (bootstrap +
server start/stop) and parse-check them. The AWS proxy/chain scripts under
scripts/ are Linux cloud/ssh deploy helpers and are intentionally not ported.
"""
import pathlib
import shutil
import subprocess

import pytest

REPO = pathlib.Path(__file__).resolve().parent.parent

SCRIPT_STEMS = [
    "bootstrap",
    "start-mu2edaq-notify-server",
    "stop-mu2edaq-notify-server",
]

PWSH = shutil.which("pwsh") or shutil.which("powershell")


def test_server_scripts_have_both_forms():
    for stem in SCRIPT_STEMS:
        assert (REPO / f"{stem}.sh").is_file(), f"missing bash script: {stem}.sh"
        assert (REPO / f"{stem}.ps1").is_file(), f"missing PowerShell port: {stem}.ps1"


def test_aws_deploy_scripts_are_not_ported():
    # Cloud/ssh deploy helpers -- Linux only, intentionally no PowerShell port.
    for rel in ("scripts/aws-proxy-user-data.sh",
                "scripts/start-mu2edaq-notify-proxy.sh",
                "scripts/start-mu2edaq-notify-chain.sh"):
        assert (REPO / rel).is_file()
        assert not (REPO / rel).with_suffix(".ps1").exists()


@pytest.mark.skipif(not PWSH, reason="PowerShell not available")
@pytest.mark.parametrize("stem", SCRIPT_STEMS)
def test_powershell_scripts_parse(stem):
    path = (REPO / f"{stem}.ps1").as_posix()
    code = (
        "$e=$null;"
        f"[System.Management.Automation.Language.Parser]::ParseFile('{path}',[ref]$null,[ref]$e)|Out-Null;"
        "if($e){$e|ForEach-Object{Write-Error $_};exit 1}else{exit 0}"
    )
    result = subprocess.run(
        [PWSH, "-NoProfile", "-NonInteractive", "-Command", code],
        capture_output=True, text=True, timeout=60,
    )
    assert result.returncode == 0, result.stderr


def test_server_config_has_no_unix_only_default_paths():
    # Deep-review guard: the config module must not hard-code POSIX paths that
    # would be invalid on Windows (the server writes under data/ relative to the
    # working dir, which is cross-platform).
    src = (REPO / "src" / "mu2edaq_notify" / "server" / "config.py").read_text(encoding="utf-8")
    for bad in ('"/tmp', "'/tmp", '"/var', "'/var", '"/etc', "'/etc"):
        assert bad not in src, f"unexpected POSIX path literal {bad} in config.py"
