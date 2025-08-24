#!/bin/bash

set -e
set +o history

# Ensure CircleCI environment variables can be passed in as orb parameters
CLI_ARCH="amd64"
CLI_OS="linux"
CLI_MAJOR_VER="v2-jf"
INSTALL_PATH=$(circleci env subst "${PARAM_INSTALL_PATH}")
VERIFY_CHECKSUMS="${PARAM_VERIFY_CHECKSUMS}"
VERSION=$(circleci env subst "${PARAM_VERSION}")

# Print command arguments for debugging purposes.
echo "Running Syft installer..."
echo "  CLI_ARCH: ${CLI_ARCH}"
echo "  CLI_OS: ${CLI_OS}"
echo "  CLI_MAJOR_VER: ${CLI_MAJOR_VER}"
echo "  INSTALL_PATH: ${INSTALL_PATH}"
echo "  VERIFY_CHECKSUMS: ${VERIFY_CHECKSUMS}"
echo "  VERSION: ${VERSION}"

# Lookup table of sha512 checksums for different versions of syft
declare -A sha512sums
sha512sums=(
    ["2.78.5"]="75a410d2a136d8f5d3edb35421d7223ed17d4c3d269833331ddb3da8c03663db49e70c775e349f41a1ed3fbf3a56e7513b40bd3b70454c282255c1f396069ff6"
    ["2.78.4"]="7ab4a721a2333a6d7f407d01bb4942f1c1b6670cb88c7fde5826f197b9df21b215dc3cc6fc72cd6e5c8dd1a322ce2f826128e5cffa2b536276533ed50daea546"
    ["2.78.3"]="becdc998cd67d7169d7b113c513ce4c6ee9abdf85f8060348058c86cb0ad225de1f2086d741f4e3e9967d3da0ed09d0398c304c1a78d434ec051a391f7871302"
    ["2.78.2"]="afe611354918cb94032c954427f9adde8ea1dd7b2ad1ffc53f45a09ff3ecb04eb2ff230cf408c39a4548cce41b0f8374d01ac67f05b096683e3491908e05d7c6"
    ["2.78.1"]="9a0e7efc6642f4eed941a868a12cebc293adf4bc318432e6f004115e8d21c24d0f6d085a712b201c2c32be429f3431c9ccd7759282dc979588e651f989a7ad5a"
    ["2.78.0"]="7f7c952ae8cf15bbff3dba87f329d3939eb4bc8100a510202c390a1364a5738f1246d2cbcae54c408652ffce7ed554755b776146fa0535a9932dacef11cdfc84"
)

# Verfies that the SHA-512 checksum of a file matches what was in the lookup table
verify_checksum() {
    local file=$1
    local expected_checksum=$2

    actual_checksum=$(sha512sum "${file}" | awk '{ print $1 }')

    echo "Verifying checksum for ${file}..."
    echo "  Actual: ${actual_checksum}"
    echo "  Expected: ${expected_checksum}"

    if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
        echo "ERROR: Checksum verification failed!"
        exit 1
    fi

    echo "Checksum verification passed!"
}

# Check if the jf tar file was in the CircleCI cache.
# Cache restoration is handled in install.yml
if [[ -f jf.tar.gz ]]; then
    tar xvzf jf.tar.gz jf
fi

# If there was no cache hit, go ahead and re-download the binary.
if [[ ! -f jf ]]; then
    if command -v wget &> /dev/null; then
        wget "https://releases.jfrog.io/artifactory/jfrog-cli/${CLI_MAJOR_VER}/${VERSION}/jfrog-cli-${CLI_OS}-${CLI_ARCH}/jf" -O jf
    elif command -v curl &> /dev/null; then
        curl -L "https://releases.jfrog.io/artifactory/jfrog-cli/${CLI_MAJOR_VER}/${VERSION}/jfrog-cli-${CLI_OS}-${CLI_ARCH}/jf" -o jf
    else
        echo "ERROR: Neither wget nor curl is available. Please install one of them."
        exit 1
    fi

    # Tar up the file to save in the CircleCI cache
    tar cvzf jf.tar.gz jf
fi

# An jf binary should exist at this point, regardless of whether it was obtained
# through cache or re-downloaded. First verify its integrity.
if [[ "${VERIFY_CHECKSUMS}" != "false" ]]; then
    EXPECTED_CHECKSUM=${sha512sums[${VERSION}]}
    if [[ -n "${EXPECTED_CHECKSUM}" ]]; then
        # If the version is in the table, verify the checksum
        verify_checksum "jf" "${EXPECTED_CHECKSUM}"
    else
        # If the version is not in the table, this means that a new version of jf
        # was released but this orb hasn't been updated yet to include its checksum in
        # the lookup table. Allow developers to configure if they want this to result in
        # a hard error, via "strict mode" (recommended), or to allow execution for versions
        # not directly specified in the above lookup table.
        if [[ "${VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            echo "WARN: No checksum available for version ${VERSION}, but strict mode is not enabled."
            echo "WARN: Either upgrade this orb, submit a PR with the new checksum."
            echo "WARN: Skipping checksum verification..."
        else
            echo "ERROR: No checksum available for version ${VERSION} and strict mode is enabled."
            echo "ERROR: Either upgrade this orb, submit a PR with the new checksum, or set 'verify_checksums' to 'known_versions'."
            exit 1
        fi
    fi
else
    echo "WARN: Checksum validation is disabled. This is not recommended. Skipping..."
fi

# After verifying integrity, install it by moving it to an appropriate bin
# directory and marking it as executable. If your pipeline throws an error
# here, you may want to choose an INSTALL_PATH that doesn't require sudo access,
# so this orb can avoid any root actions.
mv jf "${INSTALL_PATH}/jf"
chmod +x "${INSTALL_PATH}/jf"
