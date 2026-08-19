# OKD Reverse Proxy Operations Runbook

Operational reference for the `mu2edaq-pager` OKD reverse-proxy chain.
See `docs/okd-proxy-setup.md` for the architecture and Helm chart layout.

## Routine deploy / redeploy

```bash
./scripts/deploy-okd-proxy.sh --env prod
```

Safe to re-run at any time: it's a Helm `upgrade --install`, and if
cert-manager is already active (`certManager.externalCertificate: true`
in `my-values.yaml`) it skips straight to a single-pass apply plus a
rollout restart (picks up any Caddyfile changes -- the pod's checksum
annotation forces a restart when the ConfigMap content changes).

To redeploy without letting the script touch cert-manager state at all:

```bash
./scripts/deploy-okd-proxy.sh --env prod --no-cert
```

(only sensible once the Route already has a working certificate from
a prior run -- otherwise this requests the router's wildcard cert
instead).

## Cert-manager: first-time activation

Certificate initialization is a two-step process because OKD rejects a
`Route` that references a TLS secret before that secret exists.
`scripts/deploy-okd-proxy.sh` automates both passes; this section is
for when you need to do it by hand or diagnose a stuck first deploy.

1. Verify the issuer is available:

   ```bash
   oc login https://api.<your-okd-cluster>:6443
   oc project mu2edaq-pager
   oc get clusterissuer incommon-acme
   ```

2. In `my-values.yaml`, set `certManager.externalCertificate: false`
   and deploy:

   ```bash
   helm upgrade --install mu2edaq-pager ./helm \
     --namespace mu2edaq-pager --create-namespace \
     --values my-values.yaml
   ```

3. Wait for the TLS secret:

   ```bash
   oc get certificate,certificaterequest,secret,route,pods -n mu2edaq-pager
   oc describe certificate mu2edaq-pager -n mu2edaq-pager
   ```

   Wait until you see:

   ```text
   certificate.cert-manager.io/mu2edaq-pager   True   mu2edaq-pager-tls
   secret/mu2edaq-pager-tls                    kubernetes.io/tls
   ```

4. Flip `certManager.externalCertificate: true` in `my-values.yaml` and
   re-run the same `helm upgrade --install`. Verify:

   ```bash
   oc get route mu2edaq-pager -n mu2edaq-pager \
     -o jsonpath='{.spec.tls.externalCertificate.name}{"\n"}'
   ```

   Expected: `mu2edaq-pager-tls`.

5. Confirm HTTPS works end to end:

   ```bash
   curl --head --location https://mu2edaq-pager.fnal.gov/api/health
   ```

   Expect `HTTP/1.1 200 OK` (or a redirect to it).

### Troubleshooting

If Helm reports:

```text
spec.tls.externalCertificate: Not found: "secrets \"mu2edaq-pager-tls\" not found"
```

set `certManager.externalCertificate` back to `false`, redeploy, wait
for `secret/mu2edaq-pager-tls` to appear, then repeat the activation
step.

If the `Certificate` never goes `Ready`, check whether the namespace
has been allowlisted for this hostname by the cluster's OPA admission
webhook (the same mechanism `mu2e-talks` hit when setting up its test
namespace):

```bash
oc describe certificate mu2edaq-pager -n mu2edaq-pager
oc get certificaterequest -n mu2edaq-pager
```

A denial here means the DNS name isn't yet permitted in this
namespace — ask the OKD admins to allowlist it, or redeploy with
`--no-cert` in the meantime to at least get the proxy running behind
the router's wildcard certificate while that's sorted out.

After activation, cert-manager renews the certificate automatically;
the Route keeps referencing `mu2edaq-pager-tls` so renewal needs no
repeat of this procedure.

## Cluster-specific gotchas (this OKD cluster)

Two things this cluster enforces that a generic OKD/OpenShift setup
might not, both already handled by `scripts/deploy-okd-proxy.sh` and
`helm/templates/build.yaml` -- documented here in case a manual `helm
upgrade` hits them:

- **Build pods need explicit resources.** An OPA admission webhook
  (`validating-webhook.openpolicyagent.org`) rejects any pod --
  including the `BuildConfig`'s auto-generated `docker-build` container
  and `manage-dockerfile` init container -- that doesn't declare CPU
  and memory requests/limits. This is why `helm/values.yaml` has a
  `buildResources` key wired into `BuildConfig.spec.resources`. A
  build stuck at `New (CannotCreateBuildPod)` almost always means this:
  ```bash
  oc describe build <name> -n mu2edaq-pager
  ```
- **The image trigger controller co-owns the Deployment's image
  field.** Once a build completes, OpenShift's
  `openshift-controller-manager` patches
  `spec.template.spec.containers[].image` via server-side apply (see
  the `image.openshift.io/triggers` annotation in
  `helm/templates/deployment.yaml`). A subsequent `helm upgrade`
  without `--force-conflicts` fails with:
  ```text
  conflict occurred while applying object .../Deployment: ... conflict with
  "openshift-controller-manager" using apps/v1: .spec.template.spec.containers[name="caddy"].image
  ```
  `scripts/deploy-okd-proxy.sh` always passes `--force-conflicts`; add
  it to any manual `helm upgrade` too.

## Health checks

Through the OKD Route (what the phone actually sees):

```bash
curl --head --location https://mu2edaq-pager.fnal.gov/api/health
```

Caddy pod directly (bypasses the Route, confirms the pod itself is up):

```bash
oc exec -n mu2edaq-pager deployment/mu2edaq-pager -- \
  wget -qO- http://127.0.0.1:8080/api/health
```

Backend reachability from inside the cluster (confirms OKD can actually
reach the local Mu2e host -- the thing that makes this whole setup
possible without a tunnel):

```bash
oc exec -n mu2edaq-pager deployment/mu2edaq-pager -- \
  wget --no-check-certificate -qO- https://<backend-host>:8095/api/health
```

All three should return the same JSON health payload the local server
returns directly.

## Logs and status

```bash
oc get pods,svc,route,certificate -n mu2edaq-pager
oc logs deployment/mu2edaq-pager -n mu2edaq-pager --tail=100
oc rollout status deployment/mu2edaq-pager -n mu2edaq-pager
```

## Rolling back

Helm keeps release history:

```bash
helm history mu2edaq-pager -n mu2edaq-pager
helm rollback mu2edaq-pager <REVISION> -n mu2edaq-pager
```

## Cutover

This deployment does **not** automatically change anything about the
existing AWS path or the local server's configuration. Once
`https://mu2edaq-pager.fnal.gov/api/health` has been verified working
end to end (including a real test event delivered through it), cutover
to making it the primary public endpoint is a deliberate, separate step:

1. Update `server.base_url` and `discovery.fallback_url` in
   `config/notify-server.yaml` to `https://mu2edaq-pager.fnal.gov`, and
   restart the local server (`./stop-mu2edaq-notify-server.sh &&
   ./start-mu2edaq-notify-server.sh`). This changes what QR enrollment
   payloads and off-network publisher fallback URLs point at.
2. Re-enroll any devices whose QR code was generated before the change
   (existing registered devices keep working; only new enrollments pick
   up the new URL).
3. Once confident, retire the AWS chain
   (`scripts/stop-mu2edaq-notify-proxy.sh`, then decommission the EC2
   instance and Route 53 record per `docs/reverse-proxy-operations.md`)
   -- or keep both running as a fallback pair if that's preferred.

There is no requirement to ever do step 3; running both proxies
indefinitely is a legitimate choice too.
