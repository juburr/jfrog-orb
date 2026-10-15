#!/bin/bash

set -eo pipefail
set +o history
set +o xtrace

# Ping Artifactory with the server profile written by configure.
# A successful ping means that URL answered. It does not prove permission to a
# repository, and an anonymous Artifactory returns OK for a wrong token.

if ! command -v circleci >/dev/null 2>&1; then
    echo "ERROR: The circleci CLI is not on PATH, so command parameters cannot be expanded."
    exit 1
fi

# This step should not call api.github.com to ask whether a newer jf exists.
# Later jf commands in the job still do that check unless the job sets the variable.
export JFROG_CLI_AVOID_NEW_VERSION_WARNING=true

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# CircleCI writes a boolean parameter into the step environment as 1 or 0.
# The insecure-tls flag below needs the word true.
# printf -v assigns by name without `local -n`, which Bash 4.2 does not have.
normalize_bool() {
    local name="$1" value="$2" dest="$3" normalized
    case "$value" in
        true | TRUE | True | 1) normalized=true ;;
        false | FALSE | False | 0) normalized=false ;;
        *)
            echo "ERROR: ${name} must be true or false, not '${value}'."
            exit 1
            ;;
    esac
    printf -v "$dest" '%s' "$normalized"
}

# Pipe the value on stdin. `circleci env subst` with no argument reads stdin;
# an empty argument is not a reliable way to expand an empty parameter.
SERVER_ID="$(trim "$(printf '%s' "${PARAM_SERVER_ID-}" | circleci env subst)")"
INSECURE_TLS="$(trim "${PARAM_INSECURE_TLS-}")"
normalize_bool insecure_tls "$INSECURE_TLS" INSECURE_TLS

# An empty server_id follows the id configure exported, then jf's default server.
if [[ -z "$SERVER_ID" && -n "${JFROG_CLI_SERVER_ID:-}" ]]; then
    SERVER_ID="${JFROG_CLI_SERVER_ID}"
fi
if [[ -n "$SERVER_ID" && "$SERVER_ID" == -* ]]; then
    echo "ERROR: server_id must not start with '-'."
    exit 1
fi

if ! command -v jf >/dev/null 2>&1; then
    echo "ERROR: jf is not on PATH. Run the install command before ping."
    exit 1
fi

if [[ -n "$SERVER_ID" ]]; then
    echo "Pinging Artifactory (server id: ${SERVER_ID})."
else
    echo "Pinging Artifactory (server id: the default server)."
fi

args=(rt ping)
if [[ -n "$SERVER_ID" ]]; then
    args+=("--server-id=${SERVER_ID}")
fi
if [[ "$INSECURE_TLS" == "true" ]]; then
    args+=(--insecure-tls=true)
fi

jf "${args[@]}"
