# Reverse Proxy Operations Runbook

This runbook covers day-to-day start, stop, status, and troubleshooting for the
Mu2e Notify public reverse-proxy chain.

## Start

From the repo root:

```bash
scripts/start-mu2edaq-notify-chain.sh
```

The script:

1. Starts the EC2 proxy instance if it is stopped, and waits for the instance
   and system status checks.
2. Reads the public IPv4 EC2 assigned **for this start**, then checks
   **Route 53 itself** for the A record. If it disagrees, the instance-side
   updater gets ~30 s to publish it, and failing that the script publishes it
   from here. Resolver convergence is then waited on separately and only
   warned about.
3. Verifies SSH to that address.
4. Starts remote Caddy on EC2 with `sudo systemctl start caddy`.
5. Starts the SSH reverse tunnel and verifies the remote bind:

   ```text
   EC2 127.0.0.1:18095 -> local 127.0.0.1:8095
   ```

6. Starts the local notification server with `./start-mu2edaq-notify-server.sh`.
7. Verifies EC2 can reach the local server through the tunnel.
8. Verifies the public health endpoint.

Step 2 is the one that is new with dynamic addressing, and it deliberately does
not depend on the instance-side updater: this script is also what *stops* the
chain, stopping can retract the record, so it has to be able to put it back.
`MU2EDAQ_NOTIFY_DNS_LOCAL_FALLBACK=0` reduces it to a warning.

Two distinctions worth keeping straight when reading its output:

* **Route 53 vs a resolver.** The `[record]` lines are the authoritative value
  and change immediately. The `[dns]` lines are this host's resolver, which
  caches the previous answer for up to the 60 s TTL — a stale `[dns]` line with
  a correct `[record]` line is normal and expires on its own.
* **What actually needs DNS.** The tunnel and Caddy do not; only phones and the
  final public health check do. So a resolver still catching up is a warning,
  not a failure.

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
| `MU2EDAQ_NOTIFY_PROXY_REGION` | `us-west-2` | region for every `aws` call |
| `MU2EDAQ_NOTIFY_PUBLIC_URL` | `https://notify.andrewnorman.org` | public health-check URL base |
| `MU2EDAQ_NOTIFY_PROXY_DNS_NAME` | `notify.andrewnorman.org` | public name, and the SSH `HostKeyAlias` |
| `MU2EDAQ_NOTIFY_ROUTE53_ZONE_ID` | `Z2OL4WKH228GKD` | hosted zone holding that record |
| `MU2EDAQ_NOTIFY_DNS_TTL` | `60` | TTL used when republishing |
| `MU2EDAQ_NOTIFY_PROXY_HOST` | *(unset)* | override the address; unset means ask the EC2 API, then DNS |
| `MU2EDAQ_NOTIFY_RECORD_WAIT_TRIES` | `6` | Route 53 checks giving the instance-side updater a chance to publish |
| `MU2EDAQ_NOTIFY_RECORD_WAIT_DELAY` | `5` | seconds between those checks |
| `MU2EDAQ_NOTIFY_DNS_WAIT_TRIES` | `12` | resolver convergence checks before warning |
| `MU2EDAQ_NOTIFY_DNS_WAIT_DELAY` | `5` | seconds between those checks |
| `MU2EDAQ_NOTIFY_DNS_LOCAL_FALLBACK` | `1` | repair a stale record from the operator host during a chain start; `0` = warn only |
| `MU2EDAQ_NOTIFY_DNS_RETRACT` | `1` | park the record on the sink address when the chain is stopped; `0` = leave it |
| `MU2EDAQ_NOTIFY_DNS_SINK` | `192.0.2.1` | unroutable address the record is parked on (RFC 5737 TEST-NET-1) |
| `MU2EDAQ_NOTIFY_CAA_CA` | `letsencrypt.org` | CA named in the CAA record |
| `MU2EDAQ_NOTIFY_CAA_VALIDATION_METHODS` | `http-01,tls-alpn-01` | RFC 8657 `validationmethods`; empty omits the parameter |
| `MU2EDAQ_NOTIFY_CAA_TTL` | `300` | TTL of the CAA record |
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
ssh -i data/mu2edaq-notify-proxy.pem \
  -o HostKeyAlias=notify.andrewnorman.org \
  ec2-user@notify.andrewnorman.org \
  'sudo journalctl -u caddy -n 100 --no-pager'
