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
  -> AWS Route 53 A record, TTL 60
       ^ republished by the instance itself at every start
  -> the EC2 instance's current auto-assigned public IPv4
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
| AWS account / region | `600699205872` / `us-west-2` |
| EC2 instance ID | `i-000ee813ecd9a47b3` |
| EC2 type | `t3.nano` |
| Public IPv4 | **none held**; auto-assigned on each start, released on stop |
| Instance profile assoc. | `iip-assoc-04fc734ecacaf5cc2` (attached 31 Aug 2026) |
| Retired Elastic IP | `eipalloc-003c30b24e96af804` / `54.70.241.171` — released 31 Aug 2026; the account now holds no Elastic IP |
| Subnet | `subnet-7620d301` (`MapPublicIpOnLaunch: true` -- this is what supplies the address) |
| Security group | `sg-0bd09144a54c10361` |
| Instance profile | `mu2edaq-notify-proxy-dns` (Route 53 self-registration) |
| EC2 SSH user | `ec2-user` |
| SSH key file | `data/mu2edaq-notify-proxy.pem` |
| Route 53 zone | `andrewnorman.org` = `Z2OL4WKH228GKD` |
| Route 53 record | `notify.andrewnorman.org A <current address>`, TTL 60 |

There is deliberately **no Elastic IP**. See "Dynamic DNS registration" below.

Security group intent:

| Port | Source | Purpose |
| --- | --- | --- |
| `22/tcp` | `0.0.0.0/0` | SSH and reverse tunnel from changing client IPs |
| `80/tcp` | `0.0.0.0/0`, `::/0` | Let's Encrypt HTTP challenge and HTTP redirect |
| `443/tcp` | `0.0.0.0/0`, `::/0` | public HTTPS endpoint |

Do not expose the local server port `8095` publicly. The public side should
only be `80` and `443` on EC2.

## Dynamic DNS registration

### Why there is no Elastic IP

The proxy is a standby: it is normally **stopped**, and started only when the
public endpoint is wanted. An Elastic IP is billed whenever it is not attached
to a *running* instance, so a stopped proxy holding one pays for an address it
is not using -- and since 2024 every public IPv4 is billed anyway, so the EIP
bought nothing but stability. An auto-assigned address is released the moment
the instance stops and costs nothing while it is idle.

The price of dropping it is that the instance gets a **different public IPv4
on every start**. Rather than pin the instance to an address, the record is
made to follow the instance: at boot the instance reads its own address from
IMDSv2 and `UPSERT`s `notify.andrewnorman.org` to it.

### Mechanism

| Piece | Where it lives | Role |
| --- | --- | --- |
| `scripts/aws-notify-dns-update.sh` | repo; installed as `/usr/local/sbin/mu2edaq-notify-dns-update` | reads IMDSv2 `public-ipv4`, upserts the A record, waits for `INSYNC` |
| `config/aws/mu2edaq-notify-dns.conf` | `/etc/mu2edaq-notify-dns.conf` | zone, record, TTL, retry budget |
| `config/aws/mu2edaq-notify-dns.service` | `/etc/systemd/system/` | runs it at every boot, ordered **before** `caddy.service` |
| `config/aws/mu2edaq-notify-dns.timer` | `/etc/systemd/system/` | 5-minute drift guard; a no-op read when the record is already right |
| `config/aws/caddy.service.d/10-wait-for-dns.conf` | `/etc/systemd/system/caddy.service.d/` | orders Caddy after the DNS update on later boots |
| `config/aws/notify-dns-role.cfn.yaml` | CloudFormation | the IAM role and instance profile that permit exactly that one write |
| `config/aws/Caddyfile` | `/etc/caddy/Caddyfile` | site config, with the ACME issuer pinned to Let's Encrypt to match the CAA record |
| `scripts/update-notify-caa.sh` | repo | publishes, checks and removes the CAA record that pins issuance to the instance's own ACME account |
| `scripts/install-notify-dns-updater.sh` | repo | puts all of the above on the instance, or emits the equivalent user-data |
| `scripts/update-notify-dns.sh` | repo | operator-side inspect and repair, for when the instance cannot |

Three ordering and scoping decisions worth keeping:

* **Caddy starts after the DNS update, not before.** Caddy answers the Let's
  Encrypt HTTP-01 challenge on this host's public address. Starting it while
  the A record still points at the previous start's address risks a failed
  validation and a rate-limit penalty. The dependency is `Wants=`/`After=`,
  not `Requires=`: an existing certificate is valid for up to 90 days, so a
  Route 53 outage must not take the proxy offline.
* **The updater reads, then writes.** A boot where the address did not change
  costs one `ListResourceRecordSets` and no write.
* **The instance can only touch its own record.** The IAM policy allows
  `route53:ChangeResourceRecordSets` on zone `Z2OL4WKH228GKD` only under
  `ForAllValues:StringEquals` on the normalized record name
  (`notify.andrewnorman.org`), the record type (`A`) and the action (`UPSERT`).
  A compromised proxy cannot delete the record, create another name, or touch
  any other zone.

