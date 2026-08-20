"""Fetch mu2edaq-pager secrets from HashiCorp Vault (KV v2).

Human developers authenticate with the `vault` CLI (e.g.
`vault login -method=ldap -address=https://ssivault.fnal.gov:8200`), which
caches a token at ~/.vault-token. This module never re-implements that login
flow -- it only reads the cached token (or VAULT_TOKEN / --token).

There are two separate secret instances: production and test. Pick one with
--env (or VAULT_ENV / vault.yaml's env key); read-only usage defaults to
"test" if nothing is specified.

Alternatively, pass --approle (or MU2EDAQ_PAGER_VAULT_APPROLE=1) to
authenticate as the application rather than as a person: the token is minted
on demand by scripts/get-vault-apptoken.sh, which exchanges AppRole
role-id/secret-id for a short-lived app token. Useful for CI and unattended
deploys.

SECRET_REGISTRY is empty right now -- this deployment is a reverse proxy
only and needs no secrets today. The plumbing (this script,
config/vault.yaml, scripts/get-vault-apptoken.sh) is set up so a secret can
be added later with a single line here plus a `vault kv put`; see
docs/Vault-Secrets.md.

Usage:
    python3 scripts/vault_client.py env --env test
    python3 scripts/vault_client.py helm-values --env prod
    python3 scripts/vault_client.py json --env test
    python3 scripts/vault_client.py helm-values --env prod --approle

See docs/Vault-Secrets.md for the full setup guide and man/vault-client.1
for the man page.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import yaml

try:
    import hvac
    from hvac.exceptions import Forbidden, InvalidPath, VaultError
except ImportError:  # pragma: no cover - exercised only when hvac truly missing
    hvac = None
    Forbidden = InvalidPath = VaultError = Exception

PROJECT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG_PATH = PROJECT_DIR / 'config' / 'vault.yaml'

# AppRole application token, minted by the sibling shell script rather than
# reimplemented here (it owns the personal-login-then-exchange dance). Opt-in:
# without it, tokens come from --token / VAULT_TOKEN / ~/.vault-token as before.
APPROLE_SCRIPT = PROJECT_DIR / 'scripts' / 'get-vault-apptoken.sh'
APPROLE_TIMEOUT = 120

DEFAULT_ADDR = 'https://ssivault.fnal.gov:8200'
# KV v2 mount point. Following the convention confirmed on mu2e-talks: the
# full logical path to this app's secrets is
# okd/shared/<env>/mu2edaq-pager/<section>, so "okd" is the mount itself and
# BASE_PATH_TEMPLATE below is everything after it. Override with
# --kv-mount / VAULT_KV_MOUNT / config/vault.yaml if this turns out to be
# wrong for this app.
DEFAULT_KV_MOUNT = 'okd'

# There are two separate instances of this app's secrets in Vault: a
# production one and a test one. base_path is computed from this template
# unless explicitly overridden (--base-path / VAULT_BASE_PATH / vault.yaml's
# base_path key), which is a full escape hatch for anything that doesn't fit
# the template. This is everything *after* the okd/ mount point above.
BASE_PATH_TEMPLATE = 'shared/{env}/mu2edaq-pager'
ENVIRONMENTS = ('prod', 'test')
# Read-only convenience scripts default here so nothing talks to production
# secrets without an explicit --env prod. Scripts that write or actually
# deploy require an explicit --env every time instead of relying on this
# default -- see scripts/deploy-okd-proxy.sh.
DEFAULT_ENV = 'test'

# Single source of truth: (vault section, field within section, env var name,
# dotted helm values.yaml path). The tunnel keytab is the first real entry
# -- see docs/Vault-Secrets.md for how to populate it and
# backend.tunnel.enabled in helm/values.yaml for what it's used for.
SECRET_REGISTRY = [
    ('tunnel', 'principal', 'TUNNEL_PRINCIPAL', 'backend.tunnel.principal'),
    ('tunnel', 'keytab_b64', 'TUNNEL_KEYTAB_B64', 'backend.tunnel.keytabB64'),
]


class VaultAuthError(RuntimeError):
    """No usable Vault token could be found."""


class VaultAccessError(RuntimeError):
    """Vault was reachable but the read failed (permissions, path, network)."""


class VaultConfigError(RuntimeError):
    """Invalid configuration input, e.g. an unrecognized --env value."""


@dataclass
class VaultConfig:
    addr: str = DEFAULT_ADDR
    env: str = DEFAULT_ENV
    base_path: str = ''
    kv_mount: str = DEFAULT_KV_MOUNT
    token: Optional[str] = None
    approle: bool = False
    approle_role: Optional[str] = None

    def __post_init__(self):
        if not self.base_path:
            self.base_path = BASE_PATH_TEMPLATE.format(env=self.env)


def load_config_file(path: Path) -> dict:
    """Read config/vault.yaml (non-secret connection defaults). Missing file is fine."""
    if not path.exists():
        return {}
    with open(path) as fh:
        data = yaml.safe_load(fh) or {}
    return data.get('vault', {})


def _as_bool(value) -> bool:
    """Interpret a CLI/env/YAML flag value as a boolean.

    Env vars arrive as strings, YAML may already have parsed `true` into a
    bool, and argparse gives us True/None -- normalize all three.
    """
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    return str(value).strip().lower() in ('1', 'true', 'yes', 'on')


def resolve_config(args: Optional[argparse.Namespace] = None, env: Optional[dict] = None) -> VaultConfig:
    """CLI args > env vars > config/vault.yaml > hardcoded defaults.

    base_path is normally computed from BASE_PATH_TEMPLATE + the resolved
    environment (prod/test); passing an explicit base_path (via any of the
    three sources) bypasses the template entirely.
    """
    env = os.environ if env is None else env
    args = args or argparse.Namespace(
        addr=None, env=None, base_path=None, kv_mount=None, token=None, config=None,
        approle=None, approle_role=None,
    )

    config_path = Path(args.config) if getattr(args, 'config', None) else DEFAULT_CONFIG_PATH
    file_cfg = load_config_file(config_path)

    addr = args.addr or env.get('VAULT_ADDR') or file_cfg.get('addr') or DEFAULT_ADDR
    vault_env = getattr(args, 'env', None) or env.get('VAULT_ENV') or file_cfg.get('env') or DEFAULT_ENV
    if vault_env not in ENVIRONMENTS:
        raise VaultConfigError(
            f"Invalid Vault environment {vault_env!r}; must be one of {', '.join(ENVIRONMENTS)}."
        )
    base_path = args.base_path or env.get('VAULT_BASE_PATH') or file_cfg.get('base_path') or ''
    kv_mount = args.kv_mount or env.get('VAULT_KV_MOUNT') or file_cfg.get('kv_mount') or DEFAULT_KV_MOUNT
    token = args.token or env.get('VAULT_TOKEN')

    # An explicit token always wins: if the caller already handed us one (e.g.
    # deploy-okd-proxy.sh exporting a token it minted once for the whole run),
    # there is nothing to gain from minting another.
    approle = False
    if not token:
        approle = _as_bool(
            getattr(args, 'approle', None)
            if getattr(args, 'approle', None) is not None
            else env.get('MU2EDAQ_PAGER_VAULT_APPROLE', file_cfg.get('approle'))
        )
    approle_role = (
        getattr(args, 'approle_role', None)
        or env.get('MU2EDAQ_PAGER_VAULT_ROLE')
        or file_cfg.get('role')
    )

    return VaultConfig(
        addr=addr, env=vault_env, base_path=base_path, kv_mount=kv_mount,
        token=token, approle=approle, approle_role=approle_role,
    )


def resolve_token(explicit: Optional[str] = None, env: Optional[dict] = None, home: Optional[Path] = None) -> str:
    """Resolve a Vault token: explicit arg > VAULT_TOKEN env > ~/.vault-token file."""
    if explicit:
        return explicit

    env = os.environ if env is None else env
    env_token = env.get('VAULT_TOKEN')
    if env_token:
        return env_token

    home = home or Path.home()
    token_file = home / '.vault-token'
    if token_file.exists():
        token = token_file.read_text().strip()
        if token:
            return token

    raise VaultAuthError(
        "No Vault token found (checked --token, VAULT_TOKEN, and "
        f"{token_file}). Run:\n"
        f"    vault login -method=ldap -address={DEFAULT_ADDR}\n"
        "then try again."
    )


def fetch_approle_token(
    addr: Optional[str] = None,
    role: Optional[str] = None,
    script: Optional[Path] = None,
    runner=None,
) -> str:
    """Mint a short-lived AppRole application token via get-vault-apptoken.sh.

    The shell script owns the whole flow (personal login if needed, read
    role-id, mint secret-id, exchange for an app token), so this is a thin
    wrapper rather than a second implementation. Its diagnostics go to stderr
    and are passed through; only the bare token lands on stdout.
    """
    script = Path(script) if script else APPROLE_SCRIPT
    if not script.exists():
        raise VaultAuthError(
            f"AppRole mode requested but {script} was not found."
        )
    if not os.access(script, os.X_OK):
        raise VaultAuthError(
            f"AppRole mode requested but {script} is not executable "
            f"(fix with: chmod +x {script})."
        )

    cmd = [str(script), '--format', 'token', '--quiet']
    if addr:
        cmd += ['--addr', addr]
    if role:
        cmd += ['--role', role]

    runner = runner or subprocess.run
    try:
        completed = runner(cmd, capture_output=True, text=True, timeout=APPROLE_TIMEOUT)
    except subprocess.TimeoutExpired as exc:
        raise VaultAuthError(
            f"{script.name} timed out after {APPROLE_TIMEOUT}s. It may be waiting on an "
            "interactive login -- run it once by hand to authenticate, then retry."
        ) from exc
    except OSError as exc:
        raise VaultAuthError(f"Could not run {script}: {exc}") from exc

    if completed.returncode != 0:
        detail = (completed.stderr or '').strip() or f'exit status {completed.returncode}'
        raise VaultAuthError(f"Could not obtain a Vault AppRole token:\n{detail}")

    token = (completed.stdout or '').strip()
    if not token:
        raise VaultAuthError(
            f"{script.name} succeeded but returned no token on stdout."
        )
    return token


class VaultClient:
    """Thin wrapper around hvac for KV v2 reads, with actionable errors."""

    def __init__(self, addr: str, token: str, kv_mount: str, verify: bool = True):
        if hvac is None:
            raise RuntimeError(
                "The 'hvac' package is required. Install it with: pip install hvac"
            )
        self.addr = addr
        self.kv_mount = kv_mount
        self._client = hvac.Client(url=addr, token=token, verify=verify)

    def read_section(self, base_path: str, section: str, missing_ok: bool = False) -> dict:
        """Read one KV v2 secret (base_path/section) under kv_mount, return its data dict.

        If missing_ok is True, a not-found path returns {} instead of raising --
        used by a populate script, where "no secret written yet" is expected.
        """
        path = f"{base_path.strip('/')}/{section}"
        try:
            response = self._client.secrets.kv.v2.read_secret_version(
                path=path, mount_point=self.kv_mount, raise_on_deleted_version=True,
            )
        except Forbidden as exc:
            raise VaultAccessError(
                f"Permission denied reading '{self.kv_mount}/{path}' at {self.addr}. "
                "Confirm your Vault token has read access to this path."
            ) from exc
        except InvalidPath as exc:
            if missing_ok:
                return {}
            raise VaultAccessError(
                f"No secret found at '{self.kv_mount}/{path}' ({self.addr}). "
                "Confirm the mount point and base path are correct, and that "
                "this section has been populated (see docs/Vault-Secrets.md)."
            ) from exc
        except VaultError as exc:
            raise VaultAccessError(f"Vault error reading '{self.kv_mount}/{path}': {exc}") from exc
        except Exception as exc:  # connection errors, DNS, TLS, etc.
            raise VaultAccessError(
                f"Could not reach Vault at {self.addr} to read '{self.kv_mount}/{path}': {exc}"
            ) from exc

        return response['data']['data']

    def write_section(self, base_path: str, section: str, data: dict) -> None:
        """Write (replace) one KV v2 secret's full data dict at base_path/section."""
        path = f"{base_path.strip('/')}/{section}"
        try:
            self._client.secrets.kv.v2.create_or_update_secret(
                path=path, secret=data, mount_point=self.kv_mount,
            )
        except Forbidden as exc:
            raise VaultAccessError(
                f"Permission denied writing '{self.kv_mount}/{path}' at {self.addr}. "
                "Confirm your Vault token has create/update access to this path."
            ) from exc
        except VaultError as exc:
            raise VaultAccessError(f"Vault error writing '{self.kv_mount}/{path}': {exc}") from exc
        except Exception as exc:  # connection errors, DNS, TLS, etc.
            raise VaultAccessError(
                f"Could not reach Vault at {self.addr} to write '{self.kv_mount}/{path}': {exc}"
            ) from exc


