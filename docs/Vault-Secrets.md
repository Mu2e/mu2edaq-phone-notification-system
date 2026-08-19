# Vault-Managed Secrets

The `mu2edaq-pager` OKD proxy deployment follows the same client-side
Vault pattern already proven on the `mu2e-talks` project: secrets are
fetched by `scripts/vault_client.py` *before* `helm upgrade` runs and
handed to Helm as a generated `--values` file, rather than injected
in-cluster by an operator/webhook.

**Right now `SECRET_REGISTRY` in `scripts/vault_client.py` is empty.**
This deployment is a reverse proxy only (see `docs/okd-proxy-setup.md`)
and doesn't need any secret today — `backend.url`, the Route hostname,
and the cert-manager settings are all plain configuration, not secrets.
This page and the scripts exist so the pipeline is ready the moment a
secret actually is needed (e.g. a shared bearer token at the proxy
layer, or APNs/API-token material if this project ever grows to host
`mu2edaq-notify-server` itself in-cluster).

- **Vault address:** `https://ssivault.fnal.gov:8200`
- **Engine:** KV v2
- **Two separate instances**, each with its own base path, following the
  same convention as `mu2e-talks`:
  - production: `okd/shared/prod/mu2edaq-pager/`
  - test: `okd/shared/test/mu2edaq-pager/`

All fetching (and writing) logic lives in one place,
[`scripts/vault_client.py`](../scripts/vault_client.py) (man page:
`man/vault-client.1`), and is consumed by
[`scripts/deploy-okd-proxy.sh`](../scripts/deploy-okd-proxy.sh) via
`--env {prod,test}` (**required** unless `--skip-vault` is passed).