```

DNS registration log on EC2:

```bash
ssh -i data/mu2edaq-notify-proxy.pem \
  -o HostKeyAlias=notify.andrewnorman.org \
  ec2-user@notify.andrewnorman.org \
  'sudo journalctl -u mu2edaq-notify-dns.service -n 50 --no-pager; \
   sudo tail -n 30 /var/log/mu2edaq-notify-dns.log'
```

## Common Failures

### Public URL returns 502 or 503

Likely causes:

| Check | Command |
| --- | --- |
| Tunnel running locally | `scripts/status-mu2edaq-notify-proxy.sh` |
| EC2 can see tunnel port | `ssh -i data/mu2edaq-notify-proxy.pem -o HostKeyAlias=notify.andrewnorman.org ec2-user@notify.andrewnorman.org 'curl -k -sS -o /dev/null -w "%{http_code}\n" https://127.0.0.1:18095/api/health'` |
| Local server is healthy | `curl -k -sS https://127.0.0.1:8095/api/health` |
| Caddy is active | `ssh -i data/mu2edaq-notify-proxy.pem -o HostKeyAlias=notify.andrewnorman.org ec2-user@notify.andrewnorman.org 'systemctl is-active caddy'` |
| DNS matches the instance | `scripts/update-notify-dns.sh --check` |

Restart the chain:

```bash
scripts/stop-mu2edaq-notify-proxy.sh
scripts/start-mu2edaq-notify-proxy.sh
```

### SSH tunnel fails to start

Check:

```bash
tail -n 50 data/mu2edaq-notify-proxy-tunnel.log
ssh -i data/mu2edaq-notify-proxy.pem \
  -o HostKeyAlias=notify.andrewnorman.org \
  ec2-user@notify.andrewnorman.org 'ss -ltnp | grep 18095 || true'
```

Common causes:

| Symptom | Fix |
| --- | --- |
| `remote port forwarding failed` | another tunnel is already bound to `127.0.0.1:18095` on EC2 |
| `Permission denied (publickey)` | wrong key file or EC2 key pair changed |
| connection timeout | security group, local firewall, or EC2 instance state |
| SSH goes to the wrong host, or `HOST KEY VERIFICATION FAILED` | stale DNS: the name still resolves to a previous start's address, which AWS may have handed to someone else. Run `scripts/update-notify-dns.sh --check`, then address the instance by its API address. |

### DNS does not follow the instance

The symptom is `scripts/status-mu2edaq-notify-proxy.sh` reporting
`dns record: ... (STALE, want <address>)`, or the chain start warning at step 2.
The public endpoint is unreachable while the tunnel and Caddy are fine.

Work down this list:

| Check | Command | Meaning |
| --- | --- | --- |
| Is the record actually stale? | `scripts/update-notify-dns.sh --check` | exits 1 when Route 53 disagrees with the EC2 API |
| Did the boot unit run? | `sudo systemctl status mu2edaq-notify-dns.service` | `inactive (dead)` with no start means it is not enabled |
| Why did it fail? | `sudo journalctl -u mu2edaq-notify-dns.service -n 50` | see below |
| Are credentials present? | `curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/` | empty means the instance profile is not attached |

| Journal line | Cause | Fix |
| --- | --- | --- |
| `no IMDSv2 token` | IMDS unreachable or hop limit too low | `aws ec2 modify-instance-metadata-options --http-put-response-hop-limit 2` |
| `has no public IPv4` | the subnet is not auto-assigning one | check `MapPublicIpOnLaunch` on `subnet-7620d301`; the instance may need relaunching in a subnet that does |
| `AccessDenied` on `ChangeResourceRecordSets` | instance profile missing, or the record name does not match the policy condition | re-deploy `config/aws/notify-dns-role.cfn.yaml`, re-associate the profile |
| `AccessDenied` on `GetChange` | policy drift | the policy needs `route53:GetChange` on `arn:aws:route53:::change/*` |

Repair the record immediately from the operator host, then fix the instance:

```bash
scripts/update-notify-dns.sh
scripts/install-notify-dns-updater.sh
```

A phone that cached the old address keeps using it for up to the 60 s TTL after
the record is corrected.

