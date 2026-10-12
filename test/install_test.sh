#!/usr/bin/env bash
# Tests for checksum verification in src/scripts/install.sh.
#
# Locks these behaviors:
#   the install command's default verify_checksums refuses a version that is
#   not in the checksum table, before downloading anything
#   a listed version with the wrong checksum is refused unless checks are off,
#   whether the binary was downloaded or restored from the cache
#   known_versions and false install unverified binaries only when asked
#
# Downloads are stubbed, so no network access is needed.
#
# Run from a checkout:
#   bash test/install_test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${INSTALL_SCRIPT:-${ROOT}/src/scripts/install.sh}"
COMMAND="${ROOT}/src/commands/install.yml"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Only these tools are on PATH, so the stub curl is used and wget is not.
BIN="${TMP}/bin"
mkdir -p "$BIN"
for cmd in awk bash cat chmod gzip mv rm sha512sum tar; do
  ln -s "$(command -v "$cmd")" "${BIN}/${cmd}"
done

cat > "${BIN}/circleci" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "env" && "${2:-}" == "subst" ]]; then
  printf '%s\n' "${3-}"
  exit 0
fi
exit 1
EOF

# Writes a fake binary to the -o path and records the URL.
cat > "${BIN}/curl" << 'EOF'
#!/usr/bin/env bash
out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "$CURL_LOG"
printf '#!/bin/sh\necho "not really jf"\n' > "$out"
EOF
chmod +x "${BIN}/circleci" "${BIN}/curl"
export CURL_LOG="${TMP}/curl.log"

FAILURES=0

# The default the install command passes when verify_checksums is not set.
DEFAULT_MODE="$(awk '/^  verify_checksums:/ {found=1} found && /^    default:/ {print $2; exit}' "$COMMAND")"
if [[ -z "$DEFAULT_MODE" ]]; then
  printf 'FAIL: could not read the verify_checksums default from %s\n' "$COMMAND"
  exit 1
fi
printf 'install command default: verify_checksums=%s\n' "$DEFAULT_MODE"

# run_install NAME WANT(pass|fail) VERSION MODE|unset EXPECTED_OUTPUT
# Set PRESEED_CACHE=1 to start with a jf.tar.gz in the working directory, as if
# restore_cache had found one.
run_install() {
  local name="$1" want="$2" version="$3" mode="$4" expected="$5"
  local work="${TMP}/work-${RANDOM}" status
  mkdir -p "${work}/install"
  : > "$CURL_LOG"
  if [[ "${PRESEED_CACHE:-0}" == "1" ]]; then
    printf '#!/bin/sh\necho "cached, not really jf"\n' > "${work}/jf"
    tar czf "${work}/jf.tar.gz" -C "$work" jf
    rm "${work}/jf"
  fi
  set +e
  (
    cd "$work"
    if [[ "$mode" == "unset" ]]; then
      unset PARAM_VERIFY_CHECKSUMS
    else
      export PARAM_VERIFY_CHECKSUMS="$mode"
    fi
    PATH="$BIN" PARAM_INSTALL_PATH="${work}/install" PARAM_VERSION="$version" \
      "${BIN}/bash" "$SCRIPT" > "${work}/out" 2>&1
  )
  status=$?
  set -e

  local problem=""
  if [[ "$want" == "pass" && "$status" -ne 0 ]]; then
    problem="exit ${status}, wanted success"
  elif [[ "$want" == "fail" && "$status" -eq 0 ]]; then
    problem="succeeded, wanted a failure"
  elif [[ "$want" == "fail" && -e "${work}/install/jf" ]]; then
    problem="failed but still installed a binary"
  elif [[ "$want" == "pass" && ! -x "${work}/install/jf" ]]; then
    problem="succeeded but installed no binary"
  elif ! grep -qF -- "$expected" "${work}/out"; then
    problem="output did not mention '${expected}'"
  fi

  if [[ -n "$problem" ]]; then
    printf 'FAIL: %s: %s\n' "$name" "$problem"
    sed 's/^/    /' "${work}/out"
    FAILURES=$((FAILURES + 1))
  else
    printf 'ok: %s\n' "$name"
  fi
}

expect_no_download() {
  local name="$1"
  if [[ -s "$CURL_LOG" ]]; then
    printf 'FAIL: %s: downloaded %s\n' "$name" "$(cat "$CURL_LOG")"
    FAILURES=$((FAILURES + 1))
  else
    printf 'ok: %s\n' "$name"
  fi
}

UNLISTED="9.9.9"
LISTED="2.125.0"
RELEASES="https://releases.jfrog.io/artifactory/jfrog-cli/v2-jf"

run_install "default refuses an unlisted version" fail "$UNLISTED" "$DEFAULT_MODE" "No checksum available for version ${UNLISTED}"
expect_no_download "default refuses an unlisted version before downloading it"
run_install "unset mode refuses an unlisted version" fail "$UNLISTED" unset "No checksum available for version ${UNLISTED}"
run_install "strict refuses an unlisted version" fail "$UNLISTED" strict "opt out with verify_checksums: known_versions"
run_install "known_versions installs an unlisted version with a warning" pass "$UNLISTED" known_versions "Installing an UNVERIFIED binary"
run_install "false installs without verification" pass "$UNLISTED" false "Checksum validation is disabled"
run_install "default refuses a listed version with the wrong checksum" fail "$LISTED" "$DEFAULT_MODE" "Checksum verification failed"
if grep -qxF "${RELEASES}/${LISTED}/jfrog-cli-linux-amd64/jf" "$CURL_LOG"; then
  printf 'ok: downloads the release asset\n'
else
  printf 'FAIL: unexpected download URL: %s\n' "$(cat "$CURL_LOG")"
  FAILURES=$((FAILURES + 1))
fi
run_install "known_versions refuses a listed version with the wrong checksum" fail "$LISTED" known_versions "Checksum verification failed"
run_install "an unknown mode is refused" fail "$LISTED" relaxed "verify_checksums must be strict, known_versions or false"

export PRESEED_CACHE=1
run_install "default refuses a cached binary with the wrong checksum" fail "$LISTED" "$DEFAULT_MODE" "Checksum verification failed"
expect_no_download "a cached binary is used instead of downloading"
unset PRESEED_CACHE

if [[ "$FAILURES" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$FAILURES"
  exit 1
fi
printf '\nAll install tests passed.\n'