### Install the IAM role and instance profile

```bash
aws cloudformation deploy \
  --stack-name mu2edaq-notify-proxy-dns \
  --template-file config/aws/notify-dns-role.cfn.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2

aws ec2 associate-iam-instance-profile \
  --instance-id i-000ee813ecd9a47b3 \
  --iam-instance-profile Name=mu2edaq-notify-proxy-dns \
  --region us-west-2
```

The instance profile can be associated while the instance is stopped. Credentials
appear in IMDS on the next start.

### Install the updater on the instance

```bash
scripts/install-notify-dns-updater.sh                          # over SSH, running instance
scripts/install-notify-dns-updater.sh --emit-user-data --gzip > user-data.gz
```

The first form installs the updater, its units and the Caddyfile on a running
instance. The second prints the complete first-boot document (Caddy packages,
Caddyfile, DNS updater, then `systemctl start caddy`) for a rebuild, generated
from the repo files so the instance never runs a hand-pasted copy.

It is about 16.5 KB raw, which is over EC2's 16384-byte user-data limit, so
`--gzip` (about 6 KB) is the form to deploy — cloud-init decompresses it, and it
goes to EC2 as `fileb://`. Without `--gzip` the script warns on stderr when the
document is over the limit. Review it with `gunzip -c user-data.gz | less`.

### Verify

```bash
scripts/update-notify-dns.sh --check    # API address vs Route 53 vs DNS
dig +short notify.andrewnorman.org
```

On the instance:

```bash
systemctl status mu2edaq-notify-dns.service
systemctl list-timers mu2edaq-notify-dns.timer
sudo journalctl -u mu2edaq-notify-dns.service -n 50 --no-pager
sudo mu2edaq-notify-dns-update --dry-run
```

`scripts/status-mu2edaq-notify-proxy.sh` reports the EC2 address and the DNS
answer side by side and flags a mismatch as `STALE`; that mismatch is the one
new failure mode this design introduces.

### CAA: pinning issuance to our own ACME account

Retracting the A record closes the *window* in which the name points at an
address we no longer hold. The CAA record closes the *hole*.

Without it, anyone who is handed the released address controls ports 80 and 443
on it, can therefore satisfy an HTTP-01 or TLS-ALPN-01 challenge for
`notify.andrewnorman.org`, and can serve trusted TLS under our name to phones
that are still enrolling. With it, Let's Encrypt refuses to issue for the name
to any ACME account but ours: possession of the address stops being sufficient,
because the account key never leaves the instance.

```bash
scripts/update-notify-caa.sh            # reads the account off the instance
scripts/update-notify-caa.sh --check    # exits 1 if the pin is missing or wrong
dig +short notify.andrewnorman.org CAA
```

The record set written is:

```text
notify.andrewnorman.org. 300 IN CAA 0 issue "letsencrypt.org;accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/<N>;validationmethods=http-01,tls-alpn-01"
notify.andrewnorman.org. 300 IN CAA 0 issuewild ";"
```

`accounturi` and `validationmethods` are the RFC 8657 extensions to CAA; Let's
Encrypt has enforced both in production since December 2022. `issuewild ";"`
denies wildcard issuance outright, since this name never needs one.

Four things about this that matter:

* **It is scoped to the subdomain, never the apex.** Other names in
  `andrewnorman.org` are served by CloudFront with ACM certificates. A CAA
  record at the apex naming only `letsencrypt.org` would apply to every name
  without its own CAA and break those renewals — silently, at their next
  renewal. `update-notify-caa.sh` refuses to write at the apex.
* **The account URI is read off the instance, not configured.** Caddy creates
  the account, so the script searches Caddy's storage for it over SSH and
  refuses to guess if it finds more than one. On this instance Caddy runs with
  an empty `$HOME`, so its storage resolves to the *relative* `./caddy` under
  the unit's `WorkingDirectory` — the account lives at
  `/var/lib/caddy/caddy/acme/acme-v02.api.letsencrypt.org-directory/users/default/default.json`,
  not the `~/.local/share/caddy` the documentation implies. Searching rather
  than reading a fixed path is what makes that a non-issue.
* **A rebuilt instance gets a new ACME account.** The old pin then forbids
  issuance, and because Caddy renews at two thirds of the 90-day lifetime the
  failure surfaces *weeks* after the rebuild. Re-running
  `scripts/update-notify-caa.sh` is a mandatory rebuild step, and
  `--check` after any rebuild is worth the five seconds.
* **The instance cannot write this record.** Its IAM policy covers `UPSERT` of
  the `A` record only, so a compromised proxy cannot widen its own issuance
  policy. Only the operator writes CAA.

`config/aws/Caddyfile` pins the issuer to match:

