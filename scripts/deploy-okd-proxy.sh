#!/usr/bin/env bash
# Deploy the mu2edaq-pager OKD reverse proxy (Caddy + Route + cert-manager).
#
# No external registry or local Docker build is needed: the chart's
# BuildConfig derives a capability-stripped Caddy image (see the comment on
# `image:` in helm/values.yaml -- the stock image's cap_net_bind_service
# file capability can't exec under OKD's restricted-v2 SCC) and builds it
# in-cluster from docker.io/library/caddy:2-alpine, configured entirely
# through a ConfigMap-mounted Caddyfile. This script does not touch
# mu2edaq-notify-server itself, which keeps running on the local Mu2e
# host; it only stands up the public-facing proxy in front of it.
#
# Usage:
#   ./scripts/deploy-okd-proxy.sh [OPTIONS]
#
# Options:
#   --env <prod|test>  Which Vault secrets instance to deploy with. Required
#                   unless --skip-vault is given. SECRET_REGISTRY in
#                   scripts/vault_client.py is empty today, so this has no
#                   practical effect yet -- see docs/Vault-Secrets.md.
#   -n NAMESPACE    OKD namespace (default: mu2edaq-pager)
#   -f VALUES_FILE  Helm values file; repeat to layer files, later files win
#                   (default: my-values.yaml). Vault-sourced values are always
#                   applied last, so they still shadow every file given here.
#   --release NAME  Helm release name (default: mu2edaq-pager)
#   --tls-secret N  cert-manager TLS secret name (default: mu2edaq-pager-tls).
#                   Overrides certManager.secretName so the wait loop and the
#                   Route externalCertificate always agree.
#   --timeout SEC   Rollout timeout in seconds (default: 120)
#   --no-cert       Skip cert-manager entirely: request no Certificate and let
#                   the Route use the router's default wildcard certificate.
#                   Needed where the OPA admission webhook has not allowlisted
#                   the namespace for the route's DNS name.
#   --skip-vault    Deploy using only VALUES_FILE; don't fetch secrets from Vault
#                   (and --env is not required)
#   --vault-approle Authenticate to Vault as the application (AppRole) instead
#                   of your personal ~/.vault-token. See docs/Vault-Secrets.md.
#   --vault-role R  AppRole role name to use with --vault-approle
#                   (default: MU2EDAQ_PAGER_VAULT_ROLE, or config/vault.yaml's role)
#   -h, --help      Show this help message
#
# Secrets normally come from Vault (see docs/Vault-Secrets.md), but
# there are none registered today, so a bare `--env` run still works with
# no Vault login required. VALUES_FILE (my-values.yaml) carries all of
# this deployment's real configuration -- hostname, cert-manager settings,
# and backend.url.

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
RESET='\033[0m'

info()    { printf "${CYAN}==> %s${RESET}\n" "$*"; }
success() { printf "${GREEN}[OK] %s${RESET}\n" "$*"; }
warn()    { printf "${YELLOW}[WARN] %s${RESET}\n" "$*"; }
error()   { printf "${RED}[ERROR] %s${RESET}\n" "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACE="mu2edaq-pager"
RELEASE="mu2edaq-pager"
VALUES_FILES=()
TIMEOUT=120
CERT_MANAGER=true
TLS_SECRET="mu2edaq-pager-tls"
SKIP_VAULT=false
VAULT_ENV=""
USE_APPROLE=false
VAULT_ROLE="${MU2EDAQ_PAGER_VAULT_ROLE:-}"

usage() {
    awk '/^# Usage:/{show=1} show && /^#/{sub(/^# ?/, ""); print; next} show{exit}' "$0"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)       VAULT_ENV="$2";  shift 2 ;;
        -n)          NAMESPACE="$2";  shift 2 ;;
        -f)          VALUES_FILES+=("$2"); shift 2 ;;
        --release)   RELEASE="$2";    shift 2 ;;
        --tls-secret) TLS_SECRET="$2"; shift 2 ;;
        --timeout)   TIMEOUT="$2";    shift 2 ;;
        --no-cert)   CERT_MANAGER=false; shift ;;
        --skip-vault) SKIP_VAULT=true; shift ;;
        --vault-approle) USE_APPROLE=true; shift ;;
        --vault-role) VAULT_ROLE="$2"; shift 2 ;;
        -h|--help)   usage ;;
        *) error "Unknown option: $1"; usage ;;
    esac
