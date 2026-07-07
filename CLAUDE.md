# CLAUDE.md — mu2edaq-phone-notification-system

## Project Overview

Push-notification pipeline for the Mu2e DAQ: DAQ applications publish
error/warning events to a central Flask server (HTTP JSON, plus a ZeroMQ
compatibility listener), which filters them through DB-stored rules and
delivers to iPhones (APNs), Slack, and Discord. Includes a stdlib-only
Python publisher library, a C++17 publisher library (libcurl/CMake), a
SwiftUI iPhone app with QR-code enrollment, and a Tailwind/htmx web UI
with a live SSE dashboard. Production operations infrastructure —
correctness and reliability over convenience.

## Setup and Running

```bash
./bootstrap.sh                       # venv + deps + editable install
./start-mu2edaq-notify-server.sh     # background server, log in data/
./stop-mu2edaq-notify-server.sh
cmake -S . -B build && cmake --build build     # C++ library
cd ios/Mu2eNotify && xcodegen generate         # iOS Xcode project
```

## Architecture

- `src/mu2edaq_notify/events.py` — shared event schema/normalization
- `src/mu2edaq_notify/publisher.py` — stdlib-only HTTP publisher (never
  raises on delivery failure); `cli.py` is the `mu2edaq-notify` CLI
- `src/mu2edaq_notify/server/` — `config.py` (CLI > env > YAML > defaults),
  `storage.py` (SQLAlchemy: Event/Device/FilterRule/Destination/Delivery),
  `filters.py` (glob + regex + severity matching), `dispatch.py`
  (daemon-thread queue worker, rate limiting), `destinations.py` (APNs
  HTTP/2+JWT with log-only fallback, Slack/Discord webhooks), `auth.py`
  (API tokens, hashed device tokens, JWT enrollment tokens, OIDC),
  `zmq_listener.py`, `sse.py`, `app.py` (Flask blueprints `api` + `web`),
  `cli.py` (entry point wiring everything)
- `web/templates/` — Jinja2 + Tailwind CDN + htmx; dashboard subscribes
  to `/api/stream` (SSE)
- `src/cpp/notify.cpp` + `src/include/mu2edaq_notify/notify.hpp` — C++
  publisher; self-contained mu2edaq-discovery multicast client
- `ios/Mu2eNotify/` — SwiftUI; `AppState` owns registration + events,
  AppDelegate handles APNs token callbacks

Threading: dispatcher, zmq listener, retention pruner, and discovery
responder are daemon threads; Flask runs threaded. Storage opens a
session per operation (thread-safe).

## Configuration Schema

See `config/notify-server.yaml` (fully commented). Keys: `server`
(host/port/base_url/secret_key), `database` (SQLAlchemy url,
retention_days), `auth` (api_tokens, enrollment secret/TTL, oidc),
`apns` (key_file/key_id/team_id/bundle_id/sandbox/enabled), `zmq`
(connect/bind/defaults), `discovery`, `dispatch` (rate_limit_seconds),
`seed` (first-run filters/destinations).

## Testing

```bash
venv/bin/pytest              # Python suite; zmq tests skip without pyzmq
ctest --test-dir build       # CppUnit (skipped when CppUnit missing)
```

iOS tests: `Mu2eNotifyTests` scheme in Xcode. In dispatcher tests call
`_dispatch()` directly (synchronous) instead of starting the thread.
APNs stays in log-only mode in all tests — no network to Apple.
