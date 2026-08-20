# Mu2e Notify OKD Reverse Proxy Setup

This document records the onsite-OKD reverse-proxy setup used to expose
the local Mu2e notification server to iPhones at:

```text
https://mu2edaq-pager.fnal.gov
```

This plays the same role the AWS EC2 + Caddy + Route 53 chain plays
today (see `docs/reverse-proxy-setup.md`), but hosted on the onsite OKD
cluster instead, reusing DNS that's already provisioned and the
cluster's cert-manager `ClusterIssuer` instead of Let's Encrypt-via-Caddy.
Unlike the AWS path, **no SSH reverse tunnel is needed**: OKD is on the
FNAL network and can reach the local Mu2e host directly.

This is a **reverse proxy only**. `mu2edaq-notify-server`, its SQLite
database, and APNs delivery all keep running exactly as they do today
on the local Mu2e host — nothing about the application itself changes.

## Architecture

```text
iPhone / browser
  -> https://mu2edaq-pager.fnal.gov
  -> FNAL DNS (already provisioned)
  -> OKD Route (edge TLS termination, cert-manager Certificate
     via ClusterIssuer incommon-acme, "public-proxy" router shard)
  -> Service (ClusterIP) -> caddy:2-alpine pod (Deployment)
  -> reverse_proxy to backend.url (the local Mu2e host's existing
     HTTPS listener, tls_insecure_skip_verify for that private hop --
     same pattern the AWS Caddyfile already uses)
  -> mu2edaq-notify-server (unchanged)
```

The local server is not modified: `server.base_url` /
`discovery.fallback_url` in `config/notify-server.yaml` still point at
the AWS hostname unless and until you deliberately cut over (see
"Cutover" in `docs/okd-proxy-operations.md`). Both proxy paths can run
side by side during evaluation.

## OKD resources

| Resource | Value |
| --- | --- |
| OKD namespace / project | `mu2edaq-pager` |
| Helm release | `mu2edaq-pager` |
| Public hostname | `mu2edaq-pager.fnal.gov` |
| cert-manager `ClusterIssuer` | `incommon-acme` |
| TLS secret name | `mu2edaq-pager-tls` |
| Route ingress shard label | `ingresscontroller: public-proxy` |
| Container image | Built in-cluster from `docker.io/library/caddy:2-alpine` via `BuildConfig`/`ImageStream` -- no external registry |

Do not expose the local server's port (8095) publicly. The public side
should only ever be the OKD Route's 80/443, exactly as the AWS setup
restricts itself to Caddy's 80/443 on EC2.

## Helm chart

The chart lives at `helm/` in this repo (chart name `mu2edaq-pager`).
It renders:

- an `ImageStream` + `BuildConfig` that builds a derived Caddy image
  in-cluster: `FROM docker.io/library/caddy:2-alpine` with `setcap -r
  /usr/bin/caddy`. The stock image sets a `cap_net_bind_service` file
  capability on that binary (so it can bind :80/:443 as non-root), and
  OKD's `restricted-v2` SCC (`allowPrivilegeEscalation: false`, i.e.
  `no_new_privs`) refuses to `exec` *any* binary carrying a file
  capability -- regardless of whether it's actually needed, and it
  isn't here, since Caddy only binds :8080. The Deployment's container
  image is patched automatically once the build completes, via an
  `image.openshift.io/triggers` annotation -- no registry push, no
  polling.
- a `ConfigMap` holding a generated Caddyfile (`reverse_proxy
  {{ .Values.backend.url }}`)
- a `Deployment` running that built image, mounting the ConfigMap,
  with `readinessProbe`/`livenessProbe` hitting `/api/health` on port
  8080 (this exercises Caddy *and* the backend in one probe)
- a `Service` (ClusterIP, port 8080)
- a `Route` (edge TLS termination, `insecureEdgeTerminationPolicy:
  Redirect`), only rendered when `route.hostname` is set
- a cert-manager `Certificate`, only rendered when `route.hostname` and
  `certManager.enabled` are both set
- RBAC (`Role`/`RoleBinding`) granting the OKD router's ServiceAccount
  read access to the TLS secret, only rendered when
  `certManager.externalCertificate` is true

### Values reference

See `helm/values.yaml` for full comments. The values that matter for a
real deployment all live in the gitignored `my-values.yaml` at the repo
root:

```yaml
route:
  hostname: mu2edaq-pager.fnal.gov

certManager:
  enabled: true
  clusterIssuer: incommon-acme
  secretName: mu2edaq-pager-tls
  externalCertificate: false   # flip to true after the cert is issued

backend:
  url: "https://<local-host>:8095"   # REQUIRED -- must be reachable from OKD
```

