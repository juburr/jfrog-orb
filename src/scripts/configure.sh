#!/bin/bash

set -euo pipefail
# A job can turn xtrace on for every step (SHELLOPTS, or set -x in $BASH_ENV), and it would print the token or password.
set +o xtrace

# Configure one JFrog server profile for later jf commands in this job.
#
# jf config add exits 0 when given an empty access token and still writes the
# server, so this script checks jf config show afterwards. The text format is
# used because jf 2.70.0 (the oldest version this orb installs) rejects
# `jf config show --format=json`.
#
# access_token, username and password are the names of environment variables,
# read here by indirect expansion. Secrets are passed on stdin. Password
# encryption is off unless asked for:
# the CLI encrypts a password by calling Artifactory, and a non-Artifactory
# HTTP 200 (an HTML page, for example) can be stored as the password while
# the command still exits 0. Access tokens are stored as themselves either way.

# This step should not call api.github.com to ask whether a newer jf exists.
# Later jf commands in the job still do that check unless the job sets the variable.
export JFROG_CLI_AVOID_NEW_VERSION_WARNING=true

# Expand environment variables in a parameter value. With the circleci CLI,
# the value is piped to `circleci env subst` on stdin: with no argument it
# reads stdin, and an empty argument is not a reliable way to expand an empty
# parameter. Without the CLI, as on a GitHub Actions runner, $NAME and ${NAME}
# are replaced here with the value of that exported variable (the variables
# the CLI would see), or with nothing, so url's default ${JF_URL} reads JF_URL
# there too. Nothing else in the value is expanded or run.
subst() {
    if command -v circleci >/dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
        return
    fi
    local subst_rest="$1" subst_out="" subst_ref subst_name subst_decl
    # shellcheck disable=SC2016 # a regular expression, not an expansion
    local subst_re='\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|[A-Za-z_][A-Za-z0-9_]*)'
    # Ranges in a bracket expression follow the locale; in C they are ASCII only.
    local LC_ALL=C
    while [[ "$subst_rest" =~ $subst_re ]]; do
        subst_ref="${BASH_REMATCH[0]}"
        subst_name="${BASH_REMATCH[2]:-${BASH_REMATCH[1]}}"
        subst_out+="${subst_rest%%"$subst_ref"*}"
        subst_rest="${subst_rest#*"$subst_ref"}"
        subst_decl="$(declare -p "$subst_name" 2>/dev/null)" || subst_decl=""
        subst_decl="${subst_decl#declare -}"
        if [[ "${subst_decl%% *}" == *x* ]]; then
            subst_out+="${!subst_name-}"
        fi
    done
    printf '%s' "${subst_out}${subst_rest}"
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
# printf -v assigns by name without `local -n`, which Bash 4.2 does not have.
normalize_bool() {
    local name="$1" value="$2" dest="$3" normalized
    case "$value" in
        true | TRUE | True | 1) normalized=true ;;
        false | FALSE | False | 0) normalized=false ;;
        *)
            echo "ERROR: ${name} must be true or false, not '${value}'." >&2
            exit 1
            ;;
    esac
    printf -v "$dest" '%s' "$normalized"
}

# CircleCI checks the env_var_name type, but the script can also be run
# directly, and bash fails on an indirect expansion of an invalid name.
require_env_var_name() {
    local name="$1" value="$2"
    if [[ ! "$value" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "ERROR: ${name} must be the name of an environment variable, not '${value}'." >&2
        exit 1
    fi
    # The step sets PARAM_* to this command's parameter values, replacing any
    # variable of the same name before this script can read it.
    if [[ "$value" == PARAM_* ]]; then
        echo "ERROR: ${name} names ${value}, but PARAM_* variables are reserved for this command's parameters. Store the secret under another name." >&2
        exit 1
    fi
}

require_http_url() {
    local name="$1" value="$2"
    if [[ -z "$value" ]]; then
        return 0
    fi
    case "$value" in
        http://* | https://*) ;;
        *)
            echo "ERROR: ${name} must start with http:// or https://." >&2
            exit 1
            ;;
    esac
    if [[ "$value" == *$'\n'* || "$value" == *$'\t'* ]]; then
        echo "ERROR: ${name} must not contain tabs or newlines." >&2
        exit 1
    fi
}

json_unescape() {
    local raw="$1" out="" i=0 len c nxt hex char bs=$'\\'
    len=${#raw}
    while (( i < len )); do
        c="${raw:i:1}"
        if [[ "$c" != $'\\' ]]; then
            out+="$c"
            i=$((i + 1))
            continue
        fi
        nxt="${raw:i+1:1}"
        case "$nxt" in
            n) out+=$'\n' ;;
            r) out+=$'\r' ;;
            t) out+=$'\t' ;;
            b) out+=$'\b' ;;
            f) out+=$'\f' ;;
            "$bs") out+=$'\\' ;;
            '"') out+='"' ;;
            /) out+='/' ;;
            u)
                hex="${raw:i+2:4}"
                if [[ "$hex" =~ ^[0-9a-fA-F]{4}$ ]]; then
                    printf -v char '%b' "\\u${hex}"
                    out+="$char"
                    i=$((i + 6))
                    continue
                fi
                out+="\\u"
                i=$((i + 2))
                continue
                ;;
            *) out+="$nxt" ;;
        esac
        i=$((i + 2))
    done
    printf '%s' "$out"
}