def fetch_all_secrets(client: VaultClient, base_path: str) -> dict:
    """Read every section named in SECRET_REGISTRY once, return {env_var: value}.

    Returns an empty dict while SECRET_REGISTRY is empty -- no Vault calls
    are made at all in that case.

    A section that hasn't been populated yet reads as empty rather than
    erroring (missing_ok=True) -- not every consumer needs every section
    (e.g. the tunnel keytab is only required when backend.tunnel.enabled is
    true in helm/values.yaml; direct-mode deploys work fine whether or not
    it's ever been populated). A real auth/permission/connection failure
    still raises, from VaultClient.read_section.
    """
    sections = sorted({section for section, _field, _env, _helm in SECRET_REGISTRY})
    section_data = {
        section: client.read_section(base_path, section, missing_ok=True)
        for section in sections
    }

    secrets = {}
    for section, field, env_var, _helm_path in SECRET_REGISTRY:
        secrets[env_var] = section_data[section].get(field, '')
    return secrets


def _shell_quote(value: str) -> str:
    escaped = value.replace('\\', '\\\\').replace('"', '\\"').replace('$', '\\$').replace('`', '\\`')
    return f'"{escaped}"'


def render_env(secrets: dict) -> str:
    lines = [f"{key}={_shell_quote(value)}" for key, value in secrets.items()]
    return '\n'.join(lines) + ('\n' if lines else '')


