#!/bin/bash

set -euo pipefail
# A job can turn xtrace on for every step (SHELLOPTS, or set -x in $BASH_ENV); keep it off here as configure does.
set +o xtrace

# Ping Artifactory with the server profile written by configure.
# A successful ping means that URL answered. It does not prove permission to a
# repository, and an anonymous Artifactory returns OK for a wrong token.

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

# CircleCI writes a boolean parameter into the step environment as 1 or 0.
# The insecure-tls flag below needs the word true.
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

SERVER_ID="$(trim "$(subst "${PARAM_SERVER_ID-}")")"
INSECURE_TLS="$(trim "${PARAM_INSECURE_TLS-}")"
normalize_bool insecure_tls "$INSECURE_TLS" INSECURE_TLS

# An empty server_id follows the id configure exported, then jf's default server.
if [[ -z "$SERVER_ID" && -n "${JFROG_CLI_SERVER_ID:-}" ]]; then
    SERVER_ID="${JFROG_CLI_SERVER_ID}"
fi
if [[ -n "$SERVER_ID" && "$SERVER_ID" == -* ]]; then
    echo "ERROR: server_id must not start with '-'." >&2
    exit 1
fi

if ! command -v jf >/dev/null 2>&1; then
    echo "ERROR: jf is not on PATH. Run the install command before ping." >&2
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
