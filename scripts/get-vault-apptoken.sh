#!/usr/bin/env bash
# Obtain a HashiCorp Vault AppRole token for the mu2edaq-pager application.
#
# Ported from mu2e-talks' scripts/get-vault-apptoken.sh (itself ported from
# SCD-Reporting). The logic is unchanged; the defaults, config search path
# and environment-variable prefix are mu2edaq-pager-specific so each
# application can diverge independently.
#
# The personal LDAP login is long-lived and is only performed when the current
# session is missing, about to expire, or not privileged enough to mint a
# secret-id (which is the case when ~/.vault-token holds an application token
# rather than your own login). The AppRole role-id / secret-id are then fetched
# with that personal token and exchanged for a short-lived application token,
# which is what gets handed to the deployment.
#
# Usage:
#   ./scripts/get-vault-apptoken.sh [OPTIONS]
#
# Options:
#   -a, --addr URL        Vault server address
#                         (default: $VAULT_ADDR, or https://ssivault.fnal.gov:8200)
#   -r, --role NAME       AppRole role name (default: mu2edaq-pager-app)
#   -m, --mount PATH      AppRole auth mount path (default: auth/td-approles)
#   -u, --username USER   LDAP username for the personal login
#                         (default: $MU2EDAQ_PAGER_VAULT_LDAP_USER, or $USER)
#       --method METHOD   Personal login method: ldap, oidc, userpass
#                         (default: ldap)
#   -F, --format FORMAT   Output format (default: token)
#                           token  - the bare token, one line
#                           env    - export VAULT_ADDR= / VAULT_TOKEN= lines
#                           json   - token plus accessor, TTL and policies
#                           values - Helm values fragment (vault.token, ...)
#   -o, --output FILE     Write the result to FILE (mode 0600) instead of stdout
#   -c, --config FILE     Read defaults from FILE (flat YAML key: value)
#       --min-ttl SECS    Re-login if the personal token has less than SECS
#                         remaining (default: 300)
#       --renew           Try to renew an expiring personal token before
#                         falling back to a fresh login
#       --force-login     Always perform the personal login, even if a valid
#                         session already exists
#       --no-login        Never prompt; fail if there is no valid session
#                         (for CI and other non-interactive callers)
#       --wrap-ttl DUR    Return a response-wrapping token valid for DUR
#                         (e.g. 5m) instead of the app token itself; the
#                         consumer recovers it with `vault unwrap <token>`
#       --check-path PATH After login, verify the app token can read PATH
#       --no-verify       Skip the lookup that validates the new app token
#       --set-local-token Also point this shell's Vault session (~/.vault-token)
#                         at the new app token. NOT the default: it replaces
#                         your personal login.
#   -q, --quiet           Suppress progress output (errors are still shown)
#   -v, --verbose         Show each Vault call as it is made
#       --dry-run         Print what would run without contacting Vault
#       --version         Show the script version and exit
#   -h, --help            Show this help message
#
# Environment variables (override the config file, overridden by flags):
#   VAULT_ADDR              Vault server address
#   VAULT_TOKEN             Existing Vault token to use for the personal session
#   MU2EDAQ_PAGER_VAULT_ROLE         AppRole role name
#   MU2EDAQ_PAGER_VAULT_MOUNT        AppRole auth mount path
#   MU2EDAQ_PAGER_VAULT_LDAP_USER    LDAP username
#   MU2EDAQ_PAGER_VAULT_FORMAT       Default output format
#   MU2EDAQ_PAGER_VAULT_TOKEN_FILE   Default output file
#   MU2EDAQ_PAGER_VAULT_CONFIG       Default config file path
#
# Exit codes:
#   0 success   1 usage error        2 missing dependency   3 personal login failed
#   4 AppRole credential failure     5 app token verification failed
#
# Examples:
#   # Capture a token in a variable
#   APP_TOKEN=$(./scripts/get-vault-apptoken.sh)
#
#   # Load it into the current shell
#   eval "$(./scripts/get-vault-apptoken.sh --format env)"
#
#   # Write a Helm values fragment for the deploy script
#   ./scripts/get-vault-apptoken.sh --format values -o /tmp/vault-values.yaml
#
#   # Confirm the app token can actually read this application's secrets
#   ./scripts/get-vault-apptoken.sh --check-path okd/shared/test/mu2edaq-pager/proxy
#
#   # How the deploy script uses it
#   ./scripts/deploy-okd-proxy.sh --env test --vault-approle