### iPhone registration QR points to the wrong host

The QR code carries whatever URL the *enrollment page itself* was opened on, so
this is almost always a matter of which URL the browser used, not of
configuration. To enrol a phone against the AWS chain, open

```text
https://notify.andrewnorman.org/devices/enroll
```

and not the OKD hostname or `https://127.0.0.1:8095`.

If it is still wrong, the request host was rejected and the server fell back to
`server.base_url`. The server log says which:

```text
request host X is not in server.trusted_hosts; using the configured base_url Y
ignoring malformed request host X; using Y
```

Then check `server.trusted_hosts` and `server.dynamic_base_url` in
`config/notify-server.yaml`; `dynamic_base_url: false` pins every payload to
`server.base_url`. A restart is only needed if you change the file.

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

1. Create or restore the EC2 instance. **No Elastic IP**: launch it in a subnet
   with `MapPublicIpOnLaunch: true` (or pass `--associate-public-ip-address`),
   because the auto-assigned address is what the instance publishes.
2. Ensure the security group allows `22`, `80`, and `443`.
3. Deploy the IAM role and attach the instance profile:

   ```bash
   aws cloudformation deploy \
     --stack-name mu2edaq-notify-proxy-dns \
     --template-file config/aws/notify-dns-role.cfn.yaml \
     --capabilities CAPABILITY_NAMED_IAM --region us-west-2
   aws ec2 associate-iam-instance-profile \
     --instance-id <INSTANCE_ID> \
     --iam-instance-profile Name=mu2edaq-notify-proxy-dns --region us-west-2
   ```

4. Generate and review the first-boot document, or install onto the running
   instance:

   ```bash
   scripts/install-notify-dns-updater.sh --emit-user-data --gzip > /tmp/user-data.gz
   gunzip -c /tmp/user-data.gz | bash -n
   # or, on a running instance:
   scripts/install-notify-dns-updater.sh
   ```

5. Confirm the record followed: `scripts/update-notify-dns.sh --check`.
6. **Republish the CAA pin.** A rebuilt instance has a new ACME account, and the
   old pin forbids issuance for the name:

   ```bash
   scripts/update-notify-caa.sh
   scripts/update-notify-caa.sh --check
   ```

   Skipping this does not break anything today; it breaks certificate renewal
   weeks later.
7. Install `/etc/caddy/Caddyfile` if the generated document was not used
   (`scripts/install-notify-dns-updater.sh` does it from `config/aws/Caddyfile`),
   and start Caddy **after** the DNS registration.
8. Ensure `data/mu2edaq-notify-proxy.pem` matches the EC2 key pair.
9. Start the local chain with `scripts/start-mu2edaq-notify-chain.sh`.
10. Verify `https://notify.andrewnorman.org/api/health` returns HTTP 200.

### Certificate renewal fails after a rebuild

The symptom is Caddy logging ACME failures for `notify.andrewnorman.org`
mentioning CAA, weeks after an instance rebuild, while everything else works.
The public endpoint keeps serving until the existing certificate expires.

Cause: the CAA record pins issuance to one ACME account URI, and a rebuilt
instance's Caddy registered a new account when it found empty storage. Caddy
renews at two thirds of the 90-day lifetime, so the mismatch is invisible for
weeks.

```bash
scripts/update-notify-caa.sh --check    # names the account that is not authorized
scripts/update-notify-caa.sh            # republish the pin from the instance
```

If issuance has to be unblocked immediately and the account cannot be read:

```bash
scripts/update-notify-caa.sh --remove   # back the pin out entirely
```

Then republish it once the instance is healthy. Other CAA-shaped failures:

| Symptom | Cause | Fix |
| --- | --- | --- |
| ACME fails right after the pin is first written | Caddy fell back to a CA the record does not name | confirm `acme_ca` in `config/aws/Caddyfile` matches `--ca`, and re-run `scripts/install-notify-dns-updater.sh` |
| ACME fails for a wildcard or DNS challenge | `validationmethods=http-01,tls-alpn-01` forbids `dns-01`, and `issuewild ";"` forbids wildcards | widen deliberately with `--validation-methods` / `--no-issuewild` |
| ACM renewals fail elsewhere in `andrewnorman.org` | a CAA record was written at the zone apex | remove it; pin subdomains only. `update-notify-caa.sh` refuses the apex for this reason |

