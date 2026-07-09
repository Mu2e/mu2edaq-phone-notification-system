# Getting Started — Mu2e DAQ Phone Notification System

Step-by-step instructions for standing up the notification server,
wiring in publishers, connecting Slack/Discord, enabling Fermilab SSO,
configuring Apple push (APNs), and enrolling iPhones.

The short version:

```bash
./bootstrap.sh                       # 1. install
$EDITOR config/notify-server.yaml    # 2. set an API token (at minimum)
./start-mu2edaq-notify-server.sh     # 3. run
open http://localhost:8095/          # 4. use the web UI
```

Everything below is the long version.

---

## 1. Prerequisites

**Server host** (a machine on the DAQ network, e.g. a mu2edaq node):

- Python 3.9+ (AL9's system Python is fine)
- Network reachability from the DAQ applications that will publish, and
  outbound HTTPS to `api.push.apple.com`, `hooks.slack.com`, and
  `discord.com` for the external destinations you plan to use

**C++ publisher builds** (optional, on whatever machines build DAQ code):

- CMake ≥ 3.16, a C++17 compiler, libcurl development headers
  (`dnf install libcurl-devel` / `brew install curl`)
- CppUnit only if you want the C++ unit tests
  (`dnf install cppunit-devel` / `brew install cppunit`)

**iOS app** (on a Mac):

- Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`)
- An Apple Developer account for on-device push (see §7)

## 2. Install the server

```bash
git clone git@github.com:Mu2e/mu2edaq-phone-notification-system.git
cd mu2edaq-phone-notification-system
./bootstrap.sh
```

`bootstrap.sh` creates `venv/`, installs `requirements.txt`, installs
the package editable, and — if `../mu2edaq-discovery` is checked out
next to it (as in the `mu2edaq-main` super-repo) — installs the
discovery library so the server announces itself on the DAQ network.
Re-run it any time; it is idempotent and also updates dependencies.

## 3. Configure

All configuration lives in `config/notify-server.yaml` (fully
commented). Precedence everywhere is:

1. command line (`mu2edaq-notify-server --port 9000 …`)
2. environment (`MU2EDAQ_NOTIFY_PORT=9000 …`)
3. the YAML file
4. built-in defaults

### 3.1 Minimum required: publisher API tokens

Publishers authenticate with bearer tokens. **With no tokens configured
the event API is open** (it logs a warning at startup) — fine for a
first smoke test, not for anything reachable by others. Generate one
and add it:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

```yaml
auth:
  api_tokens:
    - "PASTE-THE-GENERATED-TOKEN-HERE"
```

Give that token to every publishing application (constructor argument,
`--token`, or `MU2EDAQ_NOTIFY_TOKEN`). You can list several tokens (one
per subsystem) so they can be revoked individually.

### 3.2 Base URL (important for QR enrollment)

QR codes and auto-configuration URLs embed the server's address. Set it
to the name phones can actually reach:

```yaml
server:
  base_url: "http://mu2edaq01.fnal.gov:8095"
```

If left empty the server infers it from the incoming request, which
breaks when you browse via `localhost` or a tunnel.

### 3.3 Database (optional)

Default is SQLite at `data/notify.db` with 30-day event retention. For
Postgres:

```yaml
database:
  url: "postgresql+psycopg2://notify:PASSWORD@dbhost/mu2enotify"
```

and `venv/bin/pip install psycopg2-binary`. Tables are created
automatically on first start.

### 3.4 ZeroMQ compatibility listener (optional)

To ingest events from applications that already publish on ZeroMQ
(downtime-logger style) without modifying them:

```yaml
zmq:
  enabled: true
  connect:                       # SUB to existing publishers (they bind)
    - "tcp://mu2edaq09:5555"
  bind: "tcp://0.0.0.0:8096"     # PULL socket new publishers can PUSH to
  default_severity: "warning"    # severity for plain-text messages
```

JSON payloads use the full event schema; plain text becomes the message
of a `default_severity` event.

## 4. Start, verify, stop

```bash
./start-mu2edaq-notify-server.sh      # background; log: data/notify-server.log
```

Verify from any machine with the repo (or just curl):

```bash
venv/bin/mu2edaq-notify --server http://mu2edaq01:8095 ping
venv/bin/mu2edaq-notify --server http://mu2edaq01:8095 --token YOURTOKEN \
    send --severity error --source smoke-test "First event" "It works"
```

Open `http://mu2edaq01:8095/` — the event appears on the dashboard live
(the page updates over SSE, no refresh needed). Then:

```bash
./stop-mu2edaq-notify-server.sh       # clean stop (SIGTERM, then SIGKILL)
```

For production, run the start script from systemd or the DAQ's standard
process management; it refuses to double-start via `data/notify-server.pid`.

## 5. Filters and destinations (the routing)

Nothing is delivered until a **filter** routes events to a
**destination**. The shipped config seeds one destination (`all-phones`,
type apns) and one filter (`errors-to-phones`: severity ≥ error → all
phones). Manage everything else in the web UI:

1. **Destinations page** — add:
   - `apns` — pushes to every enabled, registered iPhone (each phone
     additionally has its own minimum-severity setting)
   - `slack` — paste a Slack *incoming webhook* URL
     (Slack workspace → Apps → Incoming Webhooks → Add, pick a channel)
   - `discord` — paste a Discord webhook URL
     (channel → Edit → Integrations → Webhooks → New Webhook)
2. **Filters page** — add rules. A rule matches when *all* of these hold:
   - event severity ≥ the rule's minimum severity
   - event source matches the source glob (e.g. `dtc-*`)
   - event host matches the host glob (e.g. `mu2edaq0?`)
   - the optional regex matches the message
   Matched events go to every destination the rule lists; multiple
   matching rules union their destinations (each destination fires once).
3. Repeated identical events (same source + severity + title) are
   suppressed within `dispatch.rate_limit_seconds` (default 60) so an
   error storm doesn't page a phone 500 times. Suppressions are recorded
   on the event's detail page.

Use the dashboard's **Send test event** button to exercise a rule, then
check the event's detail page — every delivery attempt (sent / logged /
failed / suppressed, with the reason) is listed there.

