---
title: mu2edaq-phone-notification-system — operations
group: monitoring
tier: A
audience: expert
summary: >
  Terminal alarm destination for the Mu2e DAQ: a Flask server on 8095 that ingests
  events over an HTTP JSON API or a ZeroMQ compatibility listener, routes them with
  database-held filter rules, and delivers them to iPhones (APNs), Slack, Discord and
  a live SSE web dashboard
---

# Operations

This page covers the server process and indexes the edge runbooks, which stay
authoritative for their parts: `reverse-proxy-setup.md` and
`reverse-proxy-operations.md` (EC2 Caddy, reverse SSH tunnel, Route 53),
`okd-proxy-setup.md` and `okd-proxy-operations.md` (OKD Helm chart),
`Vault-Secrets.md`, and `application-chain.md`. Build and install:
[INSTALL.md](INSTALL.md).

## 1. How the server is run today

As found on 2026-10-06 the production server runs on a macOS workstation
under a **per-user launchd agent**:

| Key | Value |
|---|---|
| Label | `org.mu2edaq.notify-server` |
| Plist | `~/Library/LaunchAgents/org.mu2edaq.notify-server.plist` — **not in this repository** |
| Program | `venv/bin/mu2edaq-notify-server --config config/notify-server.yaml`; `WorkingDirectory` = this repository's checkout inside the `mu2edaq-main` superproject (absolute paths in the plist) |
| Supervision | `RunAtLoad`, `KeepAlive` |
| Logs | `data/notify-server.launchd.log`, `data/notify-server.launchd.err` |

```bash
launchctl print     gui/$(id -u)/org.mu2edaq.notify-server
launchctl kickstart -k gui/$(id -u)/org.mu2edaq.notify-server     # restart
```

Consequences an operator must know (PNS-007):

* A `gui/<uid>` agent exists only while that user has a login session. After a
  reboot with no login the pager is down.
* The agent runs whatever is checked out in that working tree. A `git
  checkout` there changes the code and configuration the pager runs at its
  next restart.
* `scripts/stop-mu2edaq-notify-chain.sh` boots the agent out and stops the
  server (step 1). `scripts/start-mu2edaq-notify-chain.sh` then starts the
  server with `start-mu2edaq-notify-server.sh` (nohup) and does **not**
  re-load the agent, so after a chain stop/start cycle the server is
  unsupervised until someone runs `launchctl bootstrap`.
* There is no systemd unit for a Linux host. The only units in the repository
  (`config/aws/`) run on the EC2 proxy.

Manual run, for development or a host without the agent:

```bash
./bootstrap.sh                       # venv/, deps, editable install, ../mu2edaq-discovery if present
./start-mu2edaq-notify-server.sh     # nohup; data/notify-server.pid, data/notify-server.log
./stop-mu2edaq-notify-server.sh      # SIGTERM, 5 s, SIGKILL
venv/bin/mu2edaq-notify-server --config config/notify-server.yaml --no-tls   # foreground
```