def render_json(secrets: dict) -> str:
    return json.dumps(secrets, indent=2, sort_keys=True) + '\n'


def render_helm_values(secrets: dict) -> str:
    """Render secrets as a nested YAML fragment matching each entry's full
    dotted helm_path (e.g. 'backend.tunnel.principal' -> {backend: {tunnel:
    {principal: ...}}}), not just its first segment -- registry paths are
    not all two levels deep.
    """
    env_to_helm = {env: helm for _section, _field, env, helm in SECRET_REGISTRY}
    nested: dict = {}
    for env_var, value in secrets.items():
        helm_path = env_to_helm.get(env_var)
        if not helm_path:
            continue
        *parents, leaf = helm_path.split('.')
        node = nested
        for key in parents:
            node = node.setdefault(key, {})
        node[leaf] = value
    return yaml.safe_dump(nested, default_flow_style=False, sort_keys=True)


RENDERERS = {
    'env': render_env,
    'json': render_json,
    'helm-values': render_helm_values,
}


def build_client(config: VaultConfig) -> VaultClient:
    if config.approle:
        token = fetch_approle_token(addr=config.addr, role=config.approle_role)
    else:
        token = resolve_token(explicit=config.token)
    return VaultClient(addr=config.addr, token=token, kv_mount=config.kv_mount)