# True when the decoded password, after leading whitespace and a BOM, is a
# document. Go's encoding/json writes "<" as "\u003c", and a page can be stored
# with a newline or BOM in front of that character.
password_is_document() {
    local value="$1" c
    while [[ -n "$value" ]]; do
        c="${value:0:1}"
        case "$c" in
            [[:space:]] | $'\ufeff' | $'\u00a0')
                value="${value:1}"
                ;;
            *)
                break
                ;;
        esac
    done
    [[ "$value" == "<"* ]]
}

# Print the unescaped password stored for want_id. Other servers in the same
# document are ignored. Returns 1 when that server has no password field.
saved_password_for_server() {
    local json="$1" want="$2"
    local i=0 len=${#json} c depth=0 in_str=0 esc=0
    local buf="" mode="seek" key="" decoded_id
    local -a got_id got_pw seen_pw
    while (( i < len )); do
        c="${json:i:1}"
        if (( in_str )); then
            if (( esc )); then
                buf+="$c"
                esc=0
            elif [[ "$c" == $'\\' ]]; then
                buf+="$c"
                esc=1
            elif [[ "$c" == '"' ]]; then
                in_str=0
                if [[ "$mode" == "key" ]]; then
                    key="$buf"
                    mode="colon"
                elif [[ "$mode" == "value" ]]; then
                    if [[ "$key" == "password" ]]; then
                        got_pw[depth]="$buf"
                        seen_pw[depth]=1
                    elif [[ "$key" == "serverId" ]]; then
                        got_id[depth]="$buf"
                    fi
                    key=""
                    mode="seek"
                fi
                buf=""
            else
                buf+="$c"
            fi
            i=$((i + 1))
            continue
        fi
        case "$c" in
            '"')
                in_str=1
                buf=""
                if [[ "$mode" == "seek" ]]; then
                    mode="key"
                fi
                ;;
            '{')
                depth=$((depth + 1))
                got_id[depth]=""
                got_pw[depth]=""
                seen_pw[depth]=0
                mode="seek"
                key=""
                ;;
            '}')
                if (( depth > 0 )) && [[ "${seen_pw[depth]:-0}" == 1 ]]; then
                    decoded_id="$(json_unescape "${got_id[depth]}")"
                    if [[ "$decoded_id" == "$want" ]]; then
                        json_unescape "${got_pw[depth]}"
                        return 0
                    fi
                fi
                if (( depth > 0 )); then
                    depth=$((depth - 1))
                fi
                mode="seek"
                key=""
                ;;
            ':')
                if [[ "$mode" == "colon" ]]; then
                    mode="value"
                fi
                ;;
            ',')
                mode="seek"
                key=""
                ;;
        esac
        i=$((i + 1))
    done
    return 1
}