## 6. Publishing from DAQ applications

**Python** (no dependencies — copy nothing, just `pip install -e` this
repo or vendor `src/mu2edaq_notify/{events,publisher}.py`):

```python
from mu2edaq_notify import NotifyPublisher

pub = NotifyPublisher(token="YOURTOKEN", source="dtc-monitor")
# server found via mu2edaq-discovery; or pass server_url=, or set
# MU2EDAQ_NOTIFY_URL / MU2EDAQ_NOTIFY_TOKEN in the environment
pub.error("DTC link down", "ROC link 3 lost lock", meta={"run": "107001"})
```

Publishing never raises and never blocks longer than `timeout` (5 s
default) — a dead notification server cannot take down a DAQ process.

**C++**:

```bash
cmake -S . -B build && cmake --build build && cmake --install build  # optional install
```

```cpp
#include <mu2edaq_notify/notify.hpp>          // link mu2edaq::notify
mu2edaq::notify::Options opts;
opts.token = "YOURTOKEN";
opts.source = "dtc-monitor";
mu2edaq::notify::Publisher pub(opts);
pub.error("DTC link down", "ROC link 3 lost lock");
```

**Shell / cron / scripts**:

```bash
export MU2EDAQ_NOTIFY_URL=http://mu2edaq01:8095 MU2EDAQ_NOTIFY_TOKEN=YOURTOKEN
mu2edaq-notify send --severity critical --source diskwatcher \
    "Disk full on mu2edaq05" "/data at 98%"
```

**Discovery note:** both libraries locate the server with a
`mu2edaq-discovery` query (`app=notify`). Multicast does not cross the
FNAL gateway, so off-network publishers must set the URL explicitly.

## 7. Apple push (APNs) — going from log-only to real pushes

Out of the box `apns.enabled` is false and the server runs **log-only**:
phone deliveries are recorded (status `logged`) but not sent to Apple.
Everything else — enrollment, filters, Slack/Discord — works, so do this
step last.

1. In the [Apple Developer portal](https://developer.apple.com):
   - Certificates, Identifiers & Profiles → **Identifiers** → register
     App ID `gov.fnal.mu2e.Mu2eNotify` with the **Push Notifications**
     capability. (If you use a different bundle id, change it in *both*
     `ios/Mu2eNotify/project.yml` and the server config.)
   - **Keys** → create a key with the **APNs** service enabled. Download
     the `.p8` file (one chance only) and note the **Key ID** and your
     **Team ID** (top-right of the portal).
2. On the server:
   ```bash
   cp ~/Downloads/AuthKey_ABC123DEFG.p8 config/apns_key.p8   # git-ignored
   ```
   ```yaml
   apns:
     enabled: true
     key_file: "config/apns_key.p8"
     key_id: "ABC123DEFG"
     team_id: "YOURTEAMID"
     bundle_id: "gov.fnal.mu2e.Mu2eNotify"
     sandbox: true        # true for Xcode-installed builds,
                          # false for TestFlight / App Store builds
   ```
3. Restart the server. Failed pushes show up on each event's delivery
   log with Apple's reason string (e.g. `BadDeviceToken` usually means a
   sandbox/production mismatch with `apns.sandbox`).

