# Reverse Proxy Operations Runbook

This runbook covers day-to-day start, stop, status, and troubleshooting for the
Mu2e Notify public reverse-proxy chain.

## Start

From the repo root:

```bash
scripts/start-mu2edaq-notify-chain.sh
```

The script:

1. Starts the EC2 proxy instance if it is stopped.
2. Waits for EC2 instance and system status checks.
3. Starts remote Caddy on EC2 with `sudo systemctl start caddy`.
4. Starts the SSH reverse tunnel:

   ```text
   EC2 127.0.0.1:18095 -> local 127.0.0.1:8095
   ```

5. Verifies the remote tunnel bind exists on EC2.
6. Starts the local notification server with `./start-mu2edaq-notify-server.sh`.
7. Verifies local, tunnel, and public health endpoints.

For shell tracing in addition to the normal timestamped status output:

```bash
MU2EDAQ_NOTIFY_DEBUG=1 scripts/start-mu2edaq-notify-chain.sh
```

On failure, the start script prints local listener state, pidfiles, recent
tunnel logs, EC2 state/status, remote Caddy status, remote listeners, and recent
Caddy journal lines.

Useful environment overrides:

| Variable | Default | Meaning |
| --- | --- | --- |
| `MU2EDAQ_NOTIFY_PROXY_INSTANCE_ID` | `i-000ee813ecd9a47b3` | EC2 proxy instance |
| `MU2EDAQ_NOTIFY_PUBLIC_URL` | `https://notify.andrewnorman.org` | public health-check URL base |
| `MU2EDAQ_NOTIFY_PROXY_HOST` | `54.70.241.171` | EC2 Elastic IP |
| `MU2EDAQ_NOTIFY_PROXY_USER` | `ec2-user` | EC2 SSH user |
| `MU2EDAQ_NOTIFY_PROXY_KEY` | `data/mu2edaq-notify-proxy.pem` | SSH private key |
| `MU2EDAQ_NOTIFY_PROXY_REMOTE_BIND` | `127.0.0.1:18095` | EC2-side tunnel bind |
| `MU2EDAQ_NOTIFY_PROXY_LOCAL_TARGET` | `127.0.0.1:8095` | local server target |
| `MU2EDAQ_NOTIFY_SSH_WAIT_TRIES` | `36` | SSH readiness attempts before failing |

For partial maintenance when EC2 is already running and you do not want the
script to manage the instance, use the lower-level proxy script:

```bash
scripts/start-mu2edaq-notify-proxy.sh
```

## Stop

Stop the full chain:

```bash
scripts/stop-mu2edaq-notify-chain.sh
```

The full stop script unloads matching LaunchAgents if they are loaded, stops
manual pidfile-managed local processes, stops remote Caddy, and stops the EC2
proxy instance.

The stop script is idempotent and prints verification for each stage, including
local port `8095`, SSH tunnel state, remote Caddy state when reachable, and the
final EC2 instance state.

For partial maintenance, `scripts/stop-mu2edaq-notify-proxy.sh` still stops the
manual SSH tunnel and can optionally stop the local server or remote Caddy with
environment flags.

## Status

```bash
scripts/status-mu2edaq-notify-proxy.sh
```

The script reports:

| Check | Source |
| --- | --- |
| local notify server PID | `data/notify-server.pid` |
| SSH tunnel PID | `data/mu2edaq-notify-proxy-tunnel.pid` |
| remote Caddy state | `systemctl is-active caddy` over SSH |
| public health endpoint | `https://notify.andrewnorman.org/api/health` |

## Logs

Local manually started server:

```text
data/notify-server.log
```

Local manually started tunnel:

```text
data/mu2edaq-notify-proxy-tunnel.log
```

LaunchAgent server logs:

```text
data/notify-server.launchd.log
data/notify-server.launchd.err
```

LaunchAgent tunnel logs:

```text
data/notify-proxy-tunnel.launchd.log
data/notify-proxy-tunnel.launchd.err
```

Remote Caddy logs:

```bash
ssh -i data/mu2edaq-notify-proxy.pem ec2-user@54.70.241.171 \
  'sudo journalctl -u caddy -n 100 --no-pager'
```

## Common Failures

### Public URL returns 502 or 503

Likely causes:

| Check | Command |
| --- | --- |
| Tunnel running locally | `scripts/status-mu2edaq-notify-proxy.sh` |
| EC2 can see tunnel port | `ssh -i data/mu2edaq-notify-proxy.pem ec2-user@54.70.241.171 'curl -k -sS -o /dev/null -w "%{http_code}\n" https://127.0.0.1:18095/api/health'` |
| Local server is healthy | `curl -k -sS https://127.0.0.1:8095/api/health` |
| Caddy is active | `ssh -i data/mu2edaq-notify-proxy.pem ec2-user@54.70.241.171 'systemctl is-active caddy'` |

Restart the chain:

```bash
scripts/stop-mu2edaq-notify-proxy.sh
scripts/start-mu2edaq-notify-proxy.sh
```

### SSH tunnel fails to start

Check:

```bash
tail -n 50 data/mu2edaq-notify-proxy-tunnel.log
ssh -i data/mu2edaq-notify-proxy.pem ec2-user@54.70.241.171 'ss -ltnp | grep 18095 || true'
```

Common causes:

| Symptom | Fix |
| --- | --- |
| `remote port forwarding failed` | another tunnel is already bound to `127.0.0.1:18095` on EC2 |
| `Permission denied (publickey)` | wrong key file or EC2 key pair changed |
| connection timeout | security group, local firewall, or EC2 instance state |

### iPhone registration QR points to the wrong host

Check `server.base_url` in:

```text
config/notify-server.yaml
```

It should be:

```yaml
base_url: "https://notify.andrewnorman.org"
```

Restart the local server after changing it.

### TLS or certificate error on the phone

The iPhone should connect to:

```text
https://notify.andrewnorman.org
```

That certificate is managed by Caddy and Let's Encrypt on EC2. Check it with:

```bash
curl -v https://notify.andrewnorman.org/api/health
```

Do not point the phone at `https://kaon.andrewnorman.org:8095` unless the phone
can reach that host and trusts that certificate path.

## Rebuild Checklist

If EC2 must be rebuilt:

1. Create or restore the EC2 instance and Elastic IP.
2. Ensure the security group allows `22`, `80`, and `443`.
3. Update `data/route53-notify-upsert.json` if the Elastic IP changes.
4. Apply the Route 53 record.
5. Install Caddy and configure `/etc/caddy/Caddyfile`.
6. Start Caddy with `sudo systemctl enable --now caddy`.
7. Ensure `data/mu2edaq-notify-proxy.pem` matches the EC2 key pair.
8. Start the local chain with `scripts/start-mu2edaq-notify-proxy.sh`.
9. Verify `https://notify.andrewnorman.org/api/health` returns HTTP 200.