## Why stopping the chain retracts the record, and when it does not

`scripts/stop-mu2edaq-notify-chain.sh` points `notify.andrewnorman.org` at
`192.0.2.1` **before** it stops the instance, and the next start republishes the
real address.

It retracts only when there is something to dangle and the record is ours. The
verdict comes from `notify_proxy_retract_decision()` and is logged:

| Verdict | Meaning |
| --- | --- |
| `retract` | auto-assigned address, record points at it — park it on the sink |
| `skip elastic-ip <alloc>` | an Elastic IP is attached, so the address survives the stop and cannot be reassigned to anyone else |
| `skip not-ours <record> <address>` | the record points somewhere else (the OKD proxy, say); not this script's to move |
| `skip no-address` | the instance has no public address to release |
| `skip disabled` | `MU2EDAQ_NOTIFY_DNS_RETRACT=0` |

Retracting unconditionally was a real fault, not a hypothetical one: with the
Elastic IP still attached the address never left the account, so the retraction
bought nothing and the record stayed on `192.0.2.1` until it was republished by
hand.

This is not tidiness. Stopping the instance returns its public IPv4 to the AWS
pool, and an A record still pointing there is a dangling record: whoever is
handed that address next controls port 80 on it, can therefore satisfy a Let's
Encrypt HTTP-01 challenge for `notify.andrewnorman.org`, and can then serve
trusted TLS under our name to phones that are still enrolling against it. With
an Elastic IP the address never left our account and the question did not arise.

Retracting while the address is still ours leaves no window. `192.0.2.1` is
RFC 5737 TEST-NET-1, guaranteed never routed, and an `UPSERT` rather than a
`DELETE` so the name keeps resolving and the failure looks like a timeout rather
than NXDOMAIN. `MU2EDAQ_NOTIFY_DNS_RETRACT=0` disables it; `scripts/update-notify-dns.sh --retract`
does it by hand.

On top of this, the CAA record on `notify.andrewnorman.org` pins issuance to the
instance's own ACME account, which closes the same hole even if a record is ever
left dangling: controlling the address is then not enough to obtain a
certificate for the name. See `scripts/update-notify-caa.sh` and
"CAA: pinning issuance to our own ACME account" in `docs/reverse-proxy-setup.md`.

## Cutover from the Elastic IP

One-time, in this order. The gate is step 3: if the instance comes back with no
public address, its interface is not auto-assigning one and the instance has to
be relaunched in a subnet that does, so do not release the address before then.

```bash
# 1. Role, profile and updater, while the old address still works.
aws cloudformation deploy --stack-name mu2edaq-notify-proxy-dns \
  --template-file config/aws/notify-dns-role.cfn.yaml \
  --capabilities CAPABILITY_NAMED_IAM --region us-west-2
aws ec2 associate-iam-instance-profile --instance-id i-000ee813ecd9a47b3 \
  --iam-instance-profile Name=mu2edaq-notify-proxy-dns --region us-west-2
scripts/start-mu2edaq-notify-chain.sh
scripts/install-notify-dns-updater.sh

# 2. Pin issuance to this instance's ACME account, while it is running and its
#    account can be read. Do this before the address ever changes hands.
scripts/update-notify-caa.sh
scripts/update-notify-caa.sh --check

# 3. Disassociate the Elastic IP but keep the allocation, so it can be put
#    back in one call if step 4 fails.
aws ec2 disassociate-address --region us-west-2 \
  --association-id eipassoc-0bd6e05d873510685

# 4. Stop and start, then check that a new address appeared and was published.
scripts/stop-mu2edaq-notify-chain.sh
scripts/start-mu2edaq-notify-chain.sh
scripts/update-notify-dns.sh --check
curl -fsS https://notify.andrewnorman.org/api/health

# 5. Only once step 4 has passed twice: release the allocation for good.
aws ec2 release-address --region us-west-2 \
  --allocation-id eipalloc-003c30b24e96af804
```

Rollback before step 5 is `aws ec2 associate-address --allocation-id
eipalloc-003c30b24e96af804 --instance-id i-000ee813ecd9a47b3`, followed by
`scripts/update-notify-dns.sh`. After step 5 the address is gone for good and
cannot be reclaimed.