## 8. Build and enroll the iPhone app

```bash
cd ios/Mu2eNotify
# put your Team ID in project.yml (DEVELOPMENT_TEAM), then:
xcodegen generate
open Mu2eNotify.xcodeproj      # select your iPhone, Cmd-R
```

Enrollment:

1. Server web UI → **Devices → Enroll a new phone**. You get a QR code
   and a one-time auto-configuration URL (valid 30 minutes by default,
   `auth.enrollment_ttl_minutes`).
2. In the app: **Scan QR code** (or paste the URL into the manual
   field). The app registers, receives its permanent device token, asks
   for notification permission, and uploads its APNs token.
3. The phone now appears on the Devices page. Per-device minimum
   severity is set in the app's Settings tab; the web UI can disable or
   remove a device at any time.
4. Send a test event at or above the phone's minimum severity — with
   APNs enabled the banner arrives even when the phone is off-site.

## 9. Fermilab SSO for the web interface (optional)

Request an OIDC client registration from Fermilab SSO
(PingFederate) with redirect URI
`http://<your-base-url>/auth`, then:

```yaml
auth:
  oidc:
    enabled: true
    issuer: "https://pingprod.fnal.gov"
    client_id: "YOUR-CLIENT-ID"
    client_secret: "YOUR-CLIENT-SECRET"
    allowed_users: ["anorman@fnal.gov"]   # empty list = any authenticated user
```

With OIDC enabled, all web pages and unauthenticated API reads require
sign-in; publishers and phones keep using their bearer tokens. iOS App
Transport Security also requires HTTPS for phone enrollment. Either put
the server behind TLS (a reverse proxy like nginx/caddy is the easy path)
or enable TLS in the built-in server:

```yaml
server:
  base_url: "https://your-hostname:8095"
  tls:
    enabled: true
    cert_file: "config/tls.crt"
    key_file: "config/tls.key"
```

Use a certificate trusted by the iPhone. `--tls-adhoc` starts HTTPS with
a temporary self-signed certificate for quick browser testing, but the
iPhone will not accept it unless that certificate is trusted on the
device.

## 10. Tests

```bash
venv/bin/pytest                # Python: server, filters, storage, publisher, zmq
ctest --test-dir build         # C++ (needs CppUnit installed)
# iOS: Mu2eNotifyTests scheme in Xcode (Cmd-U)
```

## 11. Troubleshooting

| Symptom | Check |
|---|---|
| `mu2edaq-notify ping` fails | Server running? (`data/notify-server.log`) Port 8095 open in the host firewall? |
| Publisher gets 401 | Token not in `auth.api_tokens`, or `Bearer ` prefix missing |
| Event on dashboard but nothing delivered | Filters page: does any enabled rule match its severity/source/host? Event detail page shows per-delivery status |
| Delivery status `suppressed` | Rate limiting — identical event within `dispatch.rate_limit_seconds` |
| Delivery status `logged` for phones | APNs still disabled (§7), or the device has no APNs token yet |
| Push fails `BadDeviceToken` | `apns.sandbox` doesn't match how the app was installed (Xcode = sandbox, TestFlight/App Store = production) |
| QR scan does nothing on the phone | Enrollment token expired (default 30 min) — generate a new one; check `server.base_url` is reachable from the phone |
| Discovery not finding the server | mu2edaq-discovery installed in the venv? Multicast doesn't cross the FNAL gateway — set `MU2EDAQ_NOTIFY_URL` off-network |
| Web UI unstyled with no internet | Tailwind/htmx load from CDNs; on an isolated network vendor them into `web/static/` and adjust `base.html` |

Man pages: `man ./man/mu2edaq-notify-server.1`, `man ./man/mu2edaq-notify.1`,
`man ./man/mu2edaq_notify.3`, `man ./man/mu2edaq_notify_cpp.3`.
