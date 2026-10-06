---
title: mu2edaq-phone-notification-system — interfaces
group: monitoring
tier: A
audience: expert
summary: >
  Terminal alarm destination for the Mu2e DAQ: a Flask server on 8095 that ingests
  events over an HTTP JSON API or a ZeroMQ compatibility listener, routes them with
  database-held filter rules, and delivers them to iPhones (APNs), Slack, Discord and
  a live SSE web dashboard
---

# Interfaces

Other packages should link to this page rather than restate the publish API.
Line references are to this repository at the `mu2e-sept-mega-review` branch.

| § | Interface | Direction | Who uses it |
|---|---|---|---|
| 1 | Event schema | in | every ingest path |
| 2 | HTTP API on 8095 | in | Python/C++ publishers, `mu2edaq-file-reaper`, iOS app, web UI |
| 3 | ZeroMQ listener on 8096 | in | nothing today (disabled by default) |
| 4 | Python publisher library | library | `mu2edaq-file-reaper` (`notify` extra) |
| 5 | C++ publisher library | library | no in-tree consumer |
| 6 | mu2edaq-discovery ANNOUNCE | out | both publisher libraries |
| 7 | SSE stream | out | web dashboard |
| 8 | iOS app | client of §2 | phones |
| 9 | Outbound delivery | out | APNs, Slack, Discord |
| 10 | Ports | | |

## 1. Event schema

An event is one flat JSON object. `normalize_event()`
(`src/mu2edaq_notify/events.py:49-82`) is the only coercion point, used by the
HTTP API (`src/mu2edaq_notify/server/app.py:270`), the ZeroMQ listener
(`src/mu2edaq_notify/server/zmq_listener.py:52-55`), the web test button
(`app.py:512`) and, client-side, the Python publisher
(`src/mu2edaq_notify/publisher.py:162-170`).