set -euo pipefail

VERSION="1.0.0"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# ── Defaults ──────────────────────────────────────────────────────────────────
DEFAULT_ADDR="https://ssivault.fnal.gov:8200"
# Dedicated mu2edaq-pager AppRole. It does not exist yet -- see
# config/vault.yaml -- so this fails with an actionable error until a Vault
# admin creates it with a policy granting read on
# okd/data/shared/{prod,test}/mu2edaq-pager/*. Override with --role /
# MU2EDAQ_PAGER_VAULT_ROLE / config if the role is named differently.
DEFAULT_ROLE="mu2edaq-pager-app"
DEFAULT_MOUNT="auth/td-approles"
DEFAULT_METHOD="ldap"
DEFAULT_FORMAT="token"
DEFAULT_MIN_TTL=300

CONFIG_CANDIDATES=(
    "${PWD}/config/vault.yaml"
    "${HOME}/.config/mu2edaq-pager/vault.yaml"
)

# Values from the command line (highest precedence; empty means "not given").
ARG_ADDR=""; ARG_ROLE=""; ARG_MOUNT=""; ARG_USERNAME=""; ARG_METHOD=""
ARG_FORMAT=""; ARG_OUTPUT=""; ARG_MIN_TTL=""; ARG_CHECK_PATH=""; ARG_CONFIG=""

# Values from the config file (lowest precedence above the built-in defaults).
CFG_ADDR=""; CFG_ROLE=""; CFG_MOUNT=""; CFG_USERNAME=""; CFG_METHOD=""
CFG_FORMAT=""; CFG_OUTPUT=""; CFG_MIN_TTL=""; CFG_CHECK_PATH=""

RENEW=false
FORCE_LOGIN=false
NO_LOGIN=false
NO_VERIFY=false
SET_LOCAL_TOKEN=false
WRAP_TTL=""
QUIET=false
VERBOSE=false
DRY_RUN=false

# ── Output helpers (everything diagnostic goes to stderr) ─────────────────────
step()  { [[ "${QUIET}" == true ]] || echo "── $* ──" >&2; }
info()  { [[ "${QUIET}" == true ]] || echo "   $*" >&2; }
ok()    { [[ "${QUIET}" == true ]] || echo "   ✓ $*" >&2; }
warn()  { echo "   ! $*" >&2; }
debug() { [[ "${VERBOSE}" == true ]] && echo "   + $*" >&2 || true; }
die()   { echo "ERROR: $1" >&2; exit "${2:-1}"; }

usage() {
    # Print the header comment block from "# Usage:" to the end of the comments.
    # Done in bash rather than sed, whose brace syntax differs between BSD and GNU.
    local line printing=false
    while IFS= read -r line; do
        [[ "${line}" == "# Usage:"* ]] && printing=true
        [[ "${printing}" == true ]] || continue
        [[ "${line}" == "#"* ]] || break
        line="${line###}"
        printf '%s\n' "${line# }"
    done < "${BASH_SOURCE[0]}"
    exit 0
}

