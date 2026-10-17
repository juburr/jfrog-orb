#!/usr/bin/env bash
# Tests for src/scripts/ping.sh.
#
# Locks these behaviors:
#   an explicit server id wins over JFROG_CLI_SERVER_ID
#   an empty server id uses JFROG_CLI_SERVER_ID, then jf's default server
#   insecure_tls is off unless asked for
#   jf's exit code is the command's exit code
#   the command does not call api.github.com to check for a newer jf
#
# jf is stubbed, so no network access is needed.
# Set RUN_REAL_JF=1 to also run a no-server ping against a local jf binary.
#
# Run from a checkout:
#   bash test/ping_test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${PING_SCRIPT:-${ROOT}/src/scripts/ping.sh}"
COMMAND="${ROOT}/src/commands/ping.yml"

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

cat > "${BIN}/circleci" << 'EOF'
#!/bin/bash
if [[ "${1:-}" != "env" || "${2:-}" != "subst" ]]; then
  echo "unexpected circleci invocation" >&2
  exit 1
fi
# The scripts pass values on stdin; as an argument, one starting with "-"
# would be parsed as a flag by the real CLI.
if [[ $# -gt 2 ]]; then
  echo "circleci env subst: value passed as an argument" >&2
  exit 1
fi
input="$(cat)"
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
if [[ "${1:-}" == "rt" && "${2:-}" == "ping" ]]; then
  printf 'OK\n'
  exit "${JF_PING_EXIT:-0}"
fi
echo "unexpected jf command: $*" >&2
exit 1
EOF
chmod +x "${BIN}/jf"
ln -s "${BIN}/jf" "${BIN_NO_CIRCLECI}/jf"

export JF_LOG="${TMP}/jf.log"
export JF_PING_EXIT=0

FAILURES=0
CASE_N=0
LAST_OUT=""

ok() { printf 'ok: %s\n' "$1"; }
bad() {
  printf 'FAIL: %s: %s\n' "$1" "$2"
  FAILURES=$((FAILURES + 1))
}

set_defaults() {
  export PARAM_SERVER_ID=
  export PARAM_INSECURE_TLS=false
  export JF_PING_EXIT=0
  unset PATH_MODE JFROG_CLI_SERVER_ID MY_SERVER
}

run_ping() {
  local name="$1" want="$2" expected="$3"
  local work status path problem
  CASE_N=$((CASE_N + 1))
  work="${TMP}/work-${CASE_N}"
  mkdir -p "$work"
  : > "$JF_LOG"
  path="$BIN"
  if [[ "${PATH_MODE:-}" == "no-jf" ]]; then
    path="$BIN_NO_JF"
  elif [[ "${PATH_MODE:-}" == "no-circleci" ]]; then
    path="$BIN_NO_CIRCLECI"
  fi
  set +e
  (
    cd "$work"
    PATH="$path" /bin/bash "$SCRIPT" > "${work}/out" 2>&1
  )
  status=$?
  set -e
  LAST_OUT="${work}/out"

  problem=""
  if [[ "$expected" == exit:* ]]; then
    if [[ "$status" -ne "${expected#exit:}" ]]; then
      problem="exit ${status}, wanted ${expected#exit:}"
    fi
  elif [[ "$want" == "pass" && "$status" -ne 0 ]]; then
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

set_defaults
export PARAM_SERVER_ID=deploy
run_ping "explicit server id is pinged" pass "Pinging Artifactory (server id: deploy)."
assert_log_has "server id flag" "--server-id=deploy"
assert_log_has "version check is disabled for this step" "ENV warning=true"
assert_log_lacks "insecure tls is off by default" "--insecure-tls=true"

set_defaults
export JFROG_CLI_SERVER_ID=jfrog-server
run_ping "empty server id uses JFROG_CLI_SERVER_ID" pass "server id: jfrog-server"
assert_log_has "exported server id is used" "--server-id=jfrog-server"

set_defaults
export PARAM_SERVER_ID=deploy
export JFROG_CLI_SERVER_ID=jfrog-server
run_ping "explicit server id wins over the environment" pass "server id: deploy"
assert_log_has "explicit id is the flag" "--server-id=deploy"
assert_log_lacks "environment id is not also passed" "--server-id=jfrog-server"

set_defaults
run_ping "no server id pings the default server" pass "the default server"
assert_log_has "ping is invoked" "rt ping"
assert_log_lacks "no server id flag" "--server-id="

set_defaults
export PARAM_INSECURE_TLS=true
export JFROG_CLI_SERVER_ID=jfrog-server
run_ping "insecure tls is passed through" pass "server id: jfrog-server"
assert_log_has "insecure tls flag" "--insecure-tls=true"

set_defaults
export PARAM_INSECURE_TLS=1
export JFROG_CLI_SERVER_ID=jfrog-server
run_ping "circleci boolean 1 enables insecure tls" pass "server id: jfrog-server"
assert_log_has "insecure tls 1 becomes the flag" "--insecure-tls=true"

set_defaults
export PARAM_INSECURE_TLS=0
export JFROG_CLI_SERVER_ID=jfrog-server
run_ping "circleci boolean 0 leaves insecure tls off" pass "server id: jfrog-server"
assert_log_lacks "insecure tls 0 stays off" "--insecure-tls=true"

set_defaults
export PARAM_INSECURE_TLS=yes
run_ping "a bad insecure_tls value fails" fail "insecure_tls must be true or false"
if [[ -s "$JF_LOG" ]]; then
  bad "a bad insecure_tls value does not call jf" "jf was called"
else
  ok "a bad insecure_tls value does not call jf"
fi

set_defaults
export PARAM_SERVER_ID=-nope
run_ping "a server id starting with a dash fails" fail "must not start with '-'"

set_defaults
export PATH_MODE=no-jf
export JFROG_CLI_SERVER_ID=jfrog-server
run_ping "missing jf fails" fail "Run the install command before ping."

set_defaults
export PATH_MODE=no-circleci
run_ping "missing circleci CLI fails" fail "circleci CLI is not on PATH"

set_defaults
export JF_PING_EXIT=7
export JFROG_CLI_SERVER_ID=jfrog-server
run_ping "jf's exit code is preserved" fail "exit:7"

set_defaults
# The ${...} text is expanded by the circleci stub, not by this shell.
# shellcheck disable=SC2016
export PARAM_SERVER_ID='${MY_SERVER}'
export MY_SERVER=from-env
run_ping "server_id is expanded with circleci env subst" pass "server id: from-env"
assert_log_has "expanded server id" "--server-id=from-env"

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

if [[ "$(yaml_default server_id)" == '""' ]]; then
  ok "command default server_id is empty"
else
  bad "command default server_id is empty" "got '$(yaml_default server_id)'"
fi
if [[ "$(yaml_default insecure_tls)" == "false" ]]; then
  ok "command default insecure_tls is false"
else
  bad "command default insecure_tls is false" "got '$(yaml_default insecure_tls)'"
fi
if grep -qF 'scripts/ping.sh' "$COMMAND"; then
  ok "ping command includes the script"
else
  bad "ping command includes the script" "include path missing"
fi

if [[ "${RUN_REAL_JF:-0}" == "1" ]]; then
  jf_bin="${JF_BIN:-/tmp/jf-research/jf}"
  if [[ ! -x "$jf_bin" ]]; then
    bad "real jf ping" "JF binary not found at ${jf_bin}"
  else
    real_dir="${TMP}/real-bin"
    mkdir -p "$real_dir"
    ln -s "$jf_bin" "${real_dir}/jf"
    ln -s "${BIN}/circleci" "${real_dir}/circleci"
    ln -s "$(command -v cat)" "${real_dir}/cat"
    home="${TMP}/empty-home"
    mkdir -p "$home"
    work="${TMP}/real-work"
    mkdir -p "$work"
    set +e
    (
      cd "$work"
      export PATH="$real_dir"
      export JFROG_CLI_HOME_DIR="$home"
      export PARAM_SERVER_ID=
      export PARAM_INSECURE_TLS=false
      unset JFROG_CLI_SERVER_ID
      /bin/bash "$SCRIPT" > "${work}/out" 2>&1
    )
    status=$?
    set -e
    if [[ "$status" -ne 0 ]] && grep -qF "no JFrog Artifactory URL" "${work}/out"; then
      ok "real jf ping fails fast when no server is configured"
    else
      bad "real jf ping fails fast when no server is configured" "exit ${status}"
      sed 's/^/    /' "${work}/out"
    fi
  fi
fi

if [[ "$FAILURES" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$FAILURES"
  exit 1
fi
printf '\nAll ping tests passed.\n'
