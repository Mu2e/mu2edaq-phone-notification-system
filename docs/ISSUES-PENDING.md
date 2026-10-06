# Staged issues — mu2edaq-phone-notification-system

Found by the September 2026 DAQ mega-review (`mu2e-sept-mega-review`),
2026-09-30 to 2026-10-06. GitHub writes are not permitted in this run
(CONTRACT §9.1), so every finding is staged here in the §6 body format with
its fingerprint, for the orchestrator's filing script.

Target repository: `Mu2e/mu2edaq-phone-notification-system` (public, issues
enabled). Fingerprint = `sha1("Mu2e/mu2edaq-phone-notification-system:<path>:<rule_id>")[:8]`;
the path and `rule_id` are listed per item so the value can be recomputed.

## Dedup

`gh issue list --state all --limit 300` on 2026-10-06 returned 15 issues,
all open (#1–#15), none carrying a `mega-review-fingerprint`. Judgements:

| Staged | Existing | Action |
|---|---|---|
| PNS-023 unauthenticated public web admin | #1 "Require auth for public web admin and event history" | **Comment on #1** — same defect; adds the production-config evidence and an S1 assessment |
| PNS-009 APNs test isolation | #15 "test_dispatch APNs test fails on every clean checkout" | **Comment on #15** — same defect, adds the working-directory dependency |
| PNS-006 token comparison timing | #3 "Fail closed when publisher API tokens are missing" | **Comment on #3** — title shares *publisher*, *API*, *tokens* (§6 rule 2) |
| PNS-018 missing `--config` silently ignored | #4 "Resolve relative config paths from the config file directory" | **Comment on #4** — same family (config path handling), shares *config*, *path* |
| PNS-002 no retry | #5 "Disable devices after permanent APNS token failures" | File; #5 is permanent errors, this is transient ones. Title avoids shared tokens |
| PNS-003 serial dispatch | #8 "Make dispatch rate limiting specific…" | File; different mechanism in the same file |
| PNS-005 ephemeral secrets | #14 "Set secure Flask session cookie attributes…" | Rollup item; only *session* shared |
| all others | — | File |

Already covered by open issues and **not** restaged as new issues:
unauthenticated web admin and anonymous history/SSE reads when OIDC is off
(#1 — commented by PNS-023 with severity S1); fail-open publishing with no
tokens (#3);
relative paths (#4); permanent APNs failures (#5); `last_seen` writes (#6);
APNs payload size (#7); rate-limit key (#8); Keychain (#9); `limit` parameter
(#10); unregister (#11); `meta` size (#12); tunnel bind address (#13); cookie
flags (#14).

**No credential-exposure issue.** `config/apns_key.p8` and `auth.api_tokens`
are gitignored (`.gitignore:10`, `.gitignore:13`) and have never been in this
repository's history. The APNs key tracked in `mu2edaq-config` is handled at
superproject level.

## Filing plan — 13 new issues, 4 comments

| ID | Sev | Action | Fingerprint | Title |
|---|---|---|---|---|
| PNS-023 | S1 | comment #1 | `317a8f36` | — |
| PNS-014 | S2 | file | `ec68136c` | `[helm] OKD proxy disables certificate verification on its hop to the backend` |
| PNS-001 | S3 | file | `3e666032` | `[zmq] dashboard-schema events lose severity, source and category in the ZeroMQ listener` |
| PNS-002 | S3 | file | `82e65376` | `[dispatch] a transient delivery failure is never retried` |
| PNS-003 | S3 | file | `9cfc629e` | `[dispatch] a slow or dead channel delays every later channel and every queued event` |
| PNS-004 | S3 | file | `8b8dfa0b` | `[config] notify-server.yaml ships one site's TLS paths and APNs identity` |
| PNS-007 | S3 | file | `d658cff3` | `[ops] production supervision is an untracked per-user LaunchAgent; no unit ships for any platform` |
| PNS-008 | S3 | file | `71973a9c` | `[ci] no CI for a 185-test suite` |
| PNS-011 | S3 | file | `cd6d3c6b` | `[build] CMake install tree has stale man paths and no package Config file` |
| PNS-013 | S3 | file | `30eb11f3` | `[health] /api/health reports configured rather than effective APNs and ZeroMQ state` |
| PNS-015 | S3 | file | `8c54748b` | `[publisher] publishers trust unauthenticated discovery replies to choose where to send their credential` |
| PNS-016 | S3 | file | `3e3775b0` | `[publisher] server discovery runs once per publisher and is never retried` |
| PNS-017 | S3 | file | `21e06c86` | `[logging] the database password and enrollment JWTs are written to the server log` |
| PNS-029 | S4 | file | `be97ef8c` | `[hygiene] mega-review S4 rollup: secrets, doc dir, SSE gaps, error bodies, license, stale comments` |
| PNS-009 | S3 | comment #15 | `1b32d7de` | — |
| PNS-006 | S4 | comment #3 | `d2710ae7` | — |
| PNS-018 | S3 | comment #4 | `3fb05df9` | — |

---

## PNS-014

**Title:** `[helm] OKD proxy disables certificate verification on its hop to the backend`
Fingerprint inputs: `helm/templates/configmap.yaml` : `tls-verify-disabled`

```markdown
**Severity:** S2 — silent wrong behaviour (unauthenticated TLS on a credential-bearing hop); workaround exists
**Category:** bug
**Location:** `helm/templates/configmap.yaml:20-25`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What
The OKD Caddy pod proxies every request to `backend.url`. For any `https://`
backend the chart unconditionally adds `tls_insecure_skip_verify`, so the pod
accepts any certificate from whatever answers at that address. There is no
value to turn it off.

## Evidence
```
$ sed -n '20,25p' helm/templates/configmap.yaml
        reverse_proxy {{ required "backend.url is required -- set it in my-values.yaml" .Values.backend.url }} {
        {{- if hasPrefix "https://" .Values.backend.url }}
            transport http {
                tls_insecure_skip_verify
            }
        {{- end }}
```
`docs/okd-proxy-setup.md:29-31` calls this "the private hop", by analogy with
the EC2 proxy. The analogy does not hold: on EC2 the backend is
`https://127.0.0.1:18095`, loopback into an SSH tunnel (`config/aws/Caddyfile`);
in OKD direct mode (`backend.tunnel.enabled: false`, the current deployment
per the gitignored `my-values.yaml`) the hop runs from the cluster across the
site network to the server host's port 8095.

Everything the server authenticates crosses that hop: publisher bearer tokens
on `POST /api/events`, device bearer tokens on every phone poll, and
enrollment JWTs on `/api/autoconfig/<token>` and `/devices/qr.png?token=`.

## Why it matters
An on-path attacker between the OKD cluster and the server host can terminate
TLS with any certificate, read and replay those tokens, inject alarms, read
event history, and enroll its own device to receive every page. The comparable
anchor in the CONTRACT rubric — `verify_tls: false` shipped as the default — is
S2; here it is not even a default but hard-wired.

## Suggested fix
The server already presents a publicly trusted certificate
(`config/notify-server.yaml:30-31`, Let's Encrypt for `kaon.andrewnorman.org`).
Drop `tls_insecure_skip_verify` and either set `backend.url` to that hostname,
or keep an address and add `tls_server_name <name>` inside `transport http`.
Gate any remaining skip behind an explicit `backend.insecureSkipVerify: false`
value. Tunnel mode (`backend.tunnel.enabled: true`) is the alternative where
the name is not resolvable from the cluster. The gitignored `my-values.yaml`
currently sets `backend.url` to an IP literal (a DNS workaround noted in
that file), so dropping the skip there needs `tls_server_name` as well.

## Related
- `docs/okd-proxy-setup.md:29-31`, `helm/values.yaml:33-41`

<!-- mega-review-fingerprint: ec68136c -->
```

---

## PNS-001

**Title:** `[zmq] dashboard-schema events lose severity, source and category in the ZeroMQ listener`
Fingerprint inputs: `src/mu2edaq_notify/server/zmq_listener.py` : `zmq-schema-mismatch`

```markdown
**Severity:** S3 — correctness risk on the paging path, no current outage (`zmq.enabled` defaults to false); S2 the moment it is enabled for a dashboard sender
**Category:** bug
**Location:** `src/mu2edaq_notify/server/zmq_listener.py:42-55`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What
The ZeroMQ PULL listener on 8096 is transport-compatible with
`mu2edaq-dashboard` senders (PUSH) but reads only the notify schema. The
dashboard's `error_level`, `subsystem` and `event_category` are never read, so
**every** dashboard message — `error`, `warning`, `normal`, `log` or `debug` —
is ingested as severity `warning`, source `zmq`, category `""`, host = the
notify server's own hostname.

## Evidence
Dashboard wire message, `mu2edaq-dashboard/sender.py:90-97` (identical keys
in `mu2edaq-dashboard/mu2edaq_sender.cpp:66-76`):
```
{"event_category": category, "error_level": level, "subsystem": subsystem,
 "timestamp": ..., "message": text}
```
Notify normalization reads only its own keys (`src/mu2edaq_notify/events.py`):
```
64:    severity = str(payload.get("severity") or default_severity).lower()
74:        "source": str(payload.get("source") or default_source)[:100],
75:        "host": str(payload.get("host") or socket.gethostname())[:100],
77:        "category": str(payload.get("category") or "").strip()[:_MAX_CATEGORY],
```
with `default_severity = zmq.default_severity = "warning"`
(`src/mu2edaq_notify/server/config.py:67`, `config/notify-server.yaml:82`) and
`default_source = "zmq"` (`zmq_listener.py:54-55`). Reproduced through
`ZmqListener._parse` with the venv:
```
error   -> warning zmq '' <server-host> ROC link 3 lost lock
warning -> warning zmq '' <server-host> ROC link 3 lost lock
normal  -> warning zmq '' <server-host> ROC link 3 lost lock
log     -> warning zmq '' <server-host> ROC link 3 lost lock
debug   -> warning zmq '' <server-host> ROC link 3 lost lock
errors-to-phones matches dashboard error: False
```

## Why it matters
- Under the shipped seed rule `errors-to-phones` (`min_severity: error`,
  `config/notify-server.yaml:135-139`), `rule_matches()` rejects every one of
  them at `src/mu2edaq_notify/server/filters.py:17`: a dashboard `error`
  produces **no page at all**, not a downgraded one.
- Under any rule with `min_severity: warning`, every dashboard message pages,
  including `log` and `debug`.
- Category rules cannot match (`""`), all dashboard senders share one
  rate-limit bucket keyed on source `"zmq"` (`dispatch.py:51`), and the event
  is attributed to the notify host.
- The module docstring promises that "applications already publishing on zmq
  need no changes" (`zmq_listener.py:3-6`). That holds for the plain-text
  format the downtime logger consumes, not for the dashboard bus, which is the
  DAQ's main structured ZeroMQ scheme.

S3 rather than S2 only because `zmq.enabled` is false in the defaults
(`config.py:64`) and the shipped config (`config/notify-server.yaml:76`), and
no shipped sender targets 8096. The SUB (`zmq.connect`) mode cannot reach the
dashboard at all (SUB pairs only with PUB).

## Suggested fix
In `ZmqListener._parse`, before `normalize_event`, map dashboard keys when the
notify keys are absent: `error_level`→`severity`, `subsystem`→`source`,
`event_category`→`category`, with a level map for the two dashboard levels
outside `SEVERITIES` (e.g. `normal`→`info`, `log`→`debug`; an operator
decision). Add a test with a `sender.py`-format message. Separately, log at
WARNING when `normalize_event` replaces an unrecognized severity
(`events.py:65-66`): silently rewriting a severity is the general form of this
bug and also turns a publisher's typo (`"fatal"`) into `info`.

## Related
- Cross-package: `mu2edaq-dashboard/docs/INTERFACES.md` (consumer table row for this package)
- `docs/INTERFACES.md` §3.3 in this repository

<!-- mega-review-fingerprint: 3e666032 -->
```

---

## PNS-002

**Title:** `[dispatch] a transient delivery failure is never retried`
Fingerprint inputs: `src/mu2edaq_notify/server/dispatch.py` : `no-delivery-retry`

```markdown
**Severity:** S3 — reliability risk on the paging path, no observed outage
**Category:** bug
**Location:** `src/mu2edaq_notify/server/dispatch.py:87-111`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What
Each delivery is attempted exactly once. An APNs 5xx or 429, a TLS reset, a
10 s timeout, or a Slack/Discord 429 records a `failed` delivery row and the
event is finished. No retry, no backoff, no dead-letter queue.

## Evidence
```
$ grep -rn 'retry\|backoff' src/mu2edaq_notify/server/
$                                   # no matches
```
`destinations.py:94-99` (APNs) and `:106-113` (webhooks) return `"failed"` on
any non-2xx or exception; `dispatch.py:94-111` writes the row and moves on.

## Why it matters
This is the last hop of the alarm chain, and everything upstream is
deliberately fail-soft: the publisher has already returned success to the DAQ
application. The only trace of a transient failure is a `deliveries` row that
nobody is watching, and `/api/health` stays green (PNS-013). Lower than S2
because no missed page has been observed; the risk is per incident.

## Suggested fix
Bounded retry with backoff for retryable outcomes only — connection/timeout
errors, HTTP 429 and 5xx — e.g. three attempts at about 1, 4 and 16 s. Treat
APNs `400 BadDeviceToken` / `410 Unregistered` as terminal (they belong to
#5). Record each attempt (or an `attempts` count) so the audit trail stays
truthful. Do the retries off the dispatcher thread, or PNS-003 gets worse.

## Related
- Mu2e/mu2edaq-phone-notification-system#5 (permanent APNs failures)
- PNS-003 (serial dispatch)

<!-- mega-review-fingerprint: 82e65376 -->
```

---

## PNS-003

**Title:** `[dispatch] a slow or dead channel delays every later channel and every queued event`
Fingerprint inputs: `src/mu2edaq_notify/server/dispatch.py` : `serial-dispatch`

```markdown
**Severity:** S3 — latency and availability risk on the paging path, no current outage
**Category:** bug
**Location:** `src/mu2edaq_notify/server/dispatch.py:75-111`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What
One daemon thread drains an unbounded queue (`dispatch.py:24,27-28`) and, for
each event, calls every matched destination in sequence, and for an APNs
destination every enrolled device in sequence (`dispatch.py:87-111`). Each
call can block for its 10 s timeout (`destinations.py:45,108`).

## Evidence
```
 87        for name in names:
 ...
108        for device in targets:
109            status, detail = self.apns.send(device["apns_token"], event)
```
Worst case per event with APNs + Slack + Discord and N phones is about
`10 × (N + 2)` s (more, since httpx applies the timeout per phase); every
event queued behind it waits that long.

## Why it matters
Alarm bursts are correlated, and a network problem that slows one channel
often slows the others: the serial path is longest exactly when pages matter.
The queue has no bound and no depth metric, so a stall is invisible until
someone notices late pages.

## Suggested fix
Minimal: send the per-device APNs fan-out concurrently (a small
`ThreadPoolExecutor`; httpx's HTTP/2 client multiplexes) and shorten the
timeout to about 5 s. Better: a small worker pool draining the queue. Log at
WARNING when queue depth crosses a threshold and expose it in `/api/health`.

## Related
- PNS-002; Mu2e/mu2edaq-phone-notification-system#8

<!-- mega-review-fingerprint: 9cfc629e -->
```

---

## PNS-004

**Title:** `[config] notify-server.yaml ships one site's TLS paths and APNs identity`
Fingerprint inputs: `config/notify-server.yaml` : `site-specific-config`

```markdown
**Severity:** S3 — correctness and onboarding risk, no current outage
**Category:** bug
**Location:** `config/notify-server.yaml:25-34,63-71`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What
The committed configuration is the production host's working file, not a
template: TLS on with Let's Encrypt paths for one personal host, APNs on with a
specific key identity, `sandbox: true`, and the public URLs pinned. The
production launchd agent runs with exactly this file.

## Evidence
```
$ sed -n '29,32p;66,71p' config/notify-server.yaml
    enabled: true
    cert_file: "data/letsencrypt/live/kaon.andrewnorman.org/fullchain.pem"
    key_file: "data/letsencrypt/live/kaon.andrewnorman.org/privkey.pem"
    adhoc: false
  enabled: true
  key_file: "config/apns_key.p8"   # ES256 auth key from developer.apple.com
  key_id: "GNTLFXC54F"
  team_id: "H7PRZ8RA2Z"
  bundle_id: "gov.fnal.mu2e.Mu2eNotify"
  sandbox: true
```
`data/` and `config/apns_key.p8` are gitignored, so on any other checkout
`./start-mu2edaq-notify-server.sh` exits with
`ValueError: TLS file does not exist` (`src/mu2edaq_notify/server/cli.py:115-117`),
and with `--no-tls` it starts with APNs silently in log-only mode (PNS-013).

## Why it matters
A second host (test stand, AL9 node, disaster recovery) cannot start from the
repository without editing a tracked file, and an edit made for that host is
one `git commit -a` away from changing production. `sandbox: true` only works
with development builds of the app; a TestFlight/App Store build gets
`400 BadDeviceToken` on every push, recorded as `failed`.

## Suggested fix
Ship a neutral `config/notify-server.yaml` (`tls.enabled: false`,
`apns.enabled: false`, empty `key_id`/`team_id`/`base_url`) and move the
production values into `config/notify-server.local.yaml`, which is already
gitignored (`.gitignore:12`) and already suggested by `README.md:37`. Point the
launchd agent at the local file. Log the resolved APNs environment at startup.

<!-- mega-review-fingerprint: 8b8dfa0b -->
```

---

## PNS-007

**Title:** `[ops] production supervision is an untracked per-user LaunchAgent; no unit ships for any platform`
Fingerprint inputs: `start-mu2edaq-notify-server.sh` : `no-tracked-service-unit`

```markdown
**Severity:** S3 — availability risk on the paging system, no current outage
**Category:** enhancement
**Location:** `start-mu2edaq-notify-server.sh:22-24`, `scripts/stop-mu2edaq-notify-chain.sh:18,93`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What
The production server is kept alive by a per-user macOS launchd agent,
`org.mu2edaq.notify-server` (`RunAtLoad`, `KeepAlive`), whose plist lives in
`~/Library/LaunchAgents/` and is not in the repository. The repository's own
start script is `nohup` with a pid file and no restart. There is no systemd
unit for a Linux host.

## Evidence
```
$ git ls-files '*.service' '*.timer' '*.plist'
config/aws/mu2edaq-notify-dns.service      # runs on the EC2 proxy, not the server
config/aws/mu2edaq-notify-dns.timer
$ grep -n LAUNCH_AGENT scripts/stop-mu2edaq-notify-chain.sh | head -2
18:SERVER_LAUNCH_AGENT=${MU2EDAQ_NOTIFY_SERVER_LAUNCH_AGENT:-$HOME/Library/LaunchAgents/org.mu2edaq.notify-server.plist}
93:launchd_bootout_if_loaded "org.mu2edaq.notify-server" "$SERVER_LAUNCH_AGENT"
```
`scripts/start-mu2edaq-notify-chain.sh` step 6 starts the server with
`./start-mu2edaq-notify-server.sh` and never re-bootstraps the agent.

## Why it matters
- A `gui/<uid>` agent runs only while that user is logged in; after an
  unattended reboot the pager is down and the publishers, being fail-soft,
  say nothing beyond a WARNING in their own logs.
- After `stop-mu2edaq-notify-chain.sh` then `start-mu2edaq-notify-chain.sh`
  the server runs unsupervised under `nohup`; the next crash is permanent.
- The agent runs whatever is checked out in that working tree, so the
  production pager's code changes with `git checkout`.
- The supervisor definition cannot be reviewed or reproduced on another host.

## Suggested fix
Track the plist (as `config/launchd/org.mu2edaq.notify-server.plist.in`) and a
systemd unit for Linux (`Restart=always`, `WorkingDirectory`, `ExecStart=venv/bin/mu2edaq-notify-server --config ...`).
For macOS use a LaunchDaemon with `UserName` rather than a LaunchAgent so it
runs without a login. Make `start-mu2edaq-notify-chain.sh` start the server via
the supervisor when one is installed. Run production from a dedicated
deployment checkout, not a development tree. Add an external liveness check on
`/api/health`.

## Related
- PNS-008, PNS-013

<!-- mega-review-fingerprint: d658cff3 -->
```

---

## PNS-008

**Title:** `[ci] no CI for a 185-test suite`
Fingerprint inputs: `.github/workflows` : `no-ci`

```markdown
**Severity:** S3 — maintainability risk, no current outage (CONTRACT anchor: "a package with 180 tests and no CI")
**Category:** enhancement
**Location:** `.github/workflows` (absent)
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What
185 pytest tests, a CppUnit test and an XCTest target, and no automation runs
any of them.

## Evidence
```
$ git ls-files | grep -Ei '^\.github/|gitlab-ci|jenkinsfile'
$
$ venv/bin/python -m pytest -q          # from the repository root
185 passed in 54.38s
$ (cd /tmp && .../venv/bin/python -m pytest -q --rootdir=$REPO $REPO/tests)
1 failed, 184 passed in 51.31s          # see #15
```
`CMakeLists.txt:43-44` turns a missing CppUnit into a STATUS message, so
`ctest` reports "No tests were found" and exits 0.

## Why it matters
#15 is the concrete cost: a test that has only ever passed on the one
workstation holding the APNs key, from the repository root, went unnoticed
until an external compatibility run. The C++ test has never run on AL9.

## Suggested fix
One GitHub Actions workflow on push and pull request: `pytest` on Python 3.9
and a current 3.x from a clean checkout; CMake build plus `ctest` with CppUnit
installed and `CppUnit` made `REQUIRED` when `BUILD_TESTING` is on; `bash -n`
over `scripts/*.sh` and the top-level scripts. Defer the iOS target.

## Related
- Mu2e/mu2edaq-phone-notification-system#15

<!-- mega-review-fingerprint: 71973a9c -->
```

---

## PNS-011

**Title:** `[build] CMake install tree has stale man paths and no package Config file`
Fingerprint inputs: `CMakeLists.txt` : `incomplete-install-tree`

```markdown
**Severity:** S3 — install/integration defect, no current outage (no out-of-tree C++ consumer yet)
**Category:** bug
**Location:** `CMakeLists.txt:50-63`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What
Three defects in the install rules:
1. The man rules name four flat paths, `man/mu2edaq-notify.1` etc. The review
   moved the pages to `man/man1/` and `man/man3/`; the rules carry `OPTIONAL`,
   so `cmake --install` now installs **no** man pages and says nothing. Even
   before the move only 4 of the package's pages (now 20) were listed.
2. `install(EXPORT mu2edaq_notify-targets ...)` installs a targets file but no
   `mu2edaq_notifyConfig.cmake`, so `find_package(mu2edaq_notify)` fails for
   any consumer of the installed library.
3. `install(TARGETS ... publish_example ...)` installs the example program into
   `bin/` under the generic name `publish_example`.

## Evidence
```
$ sed -n '50,63p' CMakeLists.txt
install(TARGETS mu2edaq_notify publish_example
...
install(EXPORT mu2edaq_notify-targets
        NAMESPACE mu2edaq::
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/mu2edaq_notify)
install(FILES man/mu2edaq-notify.1 man/mu2edaq-notify-server.1
        DESTINATION ${CMAKE_INSTALL_MANDIR}/man1 OPTIONAL)
install(FILES man/mu2edaq_notify.3 man/mu2edaq_notify_cpp.3
        DESTINATION ${CMAKE_INSTALL_MANDIR}/man3 OPTIONAL)
$ ls man/mu2edaq-notify.1
ls: man/mu2edaq-notify.1: No such file or directory
```
Also stale after the layout change, in code this review may not edit:
`scripts/vault_client.py:30` names `man/vault-client.1` (now
`man/man1/vault_client.py.1`).

## Why it matters
`man mu2edaq-notify-server` fails on any installed host, silently. The C++
library advertises a CMake namespace (`mu2edaq::notify`) that installed
consumers cannot reach with `find_package`.

## Suggested fix
```
install(DIRECTORY man/ DESTINATION ${CMAKE_INSTALL_MANDIR}
        FILES_MATCHING PATTERN "*.1" PATTERN "*.3")
include(CMakePackageConfigHelpers)
# write mu2edaq_notifyConfig.cmake (find_dependency(CURL) + include targets)
# and a ConfigVersion file; install both next to the targets file
```
Drop `publish_example` from `install(TARGETS)` or rename it
`mu2edaq-notify-publish-example`. Update the docstring at
`scripts/vault_client.py:30`.

<!-- mega-review-fingerprint: cd6d3c6b -->
```

---

## PNS-013

**Title:** `[health] /api/health reports configured rather than effective APNs and ZeroMQ state`
Fingerprint inputs: `src/mu2edaq_notify/server/app.py` : `health-reports-config`

```markdown
**Severity:** S3 — silent degradation is undetectable by the obvious probe; no current outage
**Category:** bug
**Location:** `src/mu2edaq_notify/server/app.py:248-254`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What
`/api/health` returns `apns_enabled` and `zmq_enabled` from the configuration
dict, not from the components. When `ApnsSender` cannot read its key it sets
its own `enabled = False` and records every push as `logged`, while health,
the startup log line and the iOS app all keep saying APNs is enabled. The
same holds for a ZeroMQ thread that exited because pyzmq is missing or no
endpoint is configured.

## Evidence
```
src/mu2edaq_notify/server/app.py:252   apns_enabled=cfg["apns"].get("enabled", False),
src/mu2edaq_notify/server/app.py:253   zmq_enabled=cfg["zmq"].get("enabled", False),
src/mu2edaq_notify/server/destinations.py:48-51
        except OSError as exc:
            log.error("APNs key file unreadable (%s); falling back to "
                      "log-only mode", exc)
            self.enabled = False
src/mu2edaq_notify/server/cli.py:222   "enabled" if cfg["apns"].get("enabled") else "log-only")
```
The iOS app shows the shifter this value as its push status:
`ios/Mu2eNotify/Sources/AppState.swift:163` stores `health.apnsEnabled` and
`:25-26` renders it as `"Enabled"` or `"Log-only"`, so a phone reports
"Enabled" while the server is pushing nothing. The shipped config has
`apns.enabled: true` and the key is gitignored, so any host other than
production starts in exactly this state.

## Why it matters
`/api/health` is what the deploy script, the chain scripts and any external
monitor check. A server that pages nobody passes all of them. The only
signals are one ERROR line at startup and `logged` rows in `deliveries`.

## Suggested fix
Report effective state: `apns_enabled = dispatcher.apns.enabled`, plus
`apns_mode: "sent"|"log-only"`, and a `zmq_listening` flag set by
`ZmqListener._run` once its poller loop is entered. Consider `status: "degraded"`
(still HTTP 200) when configured and effective state differ, and report the
dispatcher queue depth.

<!-- mega-review-fingerprint: 30eb11f3 -->
```

---

## PNS-015

**Title:** `[publisher] publishers trust unauthenticated discovery replies to choose where to send their credential`
Fingerprint inputs: `src/mu2edaq_notify/publisher.py` : `token-to-unauthenticated-discovery`

```markdown
**Severity:** S3 — credential exposure requires an attacker on the DAQ subnet; no current exposure observed
**Category:** bug
**Location:** `src/mu2edaq_notify/publisher.py:66-91,112-121`; `src/cpp/notify.cpp:185-200,253-257`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What
When no URL is configured, both publisher libraries take the **first**
mu2edaq-discovery ANNOUNCE for `app=notify`, build the URL from its `host`,
`port` and `scheme` (or its `meta.fallback_url`), and send
`Authorization: Bearer <publisher token>` there. ANNOUNCE packets are
unauthenticated.

## Evidence
```
publisher.py:83-90   for svc in services or []: ... primary = "%s://%s:%s" % (scheme, host, port)
                     fallback = (svc.get("meta") or {}).get("fallback_url") or None
publisher.py:120-121 if self.token: req.add_header("Authorization", "Bearer " + self.token)
notify.cpp:190-198   first ANNOUNCE with matching qid -> result.primary / result.fallback
```
`mu2edaq-discovery/doc/INTERFACES.md` §6 item 6: "Anything on the subnet can
forge an ANNOUNCE … Do not use discovery output as an authorisation input."
Discovery is the documented default path for publishers
(`GETTING-STARTED.md` §7, `mu2edaq-file-reaper/config/mu2e-file-reaper-dl-01.yaml:68`
sets no `url`).

## Why it matters
Any host on the DAQ subnet that answers first, advertising `scheme: http`,
receives every publisher token in clear text; with a token it can inject
alarms. It can also simply swallow events, so pages stop with no error at the
publisher beyond `rejected`/`unreachable` warnings.

## Suggested fix
Do not send the token to a discovered address unless it matches an allowlist
(`MU2EDAQ_NOTIFY_TRUSTED_HOSTS` or a pinned hostname), and refuse `http` for a
discovered address when a token is set. Document in both man pages that
production publishers should set `MU2EDAQ_NOTIFY_URL` explicitly.

## Related
- PNS-016 (same resolution code)

<!-- mega-review-fingerprint: 8c54748b -->
```

---

## PNS-016

**Title:** `[publisher] server discovery runs once per publisher and is never retried`
Fingerprint inputs: `src/mu2edaq_notify/publisher.py` : `one-shot-discovery`

```markdown
**Severity:** S3 — silent loss of all notifications from a long-running publisher after a startup race; workaround is restart
**Category:** bug
**Location:** `src/mu2edaq_notify/publisher.py:102-105`; `src/cpp/notify.cpp:224-237`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What
The Python publisher runs discovery in its constructor; the C++ publisher on
its first `publish()`. Neither repeats it. A publisher created while the
notify server is down, restarting, or not announcing keeps empty URLs for its
whole life, and every later publish returns false.

## Evidence
```
publisher.py:102-105  if discover and (not self.server_url or not self.fallback_url):
                          d_primary, d_fallback = _discover_server()
publisher.py:158-161  if not urls: log.warning("no notification server configured or discovered; ...")
                              return False
notify.cpp:224-237    if (resolved_) return; ... resolved_ = true;   // set even when nothing answered
```
`mu2edaq-file-reaper` builds its `NotifyPublisher` once at daemon start
(`mu2edaq-file-reaper/src/mu2edaq_file_reaper/notify/channels.py:66-69`) with
no `url` in its production config.

## Why it matters
Restart ordering after a power outage is exactly when both the DAQ daemons and
the notify server come up together. A daemon that wins the race never pages
until it is restarted. The C++ publisher does not even log.

## Suggested fix
Re-run discovery on publish when no URL is known, rate-limited (for example at
most once per 60 s), and also after a primary-and-fallback unreachable result.
Log once in C++ when no server is known.

## Related
- PNS-015

<!-- mega-review-fingerprint: 3e3775b0 -->
```

---

## PNS-017

**Title:** `[logging] the database password and enrollment JWTs are written to the server log`
Fingerprint inputs: `src/mu2edaq_notify/server/cli.py` : `secret-in-log`

```markdown
**Severity:** S3 — credential handling defect; the live deployment uses SQLite and the logged JWTs have expired, so no current exposure
**Category:** bug
**Location:** `src/mu2edaq_notify/server/cli.py:217-222`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What
1. The startup INFO line prints `database.url` verbatim. The documented
   Postgres form carries the password in the URL
   (`config/notify-server.yaml:38`, `postgresql+psycopg2://notify:PASS@dbhost/mu2enotify`).
2. Werkzeug's request log (INFO) prints the request line, which for
   `GET /devices/qr.png?token=<jwt>` and `GET /api/autoconfig/<jwt>` contains a
   live enrollment token. Enrollment tokens are bearer credentials valid for
   `auth.enrollment_ttl_minutes` (30) and reusable: anyone holding one can
   register a device that receives every page (`app.py:302-313`).

## Evidence
```
cli.py:217-221  log.info("mu2edaq-notify-server %s on %s://%s:%s (db=%s, apns=%s)", ...
                         cfg["database"]["url"], ...)
$ grep -c 'GET /devices/qr.png?token=' data/notify-server.launchd.err
9
2026-07-08 22:51:10,134 INFO werkzeug: 127.0.0.1 - - [...] "GET /devices/qr.png?token=<redacted> HTTP/1.1" 200 -
$ ls -l data/notify-server.launchd.err
-rw-r--r--  ...
```

## Why it matters
Logs are world-readable on the host and are routinely pasted into tickets and
chat. A Postgres deployment would leak the database password on every start.
A log reader within 30 minutes of an enrollment can enroll a rogue phone.

## Suggested fix
Log the URL through `sqlalchemy.engine.make_url(url).render_as_string(hide_password=True)`.
Add a `logging.Filter` on the `werkzeug` logger that redacts `token=` query
values and the `/api/autoconfig/` path segment, or move the token to a POST
body. Consider making enrollment tokens single-use (`jti` recorded on
registration).

<!-- mega-review-fingerprint: 21e06c86 -->
```

---

## PNS-029 — S4 rollup

**Title:** `[hygiene] mega-review S4 rollup: secrets, doc dir, SSE gaps, error bodies, license, stale comments`
Fingerprint inputs: `.` : `s4-rollup`

```markdown
**Severity:** S4 — cosmetic, stale or hygiene; each item has no current operational consequence
**Category:** documentation
**Location:** see each item
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What
Thirteen low-severity findings, collected to stay under the review's per-repo
issue cap. Each keeps its own fingerprint, recorded as
`mega-review-item-fingerprint` so the filing script keys this issue on the
rollup fingerprint alone; the inputs (`path` : `rule_id`) are given per item.

### PNS-005 — session and enrollment secrets regenerate on every restart
(`src/mu2edaq_notify/server/config.py` : `ephemeral-secret`)
`src/mu2edaq_notify/server/config.py:182-189` generates `server.secret_key` and
`auth.enrollment_secret` per process when empty and never persists them;
`config/notify-server.yaml:33` says the key is "auto-generated and persisted in
data/". A restart signs out web sessions and invalidates outstanding enrollment
QR codes (enrolled phones are unaffected; their tokens are hashed in the DB).
S4 because OIDC is off in the shipped config, so only in-flight enrollments
are affected. Fix: persist to `data/` with mode 0600, or correct the comment
and log a WARNING. <!-- mega-review-item-fingerprint: ea36d257 -->

### PNS-010 — empty `doc/` alongside the real `docs/`
(`doc` : `empty-doc-dir`)
`doc/` exists on disk, is empty, untracked, and referenced by nothing
(`grep -rn '\bdoc/'` over tracked files finds no hit; no Doxyfile). It costs a
reader one wrong `ls`. Fix: `rmdir doc`. <!-- mega-review-item-fingerprint: 77957a52 -->

### PNS-012 — SSE drops events for a slow client without a gap marker
(`src/mu2edaq_notify/server/sse.py` : `sse-silent-drop`)
`src/mu2edaq_notify/server/sse.py:29-33` discards an event when a client's
200-slot queue is full; events carry no SSE `id:`, so a reconnect cannot
replay. The dashboard (`web/templates/dashboard.html:72`) shows a silent
subset during a burst. The database is the record, so S4. Fix: emit a `gap`
event with a dropped count, or set `id:` and reconcile with
`GET /api/events?since_id=`. <!-- mega-review-item-fingerprint: b707e20d -->

### PNS-019 — `deploy-okd-proxy.sh` exits 0 on an unknown option
(`scripts/deploy-okd-proxy.sh` : `unknown-option-exit-zero`)
`scripts/deploy-okd-proxy.sh:92` prints an error and calls `usage`, which
exits 0 (`:74-77`). A mistyped flag in automation reads as success. Fix:
`usage` takes an exit code; unknown option exits 2.
<!-- mega-review-item-fingerprint: f9584208 -->

### PNS-020 — `/api` error bodies are HTML for 400 and 500
(`src/mu2edaq_notify/server/app.py` : `api-error-html`)
Only 401, 403 and 404 get the JSON handler (`src/mu2edaq_notify/server/app.py:59-65`);
`abort(400)` from `POST /api/events` returns `text/html`. Fix: register the
handler for `HTTPException` under `/api/`.
<!-- mega-review-item-fingerprint: b87ce721 -->

### PNS-021 — the Python publisher raises on an empty event
(`src/mu2edaq_notify/publisher.py` : `publisher-raises`)
`NotifyPublisher.publish("error", "", "")` raises `ValueError` from the
client-side `normalize_event` call (`src/mu2edaq_notify/publisher.py:162`),
outside the delivery `try`. The library's stated contract is "never raises on
delivery failure"; a caller passing an empty title from a variable can still be
taken down. Fix: catch `ValueError`, log, return False.
<!-- mega-review-item-fingerprint: a57a6404 -->

### PNS-022 — rate-limit comment names the wrong key
(`config/notify-server.yaml` : `stale-config-comment`)
`config/notify-server.yaml:103` says "Suppress identical (rule, source, title)
deliveries"; the key is `(source, severity, title)`
(`src/mu2edaq_notify/server/dispatch.py:51`). Fix the comment (scope of the key
itself is #8). <!-- mega-review-item-fingerprint: 1e16da2e -->

### PNS-024 — package metadata and LICENSE disagree
(`pyproject.toml` : `license-mismatch`)
`pyproject.toml:11` declares `license = { text = "BSD-3-Clause" }`; the
`LICENSE` file and GitHub's license detection say MIT. A wheel built from this
tree carries the wrong license metadata. Fix: `license = { text = "MIT" }`
(or the SPDX `license = "MIT"` form with a newer setuptools).
<!-- mega-review-item-fingerprint: 011e32ea -->

### PNS-025 — the header's usage example puts the token in `fallback_url`
(`src/include/mu2edaq_notify/notify.hpp` : `stale-usage-example`)
`notify.hpp:10` shows `Publisher pub({/*server_url=*/"", /*token=*/"tok"});`.
`Options` is an aggregate whose second member is `fallback_url`
(`notify.hpp:32-36`), so that line sets the fallback URL to `"tok"` and sends
no token. Fix the comment to set `o.token = "tok"` by name, as
`src/cpp/examples/publish_example.cpp` does.
<!-- mega-review-item-fingerprint: 77fdaad2 -->

### PNS-026 — "no secrets today" comments are stale
(`scripts/vault_client.py` : `stale-secret-registry-comment`)
`scripts/vault_client.py:18-22` says "SECRET_REGISTRY is empty right now";
it has two entries (`:88-91`, the tunnel principal and keytab).
`config/vault.yaml:6-10` and `docs/okd-proxy-setup.md:185` say the deployment
needs no Vault secrets, which is true only in direct mode. Fix: say that
tunnel mode needs the `tunnel` section. Also `scripts/vault_client.py:30`
names `man/vault-client.1` (now `man/man1/vault_client.py.1`).
<!-- mega-review-item-fingerprint: e0583e43 -->

### PNS-027 — DNS updater units point at a man page that is never installed
(`config/aws/mu2edaq-notify-dns.service` : `doc-ref-not-installed`)
`config/aws/mu2edaq-notify-dns.service:3` and `.timer:3` set
`Documentation=file:///usr/share/man/man1/mu2edaq-notify-dns-update.1.gz`;
neither `scripts/install-notify-dns-updater.sh` nor the user-data it emits
installs that page, so the documentation link names a file that does not
exist on the instance. Fix: install `man/man1/mu2edaq-notify-dns-update.1` in the same heredoc pass,
or drop the `Documentation=` line.
<!-- mega-review-item-fingerprint: cfb3eca4 -->

### PNS-028 — `mu2edaq-config` holds drifted copies of this config
(`config/notify-server.yaml` : `config-copy-drift`)
`mu2edaq-config/config-{main,t00.02.00-rc,t00.03.01}/mu2edaq-phone-notification-system/notify-server.yaml`
predate request-derived URLs: `base_url: "https://notify.andrewnorman.org"`
(`config-main/...:11`) and no `dynamic_base_url`/`trusted_hosts`, against
this repository's `base_url: "https://mu2edaq-pager.fnal.gov"`
(`config/notify-server.yaml:17`). Nothing in this package reads those
copies, and the production agent runs the in-repo file, so which copy is
canonical is undeclared. Fix: name one source of truth and generate or
delete the other. (The APNs key tracked next to those copies is handled at
superproject level, not here.)
<!-- mega-review-item-fingerprint: 1c286a34 -->

### Windows bootstrap
`bootstrap.sh` is bash-only; Windows 11 setup is a one-line comment
(`bootstrap.sh:5`). Documented in `docs/INSTALL.md`; a `bootstrap.ps1` would
close it. (Covered by this rollup's fingerprint.)

## Why it matters
Individually none affects delivery; together they are the residue a reader
trips over.

## Suggested fix
As given per item.

<!-- mega-review-fingerprint: be97ef8c -->
```

---

## PNS-023 — comment on #1

Fingerprint inputs: `src/mu2edaq_notify/server/auth.py` : `unauthenticated-web-admin`

```markdown
**Severity:** S1 — security exposure: an anonymous internet client can silence every page or enroll a device to receive them
**Category:** bug
**Location:** `src/mu2edaq_notify/server/auth.py:92-107`, `src/mu2edaq_notify/server/app.py:228-241`, `config/notify-server.yaml:56`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What
Confirming this issue at the current head, with evidence that the exposure
applies to the configuration production actually runs, and a severity
assessment. `require_login()` is a no-op when `auth.oidc.enabled` is false
(`auth.py:96-98`), and the shipped `config/notify-server.yaml:56` has it false.
The production launchd agent `org.mu2edaq.notify-server` runs
`venv/bin/mu2edaq-notify-server --config config/notify-server.yaml` from the
repository checkout, i.e. exactly that file. Both public proxies forward every
path: `config/aws/Caddyfile:17-28` (`notify.andrewnorman.org`) and
`helm/templates/configmap.yaml:10-27` (`mu2edaq-pager.fnal.gov`, Route on the
`public-proxy` ingress shard, `helm/values.yaml:85`).

## Evidence
Flask test client, shipped `config/notify-server.yaml`, a publisher token set,
temporary SQLite database seeded from the file:
```
oidc False
GET  /api/events            (no header)      200
GET  /api/events            (wrong token)    401
POST /api/events            (no header)      401
POST /devices/enroll        (no session)     200, page contains a live autoconfig link
GET  /destinations          (no session)     200
POST /destinations/1/delete (no session)     302; destinations now []  (was ['all-phones'])
```
The live endpoints were not probed, and the EC2 security group is managed
outside this repository; everything else in the chain is as tracked here.

## Why it matters
Deleting or disabling the `all-phones` destination (or the `errors-to-phones`
filter) silences every page with no error anywhere: the dispatcher simply finds
no destination. Minting an enrollment link and registering a phone delivers
every subsequent DAQ alarm to an outsider. Anyone can inject `test-event`
alarms. This is the paging system for the experiment, reachable from the
internet by design, so S1 rather than S2.

## Suggested fix
As in this issue: refuse to start with OIDC off unless an explicit
`auth.allow_anonymous_web: true` is set, and require a session (or an admin
token) for every mutating web route and for history reads. Until then, either
enable `auth.oidc` in the production config, or have both proxies forward only
`/api/*` (the iOS app uses nothing else, `ios/Mu2eNotify/Sources/ServerClient.swift:69-113`)
and enroll phones on site against port 8095. Add CSRF protection to the forms
when sessions become the gate (#14 covers the cookie flags).

<!-- mega-review-fingerprint: 317a8f36 -->
```

## PNS-009 — comment on #15

Fingerprint inputs: `tests/test_dispatch.py` : `test-isolation`

```markdown
**Severity:** S3 — test-suite correctness; no production impact
**Category:** bug
**Location:** `tests/test_dispatch.py:69-78`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What
Confirming #15 at the current head (still open, no comments, 2026-10-06),
with one addition: the dependency is on
the **working directory** as well as on the gitignored key. The `cfg` fixture
uses built-in defaults (`tests/conftest.py:8-14`), so `apns.key_file` is the
relative path `config/apns_key.p8` (`src/mu2edaq_notify/server/config.py:57`),
resolved against the pytest cwd. The test sets `enabled=True`, constructs
`ApnsSender` (which on `OSError` sets `self.enabled = False`,
`destinations.py:48-51`), patches `_client`, `_key` and `_token`, but never
restores `enabled`, so `send()` returns `"logged"`.

## Evidence
Same checkout, same machine, key present in `config/`:
```
$ venv/bin/python -m pytest -q                       # cwd = repo root
185 passed in 54.38s
$ cd $SCRATCH && $REPO/venv/bin/python -m pytest -q --rootdir=$REPO $REPO/tests
E       AssertionError: assert 'logged' == 'sent'
ERROR    mu2edaq_notify.server.destinations:destinations.py:49 APNs key file unreadable
         ([Errno 2] No such file or directory: 'config/apns_key.p8'); falling back to log-only mode
FAILED .../tests/test_dispatch.py::test_apns_alert_payload_is_plain_visible_notification
1 failed, 184 passed in 51.31s
```
The suite has grown from 89 (the compatibility run) to 185 tests; this is
still the only failure.

## Suggested fix
Write a dummy key to `tmp_path` and set `cfg["apns"]["key_file"]` to it before
constructing the sender (removes both dependencies), or set
`sender.enabled = True` with the other patches.

<!-- mega-review-fingerprint: 1b32d7de -->
```

## PNS-006 — comment on #3

Fingerprint inputs: `src/mu2edaq_notify/server/auth.py` : `non-constant-time-compare`

```markdown
**Severity:** S4 — hardening; timing over the proxy chain is not a practical oracle
**Category:** bug
**Location:** `src/mu2edaq_notify/server/auth.py:34`, `src/mu2edaq_notify/server/app.py:234`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What
Adjacent to this issue: when tokens *are* configured, they are compared with
`token in tokens` (list membership, short-circuiting string equality), not
`hmac.compare_digest`. Device tokens are already safe (SHA-256 lookup,
`storage.py:277-280`).

## Suggested fix
`any(hmac.compare_digest(token, t) for t in tokens)` at both sites, or store
SHA-256 digests of publisher tokens and compare digests, matching device
tokens. S4 rather than S3 because read access is already anonymous when OIDC is
off (#1), and network jitter through two proxies dominates the signal.

<!-- mega-review-fingerprint: d2710ae7 -->
```

## PNS-018 — comment on #4

Fingerprint inputs: `src/mu2edaq_notify/server/config.py` : `missing-config-silent`

```markdown
**Severity:** S3 — fail-open on operator error; workaround is to check the startup WARNING
**Category:** bug
**Location:** `src/mu2edaq_notify/server/config.py:160-165`
**Found by:** mega-review (`mu2e-sept-mega-review`), 2026-10-06

## What
Related to this issue and to #3: a `--config` (or `MU2EDAQ_NOTIFY_CONFIG`) path
that does not exist is ignored without any message, and the server starts on
built-in defaults — no publisher tokens, TLS off, APNs off, no seeded filter
rules — so it accepts anonymous publishes and pages nobody.

## Evidence
```
160    path = config_file or environ.get(ENV_CONFIG)
161    if path and os.path.exists(path):
...
165    cfg["_config_file"] = path or ""
```

## Suggested fix
Raise when an explicitly named config file is missing; keep defaults only when
no path was given at all. Resolving relative paths against the config file
(this issue) and failing closed on no tokens (#3) complete the fix.

<!-- mega-review-fingerprint: 3fb05df9 -->
```
