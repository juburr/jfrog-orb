#!/bin/bash

# Convenience script, not used by directly by the production orb, but
# for development purposes when adding SHA-512 checksums to the lookup
# table in install.sh.

set -e
set +o history

CLI_ARCH="amd64"
CLI_OS="linux"
CLI_MAJOR_VER="v2-jf"

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

# Download the specified version and get the SHA-512 checksum of
# the jf binary. Suppress output for readability; this is
# dev script, so simply re-enable output if you need to debug anything.
cd /tmp
wget "https://releases.jfrog.io/artifactory/jfrog-cli/${CLI_MAJOR_VER}/${VERSION}/jfrog-cli-${CLI_OS}-${CLI_ARCH}/jf" -O /tmp/jf -q
CHECKSUM=$(sha512sum /tmp/jf | awk '{ print $1 }')
echo "[\"${VERSION}\"]=\"${CHECKSUM}\""
rm /tmp/jf
