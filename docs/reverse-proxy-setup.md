# Mu2e Notify AWS Reverse Proxy Setup

This document records the AWS reverse-proxy setup used to expose the local
Mu2e notification server to iPhones at:

```text
https://notify.andrewnorman.org
```

The proxy exists because phones need a publicly reachable HTTPS endpoint with a
trusted certificate, while the notification server itself runs on the local
Mu2e host.

## Architecture

```text
iPhone / browser
  -> https://notify.andrewnorman.org
  -> AWS Route 53 A record
  -> AWS EC2 public IP 54.70.241.171
  -> Caddy on EC2, ports 80/443
  -> SSH reverse tunnel on EC2 127.0.0.1:18095
  -> local Mu2e host 127.0.0.1:8095
  -> mu2edaq-notify-server
```

The local server is not directly opened to the internet. EC2 only receives
public HTTPS traffic and SSH from the local host.

## AWS Resources

Current resources:

| Resource | Value |
| --- | --- |
| Public hostname | `notify.andrewnorman.org` |
| EC2 instance ID | `i-000ee813ecd9a47b3` |
| EC2 type | `t3.nano` |
| Elastic IP | `54.70.241.171` |
| Security group | `sg-0bd09144a54c10361` |
| EC2 SSH user | `ec2-user` |
| SSH key file | `data/mu2edaq-notify-proxy.pem` |
| Route 53 record | `notify.andrewnorman.org A 54.70.241.171` |

Security group intent:

| Port | Source | Purpose |
| --- | --- | --- |
| `22/tcp` | `0.0.0.0/0` | SSH and reverse tunnel from changing client IPs |
| `80/tcp` | `0.0.0.0/0`, `::/0` | Let's Encrypt HTTP challenge and HTTP redirect |
| `443/tcp` | `0.0.0.0/0`, `::/0` | public HTTPS endpoint |

Do not expose the local server port `8095` publicly. The public side should
only be `80` and `443` on EC2.

## DNS

Route 53 points the public name at the EC2 Elastic IP.

The checked-in change batch is:

```text
data/route53-notify-upsert.json
```

Apply or reapply it with:

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id <HOSTED_ZONE_ID> \
  --change-batch file://data/route53-notify-upsert.json
```

Verify DNS:

```bash
dig +short notify.andrewnorman.org
```

Expected result:

```text
54.70.241.171
```

## EC2 Caddy Setup

Caddy terminates public HTTPS on the EC2 instance. It obtains and renews the
trusted Let's Encrypt certificate for `notify.andrewnorman.org` automatically.

The live Caddyfile is:

```caddy
notify.andrewnorman.org {
    encode gzip
    reverse_proxy https://127.0.0.1:18095 {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
```

The `tls_insecure_skip_verify` setting is only for the private hop from Caddy to
the SSH reverse-tunnel listener on `127.0.0.1`. The public browser/iPhone side
still uses a normal trusted certificate from Let's Encrypt.

Install or refresh Caddy on the EC2 host:

```bash
ssh -i data/mu2edaq-notify-proxy.pem ec2-user@54.70.241.171
```

Then on EC2:

```bash
sudo mkdir -p /etc/caddy
sudo vi /etc/caddy/Caddyfile
sudo systemctl enable --now caddy
sudo systemctl status caddy
```

The EC2 bootstrap script for this host is:

```text
scripts/aws-proxy-user-data.sh
```

If the instance is rebuilt, review that script before use because package
installation details can change across Amazon Linux releases.

## Local Server Configuration

The local server config is:

```text
config/notify-server.yaml
```

Relevant settings:

```yaml
server:
  host: 0.0.0.0
  port: 8095
  base_url: "https://notify.andrewnorman.org"
```

`base_url` is important. It controls the URL embedded in QR enrollment payloads
and iPhone auto-configuration responses. It must be the public HTTPS URL, not
`localhost` and not the private EC2 tunnel address.

The current local server also has direct TLS enabled with a certificate for
`kaon.andrewnorman.org`. That is acceptable for the private Caddy-to-tunnel hop.
The phone only sees `https://notify.andrewnorman.org`.

Do not copy API tokens into documentation or issue reports. Tokens live in local
configuration only.

## SSH Reverse Tunnel

The tunnel is initiated from the local Mu2e host to EC2:

```bash
ssh -i data/mu2edaq-notify-proxy.pem \
  -N \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=accept-new \
  -R 127.0.0.1:18095:127.0.0.1:8095 \
  ec2-user@54.70.241.171
```

Meaning:

| Segment | Meaning |
| --- | --- |
| `-R 127.0.0.1:18095:127.0.0.1:8095` | Open EC2-local port `18095` and forward it back to local port `8095` |
| `127.0.0.1:18095` | Only Caddy on EC2 can reach the tunnel listener |
| `127.0.0.1:8095` | The local notification server |
| `ExitOnForwardFailure=yes` | Fail immediately if EC2 cannot bind the remote tunnel port |

## Persistent macOS LaunchAgents

Two user LaunchAgents keep the local pieces running:

| Label | Purpose |
| --- | --- |
| `org.mu2edaq.notify-server` | starts `mu2edaq-notify-server` |
| `org.mu2edaq.notify-proxy-tunnel` | starts the SSH reverse tunnel |

Installed paths:

```text
~/Library/LaunchAgents/org.mu2edaq.notify-server.plist
~/Library/LaunchAgents/org.mu2edaq.notify-proxy-tunnel.plist
```

Useful commands:

```bash
launchctl print gui/$(id -u)/org.mu2edaq.notify-server
launchctl print gui/$(id -u)/org.mu2edaq.notify-proxy-tunnel

launchctl kickstart -k gui/$(id -u)/org.mu2edaq.notify-server
launchctl kickstart -k gui/$(id -u)/org.mu2edaq.notify-proxy-tunnel
```

Logs:

```text
data/notify-server.launchd.log
data/notify-server.launchd.err
data/notify-proxy-tunnel.launchd.log
data/notify-proxy-tunnel.launchd.err
```

## Verification

From the repo root:

```bash
scripts/status-mu2edaq-notify-proxy.sh
curl -fsS https://notify.andrewnorman.org/api/health
```

On EC2:

```bash
sudo systemctl status caddy
sudo journalctl -u caddy -n 100 --no-pager
```

Expected public health check:

```text
HTTP 200
```