`backend.url` is deliberately not hardcoded anywhere in the chart --
it's the one piece of real deployment-specific configuration this setup
needs, and it belongs in `my-values.yaml`, not committed to git.

## SSH tunnel (selectable alternative to a direct connection)

**Live and verified working as of 2026-08-20** against
`mu2egateway01.fnal.gov` -- real Kerberos auth, tunnel established, and
`/api/health` confirmed responding end to end through it. See
`docs/okd-proxy-operations.md`'s SSH tunnel section for the concrete
issues that came up standing this up (Alpine's GSSAPI-SSH package
split, a `$PATH` gotcha under a `command:` override, `BuildConfig`
`ConfigChange` triggers not re-firing on Dockerfile edits, and the
GSSAPI handshake's realistic timing) -- all fixed in the chart, not
just worked around by hand.

Some backend hosts have their application port firewalled off from the
OKD cluster network even though direct connectivity generally works
(confirmed for `kaon.andrewnorman.org`, but not for every host --
`mu2egateway01.fnal.gov:8095` times out from OKD as of 2026-08-19). If
the target's SSH port (22) *is* reachable even though its app port
isn't -- a common asymmetry, since admin SSH access is often allowed
from a broader set of sources than one specific application port --
`backend.tunnel` routes around it without needing anything new opened
on the OKD side:

```text
Caddy (127.0.0.1:<localPort>)
  -> ssh-tunnel sidecar, same pod
  -> SSH (GSSAPI/Kerberos auth) to backend.tunnel.sshHost:22
  -> -L forwards to backend.tunnel.remoteTarget, as seen from sshHost
```

Both containers share one pod (and therefore one network namespace),
so `127.0.0.1` between them just works -- no extra Service needed. The
sidecar authenticates from a keytab (`kinit`), holds the tunnel open
with `ssh -N -L`, and reconnects (re-`kinit`ing first) if it drops; its
own `livenessProbe` (a TCP check on `localPort`) restarts it if the
retry loop doesn't recover fast enough on its own.

Enable it in `my-values.yaml`:

```yaml
backend:
  # url: still here, but ignored while tunnel.enabled is true
  tunnel:
    enabled: true
    sshHost: mu2egateway01.fnal.gov
    sshUser: <principal's short username on that host>
    remoteTarget: "127.0.0.1:8095"   # as seen from sshHost, not from OKD
    scheme: http   # or https -- whatever remoteTarget itself actually speaks,
                    # not necessarily what backend.url uses elsewhere. Getting
                    # this wrong fails fast and clearly (Caddy won't start, or
                    # 502s with a TLS-handshake error) -- see the
                    # scheme-mismatch rows in docs/okd-proxy-operations.md.
```

The keytab and principal (`backend.tunnel.principal` /
`backend.tunnel.keytabB64`) come from Vault, never from a committed
file -- see [`docs/Vault-Secrets.md`'s SSH tunnel keytab
section](Vault-Secrets.md#ssh-tunnel-keytab) for how to obtain and
populate one. Switching back to direct mode later is just
`backend.tunnel.enabled: false` and a redeploy -- both modes are fully
supported side by side in the chart, so it's a one-line flip once a
firewall exception makes direct connectivity possible instead.

## Deploying

```bash
./scripts/deploy-okd-proxy.sh --env prod
```

This runs the two-pass cert-manager dance automatically (see
`docs/okd-proxy-operations.md` for what that means and how to
troubleshoot it), then verifies `https://mu2edaq-pager.fnal.gov/api/health`.
See `man/deploy-okd-proxy.1` for the full flag reference, including
`--no-cert` (skip cert-manager, use the router's wildcard cert) and
`--skip-vault` (this deployment needs no Vault secrets today -- see
`docs/Vault-Secrets.md`).

Equivalently, without the wrapper script:

```bash
helm upgrade --install mu2edaq-pager ./helm \
  -n mu2edaq-pager --create-namespace \
  -f my-values.yaml
```

## Verify

```bash
oc get pods,svc,route,certificate -n mu2edaq-pager
curl --head --location https://mu2edaq-pager.fnal.gov/api/health
```

Both should show a healthy pod and a `200` response with the same JSON
shape as the local server's own health check
(`curl -k https://127.0.0.1:8095/api/health`).

Reverse-proxy and phone access docs:

- `docs/okd-proxy-operations.md` -- runbook, cert-manager
  troubleshooting, and the cutover checklist.
- `docs/reverse-proxy-setup.md` / `docs/reverse-proxy-operations.md` --
  the AWS EC2/Caddy/Route53 path this complements.
- `docs/Vault-Secrets.md` -- the (currently unused) Vault secrets
  pipeline.