```caddy
{
	acme_ca https://acme-v02.api.letsencrypt.org/directory
}
```

Caddy would otherwise be free to fall back to a second CA that this CAA record
can only refuse. Change the two together, or `scripts/update-notify-caa.sh
--remove` if the pin ever has to come off in a hurry.

### Teardown retracts the record, conditionally

`scripts/stop-mu2edaq-notify-chain.sh` parks the record on `192.0.2.1` before
stopping the instance, because a released address goes back to the AWS pool and
a record still pointing at it would let its next holder obtain a Let's Encrypt
certificate for `notify.andrewnorman.org`.

It skips the retraction when there is nothing to dangle — an Elastic IP still
attached, no public address at all — or when the record points somewhere that is
not this instance. And the start path repairs a stale record itself rather than
relying on the instance-side updater, because the same script is what retracted
it. See "Why stopping the chain retracts the record, and when it does not" in
`docs/reverse-proxy-operations.md`.

### Break-glass

If the record is stale -- the instance-side updater failed, or the instance
profile is not attached yet:

```bash
scripts/update-notify-dns.sh              # publish the API address from here
```

`MU2EDAQ_NOTIFY_DNS_LOCAL_FALLBACK=1 scripts/start-mu2edaq-notify-chain.sh`
does the same thing inline during a chain start.

## EC2 Caddy Setup

Caddy terminates public HTTPS on the EC2 instance. It obtains and renews the
trusted Let's Encrypt certificate for `notify.andrewnorman.org` automatically.

The Caddyfile lives in the repo at `config/aws/Caddyfile` and is installed by
`scripts/install-notify-dns-updater.sh`, which validates it with `caddy
validate` before replacing the installed copy and reloads rather than restarts a
running Caddy. Do not edit it on the instance.

The `tls_insecure_skip_verify` setting is only for the private hop from Caddy to
the SSH reverse-tunnel listener on `127.0.0.1`. The public browser/iPhone side
still uses a normal trusted certificate from Let's Encrypt.

Install or refresh Caddy on the EC2 host. `HostKeyAlias` pins the host key to
the stable public name instead of accumulating a `known_hosts` entry per start:

```bash
ssh -i data/mu2edaq-notify-proxy.pem \
  -o HostKeyAlias=notify.andrewnorman.org \
  ec2-user@notify.andrewnorman.org
```

If DNS is stale, address the instance directly instead:

```bash
PROXY=$(aws ec2 describe-instances --region us-west-2 \
  --instance-ids i-000ee813ecd9a47b3 \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
ssh -i data/mu2edaq-notify-proxy.pem \
  -o HostKeyAlias=notify.andrewnorman.org ec2-user@"$PROXY"
```

Then on EC2:

```bash
sudo mkdir -p /etc/caddy
sudo vi /etc/caddy/Caddyfile
sudo systemctl enable --now caddy
sudo systemctl status caddy
```

The Caddy half of the EC2 bootstrap is:

```text
scripts/aws-proxy-user-data.sh
```

It installs and *enables* Caddy but neither configures nor starts it: the
Caddyfile comes from `config/aws/Caddyfile` and the start is ordered after the
DNS registration. Generate the whole first-boot document with

```bash
scripts/install-notify-dns-updater.sh --emit-user-data --gzip > user-data.gz
gunzip -c user-data.gz | less        # review it
```

It is now about 16.5 KB raw, over EC2's 16 KB user-data limit, so `--gzip` is
the form that fits (cloud-init decompresses it; pass it as `fileb://`).
Reviewing it before use still matters, because package installation details
change across Amazon Linux releases.

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

`base_url` is now only a fallback. The URL embedded in QR enrollment payloads
and iPhone auto-configuration responses is derived from the request that asked
for it (`server.dynamic_base_url`, on by default), so enrolling a phone against
this chain means opening
`https://notify.andrewnorman.org/devices/enroll` -- not the OKD hostname, and
not `https://127.0.0.1:8095`. See "Registration and Enrollment" in
`docs/application-chain.md`.

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
  -o HostKeyAlias=notify.andrewnorman.org \
  -R 127.0.0.1:18095:127.0.0.1:8095 \
  ec2-user@notify.andrewnorman.org
```

The scripts do not spell out an address: they ask the EC2 API for the current
one (`scripts/notify-proxy-common.sh`) and fall back to DNS.

Meaning:

| Segment | Meaning |
| --- | --- |
| `-R 127.0.0.1:18095:127.0.0.1:8095` | Open EC2-local port `18095` and forward it back to local port `8095` |
| `127.0.0.1:18095` | Only Caddy on EC2 can reach the tunnel listener |
| `127.0.0.1:8095` | The local notification server |
| `ExitOnForwardFailure=yes` | Fail immediately if EC2 cannot bind the remote tunnel port |
| `HostKeyAlias=notify.andrewnorman.org` | Verify the host key against the stable name, not the per-start IPv4 |

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
