# mu2edaq-phone-notification-system

Push notifications from the Mu2e DAQ to iPhones, Slack, and Discord.

DAQ applications publish error/warning events (HTTP JSON or the existing
ZeroMQ scheme) to a central **notification server** running on the DAQ
network. The server stores the events, runs them through configurable
filter rules, and delivers matched notifications to registered iPhones
(Apple Push Notification service), Slack webhooks, and Discord webhooks —
so users get notified even when they are off the DAQ network.

```
 DAQ applications                Notification server                Destinations
 ────────────────                ───────────────────────────        ────────────
 Python lib ──── HTTP ────►      Flask API ──► SQLite/Postgres      ──► APNs ──► iPhones
 C++ lib    ──── HTTP ────►         │              │                ──► Slack webhook
 zmq apps   ──── PUB/PUSH ──►    zmq listener   filter rules        ──► Discord webhook
                                    │              │
 Web browser ◄── SSE/HTTP ──     dashboard · filters · devices (QR enroll)
```

Components:

| Path | What |
|---|---|
| `src/mu2edaq_notify/server/` | Notification server (Flask, SQLAlchemy, APNs/Slack/Discord dispatch) |
| `src/mu2edaq_notify/` | Python publisher library (stdlib-only) + `mu2edaq-notify` CLI |
| `src/cpp/`, `src/include/` | C++17 publisher library (libcurl, CMake) |
| `ios/Mu2eNotify/` | SwiftUI iPhone app (splash screen, dashboard, QR enrollment) |
| `web/templates/` | Web interface (Tailwind + htmx, live SSE dashboard) |
| `man/` | Man pages for every executable and API |

## Install and run the server

```bash
./bootstrap.sh                        # venv/, deps, editable install,
                                      # discovery sibling if checked out
cp config/notify-server.yaml config/notify-server.local.yaml   # optional
./start-mu2edaq-notify-server.sh      # background, log in data/
./stop-mu2edaq-notify-server.sh
```

Web interface: `http://<host>:8095/` by default, or
`https://<host>:8095/` when `server.tls.enabled: true`.
Configuration precedence:
command line > `MU2EDAQ_NOTIFY_*` environment > YAML > defaults
(see `man ./man/mu2edaq-notify-server.1`).

Before exposing the server, set at least one publisher token in
`auth.api_tokens`. The database is SQLite (`data/notify.db`) by default;
point `database.url` at `postgresql+psycopg2://…` to use Postgres.

### HTTPS / phone enrollment

iOS App Transport Security requires HTTPS for the QR enrollment URL.
Either run behind a trusted reverse proxy, or configure the built-in
server with a certificate trusted by the phone:

```yaml
server:
  base_url: "https://your-hostname:8095"
  tls:
    enabled: true
    cert_file: "config/tls.crt"
    key_file: "config/tls.key"
```

For temporary browser testing only:

```bash
./start-mu2edaq-notify-server.sh --tls-adhoc \
  --base-url https://your-hostname:8095
```

### Fermilab SSO

Set `auth.oidc.enabled: true` with the Fermilab OIDC `issuer`,
`client_id`, and `client_secret` to require sign-on for the web
interface. Without it the web UI is open (fine behind the DAQ gateway).

### APNs (real pushes to phones)

Until Apple credentials are configured the server runs in **log-only**
mode: deliveries are recorded (status `logged`) but nothing is sent to
Apple, so the whole pipeline can be tested first. To go live: create an
APNs auth key at developer.apple.com, save it as `config/apns_key.p8`
(git-ignored), and fill in `apns.key_id`, `apns.team_id`,
`apns.bundle_id`, and `apns.enabled: true`.

## Publishing events

Python (no dependencies beyond the stdlib):

```python
from mu2edaq_notify import NotifyPublisher
pub = NotifyPublisher(token="api-token", source="dtc-monitor")   # server via discovery
pub.error("DTC link down", "ROC link 3 lost lock", meta={"run": "107001"})
```

C++ (`cmake -S . -B build && cmake --build build`, link `mu2edaq::notify`):

```cpp
#include <mu2edaq_notify/notify.hpp>
mu2edaq::notify::Options opts;
opts.token = "api-token";
opts.source = "dtc-monitor";
mu2edaq::notify::Publisher pub(opts);
pub.error("DTC link down", "ROC link 3 lost lock");
```

Shell: `mu2edaq-notify send --severity error "DTC link down" "detail"`.

Both libraries find the server automatically via
[mu2edaq-discovery](https://github.com/Mu2e/mu2edaq-discovery)
(`app=notify`), or use `$MU2EDAQ_NOTIFY_URL`. The server advertises its
own **local** address as primary (so on-network publishers talk to it
directly) and carries the public reverse-proxy URL as a **fallback** in
the ANNOUNCE metadata (`discovery.fallback_url` in the config); a
publisher only tries the fallback when the local address is unreachable
at the network level — an explicit rejection (bad token, bad payload) is
never retried against the fallback. Off-network publishers that can't
reach the multicast group at all should just set `$MU2EDAQ_NOTIFY_URL`
(and optionally `$MU2EDAQ_NOTIFY_FALLBACK_URL`) directly. Existing
ZeroMQ publishers (downtime-logger style) are ingested unchanged when
`zmq.enabled: true`.

## iPhone app

`ios/Mu2eNotify/` is a SwiftUI app (iOS 16+). Generate the Xcode project
with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
cd ios/Mu2eNotify && xcodegen generate && open Mu2eNotify.xcodeproj
```

Set your `DEVELOPMENT_TEAM` in `project.yml`. To enroll a phone: web UI →
**Devices → Enroll a new phone**, then scan the QR code in the app (or
paste the one-time auto-configuration URL). The app registers with a
bearer token, uploads its APNs token, and shows the event dashboard.

## Tests

```bash
venv/bin/pytest                 # Python: 49 tests (server, filters, publisher, zmq)
ctest --test-dir build          # C++: CppUnit (skipped if CppUnit not installed)
# iOS: run the Mu2eNotifyTests scheme in Xcode (XCTest)
```

## Documentation

Man pages in `man/`: `mu2edaq-notify-server(1)`, `mu2edaq-notify(1)`,
`mu2edaq_notify(3)` (Python API), `mu2edaq_notify_cpp(3)` (C++ API).
The web interface has About, API, and Sitemap pages. The original
specification is `PhonePushNotificationSpecifications.md`.

Reverse-proxy and phone access docs:

- `docs/reverse-proxy-setup.md` - AWS EC2, Route 53, Caddy, tunnel setup.
- `docs/reverse-proxy-operations.md` - start/stop/status runbook and troubleshooting.
- `docs/application-chain.md` - end-to-end publishing, registration, proxy, and APNS chain.
