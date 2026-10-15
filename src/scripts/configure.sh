#!/bin/bash

set -eo pipefail
set +o history
set +o xtrace

# Configure one JFrog server profile for later jf commands in this job.
#
# jf config add exits 0 when given an empty access token and still writes the
# server, so this script checks jf config show afterwards. The text format is
# used because jf 2.70.0 (the oldest version this orb installs) rejects
# `jf config show --format=json`.
#
# Secrets are passed on stdin. Password encryption is off unless asked for:
# the CLI encrypts a password by calling Artifactory, and a non-Artifactory
# HTTP 200 (an HTML page, for example) can be stored as the password while
# the command still exits 0. Access tokens are stored as themselves either way.

if ! command -v circleci >/dev/null 2>&1; then
    echo "ERROR: The circleci CLI is not on PATH, so command parameters cannot be expanded."
    exit 1
fi

# This step should not call api.github.com to ask whether a newer jf exists.
# Later jf commands in the job still do that check unless the job sets the variable.
export JFROG_CLI_AVOID_NEW_VERSION_WARNING=true

# Pipe the value on stdin. `circleci env subst` with no argument reads stdin;
# an empty argument is not a reliable way to expand an empty parameter.
subst() {
    printf '%s' "$1" | circleci env subst
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# Drop userinfo before writing a URL to the step log.
redact_url() {
    local url="$1" scheme rest hostport
    if [[ "$url" != *"://"* ]]; then
        printf '%s' "$url"
        return 0
    fi
    scheme="${url%%://*}"
    rest="${url#*://}"
    hostport="${rest%%/*}"
    if [[ "$hostport" == *"@"* ]]; then
        printf '%s://***@%s' "$scheme" "${rest#*@}"
        return 0
    fi
    printf '%s' "$url"
}

# CircleCI writes a boolean parameter into the step environment as 1 or 0.
# jf flags and the comparisons below need the words true and false.
normalize_bool() {
    local name="$1"
    local -n dest="$2"
    case "$dest" in
        true | TRUE | True | 1) dest=true ;;
        false | FALSE | False | 0) dest=false ;;
        *)
            echo "ERROR: ${name} must be true or false, not '${dest}'."
            exit 1
            ;;
    esac
}

require_http_url() {
    local name="$1" value="$2"
    if [[ -z "$value" ]]; then
        return 0
    fi
    case "$value" in
        http://* | https://*) ;;
        *)
            echo "ERROR: ${name} must start with http:// or https://."
            exit 1
            ;;
    esac
    if [[ "$value" == *$'\n'* || "$value" == *$'\t'* ]]; then
        echo "ERROR: ${name} must not contain tabs or newlines."
        exit 1
    fi
}

# True when the saved password field is an HTML document rather than a ciphertext.
password_field_is_document() {
    local contents needle
    contents="$(<"$1")"
    local needles=(
        '"password": "\u003c'
        '"password": "\u003C'
        '"password": "<'
        '"password":"\u003c'
        '"password":"\u003C'
        '"password":"<'
    )
    for needle in "${needles[@]}"; do
        if [[ "$contents" == *"$needle"* ]]; then
            return 0
        fi
    done
    return 1
}

# Value of one "Label: value" line from `jf config show`. Empty if absent.
field_value() {
    local label="$1" line value
    while IFS= read -r line; do
        if [[ "$line" == "${label}:"* ]]; then
            value="${line#"${label}:"}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            printf '%s' "$value"
            return 0
        fi
    # `read` returns 1 at EOF. Swallow that so `set -e` does not abort when the
    # label is absent; the caller treats an empty value as a missing field.
    done <<< "$SHOW_OUT" || true
}

