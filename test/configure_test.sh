#!/usr/bin/env bash
# Tests for src/scripts/configure.sh.
#
# Locks these behaviors:
#   missing URL, missing credentials, or both a token and a password fail
#     before jf is executed
#   the access token or password is passed on stdin, not as an argument
#   an empty token saved by jf config add is still a failure
#   password encryption is off unless encrypt_password is true
#   an encrypted password that is actually an HTML document is rejected
#   use exports JFROG_CLI_SERVER_ID for later steps
#   the command does not call api.github.com to check for a newer jf
#
# jf is stubbed, so no network access is needed.
# Set RUN_REAL_JF=1 to also run the script against jf binaries named by JF_BIN
# (default: /tmp/jf-research/jf and /tmp/jf-research/jf-2.70.0 when present).
#
# Run from a checkout:
#   bash test/configure_test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${CONFIGURE_SCRIPT:-${ROOT}/src/scripts/configure.sh}"
COMMAND="${ROOT}/src/commands/configure.yml"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BIN="${TMP}/bin"
BIN_NO_JF="${TMP}/bin-no-jf"
BIN_NO_CIRCLECI="${TMP}/bin-no-circleci"
mkdir -p "$BIN" "$BIN_NO_JF" "$BIN_NO_CIRCLECI"
# The stubs read stdin with cat. Nothing else from the system PATH is visible
# to the script under test, so a real jf cannot be picked up by accident.
ln -s "$(command -v cat)" "${BIN}/cat"
ln -s "$(command -v cat)" "${BIN_NO_JF}/cat"
ln -s "$(command -v cat)" "${BIN_NO_CIRCLECI}/cat"

# Expand ${VAR} and $VAR the way `circleci env subst` does, including unset vars.
cat > "${BIN}/circleci" << 'EOF'
#!/bin/bash
if [[ "${1:-}" != "env" || "${2:-}" != "subst" ]]; then
  echo "unexpected circleci invocation" >&2
  exit 1
