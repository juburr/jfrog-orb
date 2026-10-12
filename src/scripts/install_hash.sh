#!/bin/bash

# Convenience script, not used directly by the production orb, but
# for development purposes when adding SHA-512 checksums to the lookup
# table in install.sh. Prints one entry per supported architecture.
#
# JFrog doesn't sign the jf binaries, so each download is checked against
# the SHA-256 that Artifactory recorded for the file before its SHA-512 is
# printed. A binary that doesn't match is reported and gets no entry.

set -e
set +o history

CLI_OS="linux"
CLI_MAJOR_VER="v2-jf"
BASE_URL="https://releases.jfrog.io/artifactory"

# Fetch CLI arguments
# Can also be set as environment variables.
while getopts :v: flag
do
    case "${flag}" in
        v) VERSION=${OPTARG};;
        *) echo "Invalid option: -${OPTARG}" >&2; exit 1;;
    esac
done

# Validate input arguments
if [[ -z "${VERSION}" ]]; then
  echo "Must specify a version number."
  echo "Usage: $0 -v 1.0.0"
  echo "Alternatively: VERSION=1.0.0 $0"
  exit 1
fi
if ! command -v curl > /dev/null || ! command -v jq > /dev/null; then
  echo "curl and jq are required."
  exit 1
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

# Download output is suppressed for readability; this is a dev script, so
# simply re-enable output if you need to debug anything.
for CLI_ARCH in amd64 arm64; do
  ASSET_PATH="jfrog-cli/${CLI_MAJOR_VER}/${VERSION}/jfrog-cli-${CLI_OS}-${CLI_ARCH}/jf"
  if ! curl -sSfL "${BASE_URL}/${ASSET_PATH}" -o "${WORK_DIR}/jf"; then
    echo "# ${VERSION} has no jfrog-cli-${CLI_OS}-${CLI_ARCH} release asset" >&2
    continue
  fi
  RECORDED_SHA256=$(curl -sSf "${BASE_URL}/api/storage/${ASSET_PATH}" | jq -r '.checksums.sha256 // empty')
  ACTUAL_SHA256=$(sha256sum "${WORK_DIR}/jf" | awk '{ print $1 }')
  if [[ -z "${RECORDED_SHA256}" || "${ACTUAL_SHA256}" != "${RECORDED_SHA256}" ]]; then
    echo "# ${VERSION} ${CLI_ARCH}: SHA-256 ${ACTUAL_SHA256} doesn't match Artifactory's '${RECORDED_SHA256}', skipped" >&2
    continue
  fi
  CHECKSUM=$(sha512sum "${WORK_DIR}/jf" | awk '{ print $1 }')
  echo "[\"${VERSION}/${CLI_ARCH}\"]=\"${CHECKSUM}\""
done