# jf config show masks a saved secret as "***". A decodable access token also
# gets a subject suffix, for example: *** (Subject: 'jffe@000/users/ci').
secret_is_masked() {
    local value="$1"
    [[ "$value" == "***" || "$value" == "*** "* ]]
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

require_env_var_name access_token "${PARAM_ACCESS_TOKEN-}"
require_env_var_name username "${PARAM_USERNAME-}"
require_env_var_name password "${PARAM_PASSWORD-}"
# Read all three in one statement, before this script assigns a variable that
# could share a name with one of them (ACCESS_TOKEN, PASSWORD, URL, ...).
CREDENTIALS=("${!PARAM_USERNAME:-}" "${!PARAM_ACCESS_TOKEN:-}" "${!PARAM_PASSWORD:-}")
ACCESS_TOKEN_VAR="$PARAM_ACCESS_TOKEN"
USERNAME_VAR="$PARAM_USERNAME"
PASSWORD_VAR="$PARAM_PASSWORD"

# The variables that hold the token and password are exported to this step.
# Stop exporting them, and drop the parameters that name them, before jf is
# executed so the secret is not also sitting in the child process environment.
# export -n keeps the value, so a name this script also uses is not lost, and
# later steps still see the variables. The variables below are not exported.
export -n "${ACCESS_TOKEN_VAR?}" "${PASSWORD_VAR?}"
unset PARAM_ACCESS_TOKEN PARAM_PASSWORD

SERVER_ID="$(trim "$(subst "${PARAM_SERVER_ID-}")")"
URL="$(trim "$(subst "${PARAM_URL-}")")"
ARTIFACTORY_URL="$(trim "$(subst "${PARAM_ARTIFACTORY_URL-}")")"
CONFIG_USER="$(trim "${CREDENTIALS[0]}")"
ACCESS_TOKEN="$(trim "${CREDENTIALS[1]}")"
# jf itself trims password stdin (checked on 2.70.0 and 2.125.0), so this trim
# does not change what is stored. It does make a whitespace-only password fail
# as missing credentials instead of being saved empty.
PASSWORD="$(trim "${CREDENTIALS[2]}")"
unset CREDENTIALS
OVERWRITE="$(trim "${PARAM_OVERWRITE-}")"
INSECURE_TLS="$(trim "${PARAM_INSECURE_TLS-}")"
ENCRYPT_PASSWORD="$(trim "${PARAM_ENCRYPT_PASSWORD-}")"
SET_DEFAULT="$(trim "${PARAM_SET_DEFAULT-}")"

normalize_bool overwrite "$OVERWRITE" OVERWRITE
normalize_bool insecure_tls "$INSECURE_TLS" INSECURE_TLS
normalize_bool encrypt_password "$ENCRYPT_PASSWORD" ENCRYPT_PASSWORD
normalize_bool set_default "$SET_DEFAULT" SET_DEFAULT

if [[ -z "$SERVER_ID" ]]; then
    echo "ERROR: server_id is empty." >&2
    exit 1
fi
if [[ "$SERVER_ID" == -* ]]; then
    echo "ERROR: server_id must not start with '-'." >&2
    exit 1
fi
if [[ "$SERVER_ID" == *$'\n'* || "$SERVER_ID" == *$'\t'* ]]; then
    echo "ERROR: server_id must not contain tabs or newlines." >&2
    exit 1
fi
case "$SERVER_ID" in
    delete | use | show | clear)
        echo "ERROR: server_id '${SERVER_ID}' is reserved by jf. Choose another id." >&2
        exit 1
        ;;
esac

require_http_url url "$URL"
require_http_url artifactory_url "$ARTIFACTORY_URL"
if [[ -z "$URL" && -z "$ARTIFACTORY_URL" ]]; then
    echo "ERROR: No JFrog URL. Set url or JF_URL to the platform URL (for example https://acme.jfrog.io), or set artifactory_url." >&2
    exit 1
fi

url_without_slash="${URL%/}"
if [[ -n "$URL" && "$url_without_slash" == */artifactory ]]; then
    echo "WARN: url ends with /artifactory. url is the JFrog Platform URL, for example https://acme.jfrog.io. Put an Artifactory-only URL in artifactory_url." >&2
fi

if [[ -n "$ACCESS_TOKEN" && -n "$PASSWORD" ]]; then
    echo "ERROR: Both an access token and a password were provided: ${ACCESS_TOKEN_VAR} (named by access_token) and ${PASSWORD_VAR} (named by password) are both set. Unset the one this job should not use, or point its parameter at a variable that is not set." >&2
    exit 1
fi
if [[ -z "$ACCESS_TOKEN" && -z "$PASSWORD" ]]; then
    echo "ERROR: No credentials. Set ${ACCESS_TOKEN_VAR} (named by access_token), or set ${USERNAME_VAR} and ${PASSWORD_VAR} (named by username and password)." >&2
    exit 1
fi
if [[ -n "$PASSWORD" && -z "$CONFIG_USER" ]]; then
    echo "ERROR: A password was provided without a username. Set ${USERNAME_VAR} (named by username)." >&2
    exit 1
fi

if ! command -v jf >/dev/null 2>&1; then
    echo "ERROR: jf is not on PATH. Run the install command before configure." >&2
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
    echo "  username: ${USERNAME_VAR} (${CONFIG_USER})"
else
    echo "  username: ${USERNAME_VAR} (unset)"
fi
if [[ -n "$ACCESS_TOKEN" ]]; then
    echo "  access_token: ${ACCESS_TOKEN_VAR} (set)"
else
    echo "  access_token: ${ACCESS_TOKEN_VAR} (unset)"
fi
if [[ -n "$PASSWORD" ]]; then
    echo "  password: ${PASSWORD_VAR} (set)"