# Show enough of a credential to correlate it in Vault's audit log, no more.
mask() {
    local s="$1"
    if [[ ${#s} -le 12 ]]; then
        printf '****'
    else
        printf '%s...%s' "${s:0:6}" "${s: -4}"
    fi
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
TMP_FILES=()
cleanup() {
    local f
    for f in "${TMP_FILES[@]:-}"; do
        [[ -n "${f}" && -f "${f}" ]] && rm -f "${f}"
    done
    return 0
}
trap cleanup EXIT INT TERM

mktemp_secure() {
    local f
    f="$(umask 077; mktemp "${TMPDIR:-/tmp}/mu2e-vault.XXXXXX")"
    TMP_FILES+=("${f}")
    printf '%s' "${f}"
}

# ── Minimal JSON scalar extraction (jq when available, sed otherwise) ─────────
json_field() {
    local json="$1" key="$2" val=""
    # jq handles nesting and arrays properly when it is available...
    if command -v jq >/dev/null 2>&1; then
        val="$(printf '%s' "${json}" | jq -r --arg k "${key}" '
            [.. | objects | select(has($k)) | .[$k]] | first
            | if . == null then ""
              elif type == "array" then join(",")
              else tostring end' 2>/dev/null || true)"
    fi
    # ...otherwise (or if jq is broken) scan for the key as a string, then as a
    # number. Enough for the flat scalars this script reads out of Vault.
    if [[ -z "${val}" ]]; then
        val="$(printf '%s' "${json}" \
            | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1)"
    fi
    if [[ -z "${val}" ]]; then
        val="$(printf '%s' "${json}" \
            | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -1)"
    fi
    printf '%s' "${val}"
}

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# ── Config file parsing (flat "key: value" YAML) ──────────────────────────────
load_config() {
    local file="$1" line key val
    [[ -f "${file}" ]] || return 1
    debug "reading config ${file}"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%%#*}"
        [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
        [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*:[[:space:]]*(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        val="${val%"${val##*[![:space:]]}"}"           # trim trailing space
        val="${val#\"}"; val="${val%\"}"                # strip quotes
        val="${val#\'}"; val="${val%\'}"
        case "${key}" in
            addr|vault_addr)   CFG_ADDR="${val}" ;;
            role)              CFG_ROLE="${val}" ;;
            mount)             CFG_MOUNT="${val}" ;;
            username|ldap_user) CFG_USERNAME="${val}" ;;
            method)            CFG_METHOD="${val}" ;;
            format)            CFG_FORMAT="${val}" ;;
            output|token_file) CFG_OUTPUT="${val}" ;;
            min_ttl)           CFG_MIN_TTL="${val}" ;;
            check_path)        CFG_CHECK_PATH="${val}" ;;
            # config/vault.yaml is shared with vault_client.py, which owns
            # these keys. Recognised and skipped so --verbose stays quiet.
            vault|env|kv_mount|base_path|approle) debug "skipping vault_client.py key: ${key}" ;;
            *) debug "ignoring unknown config key: ${key}" ;;
        esac
    done < "${file}"
    return 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
require_arg() {
    [[ $# -ge 2 && -n "${2:-}" ]] || die "Option $1 requires a value (see --help)"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--addr)        require_arg "$1" "${2:-}"; ARG_ADDR="$2";       shift 2 ;;
        -r|--role)        require_arg "$1" "${2:-}"; ARG_ROLE="$2";       shift 2 ;;
        -m|--mount)       require_arg "$1" "${2:-}"; ARG_MOUNT="$2";      shift 2 ;;
        -u|--username)    require_arg "$1" "${2:-}"; ARG_USERNAME="$2";   shift 2 ;;
        --method)         require_arg "$1" "${2:-}"; ARG_METHOD="$2";     shift 2 ;;
        -F|--format)      require_arg "$1" "${2:-}"; ARG_FORMAT="$2";     shift 2 ;;
        -o|--output)      require_arg "$1" "${2:-}"; ARG_OUTPUT="$2";     shift 2 ;;
        -c|--config)      require_arg "$1" "${2:-}"; ARG_CONFIG="$2";     shift 2 ;;
        --min-ttl)        require_arg "$1" "${2:-}"; ARG_MIN_TTL="$2";    shift 2 ;;
        --wrap-ttl)       require_arg "$1" "${2:-}"; WRAP_TTL="$2";       shift 2 ;;
        --check-path)     require_arg "$1" "${2:-}"; ARG_CHECK_PATH="$2"; shift 2 ;;
        --renew)           RENEW=true;           shift ;;
        --force-login)     FORCE_LOGIN=true;     shift ;;
        --no-login)        NO_LOGIN=true;        shift ;;
        --no-verify)       NO_VERIFY=true;       shift ;;
        --set-local-token) SET_LOCAL_TOKEN=true; shift ;;
        -q|--quiet)        QUIET=true;           shift ;;
        -v|--verbose)      VERBOSE=true;         shift ;;
        --dry-run)         DRY_RUN=true;         shift ;;
        --version)         echo "${SCRIPT_NAME} ${VERSION}"; exit 0 ;;
        -h|--help)         usage ;;
        --) shift; break ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

[[ "${FORCE_LOGIN}" == true && "${NO_LOGIN}" == true ]] && \
    die "--force-login and --no-login are mutually exclusive"