Authentication is a separate axis from environment selection: by
default it uses **your personal** `~/.vault-token`, but it can instead
authenticate **as the application** with an AppRole token — see
[Application (AppRole) authentication](#application-approle-authentication).

`my-values.yaml` is still fully supported and is where all of this
deployment's real configuration lives today — Vault only adds secret
values on top of it, and with an empty registry it contributes nothing
at all, so nothing breaks if Vault is unreachable or you haven't logged
in.

## Adding the first secret

When a secret is actually needed:

1. Add a tuple to `SECRET_REGISTRY` in `scripts/vault_client.py`:
   ```python
   SECRET_REGISTRY = [
       ('proxy', 'shared_token', 'PROXY_SHARED_TOKEN', 'proxy.sharedToken'),
   ]
   ```
   `(vault section, field, env var, dotted helm/values.yaml path)` — the
   env var name only matters for the `env` output format; the OKD path
   uses the `helm-values` format and the dotted path directly.
2. Add the corresponding key to `helm/values.yaml` (e.g. `proxy.sharedToken:
   ""`) and wire it into whichever template needs it (a `Secret` resource,
   or an `envFrom`/`env` entry on the Deployment).
3. Write the value into Vault:
   ```bash
   vault kv put -mount=okd shared/<env>/mu2edaq-pager/proxy \
     shared_token="<value>"
   ```
   (or the interactive `vault_populate.py` pattern from `mu2e-talks`, if
   more than one or two secrets end up needed here).
4. `scripts/deploy-okd-proxy.sh --env <prod|test>` picks it up
   automatically from then on.

## One-time setup (per developer)

1. Install the `vault` CLI (used only for interactive login — the app
   itself uses the lightweight `hvac` Python library; see
   `requirements-deploy.txt`).
2. Authenticate with your Fermilab Services (LDAP) credentials:

   ```bash
   vault login -method=ldap -address=https://ssivault.fnal.gov:8200
   ```

   On success this caches a token at `~/.vault-token`.
   `scripts/vault_client.py` reads that cached token — it never
   re-implements the login flow itself. Re-run this command whenever
   your token expires.

## Application (AppRole) authentication

Everything above authenticates as **you**, via the LDAP login cached in
`~/.vault-token`. That's fine interactively but wrong for CI and
unattended deploys, where the credential should belong to the
application rather than to a person.

`scripts/get-vault-apptoken.sh` (man page: `man/get-vault-apptoken.1`)
provides the alternative, ported from `mu2e-talks`' script of the same
name with `mu2edaq-pager` defaults and a `MU2EDAQ_PAGER_VAULT_*`
environment prefix. It:

1. Uses your personal login **only if needed** — to read the AppRole
   `role-id` and mint a `secret-id`.
2. Exchanges those for a short-lived application token.
3. Prints that token (or writes it to a `0600` file) for the deploy to
   consume.

**This is opt-in. Nothing changes unless you ask for it:**

```bash
./scripts/deploy-okd-proxy.sh --env test --vault-approle   # OKD deploy
python3 scripts/vault_client.py env --approle              # direct
```

Add `--vault-role NAME` (or `MU2EDAQ_PAGER_VAULT_ROLE`, or `vault.role`
in `config/vault.yaml`) to select a role other than the default
`mu2edaq-pager-app`.

### ⚠️ The AppRole does not exist yet

**No role has been requested from Vault admins yet** — `--approle` /
`--vault-approle` will fail with an actionable error until one is
created. When it is, the role needs a policy granting:

```hcl
path "okd/data/shared/prod/mu2edaq-pager/*" { capabilities = ["read"] }
path "okd/data/shared/test/mu2edaq-pager/*" { capabilities = ["read"] }
```

Note the `/data/` segment — KV v2 puts secret reads under it, so a
policy written against `okd/shared/...` will not match. There's no
urgency to request this until `SECRET_REGISTRY` actually has entries —
the personal-login path (the default) works fine for manual deploys in
the meantime.

## Configuration precedence

Like the rest of this project, Vault connection settings follow
CLI flag > environment variable > config file > hardcoded default:

| Setting | CLI flag | Env var | Config file key |
|---|---|---|---|
| Address | `--addr` | `VAULT_ADDR` | `vault.addr` |
| Environment (prod/test) | `--env` | `VAULT_ENV` | `vault.env` |
| Base path | `--base-path` | `VAULT_BASE_PATH` | `vault.base_path` |
| KV mount | `--kv-mount` | `VAULT_KV_MOUNT` | `vault.kv_mount` |
| Token | `--token` | `VAULT_TOKEN` | *(never in a file)* |
| AppRole auth | `--approle` | `MU2EDAQ_PAGER_VAULT_APPROLE` | `vault.approle` |
| AppRole role | `--approle-role` | `MU2EDAQ_PAGER_VAULT_ROLE` | `vault.role` |

Base path is normally *computed* from the resolved environment as
`shared/<env>/mu2edaq-pager` — you don't need to set it explicitly.
Setting `--base-path` / `VAULT_BASE_PATH` / `vault.base_path`
explicitly bypasses that computation entirely.

Defaults live in [`config/vault.yaml`](../config/vault.yaml), which is
committed to git and contains no secrets.

## Usage

```bash
# Print KEY="value" lines
python3 scripts/vault_client.py env --env test

# Print a Helm values.yaml fragment matching helm/values.yaml
# (used by scripts/deploy-okd-proxy.sh)
python3 scripts/vault_client.py helm-values --env prod

# Print a flat JSON object (for ad hoc use / debugging)
python3 scripts/vault_client.py json --env test
```

With an empty `SECRET_REGISTRY`, all three commands succeed
immediately with empty output and never contact Vault at all.

## Troubleshooting

| Message | Meaning | Fix |
|---|---|---|
| `No Vault token found...` | Not logged in, or `~/.vault-token` expired | `vault login -method=ldap -address=https://ssivault.fnal.gov:8200` |
| `Invalid Vault environment '...'...` | `--env`/`VAULT_ENV`/`vault.yaml`'s `env` key isn't `prod` or `test` | Fix the value at whichever source set it |
| `Permission denied reading '<mount>/<path>'...` | Token lacks read access to that path | Ask a Vault admin to grant your identity/group a read policy on `okd/shared/<env>/mu2edaq-pager/*` |
| `No secret found at '<mount>/<path>'...` | Wrong mount name, wrong environment/base path, or that section was never populated | Confirm `vault.kv_mount` in `config/vault.yaml`, that you're using the right `--env`, and that the section has actually been written |
| `Could not reach Vault at ...` | Network/DNS/TLS issue, or off the Fermilab network/VPN | Check connectivity to `ssivault.fnal.gov:8200` |
| `The AppRole '<name>' does not exist at auth/td-approles` | The role hasn't been created yet (expected today — see above) | Ask a Vault admin to create it once a secret is actually needed |