SERVER_ID="$(trim "$(subst "${PARAM_SERVER_ID-}")")"
URL="$(trim "$(subst "${PARAM_URL-}")")"
ARTIFACTORY_URL="$(trim "$(subst "${PARAM_ARTIFACTORY_URL-}")")"
CONFIG_USER="$(trim "$(subst "${PARAM_USER-}")")"
ACCESS_TOKEN="$(trim "$(subst "${PARAM_ACCESS_TOKEN-}")")"
PASSWORD="$(trim "$(subst "${PARAM_PASSWORD-}")")"
OVERWRITE="$(trim "${PARAM_OVERWRITE-}")"
INSECURE_TLS="$(trim "${PARAM_INSECURE_TLS-}")"
ENCRYPT_PASSWORD="$(trim "${PARAM_ENCRYPT_PASSWORD-}")"
USE_SERVER="$(trim "${PARAM_USE-}")"

# The CircleCI step exports these. Drop them before jf is executed so the
# secret is not also sitting in the child process environment. The locals
# above are not exported.
unset PARAM_ACCESS_TOKEN PARAM_PASSWORD

normalize_bool overwrite OVERWRITE
normalize_bool insecure_tls INSECURE_TLS
normalize_bool encrypt_password ENCRYPT_PASSWORD
normalize_bool use USE_SERVER

if [[ -z "$SERVER_ID" ]]; then
    echo "ERROR: server_id is empty."
    exit 1
fi
if [[ "$SERVER_ID" == -* ]]; then
    echo "ERROR: server_id must not start with '-'."
    exit 1
fi
if [[ "$SERVER_ID" == *$'\n'* || "$SERVER_ID" == *$'\t'* ]]; then
    echo "ERROR: server_id must not contain tabs or newlines."
    exit 1
fi
case "$SERVER_ID" in
    delete | use | show | clear)
        echo "ERROR: server_id '${SERVER_ID}' is reserved by jf. Choose another id."
        exit 1
        ;;
esac

require_http_url url "$URL"
require_http_url artifactory_url "$ARTIFACTORY_URL"
if [[ -z "$URL" && -z "$ARTIFACTORY_URL" ]]; then
    echo "ERROR: No JFrog URL. Set url or JF_URL to the platform URL (for example https://acme.jfrog.io), or set artifactory_url."
    exit 1
fi

url_without_slash="${URL%/}"
if [[ -n "$URL" && "$url_without_slash" == */artifactory ]]; then
    echo "WARN: url ends with /artifactory. url is the JFrog Platform URL, for example https://acme.jfrog.io. Put an Artifactory-only URL in artifactory_url."
fi

if [[ -n "$ACCESS_TOKEN" && -n "$PASSWORD" ]]; then
    echo "ERROR: Both an access token and a password were provided. Set access_token or password, not both. If JF_ACCESS_TOKEN and JF_PASSWORD are both set, unset the one this job should not use."
    exit 1
fi
if [[ -z "$ACCESS_TOKEN" && -z "$PASSWORD" ]]; then
    echo "ERROR: No credentials. Set access_token or JF_ACCESS_TOKEN, or set user and password (JF_USER and JF_PASSWORD)."
    exit 1
fi
if [[ -n "$PASSWORD" && -z "$CONFIG_USER" ]]; then
    echo "ERROR: A password was provided without a user. Set user or JF_USER."
    exit 1
fi

if ! command -v jf >/dev/null 2>&1; then
    echo "ERROR: jf is not on PATH. Run the install command before configure."
    exit 1
fi

echo "Running jf configure..."
echo "  server_id: ${SERVER_ID}"
if [[ -n "$URL" ]]; then
    echo "  url: $(redact_url "$URL")"
else
    echo "  url: (unset)"
fi
if [[ -n "$ARTIFACTORY_URL" ]]; then
    echo "  artifactory_url: $(redact_url "$ARTIFACTORY_URL")"
else
    echo "  artifactory_url: (unset)"
fi
if [[ -n "$CONFIG_USER" ]]; then
    echo "  user: ${CONFIG_USER}"
else
    echo "  user: (unset)"
fi
if [[ -n "$ACCESS_TOKEN" ]]; then
    echo "  access_token: (set)"
else
    echo "  access_token: (unset)"
fi
if [[ -n "$PASSWORD" ]]; then
    echo "  password: (set)"
else
    echo "  password: (unset)"