# ── Resolve settings: flag > environment > config file > default ──────────────
CONFIG_FILE="${ARG_CONFIG:-${MU2EDAQ_PAGER_VAULT_CONFIG:-${MU2EDAQ_PAGER_VAULT_CONFIG:-}}}"
if [[ -n "${CONFIG_FILE}" ]]; then
    load_config "${CONFIG_FILE}" || die "Config file not found: ${CONFIG_FILE}"
else
    for candidate in "${CONFIG_CANDIDATES[@]}"; do
        if load_config "${candidate}"; then
            CONFIG_FILE="${candidate}"
            break
        fi
    done
fi

ADDR="${ARG_ADDR:-${VAULT_ADDR:-${CFG_ADDR:-${DEFAULT_ADDR}}}}"
ROLE="${ARG_ROLE:-${MU2EDAQ_PAGER_VAULT_ROLE:-${CFG_ROLE:-${DEFAULT_ROLE}}}}"
MOUNT="${ARG_MOUNT:-${MU2EDAQ_PAGER_VAULT_MOUNT:-${CFG_MOUNT:-${DEFAULT_MOUNT}}}}"
USERNAME="${ARG_USERNAME:-${MU2EDAQ_PAGER_VAULT_LDAP_USER:-${CFG_USERNAME:-${USER:-}}}}"
METHOD="${ARG_METHOD:-${CFG_METHOD:-${DEFAULT_METHOD}}}"
FORMAT="${ARG_FORMAT:-${MU2EDAQ_PAGER_VAULT_FORMAT:-${CFG_FORMAT:-${DEFAULT_FORMAT}}}}"
OUTPUT="${ARG_OUTPUT:-${MU2EDAQ_PAGER_VAULT_TOKEN_FILE:-${CFG_OUTPUT:-}}}"
MIN_TTL="${ARG_MIN_TTL:-${CFG_MIN_TTL:-${DEFAULT_MIN_TTL}}}"
CHECK_PATH="${ARG_CHECK_PATH:-${CFG_CHECK_PATH:-}}"