def main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(
        description='Fetch mu2edaq-pager secrets from Vault and render them for a consumer.'
    )
    parser.add_argument('format', choices=sorted(RENDERERS), help='Output format')
    parser.add_argument(
        '--env', choices=ENVIRONMENTS,
        help=f'Which instance to read (default: {DEFAULT_ENV}, or VAULT_ENV / vault.yaml)',
    )
    parser.add_argument('--addr', help=f'Vault address (default: {DEFAULT_ADDR})')
    parser.add_argument(
        '--base-path',
        help=f"KV base path (default: computed as {BASE_PATH_TEMPLATE.format(env='<env>')})",
    )
    parser.add_argument('--kv-mount', help=f'KV v2 mount point (default: {DEFAULT_KV_MOUNT})')
    parser.add_argument('--token', help='Vault token (overrides VAULT_TOKEN / ~/.vault-token)')
    parser.add_argument(
        '--approle', action='store_true', default=None,
        help='Authenticate with an AppRole application token minted by '
             'get-vault-apptoken.sh instead of the personal ~/.vault-token '
             '(or set MU2EDAQ_PAGER_VAULT_APPROLE=1)',
    )
    parser.add_argument(
        '--approle-role',
        help='AppRole role name to use with --approle (or MU2EDAQ_PAGER_VAULT_ROLE / vault.yaml role)',
    )
    parser.add_argument('--config', help=f'Path to vault.yaml config (default: {DEFAULT_CONFIG_PATH})')
    args = parser.parse_args(argv)

    try:
        config = resolve_config(args)
        if SECRET_REGISTRY:
            client = build_client(config)
            secrets = fetch_all_secrets(client, config.base_path)
        else:
            secrets = {}
    except (VaultAuthError, VaultAccessError, VaultConfigError) as exc:
        print(str(exc), file=sys.stderr)
        return 1

    sys.stdout.write(RENDERERS[args.format](secrets))
    return 0


if __name__ == '__main__':
    sys.exit(main())