fi
echo "  overwrite: ${OVERWRITE}"
echo "  insecure_tls: ${INSECURE_TLS}"
echo "  encrypt_password: ${ENCRYPT_PASSWORD}"
echo "  use: ${USE_SERVER}"

args=(config add "$SERVER_ID" --interactive=false "--overwrite=${OVERWRITE}" "--enc-password=${ENCRYPT_PASSWORD}")
if [[ -n "$URL" ]]; then
    args+=("--url=${URL}")
fi
if [[ -n "$ARTIFACTORY_URL" ]]; then
    args+=("--artifactory-url=${ARTIFACTORY_URL}")
fi
if [[ -n "$CONFIG_USER" ]]; then
    args+=("--user=${CONFIG_USER}")
fi
if [[ "$INSECURE_TLS" == "true" ]]; then
    args+=(--insecure-tls=true)
fi

auth_mode="token"
secret="$ACCESS_TOKEN"
if [[ -n "$ACCESS_TOKEN" ]]; then
    args+=(--access-token-stdin=true)
else
    auth_mode="password"
    secret="$PASSWORD"
    args+=(--password-stdin=true)
fi
unset ACCESS_TOKEN PASSWORD

printf '%s' "$secret" | jf "${args[@]}"
unset secret

if ! SHOW_OUT="$(jf config show "$SERVER_ID")"; then
    echo "ERROR: jf config show failed for server id '${SERVER_ID}'."
    exit 1
fi

shown_id="$(field_value "Server ID")"
shown_platform="$(field_value "JFrog Platform URL")"
shown_artifactory="$(field_value "Artifactory URL")"
shown_token="$(field_value "Access token")"
shown_password="$(field_value "Password")"

if [[ "$shown_id" != "$SERVER_ID" ]]; then
    echo "ERROR: jf config show did not report server id '${SERVER_ID}'."
    printf '%s\n' "$SHOW_OUT"
    exit 1
fi
if [[ -z "$shown_platform" && -z "$shown_artifactory" ]]; then
    echo "ERROR: jf saved server id '${SERVER_ID}' without a URL. jf config add exits 0 even when the saved profile is incomplete."
    printf '%s\n' "$SHOW_OUT"
    exit 1
fi
if [[ "$shown_token" != "***" && "$shown_password" != "***" ]]; then
    echo "ERROR: jf saved server id '${SERVER_ID}' without an access token or password. jf config add exits 0 even when the saved profile has no credentials."
    printf '%s\n' "$SHOW_OUT"
    exit 1
fi

# Opt-in encryption calls GET /artifactory/api/security/encryptedPassword. If that
# URL returns a web page, jf stores the page as the password and exits 0. Go's
# JSON encoder writes a leading "<" as "\u003c".
if [[ "$auth_mode" == "password" && "$ENCRYPT_PASSWORD" == "true" && -z "${JFROG_CLI_ENCRYPTION_KEY:-}" ]]; then
    config_home="${JFROG_CLI_HOME_DIR:-${HOME}/.jfrog}"
    config_file="${config_home}/jfrog-cli.conf.v6"
    if [[ -f "$config_file" ]] && password_field_is_document "$config_file"; then
        jf config rm "$SERVER_ID" --quiet || true
        echo "ERROR: Password encryption stored a document instead of a ciphertext. The Artifactory encryption endpoint returned a page that is not an encrypted password. Leave encrypt_password false, or point url at the JFrog Platform."
        exit 1
    fi
fi

if [[ "$USE_SERVER" == "true" ]]; then
    jf config use "$SERVER_ID"
    export JFROG_CLI_SERVER_ID="$SERVER_ID"
    if [[ -n "${BASH_ENV:-}" ]]; then
        printf 'export JFROG_CLI_SERVER_ID=%q\n' "$SERVER_ID" >> "$BASH_ENV"
    else
        echo "WARN: BASH_ENV is unset, so later steps will not see JFROG_CLI_SERVER_ID. jf config use still marked this server as the default."
    fi
fi

echo "Configured jf server '${SERVER_ID}'."
