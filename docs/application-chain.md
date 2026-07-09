# Mu2e Notify End-to-End Application Chain

This document describes how an event travels through the Mu2e notification
system and where the reverse proxy fits.

## Components

| Component | Location | Role |
| --- | --- | --- |
| Publisher/client library | DAQ applications | submits notification events |
| `mu2edaq-notify-server` | local Mu2e host | stores events, exposes web/API endpoints, performs dispatch |
| SQLite database | `data/notify.db` | stores events, devices, filters, destinations |
| APNS destination | server-side dispatch config | sends push notifications to registered iPhones |
| SSH reverse tunnel | local host to EC2 | carries private traffic from EC2 back to local server |
| Caddy | AWS EC2 | public HTTPS termination and reverse proxy |
| Route 53 | AWS | DNS for `notify.andrewnorman.org` |
| iPhone app | iOS device | registers device, receives pushes, reads events |

## Public Access Path

```text
iPhone
  -> https://notify.andrewnorman.org/api/...
  -> Route 53
  -> EC2 54.70.241.171:443
  -> Caddy
  -> EC2 127.0.0.1:18095
  -> SSH reverse tunnel
  -> local 127.0.0.1:8095
  -> mu2edaq-notify-server
```

## Event Publishing Path

DAQ publishers can send events to the server API:

```bash
venv/bin/mu2edaq-notify \
  --server https://notify.andrewnorman.org \
  --token "$MU2EDAQ_NOTIFY_TOKEN" \
  send --severity error --source daq --title "Example" --body "Message"
```

If a publisher runs on the same local network as the server, it can also use the
local server endpoint directly. For phone enrollment and external clients, use
the public HTTPS URL.

## Device Registration Path

1. Operator opens the server enrollment page.
2. Server creates a short-lived enrollment token.
3. QR payload contains:

   ```text
   https://notify.andrewnorman.org
   ```

4. iPhone app scans the QR code.
5. iPhone registers with:

   ```text
   POST https://notify.andrewnorman.org/api/devices/register
   ```

6. Server stores the APNS device token in `data/notify.db`.

The registration URL comes from `server.base_url` in
`config/notify-server.yaml`. If QR codes or auto-config payloads contain the
wrong hostname, fix `server.base_url` and restart the local server.

## Push Notification Path

```text
Event accepted by server
  -> stored in database
  -> filters evaluated
  -> matching APNS destination selected
  -> Apple Push Notification service
  -> iPhone
```

APNS settings live under `apns:` in `config/notify-server.yaml`.

Required APNS items for live push delivery:

| Setting | Meaning |
| --- | --- |
| `enabled` | must be `true` for real APNS sends |
| `key_file` | Apple `.p8` APNS auth key |
| `key_id` | APNS key ID from Apple Developer |
| `team_id` | Apple Developer Team ID |
| `bundle_id` | iOS bundle ID, currently `gov.fnal.mu2e.Mu2eNotify` |
| `sandbox` | `true` for development builds, `false` for production/TestFlight |

If APNS is disabled, the server can still receive registrations and store
events, but it will not send real push notifications.

## Runtime Control

Use these scripts from the repo root:

```bash
scripts/start-mu2edaq-notify-proxy.sh
scripts/status-mu2edaq-notify-proxy.sh
scripts/stop-mu2edaq-notify-proxy.sh
```

The older server-only scripts still exist:

```bash
./start-mu2edaq-notify-server.sh
./stop-mu2edaq-notify-server.sh
```

Use the proxy scripts when the phone app must reach the service through
`https://notify.andrewnorman.org`.

## Health Checks

Local server:

```bash
curl -k https://127.0.0.1:8095/api/health
```

Public endpoint:

```bash
curl https://notify.andrewnorman.org/api/health
```

Remote tunnel from EC2:

```bash
ssh -i data/mu2edaq-notify-proxy.pem ec2-user@54.70.241.171 \
  'curl -k https://127.0.0.1:18095/api/health'
```

All three should return successfully when the chain is healthy.