| Field | Type | Default when absent or empty | Limit | Notes |
|---|---|---|---|---|
| `severity` | string | `info` (HTTP), `zmq.default_severity` = `warning` (ZeroMQ) | one of `debug info warning error critical` (`events.py:30`) | lower-cased; **any other value is silently replaced by the default** (`events.py:64-66`) |
| `title` | string | first line of `message` | 200 chars | one of `title`/`message` is required |
| `message` | string | `""` | 4000 chars | |
| `source` | string | `unknown` (HTTP), `zmq` (ZeroMQ) | 100 chars | filter rules glob on it |
| `host` | string | `socket.gethostname()` **of the server** (`events.py:75`) | 100 chars | both client libraries always set it |
| `category` | string | `""` | 100 chars | freeform; `categories:` in the config is a UI list, not enforced |
| `timestamp` | string | server time, ISO-8601 UTC | none | stored verbatim, never parsed; retention uses the server-side `received_at` |
| `meta` | object | `{}` | **none** (open: #12) | keys and values `str()`-coerced; a non-object becomes `{"value": str(x)}` |

`normalize_event` raises `ValueError` only for a non-object payload or when
`title` and `message` are both empty (`events.py:54-60`). Everything else is
coerced without error. Two consequences matter to a publisher:

* A misspelt severity (`"fatal"`, `"err"`) is not rejected; it becomes `info`
  over HTTP and will not page under any rule with `min_severity` above `info`.
* An omitted `host` is recorded as the notification server's own hostname.

The stored form adds `id` (integer, monotonically increasing) and
`received_at` (ISO-8601 UTC, server clock) (`storage.py:38-51`).

## 2. HTTP API — port 8095

Flask's threaded development server (`server/cli.py:224-226`), HTTPS when
`server.tls.enabled` (built-in default `false`, shipped
`config/notify-server.yaml:29` `true`), else HTTP. Public access is through a
reverse proxy that forwards **every path** to this port (§10).

### 2.1 Endpoints

| Method | Path | Auth | Handler | Purpose |
|---|---|---|---|---|
| POST | `/api/events` | publisher token (§2.3) | `app.py:266` | **Publish one event.** `201` and the stored event |
| GET | `/api/events` | read rule (§2.3) | `app.py:277` | Newest first. `limit` (default 100, capped 1000; non-integer → 500, negative → unlimited — #10), `severity`, `source`, `category`, `since_id` |
| GET | `/api/events/<id>` | read rule | `app.py:291` | One event plus `deliveries[]` (the audit trail) |
| GET | `/api/stream` | read rule | `app.py:352` | SSE (§7) |
| GET | `/api/health` | none | `app.py:248` | `status`, `version`, `apns_enabled`, `zmq_enabled`, `events` (count per severity) |
| GET | `/api/categories` | none | `app.py:257` | `{"categories": [...]}` from config |
| POST | `/api/devices/register` | enrollment token in body | `app.py:302` | `{enrollment_token, name?, apns_token?}` → `201 {device, device_token, server_url}` |
| POST | `/api/devices/token` | device token | `app.py:316` | `{apns_token}` |
| POST | `/api/devices/settings` | device token | `app.py:328` | `{name?, min_severity?}` |
| GET | `/api/autoconfig/<token>` | enrollment token in path | `app.py:341` | `{type: "mu2edaq-notify-config", version: 1, server_url, enrollment_token, register_endpoint}` |

`/api/health` reports the **configured** `apns.enabled` and `zmq.enabled`
(`app.py:252-253`), not whether APNs delivery or the ZeroMQ thread is actually
running. An unreadable APNs key leaves `apns_enabled: true` while every push
is recorded as `logged` (PNS-013).

Error bodies: 401, 403 and 404 under `/api/` are JSON `{"error": ...}`
(`app.py:59-65`). Every other status, including the `400` for an unusable
event and any `500`, is Flask's default HTML page. Clients should key on the
status code, not parse the body.

### 2.2 Publishing — the call other packages make

```bash
curl -sS -X POST https://mu2edaq-pager.fnal.gov/api/events \
  -H "Authorization: Bearer $MU2EDAQ_NOTIFY_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"source":"dtc-monitor","host":"mu2edaq09","severity":"error",
       "category":"Trigger","title":"DTC link down",
       "message":"ROC link 3 lost lock","meta":{"run":"107001"}}'
```

| Status | Meaning |
|---|---|
| 201 | Stored and queued for delivery. Delivery is asynchronous: 201 says nothing about whether anyone was paged |
| 400 | Body not JSON, not an object, or no `title`/`message` (HTML body) |
| 401 | A token is configured and the header is missing or wrong |

What happens after 201 (`app.py:217-225`, `dispatch.py:40-111`): the event is
pushed to the SSE hub, queued, matched against every enabled filter rule, rate
limited on `(source, severity, title)` for `dispatch.rate_limit_seconds`
(default 60), and delivered to each matched destination in turn. Each attempt
writes a `deliveries` row: `sent`, `logged` (APNs log-only mode or no enrolled
device), `failed` (one attempt, no retry), or `suppressed` (rate limited). To
confirm a page, read `GET /api/events/<id>` and inspect `deliveries[]`.

### 2.3 Authentication and token scoping

Three token types, not interchangeable:

| Token | Issued by | Stored | Checked | Scope |
|---|---|---|---|---|
| Publisher API token | operator; `auth.api_tokens`, `--api-token`, `MU2EDAQ_NOTIFY_API_TOKEN`, or one per line in `auth.api_tokens_file` | plaintext in memory | `token in tokens`, `auth.py:34`, `app.py:234` | publish **and** read; any token may publish any `source`/`host` |
| Device bearer token | server, `"mu2edev-" + token_urlsafe(32)` at registration (`storage.py:152`) | SHA-256 only (`storage.py:59,148`) | hash lookup, `storage.py:277-284` | read all events + own device settings |
| Enrollment token | web UI, HS256 JWT `{"purpose":"enroll","exp":now+TTL}` signed with `auth.enrollment_secret` (`auth.py:56-59`) | not stored | `jwt.decode` + `purpose`, `auth.py:62-69` | register any number of devices until expiry (default 30 min); not single-use |

Behaviour a caller or operator must know:

* **No publisher token configured → publishing is unauthenticated.**
  `auth.py:31-33` returns the view unguarded; startup logs one WARNING
  (`cli.py:212-214`). Tracked as #3.
* **Read access is open whenever OIDC is off, regardless of tokens.**
  `_read_access_ok()` (`app.py:228-241`) accepts any publisher or device
  token, a web session, **or a request with no `Authorization` header when
  `auth.oidc.enabled` is false**. A request carrying a *wrong* token gets
  401; a request carrying none gets 200. Verified with the Flask test client
  against a config with tokens set. Tracked as #1, which also covers the web
  UI: every page and every mutating form (filters, destinations, devices,
  enrollment, test event) is unauthenticated when OIDC is off, which is the
  shipped setting (`config/notify-server.yaml:56`) and the file the production
  launchd agent runs. With that file and a publisher token set, the test
  client shows `POST /api/events` without a token → 401, but
  `POST /devices/enroll` → 200 with a live enrollment link and
  `POST /destinations/1/delete` → 302 with the `all-phones` destination gone.
  Both public proxies forward every path (§10), so this is reachable from the
  internet. Assessed S1 in the comment staged on #1 (PNS-023).
* Publisher-token comparison is a Python `in` over a list, not
  `hmac.compare_digest` (PNS-006, S4).
* A missing `auth.api_tokens_file` is skipped silently (`config.py:174-180`),
  and so is a missing `--config` file (`config.py:160-161`); either can leave
  the server with no tokens and therefore open (comment staged on #4).
* Publisher tokens and enrollment JWTs are bearer secrets over whatever scheme
  the URL names. The publishers send the token to an address learned from an
  unauthenticated discovery reply if none is configured (§6, PNS-015).

Web-UI login is optional Fermilab SSO over OIDC (`auth.py:74-107`, Authlib,
issuer `https://pingprod.fnal.gov`) with an optional `allowed_users` list of
emails or usernames. There is no CSRF token on the mutating forms; with OIDC
on they rely on the session cookie (cookie flags: #14).

### 2.4 Public URL derivation (enrollment)

The `server_url` handed to a phone (QR payload, autoconfig, registration
response) is computed per request by `public_base_url()` (`app.py:147-192`):
leftmost `X-Forwarded-Host`/`X-Forwarded-Proto`, else the request's `Host` and
scheme; validated against a hostname grammar (`app.py:84-116`); restricted by
`server.trusted_hosts` when set, with `server.base_url` as the fallback. The
QR payload is built with `json.dumps`
(`app.py:195-200`): `{"type":"mu2edaq-notify-config","server_url":...,"enrollment_token":...}`.

## 3. ZeroMQ compatibility listener — port 8096

Disabled unless `zmq.enabled` (default `false` in `config.py:64` and
`config/notify-server.yaml:76`). Started only at `cli.py:201-207`; needs
`pyzmq` (installed by `requirements.txt:12`; without it the thread logs one
WARNING and exits, `zmq_listener.py:58-62`).

### 3.1 Transport

| Mode | Socket | Endpoint | Pairs with | Source |
|---|---|---|---|---|
| bind | `ZMQ_PULL` | `zmq.bind`, default `tcp://0.0.0.0:8096` | `PUSH` senders that connect | `zmq_listener.py:73-79`, `config.py:66` |
| connect | `ZMQ_SUB`, subscribe all | each `zmq.connect` entry | `PUB` sockets that bind | `zmq_listener.py:66-72` |

One `zmq.Poller`, 500 ms timeout (`zmq_listener.py:83-89`). Any exception while
parsing or storing a message is logged at WARNING and the message is dropped.
There is no topic stripping: a `PUB` sender that prefixes a topic gets the
topic included in the message text.

### 3.2 Payload handling

```text
bytes --decode(utf-8, errors=replace).strip()-->
  json.loads() is a dict  -> used as the event dict as-is
  otherwise               -> {"message": text, "severity": zmq.default_severity}
then normalize_event(payload,
                     default_source   = zmq.default_source,    # "zmq"
                     default_severity = zmq.default_severity)  # "warning"
```

(`zmq_listener.py:42-55`.) Only the keys of §1 are read.

### 3.3 Against the `mu2edaq-dashboard` bus: transport-compatible, schema-incompatible

The dashboard bus (`mu2edaq-dashboard/docs/INTERFACES.md`; dashboard binds
`ZMQ_PULL` on 5555, senders `PUSH`-connect) carries five keys, built at
`mu2edaq-dashboard/sender.py:90-97` and identically by the C++ sender
(`mu2edaq-dashboard/mu2edaq_sender.cpp:66-76`):

```json
{"event_category": "...", "error_level": "error|warning|normal|log|debug",
 "subsystem": "...", "timestamp": "...", "message": "..."}
```

*Transport.* A dashboard sender pointed at `tcp://<notify-host>:8096`
(`sender.py --port 8096`) delivers into the PULL socket: PUSH→PULL is a valid
pair. The `zmq.connect` (SUB) mode cannot receive from the dashboard at all:
SUB pairs only with PUB, and the dashboard has no PUB socket. Nor can one
sender feed both consumers: a PUSH socket connected to both 5555 and 8096
round-robins messages between them rather than copying, so each consumer
would see about half the traffic. Feeding this listener from the dashboard bus
needs a separate sender (or a forwarder), not a second `connect`.

*Schema.* Field by field, through `normalize_event`:

| Dashboard key | Read by notify? | Result |
|---|---|---|
| `error_level` | **no** — only `severity` is read (`events.py:64`) | `zmq.default_severity` = **`warning`**, for every level |
| `subsystem` | **no** — only `source` (`events.py:74`) | `"zmq"` for every sender |
| `event_category` | **no** — only `category` (`events.py:77`) | `""` |
| (no host key) | — | the notify server's own hostname (`events.py:75`) |
| `message` | yes | `message`, and its first line becomes `title` (`events.py:61-62`) |
| `timestamp` | yes | stored verbatim |

Verified by feeding all five dashboard levels through `ZmqListener._parse`:
`error`, `warning`, `normal`, `log` and `debug` each come out as
`severity: warning, source: zmq, category: ""`.

**Verdict: confirmed, and the consequence is stronger than "error becomes
warning".** The level is not mapped at all; it is discarded, and every
dashboard message — routine `log` and `debug` traffic included — is ingested
at one flat severity. Under the shipped seed rule `errors-to-phones`
(`min_severity: error`, `config/notify-server.yaml:135-139`)
`rule_matches()` rejects all of them at `filters.py:17`, so a dashboard
`error` produces **no page**; under any rule with `min_severity: warning`
every dashboard message pages, including `debug`. Category routing cannot
work because every category is empty, and every dashboard sender shares one
rate-limit bucket keyed on source `"zmq"`. Severity **S3** (PNS-001): a
silent-wrong path on the alarm system, but unreachable without an operator
enabling `zmq.enabled` and pointing a sender at 8096, which no shipped
configuration does. It becomes S2 the day anyone does.

The module docstring's claim of compatibility with "the existing Mu2e DAQ
ZeroMQ publishing scheme … so applications already publishing on zmq need no
changes" (`zmq_listener.py:3-6`) holds only for plain-text bodies, the
format `mu2edaq-downtime-logger`'s `ZmqDetector` consumes
(`mu2edaq-downtime-logger/tools/zmq_publish.py:27-41` is its diagnostic
emitter: `PUB`, bodies such as `RUN STATE stopped`). Those take the non-JSON
branch and become `warning`/`zmq` events; `tests/test_zmq_listener.py:59-65`
covers that case and `:48-56` covers a notify-schema JSON event. No test
covers a dashboard-schema message.

A producer that wants correct severities over ZeroMQ today must send the
notify schema of §1 (`severity`, `source`, `category`, `title`, `message`,
`host`) as a JSON object.

## 4. Python publisher — `mu2edaq_notify`

`from mu2edaq_notify import NotifyPublisher, publish_event`
(`src/mu2edaq_notify/__init__.py:11-12`). Standard library only at runtime,
although the `mu2edaq-notify` distribution declares the server's dependencies
(`pyproject.toml:13-22`), so `pip install mu2edaq-notify` pulls Flask,
SQLAlchemy, httpx and cryptography into the publisher's environment. Full
reference: `man/man3/mu2edaq_notify.3`.

```python
NotifyPublisher(server_url=None, token=None, source=None, category=None,
                host=None, timeout=5.0, discover=True, fallback_url=None)
.publish(severity, title, message="", source=None, category=None, meta=None) -> bool
.debug/.info/.warning/.error/.critical(title, message="", **kw) -> bool
publish_event(severity, title, message="", **kwargs) -> bool
```

* Address resolution (`publisher.py:97-110`): argument > `MU2EDAQ_NOTIFY_URL` /
  `MU2EDAQ_NOTIFY_FALLBACK_URL` > discovery (§6). Discovery runs **once, in the
  constructor**, and is never repeated; a publisher built while the server is
  down or not announcing never finds it (PNS-016).
* `publish()` tries the primary, then the fallback only on a network-level
  failure (DNS, connect, timeout, TLS); any HTTP reply, including 5xx, ends the
  attempt (`publisher.py:112-134,172-181`). Returns `True` on 2xx.
* It does not raise on delivery failure, but it **does** raise `ValueError` when
  `title` and `message` are both empty, because it normalizes client-side
  (`publisher.py:162`). The same client-side normalization turns an unknown
  severity into `info` before sending.
* HTTPS is verified against `certifi` when present, else the system store
  (`publisher.py:51-63`), with no way to disable it: a URL must name a host
  the server certificate covers (`https://localhost:8095` fails against the
  production certificate and is treated as unreachable).

## 5. C++ publisher — `mu2edaq::notify`

Header `src/include/mu2edaq_notify/notify.hpp`, implementation
`src/cpp/notify.cpp`, C++17, libcurl, built by `CMakeLists.txt:17-30`. Full
reference: `man/man3/mu2edaq_notify_cpp.3`.

```cpp
namespace mu2edaq::notify {
struct Options {                    // notify.hpp:32-46
    std::string server_url;         // "" -> $MU2EDAQ_NOTIFY_URL, then discovery
    std::string fallback_url;       // "" -> $MU2EDAQ_NOTIFY_FALLBACK_URL, then ANNOUNCE meta.fallback_url
    std::string token;              // "" -> $MU2EDAQ_NOTIFY_TOKEN
    std::string source = "cpp";
    std::string category;           // "" -> $MU2EDAQ_NOTIFY_CATEGORY
    std::string host;               // "" -> gethostname()
    long timeout_ms = 5000;
    bool discover = true;
};
using Meta = std::map<std::string, std::string>;
class Publisher {                   // notify.hpp:50-96
public:
    explicit Publisher(Options opts = {});
    bool publish(const std::string& severity, const std::string& title,
                 const std::string& message = "", const Meta& meta = {},
                 const std::string& category = "");
    bool debug(...), info(...), warning(...), error(...), critical(...);
    const std::string& server_url() const;
    const std::string& fallback_url() const;
};
DiscoveredServer discover_server_pair(double timeout_s = 2.0);   // notify.hpp:107
std::string      discover_server(double timeout_s = 2.0);        // notify.hpp:111
}
```

Semantics that differ from, or are not visible in, the header:

* Resolution is lazy: the first `publish()` reads the environment and, if
  needed, runs one 2 s discovery (`notify.cpp:224-237`). It is cached for the
  object's lifetime, including a failed lookup (PNS-016).
* `publish()` returns `false` silently in every failure case; it never throws
  and never logs. A transport error (`rc != CURLE_OK`) moves to the fallback;
  any HTTP status ends the attempt (`notify.cpp:267-280,282-305`).
* Severity is not validated client-side; the server maps unknown values to
  `info`.
* Not thread-safe on first use: `resolve_server()` mutates `opts_` without a
  lock, and the constructor calls `curl_global_init`.
* Discovery is self-contained (`notify.cpp:148-210`): it multicasts a
  `mu2edaq-discovery/1` DISCOVER with `filter: {app: notify}` to
  `239.255.42.99:28999` and parses the reply with a minimal string scanner; it
  does not link `mu2edaq-discovery`. Unlike the Python client it does not also
  broadcast.
* Consuming the installed library: `CMakeLists.txt:57-59` installs only an
  export set (`mu2edaq_notify-targets.cmake`), no package Config file, so
  `find_package(mu2edaq_notify)` fails. In-tree use via `add_subdirectory` and
  the `mu2edaq::notify` alias (`CMakeLists.txt:20`) works (PNS-011).

## 6. mu2edaq-discovery

The server announces itself when `mu2edaq_discovery` is importable and
`discovery.enabled` (`cli.py:138-162`):

| ANNOUNCE field | Value |
|---|---|
| `app` | `notify` (`discovery.app`) |
| `name` | `Mu2e DAQ Notification Server` |
| `host` | `discovery.host`, else `None` → the responder's own FQDN |
| `port` | `discovery.port`, else `server.port` (8095) |
| `scheme` | `discovery.scheme`, else `https` if `server.tls.enabled` else `http` |
| `meta` | `{"fallback_url": <discovery.fallback_url>}` when set, else none |

`meta` values are strings, as `mu2edaq-discovery/doc/INTERFACES.md` §6
requires; `version` is not passed. Shipped `fallback_url` is
`https://mu2edaq-pager.fnal.gov` (`config/notify-server.yaml:100`).

Both publishers take the **first** ANNOUNCE that answers `app=notify`
(`publisher.py:83-90`, `notify.cpp:185-200`) and then send their bearer token
to the host, port and scheme it names, or to its `meta.fallback_url`.
Discovery replies are unauthenticated (`mu2edaq-discovery/doc/INTERFACES.md`
§6 item 6), so any host on the DAQ subnet can collect publisher tokens by
answering first, over plain HTTP if it advertises `scheme: http` (PNS-015).

## 7. SSE stream — `GET /api/stream`

`text/event-stream` with `Cache-Control: no-cache` and `X-Accel-Buffering: no`
(`app.py:352-360`); read rule of §2.3.

* On connect: `retry: 3000`. Then one message type, `event`, whose `data` is
  the stored event dict of §1 as JSON (`sse.py:25-26`). A comment line
  `: keepalive` every 25 s of silence (`sse.py:38-43`).
* Each client has a private `queue.Queue(maxsize=200)` (`sse.py:15-19`).
  Publishing is `put_nowait`; on a full queue the event is **dropped for that
  client with no marker** (`sse.py:29-33`). There is no event id and no
  `Last-Event-ID` replay, so a reconnect does not recover missed events
  (PNS-012, S4; the database is the record).
* The event is published to SSE when it is queued, before delivery
  (`dispatch.py:40-44`), so the dashboard shows events that have not yet been
  (and may never be) delivered.
* Each open stream holds one Flask worker thread for its lifetime.

The dashboard opens one `EventSource('/api/stream')`
(`web/templates/dashboard.html:72`) and inserts text with `textContent`.

## 8. iOS app

`ios/Mu2eNotify/`, SwiftUI, bundle id `gov.fnal.mu2e.Mu2eNotify`,
`aps-environment: development` (`Sources/Mu2eNotify.entitlements`), background
mode `remote-notification` (`Sources/Info.plist:26-29`). Reviewed for role and
API surface only. Server calls (`Sources/ServerClient.swift`):

| Function | Request | Auth |
|---|---|---|
| `register(serverUrl:enrollmentToken:name:apnsToken:)` `:69` | `POST api/devices/register` | enrollment token in body |
| `fetchEvents(limit:)` `:81` | `GET api/events?limit=200` | device token |
| `fetchHealth()` `:90` | `GET api/health` | token sent, not required |
| `fetchCategories()` `:98` | `GET api/categories` | not required |
| `updateApnsToken(_:)` `:104` | `POST api/devices/token` | device token |
| `updateSettings(name:minSeverity:)` `:109` | `POST api/devices/settings` | device token |

Enrollment is the QR payload or `/api/autoconfig/<token>` of §2.4. In the
foreground the app polls `GET /api/events?limit=200` every 5 s
(`Sources/AppState.swift:174-178`); each poll writes `last_seen` (#6). There is
no server-side unregister — `AppState.unregister()` (`AppState.swift:88`)
clears local state only (#11) — and the device token lives in `@AppStorage`
(`UserDefaults`), not the Keychain (`AppState.swift:10`, #9). APNs payloads
carry `aps.alert`, `thread-id` = source, `sound` for `error`/`critical`, and
an `event` object of `id, source, host, severity, category, timestamp`
(`destinations.py:67-80`). The app's push-status line ("Enabled" /
"Log-only", `AppState.swift:25-26,163`) comes from `/api/health` and so shows
the configured value, not whether the server can actually push (§2.1,
PNS-013).

## 9. Outbound delivery

| Target | Request | Timeout / retry | Source |
|---|---|---|---|
| APNs | HTTP/2 `POST /3/device/<token>` to `api.sandbox.push.apple.com` if `apns.sandbox` else `api.push.apple.com`; headers `authorization: bearer <ES256 JWT>`, `apns-topic`, `apns-push-type: alert`, `apns-priority: 10`; provider JWT re-minted after 30 min | 10 s, no retry; one serial call per enrolled device | `destinations.py:30-103` |
| Slack | incoming-webhook JSON: `text` + one coloured attachment with Source/Host/Category/Time fields | 10 s, no retry | `destinations.py:106-139` |
| Discord | webhook JSON: one embed, description truncated to 2000 | 10 s, no retry | `destinations.py:142-163` |

An APNs destination fans out to **every** enabled device whose
`min_severity` admits the event (`storage.py:311-319`); destinations do not
select devices. Permanent APNs errors (`410 Unregistered`, `400
BadDeviceToken`) are recorded as `failed` and retried on every later event
(#5).

Deploy-time only (never used by the running server): Vault KV v2 at
`https://ssivault.fnal.gov:8200`, mount `okd`, path
`shared/<prod|test>/mu2edaq-pager/tunnel` (`scripts/vault_client.py:62-91`),
read by `scripts/deploy-okd-proxy.sh`; and Route 53 / EC2 APIs from the
proxy scripts.

## 10. Ports

| Port | Proto | Bound by | Role | Source |
|---|---|---|---|---|
| 8095 | tcp | `mu2edaq-notify-server` | HTTP(S) API, web UI, SSE | `src/mu2edaq_notify/server/config.py:19`, `config/notify-server.yaml:8` |
| 8096 | tcp | `mu2edaq-notify-server`, only with `zmq.enabled` | ZeroMQ PULL ingest | `config.py:66`, `config/notify-server.yaml:80` |
| 28999 | udp, group 239.255.42.99 | discovery responder thread | mu2edaq-discovery DISCOVER/ANNOUNCE | `src/include/mu2edaq_notify/notify.hpp:106` |
| 18095 | tcp, 127.0.0.1 on the EC2 proxy | `ssh -R` from the server host | reverse tunnel to 8095 | `scripts/start-mu2edaq-notify-chain.sh:19` |
| 443 / 80 | tcp | Caddy on the EC2 proxy | public `notify.andrewnorman.org`, all paths → `https://127.0.0.1:18095` | `config/aws/Caddyfile` |
| 8080 | tcp | Caddy in the OKD pod | public `mu2edaq-pager.fnal.gov` via Route, all paths → `backend.url` | `helm/values.yaml:31`, `helm/templates/configmap.yaml:10-27` |
| 18095 | tcp, pod-local | optional `ssh -L` sidecar in the OKD pod | tunnel mode | `helm/values.yaml:66` |

Both proxies forward to an HTTPS backend with `tls_insecure_skip_verify`. On
the EC2 proxy that hop is loopback into an SSH tunnel. In the OKD chart it is
unconditional for any `https://` `backend.url`
(`helm/templates/configmap.yaml:21-25`), a real network hop from the cluster
to the server host, which leaves bearer tokens on that hop open to an on-path
attacker (PNS-014, S2).