fi
if [[ $# -ge 3 ]]; then
  input="$3"
else
  input="$(cat)"
fi
out=""
i=0
len=${#input}
while [[ $i -lt $len ]]; do
  char="${input:i:1}"
  if [[ "$char" != '$' ]]; then
    out+="$char"
    i=$((i + 1))
    continue
  fi
  nxt="${input:i+1:1}"
  if [[ "$nxt" == '{' ]]; then
    i=$((i + 2))
    name=""
    while [[ $i -lt $len && "${input:i:1}" != '}' ]]; do
      name+="${input:i:1}"
      i=$((i + 1))
    done
    if [[ $i -lt $len && "${input:i:1}" == '}' ]]; then
      i=$((i + 1))
    fi
  elif [[ "$nxt" =~ [A-Za-z_] ]]; then
    i=$((i + 1))
    name=""
    while [[ $i -lt $len && "${input:i:1}" =~ [A-Za-z0-9_] ]]; do
      name+="${input:i:1}"
      i=$((i + 1))
    done
  else
    out+="$char"
    i=$((i + 1))
    continue
  fi
  if [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    out+="${!name-}"
  fi
done
printf '%s' "$out"
EOF
chmod +x "${BIN}/circleci"
ln -s "${BIN}/circleci" "${BIN_NO_JF}/circleci"

cat > "${BIN}/jf" << 'EOF'
#!/bin/bash
{
  printf '%q ' "$@"
  printf '\n'
  printf 'ENV warning=%s\n' "${JFROG_CLI_AVOID_NEW_VERSION_WARNING-}"
} >> "${JF_LOG:?}"

if [[ "${1:-}" == "config" && "${2:-}" == "add" ]]; then
  cat > "${JF_ADD_STDIN:?}"
  exit "${JF_ADD_EXIT:-0}"
fi
if [[ "${1:-}" == "config" && "${2:-}" == "show" ]]; then
  if [[ "${JF_SHOW_EXIT:-0}" != "0" ]]; then
    echo "show failed" >&2
    exit "$JF_SHOW_EXIT"
  fi
  if [[ -n "${JF_SHOW_FILE:-}" ]]; then
    cat "$JF_SHOW_FILE"
    exit 0
  fi
  printf 'Server ID: %s\n' "${3:-}"
  printf 'JFrog Platform URL: https://example.jfrog.io/\n'
  printf 'Access token: ***\n'
  printf 'Default: true\n'
  exit 0
fi
if [[ "${1:-}" == "config" && "${2:-}" == "use" ]]; then
  exit 0
fi
if [[ "${1:-}" == "config" && "${2:-}" == "rm" ]]; then
  exit 0
fi
echo "unexpected jf command: $*" >&2
exit 1
EOF
chmod +x "${BIN}/jf"
ln -s "${BIN}/jf" "${BIN_NO_CIRCLECI}/jf"

export JF_LOG="${TMP}/jf.log"
export JF_ADD_STDIN="${TMP}/add.stdin"
export JF_ADD_EXIT=0
export JF_SHOW_EXIT=0

FAILURES=0
CASE_N=0
LAST_OUT=""
LAST_BASH=""

ok() { printf 'ok: %s\n' "$1"; }
bad() {
  printf 'FAIL: %s: %s\n' "$1" "$2"
  FAILURES=$((FAILURES + 1))
}

set_defaults() {
  export PARAM_SERVER_ID=jfrog-server
  export PARAM_URL=https://example.jfrog.io
  export PARAM_ARTIFACTORY_URL=
  export PARAM_ACCESS_TOKEN=token-secret-value
  export PARAM_USER=
  export PARAM_PASSWORD=
  export PARAM_OVERWRITE=true
  export PARAM_INSECURE_TLS=false
  export PARAM_ENCRYPT_PASSWORD=false
  export PARAM_USE=true
  export JF_ADD_EXIT=0
  export JF_SHOW_EXIT=0
  export JFROG_CLI_HOME_DIR="${TMP}/jfrog-home"
  mkdir -p "$JFROG_CLI_HOME_DIR"
  rm -f "${JFROG_CLI_HOME_DIR}/jfrog-cli.conf.v6"
  unset PATH_MODE UNSET_BASH_ENV JF_SHOW_FILE JF_URL JF_ACCESS_TOKEN JF_USER JF_PASSWORD
  unset JFROG_CLI_ENCRYPTION_KEY
}

# run_configure NAME WANT(pass|fail) EXPECTED_OUTPUT
run_configure() {
  local name="$1" want="$2" expected="$3"
  local work status path problem
  CASE_N=$((CASE_N + 1))
  work="${TMP}/work-${CASE_N}"
  mkdir -p "$work"
  : > "$JF_LOG"
  rm -f "$JF_ADD_STDIN"
  export BASH_ENV="${work}/bash.env"
  : > "$BASH_ENV"
  path="$BIN"
  if [[ "${PATH_MODE:-}" == "no-jf" ]]; then
    path="$BIN_NO_JF"
  elif [[ "${PATH_MODE:-}" == "no-circleci" ]]; then
    path="$BIN_NO_CIRCLECI"
  fi
  set +e
  (
    cd "$work"
    if [[ "${UNSET_BASH_ENV:-}" == "1" ]]; then
      unset BASH_ENV
    fi
    PATH="$path" /bin/bash "$SCRIPT" > "${work}/out" 2>&1
  )
  status=$?
  set -e
  LAST_OUT="${work}/out"
  LAST_BASH="$BASH_ENV"

  problem=""
  if [[ "$want" == "pass" && "$status" -ne 0 ]]; then
    problem="exit ${status}, wanted success"
  elif [[ "$want" == "fail" && "$status" -eq 0 ]]; then
    problem="succeeded, wanted a failure"
  elif [[ -n "$expected" ]] && ! grep -qF -- "$expected" "$LAST_OUT"; then
    problem="output did not mention '${expected}'"
  fi
  if [[ -n "$problem" ]]; then
    bad "$name" "$problem"
    sed 's/^/    /' "$LAST_OUT"
  else
    ok "$name"
  fi
}

assert_log_has() {
  local name="$1" needle="$2"
  if grep -qF -- "$needle" "$JF_LOG"; then
    ok "$name"
  else
    bad "$name" "jf log missing '${needle}'"
    sed 's/^/    /' "$JF_LOG"
  fi
}

assert_log_lacks() {
  local name="$1" needle="$2"
  if grep -qF -- "$needle" "$JF_LOG"; then
    bad "$name" "jf log contained '${needle}'"
    sed 's/^/    /' "$JF_LOG"
  else
    ok "$name"
  fi
}

assert_not_called() {
  local name="$1"
  if [[ -s "$JF_LOG" ]]; then
    bad "$name" "jf was called"
    sed 's/^/    /' "$JF_LOG"
  else
    ok "$name"
  fi
}

assert_stdin() {
  local name="$1" expected="$2" got
  if [[ ! -f "$JF_ADD_STDIN" ]]; then
    bad "$name" "jf config add was not run"
    return 0
  fi
  got="$(cat "$JF_ADD_STDIN")"
  if [[ "$got" == "$expected" ]]; then
    ok "$name"
  else
    bad "$name" "stdin did not match the secret"
  fi
}

assert_out_lacks() {
  local name="$1" needle="$2"
  if grep -qF -- "$needle" "$LAST_OUT"; then
    bad "$name" "step output contained '${needle}'"
  else
    ok "$name"
  fi
}

yaml_default() {
  local key="$1"
  awk -v key="$key" '
    $0 ~ "^  " key ":" {found=1; next}
    found && /^    default:/ {
      sub(/^    default:[[:space:]]*/, "")
      print
      exit
    }
    found && /^  [^ ]/ {exit}
  ' "$COMMAND"
}

TOKEN=token-secret-value

set_defaults
run_configure "token is saved and checked" pass "Configured jf server 'jfrog-server'."
assert_log_has "config add is invoked" "config add jfrog-server"
assert_log_has "token uses stdin" "--access-token-stdin=true"
assert_log_has "interactive is off" "--interactive=false"
assert_log_has "overwrite defaults on" "--overwrite=true"
assert_log_has "password encryption defaults off" "--enc-password=false"
assert_log_has "platform url is passed" "--url=https://example.jfrog.io"
assert_log_has "server is selected with config use" "config use jfrog-server"
assert_log_has "version check is disabled for this step" "ENV warning=true"
assert_log_lacks "token is not an argument" "$TOKEN"
assert_stdin "token is the stdin payload" "$TOKEN"
assert_out_lacks "token is not in the step output" "$TOKEN"
if [[ -f "$LAST_BASH" ]] && grep -qxF 'export JFROG_CLI_SERVER_ID=jfrog-server' "$LAST_BASH"; then
  ok "BASH_ENV exports the server id"
else
  bad "BASH_ENV exports the server id" "missing export in ${LAST_BASH}"
  sed 's/^/    /' "$LAST_BASH" || true
fi

set_defaults
export PARAM_USER=ci
run_configure "user is stored with an access token" pass "Configured jf server 'jfrog-server'."
assert_log_has "user flag is passed" "--user=ci"
assert_log_has "token stdin stays in use" "--access-token-stdin=true"
assert_log_lacks "password stdin is not used" "--password-stdin=true"

set_defaults
export PARAM_ACCESS_TOKEN=
export PARAM_USER=ci
export PARAM_PASSWORD=password-secret-value
export JF_SHOW_FILE="${TMP}/show-password.txt"
cat > "$JF_SHOW_FILE" << 'EOF'
Server ID: jfrog-server
JFrog Platform URL: https://example.jfrog.io/
User: ci
Password: ***
Default: true
EOF
run_configure "password auth uses stdin and does not encrypt" pass "Configured jf server 'jfrog-server'."
assert_log_has "password uses stdin" "--password-stdin=true"
assert_log_has "encryption flag is false" "--enc-password=false"
assert_log_has "password auth passes the user" "--user=ci"
assert_log_lacks "token stdin is not used for a password" "--access-token-stdin=true"
assert_log_lacks "password is not an argument" "password-secret-value"
assert_stdin "password is the stdin payload" "password-secret-value"
assert_out_lacks "password is not in the step output" "password-secret-value"

set_defaults
export PARAM_ACCESS_TOKEN=
export PARAM_PASSWORD=
run_configure "missing credentials fail" fail "No credentials."
assert_not_called "missing credentials do not call jf"

set_defaults
export PARAM_PASSWORD=password-secret-value
run_configure "token and password together fail" fail "Both an access token and a password"
assert_not_called "mixed credentials do not call jf"

set_defaults
export PARAM_ACCESS_TOKEN=
export PARAM_PASSWORD=password-secret-value
export PARAM_USER=
run_configure "password without a user fails" fail "without a user"
assert_not_called "password without a user does not call jf"

set_defaults
export PARAM_URL=
export PARAM_ARTIFACTORY_URL=
run_configure "missing url fails" fail "No JFrog URL."
assert_not_called "missing url does not call jf"

set_defaults
export PARAM_URL=ftp://example.jfrog.io
run_configure "a non-http url fails" fail "must start with http:// or https://"
assert_not_called "a non-http url does not call jf"
assert_out_lacks "a rejected url is not echoed" "ftp://example.jfrog.io"

set_defaults
export PARAM_URL=
export PARAM_ARTIFACTORY_URL=https://art.example.jfrog.io/artifactory
export JF_SHOW_FILE="${TMP}/show-artifactory.txt"
cat > "$JF_SHOW_FILE" << 'EOF'
Server ID: jfrog-server
Artifactory URL: https://art.example.jfrog.io/artifactory/
Access token: ***
Default: true
EOF
run_configure "artifactory url alone is accepted" pass "Configured jf server 'jfrog-server'."
assert_log_has "artifactory url is passed" "--artifactory-url=https://art.example.jfrog.io/artifactory"
assert_log_lacks "platform url is omitted" "--url="

for reserved in delete use show clear; do
  set_defaults
  export PARAM_SERVER_ID="$reserved"
  run_configure "reserved server id ${reserved} fails" fail "is reserved by jf"
  assert_not_called "reserved server id ${reserved} does not call jf"
done

set_defaults
export PARAM_SERVER_ID=
run_configure "empty server id fails" fail "server_id is empty."
assert_not_called "empty server id does not call jf"

set_defaults
export PARAM_SERVER_ID=-jfrog
run_configure "a server id starting with a dash fails" fail "must not start with '-'"
assert_not_called "a dashed server id does not call jf"

set_defaults
export PARAM_URL=https://example.jfrog.io/artifactory
run_configure "platform url ending in /artifactory warns" pass "WARN: url ends with /artifactory."

set_defaults
export PARAM_URL=https://example.jfrog.io/artifactory/
run_configure "trailing slash still warns about /artifactory" pass "WARN: url ends with /artifactory."

set_defaults
export PARAM_OVERWRITE=false
run_configure "overwrite can be turned off" pass "Configured jf server 'jfrog-server'."
assert_log_has "overwrite false is passed through" "--overwrite=false"

set_defaults
export PARAM_INSECURE_TLS=true
run_configure "insecure tls is passed through" pass "Configured jf server 'jfrog-server'."
assert_log_has "insecure tls flag" "--insecure-tls=true"

# CircleCI injects boolean parameters as 1 and 0 when they are step environment values.
set_defaults
export PARAM_OVERWRITE=1
export PARAM_INSECURE_TLS=0
export PARAM_ENCRYPT_PASSWORD=0
export PARAM_USE=1
run_configure "circleci boolean 1 and 0 are accepted" pass "Configured jf server 'jfrog-server'."
assert_log_has "overwrite 1 becomes true" "--overwrite=true"
assert_log_lacks "overwrite is not passed as 1" "--overwrite=1"
assert_log_has "encrypt 0 becomes false" "--enc-password=false"
assert_log_lacks "encrypt is not passed as 0" "--enc-password=0"
assert_log_has "use 1 still selects the server" "config use jfrog-server"
assert_log_lacks "insecure tls 0 stays off" "--insecure-tls=true"
assert_out_lacks "normalized overwrite is logged as true" "overwrite: 1"

set_defaults
export PARAM_OVERWRITE=0
export PARAM_USE=0
export PARAM_INSECURE_TLS=1
run_configure "circleci boolean 0 turns flags off" pass "Configured jf server 'jfrog-server'."
assert_log_has "overwrite 0 becomes false" "--overwrite=false"
assert_log_has "insecure tls 1 becomes the flag" "--insecure-tls=true"
assert_log_lacks "use 0 skips config use" "config use"

set_defaults
export PARAM_USE=false
run_configure "use false does not change the default server" pass "Configured jf server 'jfrog-server'."
assert_log_lacks "config use is skipped" "config use"
if [[ -s "$LAST_BASH" ]]; then
  bad "use false leaves BASH_ENV unchanged" "BASH_ENV was written"
  sed 's/^/    /' "$LAST_BASH"
else
  ok "use false leaves BASH_ENV unchanged"
fi

set_defaults
export PARAM_SERVER_ID='my server'
run_configure "server id with a space is exported safely" pass "Configured jf server 'my server'."
got_id="$(BASH_ENV="$LAST_BASH" /bin/bash -c 'printf %s "$JFROG_CLI_SERVER_ID"')"
if [[ "$got_id" == "my server" ]]; then
  ok "BASH_ENV round-trips a server id with a space"
else
  bad "BASH_ENV round-trips a server id with a space" "got '${got_id}'"
fi

set_defaults
export UNSET_BASH_ENV=1
run_configure "missing BASH_ENV still configures" pass "BASH_ENV is unset"
assert_log_has "config use still runs without BASH_ENV" "config use jfrog-server"

set_defaults
export JF_SHOW_FILE="${TMP}/show-empty-token.txt"
cat > "$JF_SHOW_FILE" << 'EOF'
Server ID: jfrog-server
JFrog Platform URL: https://example.jfrog.io/
Default: false
EOF
run_configure "a saved profile with no credentials fails" fail "without an access token or password"

set_defaults
export JF_SHOW_FILE="${TMP}/show-blank-token.txt"
printf 'Server ID: jfrog-server\nJFrog Platform URL: https://example.jfrog.io/\nAccess token:\n' > "$JF_SHOW_FILE"
run_configure "a blank access token line fails" fail "without an access token or password"

set_defaults
export JF_SHOW_FILE="${TMP}/show-tabs.txt"
printf 'Server ID:\t\tjfrog-server\nJFrog Platform URL:\t\thttps://example.jfrog.io/\nAccess token:\t\t***\n' > "$JF_SHOW_FILE"
run_configure "tab-separated jf config show output is accepted" pass "Configured jf server 'jfrog-server'."

set_defaults
export JF_SHOW_FILE="${TMP}/show-subject.txt"
printf "Server ID:\tjfrog-server\nJFrog Platform URL:\thttps://example.jfrog.io/\nUser:\tci\nAccess token:\t*** (Subject: 'jffe@000/users/ci')\nDefault:\ttrue\n" > "$JF_SHOW_FILE"
run_configure "a masked token with a subject suffix is accepted" pass "Configured jf server 'jfrog-server'."
assert_log_has "subject suffix still selects the server" "config use jfrog-server"

set_defaults
export JF_SHOW_FILE="${TMP}/show-unmasked.txt"
printf 'Server ID: jfrog-server\nJFrog Platform URL: https://example.jfrog.io/\nAccess token: eyJhbGciOiJub25lIn0.payload.sig\n' > "$JF_SHOW_FILE"
run_configure "an unmasked access token line fails" fail "without an access token or password"

set_defaults
export JF_SHOW_EXIT=1
run_configure "config show failure fails the command" fail "jf config show failed"

set_defaults
export JF_ADD_EXIT=1
run_configure "config add failure fails the command" fail ""
if grep -qF "Configured jf server" "$LAST_OUT"; then
  bad "config add failure does not report success" "output said configured"
else
  ok "config add failure does not report success"
fi

set_defaults
export PARAM_URL='https://user:url-userinfo-secret@example.jfrog.io/platform'
run_configure "userinfo in the url is redacted in the log" pass "url: https://***@example.jfrog.io/platform"
assert_out_lacks "userinfo secret is not in the step output" "url-userinfo-secret"
assert_log_has "jf still receives the original url" "--url=https://user:url-userinfo-secret@example.jfrog.io/platform"

set_defaults
# The ${...} text is expanded by the circleci stub, not by this shell.
# shellcheck disable=SC2016
export PARAM_URL='${JF_URL}'
# shellcheck disable=SC2016
export PARAM_ACCESS_TOKEN='${JF_ACCESS_TOKEN}'
export JF_URL=https://from-env.jfrog.io
export JF_ACCESS_TOKEN=env-token-secret
run_configure "JF_URL and JF_ACCESS_TOKEN are the defaults" pass "Configured jf server 'jfrog-server'."
assert_log_has "expanded platform url" "--url=https://from-env.jfrog.io"
assert_stdin "expanded access token" "env-token-secret"
assert_out_lacks "expanded token is not logged" "env-token-secret"

set_defaults
export PARAM_ACCESS_TOKEN='   token-secret-value   '
run_configure "surrounding whitespace on a token is ignored" pass "Configured jf server 'jfrog-server'."
assert_stdin "trimmed token" "token-secret-value"

set_defaults
export PARAM_ACCESS_TOKEN='   '
export PARAM_PASSWORD=
run_configure "a whitespace-only token counts as missing" fail "No credentials."
assert_not_called "a blank token does not call jf"

set_defaults
export PARAM_OVERWRITE=yes
run_configure "a bad boolean fails" fail "overwrite must be true or false"
assert_not_called "a bad boolean does not call jf"

set_defaults
export PATH_MODE=no-jf
run_configure "missing jf fails after the inputs are valid" fail "Run the install command before configure."
assert_not_called "missing jf does not call jf"

set_defaults
export PATH_MODE=no-circleci
run_configure "missing circleci CLI fails" fail "circleci CLI is not on PATH"
assert_not_called "missing circleci does not call jf"

set_defaults
export PARAM_ACCESS_TOKEN=
export PARAM_USER=ci
export PARAM_PASSWORD=password-secret-value
export PARAM_ENCRYPT_PASSWORD=true
export JF_SHOW_FILE="${TMP}/show-password.txt"
printf '%s\n' '{"servers":[{"password": "ciphertext","serverId": "jfrog-server"}]}' > "${JFROG_CLI_HOME_DIR}/jfrog-cli.conf.v6"
run_configure "encrypt_password true is passed to jf" pass "Configured jf server 'jfrog-server'."
assert_log_has "encryption flag is true" "--enc-password=true"

set_defaults
export PARAM_ACCESS_TOKEN=
export PARAM_USER=ci
export PARAM_PASSWORD=password-secret-value
export PARAM_ENCRYPT_PASSWORD=true
export JF_SHOW_FILE="${TMP}/show-password.txt"
# Go's encoding/json writes "<" as "\u003c". Keep the backslash literal.
printf '%s\n' '{"servers":[{"password": "\u003c!DOCTYPE html>","serverId": "jfrog-server"}]}' > "${JFROG_CLI_HOME_DIR}/jfrog-cli.conf.v6"
run_configure "an encrypted password that is an HTML document fails" fail "stored a document instead of a ciphertext"
assert_log_has "the bad profile is removed" "config rm jfrog-server"

set_defaults
export PARAM_ACCESS_TOKEN=
export PARAM_USER=ci
export PARAM_PASSWORD=password-secret-value
export PARAM_ENCRYPT_PASSWORD=true
export JF_SHOW_FILE="${TMP}/show-password.txt"
# A page with a leading newline is stored as "\n\u003c" rather than "\u003c".
printf '%s\n' '{"servers":[{"password": "\n\u003c!DOCTYPE html>","serverId": "jfrog-server"}]}' > "${JFROG_CLI_HOME_DIR}/jfrog-cli.conf.v6"
run_configure "HTML with a leading newline is rejected" fail "stored a document instead of a ciphertext"

set_defaults
export PARAM_ACCESS_TOKEN=
export PARAM_USER=ci
export PARAM_PASSWORD=password-secret-value
export PARAM_ENCRYPT_PASSWORD=true
export JF_SHOW_FILE="${TMP}/show-password.txt"
printf '%s\n' '{"servers":[{"password": " \u003chtml>","serverId": "jfrog-server"}]}' > "${JFROG_CLI_HOME_DIR}/jfrog-cli.conf.v6"
run_configure "HTML with a leading space is rejected" fail "stored a document instead of a ciphertext"

set_defaults
export PARAM_ACCESS_TOKEN=
export PARAM_USER=ci
export PARAM_PASSWORD=password-secret-value
export PARAM_ENCRYPT_PASSWORD=true
export JF_SHOW_FILE="${TMP}/show-password.txt"
printf '%s\n' '{"servers":[{"password": "\ufeff\u003c!DOCTYPE html>","serverId": "jfrog-server"}]}' > "${JFROG_CLI_HOME_DIR}/jfrog-cli.conf.v6"
run_configure "HTML with a leading BOM is rejected" fail "stored a document instead of a ciphertext"

set_defaults
export PARAM_ACCESS_TOKEN=
export PARAM_USER=ci
export PARAM_PASSWORD=password-secret-value
export PARAM_ENCRYPT_PASSWORD=true
export JF_SHOW_FILE="${TMP}/show-password.txt"
printf '%s\n' '{"servers":[{"password": "AM6\u003cstill-ciphertext","serverId": "jfrog-server"}]}' > "${JFROG_CLI_HOME_DIR}/jfrog-cli.conf.v6"
run_configure "a ciphertext that contains an encoded less-than is kept" pass "Configured jf server 'jfrog-server'."

if [[ "$(yaml_default server_id)" == "jfrog-server" ]]; then
  ok "command default server_id is jfrog-server"
else
  bad "command default server_id is jfrog-server" "got '$(yaml_default server_id)'"
fi
# shellcheck disable=SC2016
if [[ "$(yaml_default url)" == '"${JF_URL}"' ]]; then
  ok "command default url is JF_URL"
else
  bad "command default url is JF_URL" "got '$(yaml_default url)'"
fi
# shellcheck disable=SC2016
if [[ "$(yaml_default access_token)" == '"${JF_ACCESS_TOKEN}"' ]]; then
  ok "command default access_token is JF_ACCESS_TOKEN"
else
  bad "command default access_token is JF_ACCESS_TOKEN" "got '$(yaml_default access_token)'"
fi
# shellcheck disable=SC2016
if [[ "$(yaml_default user)" == '"${JF_USER}"' ]]; then
  ok "command default user is JF_USER"
else
  bad "command default user is JF_USER" "got '$(yaml_default user)'"
fi
# shellcheck disable=SC2016
if [[ "$(yaml_default password)" == '"${JF_PASSWORD}"' ]]; then
  ok "command default password is JF_PASSWORD"
else
  bad "command default password is JF_PASSWORD" "got '$(yaml_default password)'"
fi
if [[ "$(yaml_default encrypt_password)" == "false" ]]; then
  ok "command default encrypt_password is false"
else
  bad "command default encrypt_password is false" "got '$(yaml_default encrypt_password)'"
fi
if [[ "$(yaml_default use)" == "true" ]]; then
  ok "command default use is true"
else
  bad "command default use is true" "got '$(yaml_default use)'"
fi
if grep -qF 'scripts/configure.sh' "$COMMAND"; then
  ok "configure command includes the script"
else
  bad "configure command includes the script" "include path missing"
fi

# Run configure.sh against a real jf binary. Arguments after the outfile are
# env assignments (PATH, PARAM_*, ...). GNU env -C selects the working directory.
real_configure() {
  local work="$1" outfile="$2"
  shift 2
  env -C "$work" "$@" /bin/bash "$SCRIPT" > "$outfile" 2>&1
}

if [[ "${RUN_REAL_JF:-0}" == "1" ]]; then
  shopt -s nullglob
  real_bins=()
  if [[ -n "${JF_BIN:-}" ]]; then
    real_bins+=("$JF_BIN")
  else
    real_bins+=(/tmp/jf-research/jf /tmp/jf-research/jf-2.70.0)
  fi
  shopt -u nullglob
  found_real=0
  for jf_bin in "${real_bins[@]}"; do
    if [[ ! -x "$jf_bin" ]]; then
      continue
    fi
    found_real=1
    real_dir="${TMP}/real-$(basename "$jf_bin")"
    rm -rf "$real_dir"
    mkdir -p "$real_dir"
    ln -s "$jf_bin" "${real_dir}/jf"
    ln -s "${BIN}/circleci" "${real_dir}/circleci"
    ln -s "$(command -v cat)" "${real_dir}/cat"
    home="${TMP}/real-home-$(basename "$jf_bin")"
    rm -rf "$home"
    mkdir -p "$home"
    work="${TMP}/real-work-$(basename "$jf_bin")"
    mkdir -p "$work"
    bash_env="${work}/bash.env"
    : > "$bash_env"
    set +e
    real_configure "$work" "${work}/out" \
      PATH="$real_dir" \
      BASH_ENV="$bash_env" \
      JFROG_CLI_HOME_DIR="$home" \
      PARAM_SERVER_ID=jfrog-server \
      PARAM_URL=https://example.jfrog.io \
      PARAM_ARTIFACTORY_URL="" \
      PARAM_ACCESS_TOKEN=real-token-secret \
      PARAM_USER=ci \
      PARAM_PASSWORD="" \
      PARAM_OVERWRITE=true \
      PARAM_INSECURE_TLS=false \
      PARAM_ENCRYPT_PASSWORD=false \
      PARAM_USE=true
    status=$?
    set -e
    name="real $(basename "$jf_bin") saves a token"
    if [[ "$status" -ne 0 ]]; then
      bad "$name" "exit ${status}"
      sed 's/^/    /' "${work}/out"
      continue
    fi
    if grep -qF real-token-secret "${work}/out"; then
      bad "$name" "token appeared in the step output"
      continue
    fi
    show="$(JFROG_CLI_HOME_DIR="$home" "$jf_bin" config show jfrog-server)"
    if [[ "$show" != *"Access token:"* || "$show" != *"***"* || "$show" != *"https://example.jfrog.io/"* ]]; then
      bad "$name" "config show did not report the saved token"
      printf '%s\n' "$show" | sed 's/^/    /'
      continue
    fi
    python3 - "$home/jfrog-cli.conf.v6" << 'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
token = data["servers"][0]["accessToken"]
if token != "real-token-secret":
    raise SystemExit("stored token did not match")
PY
    ok "$name"

    # A second add with overwrite updates the stored token.
    real_configure "$work" "${work}/out2" \
      PATH="$real_dir" \
      BASH_ENV="$bash_env" \
      JFROG_CLI_HOME_DIR="$home" \
      PARAM_SERVER_ID=jfrog-server \
      PARAM_URL=https://example.jfrog.io \
      PARAM_ARTIFACTORY_URL="" \
      PARAM_ACCESS_TOKEN=real-token-secret-2 \
      PARAM_USER="" \
      PARAM_PASSWORD="" \
      PARAM_OVERWRITE=true \
      PARAM_INSECURE_TLS=false \
      PARAM_ENCRYPT_PASSWORD=false \
      PARAM_USE=true
    python3 - "$home/jfrog-cli.conf.v6" << 'PY'
import json, sys
data = json.load(open(sys.argv[1]))
token = data["servers"][0]["accessToken"]
if token != "real-token-secret-2":
    raise SystemExit("overwrite did not replace the token")
PY
    ok "real $(basename "$jf_bin") overwrite replaces the token"

    real_configure "$work" "${work}/out3" \
      PATH="$real_dir" \
      BASH_ENV="$bash_env" \
      JFROG_CLI_HOME_DIR="$home" \
      PARAM_SERVER_ID=second-server \
      PARAM_URL=https://other.example.jfrog.io \
      PARAM_ARTIFACTORY_URL="" \
      PARAM_ACCESS_TOKEN=real-token-secret-3 \
      PARAM_USER="" \
      PARAM_PASSWORD="" \
      PARAM_OVERWRITE=true \
      PARAM_INSECURE_TLS=false \
      PARAM_ENCRYPT_PASSWORD=false \
      PARAM_USE=false
    show_first="$(JFROG_CLI_HOME_DIR="$home" "$jf_bin" config show jfrog-server)"
    show_second="$(JFROG_CLI_HOME_DIR="$home" "$jf_bin" config show second-server)"
    if [[ "$show_first" == *"Default:"*"true"* && "$show_second" == *"Default:"*"false"* ]]; then
      ok "real $(basename "$jf_bin") use false keeps the first server default"
    else
      bad "real $(basename "$jf_bin") use false keeps the first server default" "defaults did not match"
    fi

    mkdir -p "${home}-jwt"
    jwt="$(python3 - << 'PY'
import base64, json
def b64(obj):
    raw = json.dumps(obj, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()
print(b64({"alg": "none", "typ": "JWT"}) + "." + b64({"sub": "jffe@000/users/ci"}) + ".sig")
PY
)"
    set +e
    real_configure "$work" "${work}/jwt.out" \
      PATH="$real_dir" \
      BASH_ENV="$bash_env" \
      JFROG_CLI_HOME_DIR="${home}-jwt" \
      PARAM_SERVER_ID=jwt-server \
      PARAM_URL=https://example.jfrog.io \
      PARAM_ARTIFACTORY_URL="" \
      PARAM_ACCESS_TOKEN="$jwt" \
      PARAM_USER="" \
      PARAM_PASSWORD="" \
      PARAM_OVERWRITE=true \
      PARAM_INSECURE_TLS=false \
      PARAM_ENCRYPT_PASSWORD=false \
      PARAM_USE=false
    jwt_status=$?
    set -e
    if [[ "$jwt_status" -eq 0 ]] && grep -qF "Configured jf server 'jwt-server'." "${work}/jwt.out"; then
      ok "real $(basename "$jf_bin") accepts a token config show marks with a subject"
    else
      bad "real $(basename "$jf_bin") accepts a token config show marks with a subject" "exit ${jwt_status}"
      sed 's/^/    /' "${work}/jwt.out"
    fi

    mkdir -p "${home}-enc"
    set +e
    real_configure "$work" "${work}/enc.out" \
      PATH="$real_dir" \
      BASH_ENV="$bash_env" \
      JFROG_CLI_HOME_DIR="${home}-enc" \
      PARAM_SERVER_ID=jfrog-server \
      PARAM_URL=https://does-not-exist.invalid \
      PARAM_ARTIFACTORY_URL="" \
      PARAM_ACCESS_TOKEN="" \
      PARAM_USER=ci \
      PARAM_PASSWORD=password-secret-value \
      PARAM_OVERWRITE=true \
      PARAM_INSECURE_TLS=false \
      PARAM_ENCRYPT_PASSWORD=true \
      PARAM_USE=true
    enc_status=$?
    set -e
    if [[ "$enc_status" -ne 0 ]] && grep -qF "encrypt your password" "${work}/enc.out"; then
      ok "real $(basename "$jf_bin") encrypt_password fails when Artifactory is unreachable"
    else
      bad "real $(basename "$jf_bin") encrypt_password fails when Artifactory is unreachable" "exit ${enc_status}"
      sed 's/^/    /' "${work}/enc.out"
    fi
    if grep -qF password-secret-value "${work}/enc.out"; then
      bad "real $(basename "$jf_bin") encryption failure does not log the password" "password appeared"
    else
      ok "real $(basename "$jf_bin") encryption failure does not log the password"
    fi
  done
  if [[ "$found_real" -eq 0 ]]; then
    bad "real jf binaries" "RUN_REAL_JF=1 but no jf binary was found"
  fi
fi

if [[ "$FAILURES" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$FAILURES"
  exit 1
fi
printf '\nAll configure tests passed.\n'