else
    echo "  password: ${PASSWORD_VAR} (unset)"
fi
echo "  overwrite: ${OVERWRITE}"
echo "  insecure_tls: ${INSECURE_TLS}"
echo "  encrypt_password: ${ENCRYPT_PASSWORD}"
echo "  set_default: ${SET_DEFAULT}"

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
    echo "ERROR: jf config show failed for server id '${SERVER_ID}'." >&2
    exit 1
fi

shown_id="$(field_value "Server ID")"
shown_platform="$(field_value "JFrog Platform URL")"
shown_artifactory="$(field_value "Artifactory URL")"
shown_token="$(field_value "Access token")"
shown_password="$(field_value "Password")"

if [[ "$shown_id" != "$SERVER_ID" ]]; then
    echo "ERROR: jf config show did not report server id '${SERVER_ID}'." >&2
    printf '%s\n' "$SHOW_OUT" >&2
    exit 1
fi
if [[ -z "$shown_platform" && -z "$shown_artifactory" ]]; then
    echo "ERROR: jf saved server id '${SERVER_ID}' without a URL. jf config add exits 0 even when the saved profile is incomplete." >&2
    printf '%s\n' "$SHOW_OUT" >&2
    exit 1
fi
if ! secret_is_masked "$shown_token" && ! secret_is_masked "$shown_password"; then
    echo "ERROR: jf saved server id '${SERVER_ID}' without an access token or password. jf config add exits 0 even when the saved profile has no credentials." >&2
    printf '%s\n' "$SHOW_OUT" >&2
    exit 1
fi

# Opt-in encryption calls GET /artifactory/api/security/encryptedPassword. If that
# URL returns a web page, jf stores the page as the password and exits 0.
# `jf config export` returns that password in the clear even when
# JFROG_CLI_ENCRYPTION_KEY or security/security.yaml has encrypted the file.
if [[ "$auth_mode" == "password" && "$ENCRYPT_PASSWORD" == "true" ]]; then
    if ! command -v base64 >/dev/null 2>&1; then
        jf config rm "$SERVER_ID" --quiet || true
        echo "ERROR: Password encryption could not be checked because base64 is not on PATH. The server profile was removed." >&2
        exit 1
    fi
    export_token="$(jf config export "$SERVER_ID")" || {
        jf config rm "$SERVER_ID" --quiet || true
        echo "ERROR: Could not read the saved password back to verify encryption. The server profile was removed." >&2
        exit 1
    }
    export_token="${export_token//$'\n'/}"
    export_token="${export_token//$'\r'/}"
    export_token="${export_token//-/+}"
    export_token="${export_token//_//}"
    case $((${#export_token} % 4)) in
        2) export_token+='==' ;;
        3) export_token+='=' ;;
        1)
            unset export_token
            jf config rm "$SERVER_ID" --quiet || true
            echo "ERROR: Could not read the saved password back to verify encryption. The server profile was removed." >&2
            exit 1
            ;;
    esac
    if ! decoded="$(printf '%s' "$export_token" | base64 -d 2>/dev/null)"; then
        unset export_token decoded
        jf config rm "$SERVER_ID" --quiet || true
        echo "ERROR: Could not read the saved password back to verify encryption. The server profile was removed." >&2
        exit 1
    fi
    unset export_token
    if ! saved_password="$(saved_password_for_server "$decoded" "$SERVER_ID")"; then
        unset decoded saved_password
        jf config rm "$SERVER_ID" --quiet || true
        echo "ERROR: Could not read the saved password for server id '${SERVER_ID}'. The server profile was removed." >&2
        exit 1
    fi
    unset decoded
    if password_is_document "$saved_password"; then
        unset saved_password
        jf config rm "$SERVER_ID" --quiet || true
        echo "ERROR: Password encryption stored a document instead of a ciphertext. The Artifactory encryption endpoint returned a page that is not an encrypted password. Leave encrypt_password false, or point url at the JFrog Platform." >&2
        exit 1
    fi
    unset saved_password
fi

if [[ "$SET_DEFAULT" == "true" ]]; then
    jf config use "$SERVER_ID"
    export JFROG_CLI_SERVER_ID="$SERVER_ID"
    if [[ -n "${BASH_ENV:-}" ]]; then
        printf 'export JFROG_CLI_SERVER_ID=%q\n' "$SERVER_ID" >> "$BASH_ENV"
    else
        echo "WARN: BASH_ENV is unset, so later steps will not see JFROG_CLI_SERVER_ID. jf config use still marked this server as the default." >&2
    fi
fi

echo "Configured jf server '${SERVER_ID}'."