done

if [[ "${SKIP_VAULT}" == true && "${USE_APPROLE}" == true ]]; then
    error "--vault-approle and --skip-vault are mutually exclusive: --skip-vault means no Vault call is made at all."
    exit 1
fi

if [[ "${SKIP_VAULT}" == false ]]; then
    if [[ -z "${VAULT_ENV}" ]]; then
        error "--env prod|test is required (or pass --skip-vault to deploy using only the -f values files)."
        exit 1
    fi
    if [[ "${VAULT_ENV}" != "prod" && "${VAULT_ENV}" != "test" ]]; then
        error "--env must be 'prod' or 'test', got: ${VAULT_ENV}"
        exit 1
    fi
    export VAULT_ENV
fi

if [[ ${#VALUES_FILES[@]} -eq 0 ]]; then
    VALUES_FILES=("my-values.yaml")
fi

for i in "${!VALUES_FILES[@]}"; do
    if [[ "${VALUES_FILES[$i]}" != /* ]]; then
        VALUES_FILES[$i]="${PROJECT_DIR}/${VALUES_FILES[$i]}"
    fi
done

VAULT_VALUES_FILE=""
APP_TOKEN=""
cleanup() {
    if [[ -n "${VAULT_VALUES_FILE}" && -f "${VAULT_VALUES_FILE}" ]]; then
        shred -u "${VAULT_VALUES_FILE}" 2>/dev/null || rm -f "${VAULT_VALUES_FILE}"
    fi
    if [[ -n "${APP_TOKEN}" ]] && command -v vault >/dev/null 2>&1; then
        VAULT_TOKEN="${APP_TOKEN}" vault token revoke -self >/dev/null 2>&1 \
            && info "Revoked the Vault application token" \
            || warn "Could not revoke the Vault application token; it expires on its own TTL"
    fi
    APP_TOKEN=""
}
trap 'error "Deployment failed at line ${LINENO}."' ERR
trap cleanup EXIT

cd "${PROJECT_DIR}"

info "[1/7] Checking prerequisites"
for command in helm oc python3; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        error "Required command is not available: ${command}"
        exit 1
    fi
done
for values_file in "${VALUES_FILES[@]}"; do
    if [[ ! -f "${values_file}" ]]; then
        error "Helm values file not found: ${values_file}"
        exit 1
    fi
done
if ! oc whoami >/dev/null 2>&1; then
    warn "No active OKD login found. Starting web login..."
    oc login --web
    if ! oc whoami >/dev/null 2>&1; then
        error "OKD login did not produce an active session."
        exit 1
    fi
fi
success "Authenticated to OKD as $(oc whoami)"
# Ordinary OKD users usually can't create/patch a raw Namespace object
# (what Helm's --create-namespace does), but can create an OKD "project"
# via `oc new-project`, which goes through self-provisioner RBAC instead.
# So the project is created here, before Helm ever runs, and --create-namespace
# is deliberately NOT passed to helm upgrade below.
if ! oc get project "${NAMESPACE}" >/dev/null 2>&1; then
    info "Project ${NAMESPACE} does not exist yet; creating it with oc new-project"
    oc new-project "${NAMESPACE}" >/dev/null
    success "Created project ${NAMESPACE}"
fi
success "Prerequisites available; OKD project is ${NAMESPACE}"

if [[ "${SKIP_VAULT}" == true ]]; then
    warn "[2/7] Skipping Vault (--skip-vault); values come only from ${VALUES_FILES[*]}"
else
    info "[2/7] Fetching secrets from Vault (environment: ${VAULT_ENV})"
    VAULT_PYTHON="${PROJECT_DIR}/venv/bin/python"
    [[ -x "${VAULT_PYTHON}" ]] || VAULT_PYTHON="python3"

    if [[ "${USE_APPROLE}" == true ]]; then
        TOKEN_SCRIPT="${SCRIPT_DIR}/get-vault-apptoken.sh"
        [[ -x "${TOKEN_SCRIPT}" ]] || { error "Not found or not executable: ${TOKEN_SCRIPT}"; exit 1; }
        info "Authenticating to Vault as the application (AppRole${VAULT_ROLE:+ ${VAULT_ROLE}})"
        _approle_args=(--format token --quiet)
        [[ -n "${VAULT_ROLE}" ]] && _approle_args+=(--role "${VAULT_ROLE}")
        if ! APP_TOKEN="$("${TOKEN_SCRIPT}" "${_approle_args[@]}")"; then
            error "Could not obtain a Vault AppRole token (see message above)."
            exit 1
        fi
        [[ -n "${APP_TOKEN}" ]] || { error "AppRole token script returned an empty token."; exit 1; }
        export VAULT_TOKEN="${APP_TOKEN}"
        success "AppRole application token acquired"
    fi

    VAULT_VALUES_FILE="$(mktemp)"
    chmod 600 "${VAULT_VALUES_FILE}"
    if ! "${VAULT_PYTHON}" "${SCRIPT_DIR}/vault_client.py" helm-values > "${VAULT_VALUES_FILE}"; then
        error "Failed to fetch secrets from Vault (see message above)."
        error "Pass --skip-vault to deploy using only the -f values files instead."
        exit 1
    fi
    success "Secrets fetched from Vault (SECRET_REGISTRY is currently empty -- see docs/Vault-Secrets.md)"
fi

info "[3/7] Applying Helm release ${RELEASE}"
_helm_values_args=()
for values_file in "${VALUES_FILES[@]}"; do
    _helm_values_args+=(--values "${values_file}")
done
if [[ -n "${VAULT_VALUES_FILE}" ]]; then
    _helm_values_args+=(--values "${VAULT_VALUES_FILE}")
fi

if [[ "${CERT_MANAGER}" == false ]]; then
    warn "cert-manager disabled; Route will use the default router certificate"
    # --force-conflicts: see the comment on the first-pass call further down --
    # OpenShift's image trigger controller co-owns the image field via SSA.
    helm upgrade --install "${RELEASE}" ./helm --force-conflicts \
        --namespace "${NAMESPACE}" \
        "${_helm_values_args[@]}" \
        --set "certManager.enabled=false" \
        --set "certManager.externalCertificate=false"
    success "Helm release applied"
else
    info "Applying first pass without Route externalCertificate while cert-manager prepares ${TLS_SECRET}"
    # --force-conflicts: once the image build completes, OpenShift's
    # ImageStream trigger controller (openshift-controller-manager) takes
    # server-side-apply ownership of spec.template.spec.containers[].image
    # to patch it in -- see the image.openshift.io/triggers annotation in
    # deployment.yaml. Without this flag, Helm's own SSA of that same field
    # conflicts with the controller's ownership and the upgrade fails.
    helm upgrade --install "${RELEASE}" ./helm --force-conflicts \
        --namespace "${NAMESPACE}" \
        "${_helm_values_args[@]}" \
        --set "certManager.enabled=true" \
        --set-string "certManager.secretName=${TLS_SECRET}" \
        --set "certManager.externalCertificate=false"
    success "Helm first pass applied"

    info "Waiting for TLS secret ${TLS_SECRET} (${TIMEOUT}s timeout)"
    deadline=$((SECONDS + TIMEOUT))
    while ! oc get secret "${TLS_SECRET}" -n "${NAMESPACE}" >/dev/null 2>&1; do
        if (( SECONDS >= deadline )); then
            error "TLS secret ${TLS_SECRET} was not created before timeout."
            error "Check: oc describe certificate ${RELEASE} -n ${NAMESPACE}"
            error "If the Certificate was refused by the openpolicyagent admission"
            error "webhook, the namespace is not allowlisted for that DNS name."
            error "Ask the OKD admins to allowlist it, or redeploy with --no-cert."
            exit 1
        fi
        sleep 5
    done
    success "TLS secret is available: ${TLS_SECRET}"

    info "Applying final pass with Route externalCertificate enabled"
    # --force-conflicts: see the comment on the first-pass call above.
    helm upgrade --install "${RELEASE}" ./helm --force-conflicts \
        --namespace "${NAMESPACE}" \
        "${_helm_values_args[@]}" \
        --set "certManager.enabled=true" \
        --set-string "certManager.secretName=${TLS_SECRET}" \
        --set "certManager.externalCertificate=true"
    success "Helm release applied"
fi

info "[4/7] Waiting for the in-cluster Caddy image build (${TIMEOUT}s timeout)"
# BuildConfig's ConfigChange trigger starts a Build as soon as it's created;
# on a redeploy where nothing about templates/build.yaml changed, no new
# Build starts and the latest existing one (already Complete) is used as-is.
# The Build object can take a few seconds to appear after the BuildConfig
# is first created, so poll rather than checking once.
BUILD_NAME=""
deadline=$((SECONDS + TIMEOUT))
while [[ -z "${BUILD_NAME}" ]]; do
    BUILD_NAME="$(oc get builds -n "${NAMESPACE}" \
        -l "openshift.io/build-config.name=${RELEASE}-caddy" \
        --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
    [[ -n "${BUILD_NAME}" ]] && break
    if (( SECONDS >= deadline )); then
        error "No build appeared for buildconfig/${RELEASE}-caddy within ${TIMEOUT}s."
        error "Check: oc get buildconfig ${RELEASE}-caddy -n ${NAMESPACE}"
        exit 1
    fi
    sleep 3
done
info "Watching build/${BUILD_NAME}"
if ! oc wait "build/${BUILD_NAME}" -n "${NAMESPACE}" \
    --for=jsonpath='{.status.phase}'=Complete --timeout="${TIMEOUT}s" 2>/dev/null; then
    PHASE="$(oc get "build/${BUILD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo unknown)"
    if [[ "${PHASE}" == "Complete" ]]; then
        : # Already finished between the check and the wait call -- fine.
    else
        error "build/${BUILD_NAME} did not complete (phase: ${PHASE})."
        error "Check: oc logs -n ${NAMESPACE} build/${BUILD_NAME}"
        exit 1
    fi
fi
success "Image build complete: ${RELEASE}-caddy:latest"

info "[5/7] Restarting deployment/${RELEASE} to pick up any Caddyfile changes"
oc rollout restart "deployment/${RELEASE}" -n "${NAMESPACE}"
success "Restart requested"

info "[6/7] Waiting for deployment/${RELEASE} readiness (${TIMEOUT}s timeout)"
oc rollout status "deployment/${RELEASE}" -n "${NAMESPACE}" --timeout="${TIMEOUT}s"
success "Deployment is ready"

info "[7/7] Current OKD status"
oc get pods,svc,route,certificate -n "${NAMESPACE}"

ROUTE_HOST="$(oc get route "${RELEASE}" -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -n "${ROUTE_HOST}" ]] && command -v curl >/dev/null 2>&1; then
    URL="https://${ROUTE_HOST}/api/health"
    info "Checking ${URL}"
    # The OKD router takes a few seconds to pick up a freshly-rolled-out
    # pod as a Route endpoint after `oc rollout status` already reports
    # ready, so a single immediate check routinely sees a transient 503.
    # Retry briefly before treating it as a real failure.
    HEALTH_OK=false
    for _attempt in 1 2 3 4 5; do
        if curl --fail --silent --show-error --head --max-time 20 "${URL}" >/dev/null; then
            HEALTH_OK=true
            break
        fi
        sleep 3
    done
    if [[ "${HEALTH_OK}" == true ]]; then
        success "Public health check is responding"
    else
        warn "Deployment is ready, but the health check failed: ${URL}"
        warn "This is expected if backend.url in my-values.yaml isn't reachable from OKD yet."
    fi
fi

success "Deployment complete: ${RELEASE} in ${NAMESPACE}"