The start script passes extra arguments through and takes the config from
`${MU2EDAQ_NOTIFY_CONFIG:-config/notify-server.yaml}`. Without `--config` or
`MU2EDAQ_NOTIFY_CONFIG` the server binary runs on built-in defaults, and a
mistyped `--config` path is ignored without a message — in both cases with no
publisher tokens (comment staged on #4).

## 2. Startup behaviour

* Schema: `Storage.__init__` runs `create_all()` and `_ensure_columns()`
  (`storage.py:193-194`), a hand-maintained `ALTER TABLE ADD COLUMN` list
  (`storage.py:161-164`). A new model column needs an entry there or existing
  databases fail at query time.
* Seeding: `seed.destinations` and `seed.filters` are loaded **only into empty
  tables** (`storage.py:394-414`). After first start, edit routing in the web
  UI; editing the YAML has no effect.
* TLS: with `server.tls.enabled: true` and `cert_file`/`key_file` unset or
  missing the server exits before binding (`cli.py:103-118`). The shipped
  config points at `data/letsencrypt/live/kaon.andrewnorman.org/`, which
  exists only on the production host (PNS-004).
* APNs: an unreadable `apns.key_file` logs one ERROR and switches the sender
  to log-only for the life of the process (`destinations.py:40-51`).
  `/api/health` still reports `apns_enabled: true` (PNS-013).
* Tokens: with no publisher token the server logs
  `no auth.api_tokens configured -- the event API is open` and starts.
* Secrets: an empty `server.secret_key` or `auth.enrollment_secret` is
  generated per process (`config.py:182-189`). A restart signs out web
  sessions and invalidates outstanding enrollment QR codes; enrolled phones
  are unaffected (their tokens are hashed in the database). Set both
  explicitly to avoid this (PNS-005).
* The startup line logs `database.url` verbatim, including any Postgres
  password (`cli.py:217-222`, PNS-017).

## 3. Verifying delivery end to end

```bash
NOTIFY=https://<cert-name>:8095   # a name the server certificate covers; the shipped
                                  # cert path is for kaon.andrewnorman.org
curl -sk https://localhost:8095/api/health | python3 -m json.tool
venv/bin/mu2edaq-notify --server "$NOTIFY" --no-discover --token "$TOKEN" \
    send --severity error --source ops-check "Pager check" "Ignore - verification"
curl -sk 'https://localhost:8095/api/events?limit=1' | python3 -m json.tool   # note the id
curl -sk https://localhost:8095/api/events/<id> | python3 -m json.tool       # deliveries[]
```

`mu2edaq-notify` verifies the server certificate and has no option to skip
that, so `--server https://localhost:8095` fails against the production
certificate and the command reports the event as not accepted. The `curl -k`
reads work without a token only because OIDC is off (#1).

`/api/health` proves only that the HTTP server answers. The proof of a page is
the event's `deliveries[]`:

| status | meaning |
|---|---|
| `sent` | APNs returned 200 (detail = `apns-id`), or the webhook returned 2xx |
| `logged` | APNs in log-only mode (key unreadable or `apns.enabled: false`), or no enrolled device with an APNs token |
| `failed` | one attempt failed; it will not be retried (detail holds the HTTP status or exception) |
| `suppressed` | the 60 s `(source, severity, title)` rate limit fired |

No row at all means no filter rule matched. With the shipped seed rule
(`errors-to-phones`, `min_severity: error`) a `warning` never pages.

## 4. Log lines worth alerting on

| Line | Source | Meaning |
|---|---|---|
| `APNs key file unreadable (...); falling back to log-only mode` | `destinations.py:49` | No phone will be paged until restart with a readable key |
| `no auth.api_tokens configured -- the event API is open` | `cli.py:213` | Anonymous publishing accepted |
| `dispatch failed for event <id>` | `dispatch.py:72` | An exception escaped delivery; that event's remaining destinations were skipped |
| `bad zmq message dropped` | `zmq_listener.py:89` | Unparseable or unstorable ZeroMQ message |
| `pyzmq not installed; zmq listener disabled` | `zmq_listener.py:61` | `zmq.enabled: true` without pyzmq (it is in `requirements.txt`, so only after a bare `pip install .`) |
| `request host ... is not in server.trusted_hosts` | `app.py:182,188` | Enrollment URL fell back to `base_url`, or used an untrusted host; warned once per host |

## 5. APNs key provisioning and rotation

1. developer.apple.com → Certificates, Identifiers & Profiles → Keys: create a
   key with APNs enabled; download the `.p8` (Apple issues it once).
2. `install -m 600 ~/Downloads/AuthKey_XXXXXXXXXX.p8 config/apns_key.p8`
   (gitignored, `.gitignore:10`; never committed here).
3. Set `apns.key_id`, `apns.team_id`, `apns.bundle_id`
   (`gov.fnal.mu2e.Mu2eNotify`).
4. Match `apns.sandbox` to the app build: `true` targets
   `api.sandbox.push.apple.com` and works only with a development build
   (`aps-environment: development`, `ios/Mu2eNotify/Sources/Mu2eNotify.entitlements`);
   TestFlight and App Store builds need `false`. A mismatch returns
   `400 BadDeviceToken`, recorded as `failed`.
5. `apns.enabled: true`, restart, and confirm with a test event that the
   delivery row says `sent`, not `logged`. Do not rely on `/api/health`.

The provider JWT is re-minted every 30 min (`destinations.py:57`). To rotate:
install the new key, update `key_id`, restart, re-test.

## 6. Vault (deploy time only)

The running server reads no secret from Vault; Vault being down cannot stop a
page. Vault supplies only the OKD chart's optional SSH-tunnel keytab
(`SECRET_REGISTRY`, `scripts/vault_client.py:88-91`: `tunnel/principal`,
`tunnel/keytab_b64`).

```bash
vault login -method=ldap -address=https://ssivault.fnal.gov:8200
python3 scripts/vault_client.py env  --env test
python3 scripts/vault_client.py helm-values --env prod --approle
```

* Path: KV v2 mount `okd`, `shared/<prod|test>/mu2edaq-pager/<section>`;
  defaults in `config/vault.yaml`, which holds no secret. Precedence CLI > env
  (`VAULT_ADDR`, `VAULT_ENV`, `VAULT_KV_MOUNT`, `VAULT_BASE_PATH`,
  `VAULT_TOKEN`) > `config/vault.yaml` > defaults (`vault_client.py:143`).
  Token from `--token`, `VAULT_TOKEN` or `~/.vault-token`
  (`vault_client.py:191`).
* `--approle` mints a short-lived application token via
  `scripts/get-vault-apptoken.sh`; the role `mu2edaq-pager-app` on
  `auth/td-approles` does not exist yet (`config/vault.yaml:30-34`).
* **Fail closed.** Any auth, permission, connection, DNS or TLS failure exits 1
  with a one-line message (`vault_client.py:444`), and
  `deploy-okd-proxy.sh:199-203` aborts the deploy. A *missing section* reads as
  empty (`vault_client.py:349`); the chart then refuses to render if the tunnel
  is enabled without its keytab (`helm/templates/tunnel-secret.yaml:15-17`).
* The rendered values file is `mktemp` + `chmod 600` and removed with
  `shred -u` by an EXIT trap (`deploy-okd-proxy.sh:125-137`); an AppRole token
  is revoked on exit. Secrets do not reach the script's output. They do end up
  in the Helm release Secret in the namespace, as with any Helm value.

## 7. Public edge

### 7.1 EC2 proxy (`notify.andrewnorman.org`)

Caddy on an EC2 instance with no Elastic IP terminates TLS and proxies every
path to `https://127.0.0.1:18095`, the remote end of an `ssh -R` tunnel from
the server host (`config/aws/Caddyfile`). The skipped certificate check on that
hop is acceptable: it is loopback into SSH. The instance republishes its own A
record at boot:

| File | Installed as | Role |
|---|---|---|
| `scripts/aws-notify-dns-update.sh` | `/usr/local/sbin/mu2edaq-notify-dns-update` | IMDSv2 `public-ipv4` → Route 53 UPSERT, waits for INSYNC |
| `config/aws/mu2edaq-notify-dns.service` | `/etc/systemd/system/` | oneshot, `Before=caddy.service`, `Restart=on-failure`, `StartLimitBurst=5` per 300 s |
| `config/aws/mu2edaq-notify-dns.timer` | `/etc/systemd/system/` | `OnBootSec=3min`, `OnUnitActiveSec=5min` drift check |
| `config/aws/caddy.service.d/10-wait-for-dns.conf` | drop-in | orders Caddy after the DNS update |
| `config/aws/Caddyfile` | `/etc/caddy/Caddyfile` | ACME pinned to Let's Encrypt, matching the CAA record |

```bash
scripts/start-mu2edaq-notify-chain.sh     # instance, DNS, Caddy, tunnel, server, 8 checks
scripts/status-mu2edaq-notify-proxy.sh    # one line per link
scripts/stop-mu2edaq-notify-chain.sh      # stops the SERVER too, retracts DNS, stops EC2
scripts/restore-mu2edaq-notify-tunnel.sh --watch --interval 60   # tunnel repair loop
scripts/update-notify-dns.sh --check      # monitoring probe for the A record
scripts/install-notify-dns-updater.sh     # (re)install the updater over SSH
```

`stop-mu2edaq-notify-chain.sh` is not "take the public edge down": it stops the
notification server, so on-network publishers and the OKD path stop delivering
too. To drop only the EC2 edge, stop the instance, or run
`stop-mu2edaq-notify-proxy.sh` after booting out the
`org.mu2edaq.notify-proxy-tunnel` agent: the script stops only a tunnel with a
pid file and leaves an agent-run tunnel up.

### 7.2 OKD proxy (`mu2edaq-pager.fnal.gov`)

`helm/` deploys a Caddy reverse proxy only; the server stays on its host
(`helm/values.yaml:1-8`).

```bash
./scripts/deploy-okd-proxy.sh --env prod          # Vault + two-pass Helm + build + rollout + health
oc get pods,svc,route,certificate -n mu2edaq-pager
```

* `backend.url` (required unless `backend.tunnel.enabled`) is set in the
  gitignored `my-values.yaml` (`.gitignore:17`). For any `https://` backend the
  chart sets `tls_insecure_skip_verify` unconditionally
  (`helm/templates/configmap.yaml:21-25`). The current deployment uses direct
  mode, so publisher tokens, device tokens and enrollment JWTs cross the
  network from the cluster to the server host on an unverified TLS connection
  (PNS-014, S2). Point `backend.url` at a name the server's certificate covers
  and drop the skip, or use tunnel mode.
* Tunnel mode runs an `ssh -L` sidecar with a Vault-sourced Kerberos keytab
  (`helm/templates/tunnel-secret.yaml`); Caddy then proxies to
  `127.0.0.1:18095`.
* `templates/build.yaml` builds Caddy in-cluster from `caddy:2-alpine` with the
  `cap_net_bind_service` file capability removed (OKD `restricted-v2` refuses
  to exec binaries with file capabilities).

## 8. Retention

`database.retention_days` (default 30; 0 keeps everything) drives the
`notify-retention` thread: every hour it deletes events with `received_at`
older than the cutoff, and their deliveries (`storage.py:252-265`,
`cli.py:165-182`).

## 9. Known operational gaps

Full bodies in [ISSUES-PENDING.md](ISSUES-PENDING.md).

* The web UI and event history are open to anyone who can reach the server
  whenever OIDC is off, which is the shipped setting and the one production
  runs; an anonymous request can delete the destination every page goes
  through (#1, assessed S1 in PNS-023). Until it is fixed, enable
  `auth.oidc`, or forward only `/api/*` at both proxies: the iOS app calls
  nothing else (`ios/Mu2eNotify/Sources/ServerClient.swift:69-113`), and
  enrollment pages can be used on site against port 8095. That closes the
  mutating web routes; anonymous history reads under `/api/` stay open.
* One delivery attempt, no retry (PNS-002); serial delivery with an unbounded
  queue (PNS-003).
* `/api/health` cannot detect log-only APNs (PNS-013).
* Supervision depends on an untracked user LaunchAgent (PNS-007).
* OKD backend hop is unverified TLS (PNS-014).
* No CI; run `venv/bin/pytest` by hand (PNS-008). Run it from the repository
  root: `tests/test_dispatch.py::test_apns_alert_payload_is_plain_visible_notification`
  fails from any other directory, and on any checkout without
  `config/apns_key.p8` (#15).