MOUNT="${MOUNT#/}"; MOUNT="${MOUNT%/}"
[[ "${MOUNT}" == auth/* ]] || MOUNT="auth/${MOUNT}"

case "${FORMAT}" in
    token|env|json|values) ;;
    *) die "Unknown --format '${FORMAT}' (expected token, env, json or values)" ;;
esac
case "${METHOD}" in
    ldap|oidc|userpass) ;;
    *) die "Unknown --method '${METHOD}' (expected ldap, oidc or userpass)" ;;
esac
[[ "${MIN_TTL}" =~ ^[0-9]+$ ]] || die "--min-ttl must be a whole number of seconds, got '${MIN_TTL}'"

export VAULT_ADDR="${ADDR}"

ROLE_ID_PATH="${MOUNT}/role/${ROLE}/role-id"
SECRET_ID_PATH="${MOUNT}/role/${ROLE}/secret-id"
LOGIN_PATH="${MOUNT}/login"

# ── Pre-flight ────────────────────────────────────────────────────────────────
command -v vault >/dev/null 2>&1 || die "The 'vault' CLI is not on PATH. Install it from https://developer.hashicorp.com/vault/downloads" 2

if [[ "${QUIET}" == false ]]; then
    echo >&2
    echo "╔══════════════════════════════════════════════════╗" >&2
    echo "║        mu2edaq-pager — Vault app token            ║" >&2
    echo "╚══════════════════════════════════════════════════╝" >&2
    echo >&2
    info "Vault addr  : ${ADDR}"
    info "AppRole     : ${ROLE}"
    info "Auth mount  : ${MOUNT}"
    info "Format      : ${FORMAT}"
    [[ -n "${OUTPUT}" ]]      && info "Output file : ${OUTPUT}"
    [[ -n "${CONFIG_FILE}" ]] && info "Config      : ${CONFIG_FILE}"
    [[ -n "${WRAP_TTL}" ]]    && info "Wrapping    : response-wrapped for ${WRAP_TTL}"
    [[ "${DRY_RUN}" == true ]] && info "Mode        : DRY RUN — Vault will not be contacted"
    echo >&2
fi

if [[ "${DRY_RUN}" == true ]]; then
    step "Would run"
    info "vault login -no-print -method=${METHOD}${USERNAME:+ username=${USERNAME}}   (only if not already logged in)"
    info "vault read -field=role_id ${ROLE_ID_PATH}"
    info "vault write -f -field=secret_id ${SECRET_ID_PATH}"
    info "vault write -format=json ${LOGIN_PATH} @<payload>   (role_id/secret_id via file, never argv)"
    [[ -n "${CHECK_PATH}" ]] && info "vault kv get ${CHECK_PATH}   (with the new app token)"
    echo >&2
    ok "Dry run complete"
    exit 0
fi

# Vault reachability. `vault status` exits 0 unsealed, 2 sealed, 1 unreachable.
STATUS_OUT="$(vault status 2>&1)" && STATUS_RC=0 || STATUS_RC=$?
case "${STATUS_RC}" in
    0) : ;;
    2) die "Vault at ${ADDR} is sealed — it cannot serve credentials until it is unsealed." 3 ;;
    *) die "Cannot reach Vault at ${ADDR}:
       ${STATUS_OUT}" 3 ;;
esac

# ── Step 1: personal (long-lived) login ───────────────────────────────────────
step "1 — Checking your Vault session"

# The vault CLI prefers $VAULT_TOKEN over the token helper file, so a stale
# exported value would shadow a fresh login. Track it and drop it if we re-auth.
HAD_ENV_TOKEN=false
[[ -n "${VAULT_TOKEN:-}" ]] && HAD_ENV_TOKEN=true

SESSION_TTL=""      # remaining seconds, or "infinite"
SESSION_NAME=""     # display_name, e.g. ldap-jdoe
SESSION_PATH=""     # auth path that issued the token, e.g. auth/ldap/login

# Populates the SESSION_* variables. Fails if there is no usable session.
# `vault token lookup` has no -field flag, so everything comes from the JSON.
load_session() {
    local json
    json="$(vault token lookup -format=json 2>/dev/null)" || return 1
    SESSION_TTL="$(json_field "${json}" ttl)"
    SESSION_NAME="$(json_field "${json}" display_name)"
    SESSION_PATH="$(json_field "${json}" path)"
    [[ -z "${SESSION_TTL}" || "${SESSION_TTL}" == "0" ]] && SESSION_TTL="infinite"
    [[ -z "${SESSION_NAME}" ]] && SESSION_NAME="unknown"
    return 0
}

# Having *a* token is not enough: it must be allowed to mint a secret-id.
# An application token issued by this very AppRole can read its own role-id but
# not create a secret-id, which otherwise surfaces as a bare 403 in step 2.
#   0 = can mint    1 = definitely cannot    2 = could not determine
session_can_mint_secret_id() {
    local caps
    caps="$(vault token capabilities "${SECRET_ID_PATH}" 2>/dev/null)" || return 2
    [[ -z "${caps}" ]] && return 2
    case ",${caps//[[:space:]]/}," in
        *,root,*|*,sudo,*|*,create,*|*,update,*) return 0 ;;
    esac
    return 1
}

NEED_LOGIN=false
LOGIN_REASON="no valid Vault session"

if [[ "${FORCE_LOGIN}" == true ]]; then
    info "--force-login given; re-authenticating"
    NEED_LOGIN=true
    LOGIN_REASON="--force-login was given"
elif load_session; then
    if [[ "${SESSION_TTL}" == "infinite" ]]; then
        ok "Already logged in as ${SESSION_NAME} (token does not expire)"
    elif (( SESSION_TTL < MIN_TTL )); then
        warn "Session expires in ${SESSION_TTL}s (below --min-ttl ${MIN_TTL}s)"
        if [[ "${RENEW}" == true ]] && vault token renew -format=json >/dev/null 2>&1; then
            load_session
            ok "Renewed the existing session (${SESSION_TTL}s remaining)"
        else
            [[ "${RENEW}" == true ]] && warn "Renewal failed; falling back to a fresh login"
            NEED_LOGIN=true
            LOGIN_REASON="the current session expires in ${SESSION_TTL}s"
        fi
    else
        ok "Already logged in as ${SESSION_NAME} (${SESSION_TTL}s remaining)"
    fi

    # Right session, wrong identity? Catch it here rather than at step 2.
    if [[ "${NEED_LOGIN}" == false ]]; then
        set +e; session_can_mint_secret_id; CAPS_RC=$?; set -e
        case "${CAPS_RC}" in
            0) debug "session may create a secret-id at ${SECRET_ID_PATH}" ;;
            1)
                # A role that does not exist also reports "deny" on its
                # secret-id path, which would otherwise send us into a pointless
                # re-login (and a confusing "you lack permission" message) when
                # the real problem is a typo or an unprovisioned role.
                ROLE_PROBE="$(vault read -field=role_id "${ROLE_ID_PATH}" 2>&1 || true)"
                # Vault phrases this as "No value found at <path>"; match
                # case-insensitively so a wording change does not silently
                # reintroduce the misleading permission error below.
                shopt -s nocasematch
                if [[ "${ROLE_PROBE}" == *"does not exist"* ]] \
                   || [[ "${ROLE_PROBE}" == *"Code: 404"* ]] \
                   || [[ "${ROLE_PROBE}" == *"no value found at"* ]]; then
                    shopt -u nocasematch
                    die "The AppRole '${ROLE}' does not exist at ${MOUNT}.

       Vault reported: ${ROLE_PROBE}

       Pick an existing role with --role / MU2EDAQ_PAGER_VAULT_ROLE / config/vault.yaml,
       or ask a Vault admin to create '${ROLE}' with a policy granting read on
       okd/data/shared/{prod,test}/mu2edaq-pager/*.
       List the roles you can see with:  vault list ${MOUNT}/role" 4
                fi
                shopt -u nocasematch
                unset ROLE_PROBE

                if [[ "${SESSION_PATH}" == "${MOUNT}/login" ]]; then
                    warn "This session is an application token issued by the '${ROLE}' AppRole"
                    warn "itself, not your personal login — it cannot mint a new secret-id."
                else
                    warn "The current session (${SESSION_NAME}) may not create a secret-id at"
                    warn "${SECRET_ID_PATH}."
                fi
                NEED_LOGIN=true
                LOGIN_REASON="the current session (${SESSION_NAME}) lacks permission to generate a secret-id"
                ;;
            *) debug "could not determine capabilities on ${SECRET_ID_PATH}; continuing" ;;
        esac
    fi
else
    info "No valid Vault session found"
    NEED_LOGIN=true
fi

if [[ "${NEED_LOGIN}" == true ]]; then
    if [[ "${NO_LOGIN}" == true ]]; then
        die "Cannot continue: ${LOGIN_REASON}, and --no-login was given.
       Log in as yourself first:  vault login -method=${METHOD}" 3
    fi
    if [[ ! -t 0 ]]; then
        die "A Vault login is required but stdin is not a terminal (no way to prompt).
       Log in interactively first: vault login -method=${METHOD}" 3
    fi

    info "Logging in with the ${METHOD} method — you will be prompted for credentials"
    LOGIN_ARGS=(login -no-print "-method=${METHOD}")
    if [[ -n "${USERNAME}" && "${METHOD}" != "oidc" ]]; then
        LOGIN_ARGS+=("username=${USERNAME}")
        info "Username    : ${USERNAME}"
    fi
    debug "vault ${LOGIN_ARGS[*]}"
    echo >&2
    vault "${LOGIN_ARGS[@]}" >&2 || die "Vault ${METHOD} login failed" 3

    # A fresh login lands in the token helper; make sure no stale exported
    # token shadows it for the rest of this run.
    if [[ "${HAD_ENV_TOKEN}" == true ]]; then
        debug "unsetting the inherited VAULT_TOKEN so the new session is used"
        unset VAULT_TOKEN
    fi
    load_session || die "Login reported success but no session is present" 3
    ok "Logged in as ${SESSION_NAME}"
fi

# ── Step 2: AppRole credentials ───────────────────────────────────────────────
step "2 — Fetching AppRole credentials for '${ROLE}'"

debug "vault read -field=role_id ${ROLE_ID_PATH}"
ROLE_ID="$(vault read -field=role_id "${ROLE_ID_PATH}" 2>&1)" || \
    die "Could not read the role-id at ${ROLE_ID_PATH}:
       ${ROLE_ID}
       Check the role name (--role) and mount path (--mount), and that your
       account has read access to that role." 4
[[ -n "${ROLE_ID}" ]] || die "Vault returned an empty role_id for ${ROLE_ID_PATH}" 4
ok "role_id  $(mask "${ROLE_ID}")"

debug "vault write -f -field=secret_id ${SECRET_ID_PATH}"
SECRET_ID="$(vault write -f -field=secret_id "${SECRET_ID_PATH}" 2>&1)" || \
    die "Could not generate a secret-id at ${SECRET_ID_PATH}:
       ${SECRET_ID}

       Your account needs 'create' or 'update' capability on that path.
       A 403 here usually means the current session is an application token
       rather than your personal login — an app token can read its own role-id
       but cannot mint a new secret-id. Current session: ${SESSION_NAME}
       (issued by ${SESSION_PATH:-unknown}).
       Check with:  vault token capabilities ${SECRET_ID_PATH}
       Fix with:    ${SCRIPT_NAME} --force-login" 4
[[ -n "${SECRET_ID}" ]] || die "Vault returned an empty secret_id for ${SECRET_ID_PATH}" 4
ok "secret_id $(mask "${SECRET_ID}")"

# ── Step 3: exchange them for the application token ───────────────────────────
step "3 — Exchanging credentials for an application token"

# Pass the credentials in a 0600 payload file rather than on the command line,
# where they would be visible to anyone running `ps`.
PAYLOAD="$(mktemp_secure)"
printf '{"role_id":"%s","secret_id":"%s"}\n' \
    "$(json_escape "${ROLE_ID}")" "$(json_escape "${SECRET_ID}")" > "${PAYLOAD}"

LOGIN_ARGS=(write -format=json)
[[ -n "${WRAP_TTL}" ]] && LOGIN_ARGS+=("-wrap-ttl=${WRAP_TTL}")
LOGIN_ARGS+=("${LOGIN_PATH}" "@${PAYLOAD}")

debug "vault write -format=json ${LOGIN_PATH} @${PAYLOAD}"
LOGIN_JSON="$(vault "${LOGIN_ARGS[@]}" 2>&1)" || \
    die "AppRole login at ${LOGIN_PATH} failed:
       ${LOGIN_JSON}" 4
rm -f "${PAYLOAD}"

if [[ -n "${WRAP_TTL}" ]]; then
    APP_TOKEN="$(json_field "${LOGIN_JSON}" token)"
    TOKEN_ACCESSOR="$(json_field "${LOGIN_JSON}" accessor)"
    TOKEN_TTL="$(json_field "${LOGIN_JSON}" ttl)"
    TOKEN_POLICIES="(wrapped)"
    TOKEN_RENEWABLE="false"
else
    APP_TOKEN="$(json_field "${LOGIN_JSON}" client_token)"
    TOKEN_ACCESSOR="$(json_field "${LOGIN_JSON}" accessor)"
    TOKEN_TTL="$(json_field "${LOGIN_JSON}" lease_duration)"
    TOKEN_POLICIES="$(json_field "${LOGIN_JSON}" token_policies)"
    TOKEN_RENEWABLE="$(json_field "${LOGIN_JSON}" renewable)"
fi
unset LOGIN_JSON SECRET_ID

[[ -n "${APP_TOKEN}" ]] || die "Vault accepted the login but returned no token — response could not be parsed." 4
ok "app token $(mask "${APP_TOKEN}")"
[[ -n "${TOKEN_TTL}" ]]      && info "TTL         : ${TOKEN_TTL}s"
[[ -n "${TOKEN_POLICIES}" ]] && info "Policies    : ${TOKEN_POLICIES}"

# ── Step 4: verify the token works ────────────────────────────────────────────
if [[ "${NO_VERIFY}" == false && -z "${WRAP_TTL}" ]]; then
    step "4 — Verifying the application token"
    if VAULT_TOKEN="${APP_TOKEN}" vault token lookup >/dev/null 2>&1; then
        ok "Token is valid"
    else
        die "The new application token failed a self-lookup — it is not usable." 5
    fi

    if [[ -n "${CHECK_PATH}" ]]; then
        if VAULT_TOKEN="${APP_TOKEN}" vault kv get -format=json "${CHECK_PATH}" >/dev/null 2>&1 \
           || VAULT_TOKEN="${APP_TOKEN}" vault read -format=json "${CHECK_PATH}" >/dev/null 2>&1; then
            ok "Token can read ${CHECK_PATH}"
        else
            die "The application token cannot read ${CHECK_PATH}.

       The AppRole authenticated fine, so this is a policy gap, not a login
       problem. The '${ROLE}' AppRole needs a policy granting read on
       okd/data/shared/{prod,test}/mu2edaq-pager/* (KV v2 puts secret reads under
       the /data/ prefix). A Vault admin has to attach it -- the role's own
       policy document is not readable by ordinary users.
       Check with:  VAULT_TOKEN=<app token> vault token capabilities ${CHECK_PATH}" 5
        fi
    fi
elif [[ -n "${WRAP_TTL}" ]]; then
    info "Skipping verification — a wrapped token can only be unwrapped once"
fi

# ── Step 5: hand the token off ────────────────────────────────────────────────
render_output() {
    case "${FORMAT}" in
        token)
            printf '%s\n' "${APP_TOKEN}"
            ;;
        env)
            printf 'export VAULT_ADDR=%s\n' "${ADDR}"
            printf 'export VAULT_TOKEN=%s\n' "${APP_TOKEN}"
            if [[ -n "${WRAP_TTL}" ]]; then printf 'export VAULT_WRAPPED=1\n'; fi
            ;;
        json)
            printf '{\n'
            printf '  "vault_addr": "%s",\n'   "$(json_escape "${ADDR}")"
            printf '  "role": "%s",\n'         "$(json_escape "${ROLE}")"
            printf '  "mount": "%s",\n'        "$(json_escape "${MOUNT}")"
            printf '  "token": "%s",\n'        "$(json_escape "${APP_TOKEN}")"
            printf '  "accessor": "%s",\n'     "$(json_escape "${TOKEN_ACCESSOR}")"
            printf '  "lease_duration": %s,\n' "${TOKEN_TTL:-0}"
            printf '  "renewable": %s,\n'      "${TOKEN_RENEWABLE:-false}"
            printf '  "policies": "%s",\n'     "$(json_escape "${TOKEN_POLICIES}")"
            printf '  "wrapped": %s\n'         "$([[ -n "${WRAP_TTL}" ]] && echo true || echo false)"
            printf '}\n'
            ;;
        values)
            printf '# Generated by %s on %s — contains a live Vault token.\n' \
                "${SCRIPT_NAME}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            printf '# Pass to Helm with: -f <this file>. Do not commit.\n'
            printf 'vault:\n'
            printf '  addr: %s\n'  "\"${ADDR}\""
            printf '  role: %s\n'  "\"${ROLE}\""
            printf '  mount: %s\n' "\"${MOUNT}\""
            printf '  token: %s\n' "\"${APP_TOKEN}\""
            ;;
    esac
    return 0
}

if [[ -n "${OUTPUT}" ]]; then
    OUT_DIR="$(dirname "${OUTPUT}")"
    [[ -d "${OUT_DIR}" ]] || die "Output directory does not exist: ${OUT_DIR}"
    ( umask 077; render_output > "${OUTPUT}" ) || die "Could not write ${OUTPUT}"
    chmod 600 "${OUTPUT}" 2>/dev/null || true
    step "Result"
    ok "Token written to ${OUTPUT} (mode 0600)"
    [[ -n "${TOKEN_TTL}" && "${TOKEN_TTL}" != "0" ]] && \
        info "Valid for ${TOKEN_TTL}s — regenerate before the next deployment if it expires"
else
    render_output
fi

# Optionally repoint the local session at the app token. Off by default: it
# overwrites the personal login this script works so hard to preserve.
if [[ "${SET_LOCAL_TOKEN}" == true && -z "${WRAP_TTL}" ]]; then
    warn "Replacing your local Vault session (~/.vault-token) with the app token"
    vault login -no-print -method=token token="${APP_TOKEN}" >/dev/null 2>&1 \
        || die "Could not set the local session to the app token" 5
    ok "Local session now uses the app token; run 'vault login -method=${METHOD}' to get your own back"
fi

[[ "${QUIET}" == true ]] || echo >&2
exit 0
