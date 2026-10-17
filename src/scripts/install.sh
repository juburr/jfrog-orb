#!/bin/bash
#
# Installs JFrog CLI for the install command: the Linux amd64 or arm64 build
# that matches this machine, verified against the checksum table in this file
# before it is installed.
#
# Every juburr orb's install.sh has the same three parts:
#   1. tool definition: what to download and how to install it (JFrog CLI only)
#   2. shared install logic: identical in every orb
#   3. checksum table: one SHA-512 per release and architecture
#
# Add the checksums for a new release with:
#   src/scripts/install_hash.sh -v <version>

# CircleCI runs steps with /bin/sh when the image has no bash, and macOS ships
# bash 3, which lacks associative arrays.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "ERROR: Installing JFrog CLI needs bash 4 or newer. Use an executor image that has it." >&2
    exit 1
fi
set -euo pipefail

# >>> tool definition >>>
ORB_NAME="jfrog-orb"
TOOL_NAME="JFrog CLI"
TOOL_BINARY="jf"
TOOL_ARCHES="amd64 arm64"
# The default install_path, under HOME.
TOOL_DEFAULT_INSTALL_DIR="bin"

# tool_asset_name VERSION ARCH: the release asset to download.
tool_asset_name() {
    printf 'jf\n'
}

# tool_asset_urls VERSION ARCH ASSET: where to download it, one URL per line,
# tried in order.
tool_asset_urls() {
    # Releases live under the major version, such as v2-jf for jf 2.x.
    printf 'https://releases.jfrog.io/artifactory/jfrog-cli/v%s-jf/%s/jfrog-cli-linux-%s/%s\n' "${1%%.*}" "$1" "$2" "$3"
}

# tool_archive_member VERSION ARCH: empty, since JFrog publishes bare
# binaries. The checksum table holds the SHA-512 of the asset itself.
tool_archive_member() {
    :
}

# tool_version BINARY: prints the installed version without using the network.
tool_version() {
    JFROG_CLI_AVOID_NEW_VERSION_WARNING=true "$1" --version
}
# <<< tool definition <<<

# >>> shared install logic >>>
# Everything from here to the end marker is identical in the install.sh of
# every juburr orb, so change it in all of them together. Tool-specific
# behavior belongs in the tool definition above.
#
# Parameters arrive as PARAM_VERSION, PARAM_VERIFY_CHECKSUMS,
# PARAM_INSTALL_PATH and PARAM_CACHING. The checksum table (sha512sums) is
# defined after this block.

orb_info() { printf '%s\n' "$*"; }
orb_warn() { printf 'WARN: %s\n' "$*" >&2; }
orb_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Expands environment variables in a parameter value. The value is piped in
# on stdin: passed as an argument, a value starting with "-" would be parsed
# as a flag. Without the CircleCI CLI (local runs), the value is used as is.
orb_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# CircleCI passes boolean parameters as 1/0; local callers use true/false.
orb_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *) orb_die "${1} must be true or false, not '${2}'." ;;
    esac
}

# Reads an absolute directory parameter: NAME VALUE HOME_SUBDIR. Environment
# variables and a leading ~/ are expanded, trailing slashes are removed, and
# an empty value means $HOME/HOME_SUBDIR.
orb_dir_param() {
    local value
    value=$(orb_subst "$2")
    if [[ -z "${value}" || "${value}" == \~ || "${value}" == \~/* ]]; then
        if [[ -z "${HOME:-}" ]]; then
            orb_die "HOME is not set, so ${1} has no default. Set ${1} to an absolute path."
        fi
        if [[ -z "${value}" ]]; then
            value="${HOME}/${3}"
        else
            value="${HOME}${value:1}"
        fi
    fi
    while [[ "${value}" == */ && "${value}" != "/" ]]; do
        value=${value%/}
    done
    if [[ "${value}" != /* ]]; then
        orb_die "${1} must be an absolute path, not '${value}'."
    fi
    printf '%s\n' "${value}"
}

orb_require_tools() {
    local tool package
    for tool in "$@"; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            case "${tool}" in
                tar | gzip) package=${tool} ;;
                *) package=coreutils ;;
            esac
            orb_die "Installing ${TOOL_NAME} needs '${tool}', which is not available. Install it in an earlier step," \
                "for example with 'microdnf install -y ${package}' on Red Hat UBI images."
        fi
    done
}

# Newest version in the checksum table.
orb_latest_version() {
    local key
    for key in "${!sha512sums[@]}"; do
        printf '%s\n' "${key%/*}"
    done | sort -uV | tail -n 1
}

orb_detect_arch() {
    local os machine
    os=$(uname -s)
    machine=$(uname -m)
    if [[ "${TOOL_ARCHES}" == "noarch" ]]; then
        ORB_ARCH="noarch"
        orb_info "  platform:         noarch (${os} ${machine})"
        return 0
    fi
    if [[ "${os}" != "Linux" ]]; then
        orb_die "This orb installs Linux builds of ${TOOL_NAME}, but this machine runs ${os}."
    fi
    case "${machine}" in
        x86_64 | amd64) ORB_ARCH="amd64" ;;
        aarch64 | arm64) ORB_ARCH="arm64" ;;
        *) orb_die "Unsupported CPU architecture '${machine}'. Supported: x86_64 (amd64), aarch64/arm64 (arm64)." ;;
    esac
    if [[ " ${TOOL_ARCHES} " != *" ${ORB_ARCH} "* ]]; then
        orb_die "${TOOL_NAME} is not published for ${ORB_ARCH}. Supported: ${TOOL_ARCHES}."
    fi
    orb_info "  platform:         linux/${ORB_ARCH} (uname -m: ${machine})"
}

# Decides how this install is verified, before anything is downloaded.
orb_lookup_checksum() {
    ORB_EXPECTED_SHA512=${sha512sums["${ORB_VERSION}/${ORB_ARCH}"]:-}
    if [[ -n "${ORB_EXPECTED_SHA512}" && ! "${ORB_EXPECTED_SHA512}" =~ ^[0-9a-f]{128}$ ]]; then
        orb_die "The checksum table entry for ${ORB_VERSION}/${ORB_ARCH} is malformed."
    fi
    if [[ "${ORB_VERIFY_CHECKSUMS}" == "false" ]]; then
        orb_warn "verify_checksums is false, so ${TOOL_NAME} will be installed WITHOUT checksum verification. This is not recommended."
        ORB_EXPECTED_SHA512=""
    elif [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        if [[ "${ORB_VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            orb_warn "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), and verify_checksums is known_versions."
            orb_warn "Installing an UNVERIFIED binary. Upgrade this orb, or submit a PR with the checksum."
        else
            orb_die "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), so it cannot be verified (verify_checksums: strict)." \
                "Use a version this orb lists (the newest is $(orb_latest_version)), upgrade the orb, or opt out with verify_checksums: known_versions."
        fi
    fi
}

orb_init() {
    ORB_VERSION=$(orb_subst "${PARAM_VERSION:-}")
    ORB_VERSION=${ORB_VERSION#v}
    # The version is part of the download URL, so only release versions pass.
    if [[ ! "${ORB_VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
        orb_die "Invalid ${TOOL_NAME} version '${ORB_VERSION}'. Expected a release version such as $(orb_latest_version)."
    fi
    ORB_VERIFY_CHECKSUMS=${PARAM_VERIFY_CHECKSUMS:-strict}
    case "${ORB_VERIFY_CHECKSUMS}" in
        strict | known_versions | false) ;;
        *) orb_die "verify_checksums must be strict, known_versions or false, not '${ORB_VERIFY_CHECKSUMS}'." ;;
    esac
    ORB_INSTALL_PATH=$(orb_dir_param install_path "${PARAM_INSTALL_PATH:-}" "${TOOL_DEFAULT_INSTALL_DIR}")
    ORB_BIN_DIR=${ORB_INSTALL_PATH}
    ORB_CACHING=$(orb_bool caching "${PARAM_CACHING:-false}")

    orb_info "Installing ${TOOL_NAME} ${ORB_VERSION}"
    orb_info "  install_path:     ${ORB_INSTALL_PATH}"
    orb_info "  verify_checksums: ${ORB_VERIFY_CHECKSUMS}"
    orb_info "  caching:          ${ORB_CACHING}"
    orb_detect_arch
    orb_lookup_checksum

    ORB_ASSET_NAME=$(tool_asset_name "${ORB_VERSION}" "${ORB_ARCH}")
    ORB_ARCHIVE_MEMBER=$(tool_archive_member "${ORB_VERSION}" "${ORB_ARCH}")
    orb_require_tools mktemp
    # Only verification needs sha512sum, so the opt-out modes run without it.
    if [[ -n "${ORB_EXPECTED_SHA512}" ]]; then
        orb_require_tools sha512sum
    fi
    if [[ -n "${ORB_ARCHIVE_MEMBER}" ]]; then
        orb_require_tools tar gzip
    fi

    ORB_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${ORB_NAME}.XXXXXX")
    ORB_CLEANUP=("${ORB_WORK_DIR}")
    trap 'rm -rf "${ORB_CLEANUP[@]}"' EXIT

    # Restored and saved by install.yml. Files are stored by version and
    # architecture, so a cache restored for another version is never used.
    # Nothing is created here unless a verified asset is stored, so an
    # unverified install leaves nothing for save_cache to save.
    ORB_CACHE_FILE=""
    if [[ "${ORB_CACHING}" == "true" && -z "${HOME:-}" ]]; then
        orb_warn "HOME is not set, so the cache is not used."
        ORB_CACHING=false
    elif [[ "${ORB_CACHING}" == "true" ]]; then
        ORB_CACHE_FILE="${HOME}/.cache/${ORB_NAME}/${ORB_VERSION}/${ORB_ARCH}/${ORB_ASSET_NAME}"
    fi
}

# orb_download DEST URL...: downloads the first URL that works to DEST.
# Transient failures are retried with backoff; a 404 moves on to the next URL.
orb_download() {
    local dest=$1 url help option attempt rc
    local -a fetch
    shift
    if command -v curl > /dev/null 2>&1; then
        # A stalled transfer counts as a failure and is retried.
        fetch=(curl -fsSL --proto '=https' --proto-redir '=https' --retry 8 --retry-max-time 300
            --connect-timeout 30 --speed-limit 1 --speed-time 60)
        # curl added --retry-connrefused in 7.52, and lists it under --help all
        # since 7.73. The output is captured, not piped, so curl can't hit a
        # closed pipe.
        help=$({ curl --help all || curl --help; } 2>&1) || true
        if [[ "${help}" == *--retry-connrefused* ]]; then
            fetch+=(--retry-connrefused)
        fi
        fetch+=(-o)
    elif command -v wget > /dev/null 2>&1; then
        fetch=(wget -q)
        # Only the retry options this wget supports (BusyBox wget has none).
        help=$(wget --help 2>&1) || true
        for option in --tries=20 --waitretry=30 --retry-connrefused --timeout=60 --retry-on-http-error=429,500,502,503,504; do
            if [[ "${help}" == *"${option%%=*}"* ]]; then
                fetch+=("${option}")
            fi
        done
        fetch+=(-O)
    else
        orb_die "Neither curl nor wget is available. Install one of them in an earlier step."
    fi
    for url in "$@"; do
        # curl retries timeouts and HTTP 5xx itself, but not a connection
        # dropped partway through, so that gets two more attempts here. An
        # HTTP error such as a 404 (curl exit code 22) moves on to the next
        # URL. wget retries both itself.
        for attempt in 1 2 3; do
            orb_info "Downloading ${url}"
            rc=0
            "${fetch[@]}" "${dest}.partial" "${url}" || rc=$?
            if [[ "${rc}" -eq 0 ]]; then
                mv -f "${dest}.partial" "${dest}"
                return 0
            fi
            if [[ "${fetch[0]}" != "curl" || "${rc}" -eq 22 || "${attempt}" -eq 3 ]]; then
                break
            fi
            orb_warn "The download failed (curl exit code ${rc}). Retrying in $((attempt * 10)) seconds."
            sleep $((attempt * 10))
        done
        orb_warn "Could not download ${url}."
    done
    rm -f "${dest}.partial"
    return 1
}

# orb_extract ASSET MEMBER: sets ORB_VERIFIED_FILE to the file the checksum
# table describes, which is MEMBER extracted from ASSET, or ASSET itself
# when MEMBER is empty.
orb_extract() {
    local asset=$1 member=$2 dir
    if [[ -z "${member}" ]]; then
        ORB_VERIFIED_FILE=${asset}
        return 0
    fi
    dir="${ORB_WORK_DIR}/extract"
    rm -rf "${dir}"
    mkdir "${dir}"
    if ! tar -xzf "${asset}" -C "${dir}" --no-same-owner -- "${member}" 2> "${ORB_WORK_DIR}/tar.log"; then
        orb_warn "Could not extract ${member} from ${ORB_ASSET_NAME}: $(head -c 300 "${ORB_WORK_DIR}/tar.log")"
        return 1
    fi
    ORB_VERIFIED_FILE="${dir}/${member}"
    if [[ ! -f "${ORB_VERIFIED_FILE}" || -L "${ORB_VERIFIED_FILE}" ]]; then
        orb_warn "${member} in ${ORB_ASSET_NAME} is not a regular file."
        return 1
    fi
}

# orb_verify FILE: checks FILE against the checksum table, when verifying.
orb_verify() {
    local actual
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        return 0
    fi
    actual=$(sha512sum "$1" | awk '{ print $1 }')
    orb_info "Verifying the SHA-512 checksum of ${1##*/}..."
    orb_info "  expected: ${ORB_EXPECTED_SHA512}"
    orb_info "  actual:   ${actual}"
    if [[ "${actual}" != "${ORB_EXPECTED_SHA512}" ]]; then
        orb_warn "Checksum verification failed."
        return 1
    fi
    orb_info "Checksum verification passed."
}

# orb_temp_beside FILE: sets ORB_TEMP to a new, empty file in FILE's
# directory, to be renamed over FILE, and registers it for cleanup. mktemp
# creates it exclusively, so a file planted in a shared directory isn't
# written through.
orb_temp_beside() {
    ORB_TEMP=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") || return 1
    ORB_CLEANUP+=("${ORB_TEMP}")
}

# Saves a downloaded asset for save_cache. Only verified assets are kept, so
# the cache never supplies a file the checksum table didn't vouch for.
orb_store_cache() {
    if [[ "${ORB_CACHING}" != "true" ]]; then
        return 0
    fi
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        orb_info "Not caching ${ORB_ASSET_NAME}, since it was not verified."
        return 0
    fi
    if mkdir -p "${ORB_CACHE_FILE%/*}" && orb_temp_beside "${ORB_CACHE_FILE}" \
        && cp "$1" "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "${ORB_CACHE_FILE}"; then
        return 0
    fi
    orb_warn "Could not save ${ORB_ASSET_NAME} to ${ORB_CACHE_FILE%/*}; continuing without the cache."
}

# Fetches the release asset, from the cache when possible, and verifies it.
# Leaves the verified file in ORB_VERIFIED_FILE. A cached asset that fails
# verification is discarded and downloaded again. The cache is only read
# when there is a checksum to verify the cached asset against.
orb_fetch_verified() {
    local asset="${ORB_WORK_DIR}/${ORB_ASSET_NAME}" use_cache=${ORB_CACHING} from_cache urls
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        use_cache=false
    fi
    while true; do
        from_cache=false
        rm -f "${asset}"
        if [[ "${use_cache}" == "true" && -f "${ORB_CACHE_FILE}" ]]; then
            orb_info "Using ${ORB_ASSET_NAME} from the cache."
            cp "${ORB_CACHE_FILE}" "${asset}"
            from_cache=true
        else
            mapfile -t urls < <(tool_asset_urls "${ORB_VERSION}" "${ORB_ARCH}" "${ORB_ASSET_NAME}")
            if ! orb_download "${asset}" "${urls[@]}"; then
                orb_die "Could not download ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}). Check that this version" \
                    "was published for ${ORB_ARCH}, or re-run the job if the download host was failing."
            fi
        fi
        if orb_extract "${asset}" "${ORB_ARCHIVE_MEMBER}" && orb_verify "${ORB_VERIFIED_FILE}"; then
            break
        fi
        if [[ "${from_cache}" == "true" ]]; then
            orb_warn "The cached ${ORB_ASSET_NAME} failed verification. Discarding it and downloading it again."
            orb_warn "CircleCI can't replace a saved cache, so later jobs will do the same until it expires." \
                "Set caching to false to skip it until then."
            rm -f "${ORB_CACHE_FILE}"
            use_cache=false
            continue
        fi
        orb_die "${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}) failed verification and was not installed."
    done
    if [[ "${from_cache}" == "false" ]]; then
        orb_store_cache "${asset}"
    fi
}

# orb_install_file SOURCE DEST: installs SOURCE as the executable DEST,
# replacing any existing file in a single rename.
orb_install_file() {
    local dir=${2%/*}
    if ! mkdir -p "${dir}"; then
        orb_die "Could not create ${dir}. Choose an install_path this job's user can write to without root."
    fi
    if [[ -d "$2" ]]; then
        orb_die "Cannot install to $2, which is a directory."
    fi
    if ! { orb_temp_beside "$2" && cp "$1" "${ORB_TEMP}" && chmod 0755 "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "$2"; }; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
}

# The default for tools that ship a single binary.
orb_install_binary() {
    orb_fetch_verified
    orb_install_file "${ORB_VERIFIED_FILE}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
}

# Adds DIR to the PATH of later steps, unless it is already there.
orb_export_path() {
    local found
    if [[ ":${PATH}:" == *":$1:"* ]]; then
        # Later steps see this PATH, so an earlier copy of the binary wins.
        # -ef accepts the same file reached through a symlinked directory.
        found=$(command -v "${TOOL_BINARY}" || true)
        if [[ -n "${found}" && ! "${found}" -ef "$1/${TOOL_BINARY}" ]]; then
            orb_warn "${found} comes before $1 on the PATH, so later steps will run it instead of the ${TOOL_BINARY} installed here."
        fi
        return 0
    fi
    if [[ -n "${BASH_ENV:-}" ]]; then
        # ${PATH} is expanded when BASH_ENV is sourced, not now.
        # shellcheck disable=SC2016
        printf 'export PATH=%q:"${PATH}"\n' "$1" >> "${BASH_ENV}"
        orb_info "Added $1 to the PATH for later steps."
    else
        orb_warn "$1 is not on the PATH. Add it to run ${TOOL_BINARY} by name."
    fi
}

# Runs the installed binary once, which catches a build that can't run here:
# one for another architecture (exit code 126), or one that crashes, such as
# with SIGILL on a CPU it doesn't support. tool_version needs no network, so
# any failure means the binary doesn't work.
orb_smoke_test() {
    local output rc=0 line
    if ! declare -F tool_version > /dev/null; then
        return 0
    fi
    output=$(tool_version "${ORB_INSTALL_PATH}/${TOOL_BINARY}" 2>&1) || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        orb_die "The installed ${TOOL_BINARY} cannot run on this machine: asking it for its version" \
            "exited with code ${rc}. ${output}"
    fi
    orb_info "${TOOL_BINARY} reports:"
    while IFS= read -r line; do
        orb_info "  ${line}"
    done <<< "${output}"
}

orb_install_main() {
    orb_init
    if declare -F tool_install > /dev/null; then
        tool_install
    else
        orb_install_binary
    fi
    orb_export_path "${ORB_BIN_DIR}"
    orb_smoke_test
    orb_info "Installed ${TOOL_NAME} ${ORB_VERSION} to ${ORB_INSTALL_PATH}."
}
# <<< shared install logic <<<

# >>> checksum table >>>
# SHA-512 checksums keyed "<version>/<arch>", newest release first, where arch
# is amd64, arm64, or noarch for a release that is the same everywhere.
# tool_archive_member says which file each checksum covers.
#
# Each entry comes from a releases.jfrog.io download whose SHA-256 matched
# the checksum Artifactory records for that file.
declare -A sha512sums=(
    ["2.125.0/amd64"]="2372e01b0b660eca6d730b7ab96c1a075e6e33b21f80ce304f8de23c3644c66a4d69945abf5b545b4b456c97606ebb38000f2f2d682a0571205233e800d73a40"
    ["2.125.0/arm64"]="8a530574fcfd909be2b82569177005f191e58148a80e50c3928e218f7c51ac2734755bca06f0e3d3c563543e94afd2ac1197e2a65b882c7faf31b1448ffd7bf3"
    ["2.124.0/amd64"]="095d0738aeca3c5a373d675cb7f544598d22eb4fa980c285274cd21586111fa110a276ad92b4cf0b3640a4a95d6df2a03476ef7ca0ed816ec741d479cea87f27"
    ["2.124.0/arm64"]="58a77091da38801548a48f250f525ff1b93e1c832d3f96aaf0e981f60720b8eb2039648a3ab41dd9b75ad4c32335ec2aa65c49f95ea9489079494f1c562ce206"
    ["2.123.0/amd64"]="1835c0a67589190eded2ab13948d8721aa6cd7c141be4b84c46bcb4749eb5fde24adf90f2894933124b048889702a3cafbd4cc13c83a7bb4010d353db734fcba"
    ["2.123.0/arm64"]="0e68a6cc80272aae122e00abc977038481dd1fd29bcd121ddd885ed0a418dd80280a85283a71eb44d67089f145853058abd304960c3d820e8ca8f327ff37a831"
    ["2.122.0/amd64"]="c63b9bf166364cabb604901244c59bee6fc114e097a06d2ec448530462abe2e967201fd7f088af64c7a4ebded570fd5f90a04553a37ea7281a245f47caa89e3e"
    ["2.122.0/arm64"]="ebf025be099f7dda332a8094f441352de27c9008c29b434d7b164645034412522b727db13d0a34447954baccdfbba7f9c38688f31caf11921cdcc4ac73fe640d"
    ["2.121.0/amd64"]="0434cb37f6b4908bbd5417045a342e7aaddf9e9062cf853cd91f8be807356f5a5bb967b1047a9604f9fe1d0554455eab0e02744a187725ca2e7898a7d21e87d4"
    ["2.121.0/arm64"]="955361bf8f5806b5e7b21fb52fb12c05c2a1792d2464adcfef1c65bc6aba9fec604acd7165530e4908fecb79f17d2816f04549673b8460ad0c5af1fd645e7d31"
    ["2.120.0/amd64"]="06960f05722eb2aea1d5683557de6beaf9ea26d0f995f72d048eeae3696de9ab68c9ff029ffc2131aadefc87e6a7d2489f67f0ab2ea7e51f9d46bc1de1e69193"
    ["2.120.0/arm64"]="77b0ee7dd0fead78a2a58f15b72a95384e13b13311b256a0c8d11c33768020fdd82e9dd2283a7737851e13686ad4238221baf2adfe0fc305219ea9e5732f0914"
    ["2.119.0/amd64"]="d3927607c8eede0f0ed9dc3921805cdb39d220d7ece8edd28d261570dc74bed5312d42621d3ebec758451c6a7a263e4bf4eac08c3baab2b412f559d6297f5808"
    ["2.119.0/arm64"]="166f1c0bbf6dfb858bcc0e0c22de7eaf4f41052937f5c50170ad2fecbdbf8215417c07a600081a5dca6fd83c14bf5931b949039e6abc5818f2811057ea42422e"
    ["2.118.0/amd64"]="63f8af5db1394faf6b3d3ba1741bcc8b9c34aaede493b0e1bd0111774084fa7ece41124945dfbac5d9ab24ca218d6c5ddbfeba0e67c629d589b55b83a315f3bb"
    ["2.118.0/arm64"]="dadebd6a281d10b31db2d876aa5a005b9a550e07523869406b05416bf668b6c268aebb3f8be1ce1a32d3f750086068485f879b67f010be80e4addcab9ed930ce"
    ["2.117.0/amd64"]="b32238fda4d5dd9b5b10f6389468065d4774f0cdec9e05d64b573fe17cbc80e8092a7eb9398717dec78e2b8b0ae59b7e4c8b85218a8fa2e653cd7ed675b505aa"
    ["2.117.0/arm64"]="fe8fdd8fb109cdc7d5e445f34657ec7642dcc2e8cbac5b8eac843fc4c818c634f9369986f0e2f20b29234f30b17a42a0137a1b9b2ecc007e1fb4f5c3e9d3d518"
    ["2.116.0/amd64"]="c5af7694b970b83d27101ea89fca58a5ad912e6f0a8a4d3d8608192c2256ed3a4f0abc1392d3567c167766e900b5e932388ec0f02e3928efa4ac6bc5571c130f"
    ["2.116.0/arm64"]="318ab8adbd44d8c83222be7ef621b765b5aabf8f090d06e04a3b8a88a041da495e281fa70d706fc3043bdea7b13e62d50478e25fa86454bcbcc58583880b5364"
    ["2.115.0/amd64"]="ef52764a6c03d663dbef35357bfb887363b8cadb5731000502c75469501f5f5aec878df2e7e003c956085bf5332b20026d79e1e21c99903f1379cd359e354321"
    ["2.115.0/arm64"]="9322126b873ffdc718bf91de5fcf013044d61001dbc69a7ce7c611c96582098ce0113f94fbb6fbdc995a0139b239ea311dbc4c312f2da48a9b568583fe4e9595"
    ["2.114.0/amd64"]="ff71f8bc366fc25db789c9ebe774afb9ad37dea6eef630639c8449a3becfbe7c24f1568238f9daad067dac695952b0884f1efcaaa51bafc2d337e3fc6e9f7a6d"
    ["2.114.0/arm64"]="2ae71f2df8f15505044412e2b357b38cd87e4530d5b088941ac8f835f970037e86720b419f06b547df8be45247fa13c5dea802f1843cfc23496c9a2ac3ce9bd4"
    ["2.113.0/amd64"]="4940f5737f5deacc5f514aa8ad8e065a372ff56e25c12e14e6805b2176f8f520de3dc90d17dbc5156dcaadd00199522e30d6564fad633854cac71ba41daeda18"
    ["2.113.0/arm64"]="c517ecb91a4a1e2cceceab1d1f78fdc7b224a8be2e976dd864b2622b54323044155235c0546e1d45b4f01c403e932a7686fe280c9047689e043c26065b12e0e5"
    ["2.112.0/amd64"]="f9e180f23b55d2f44241f095fe9a3f7076be4057333464a664f5bc46c1bfc271dd3d5ad83a19c9801f9483ddcb3dbc99fc55ce45851d0a43387fcbdb30acdaeb"
    ["2.112.0/arm64"]="d64198594c5e28b39a4c1fbf95742f28e6aa9bcbb0fee51424884802421e7f7b467fda71590eadbb594420d1f47c7dba3d83012515f0d19aa159c85f01c5f812"
    ["2.111.0/amd64"]="08ad4bfae609f5531103a3f0fc6ae90543a6b9fc8ef089aaf086cd1019408e326f4a5c798e7a61f441cc4ec5ed3af7129f82bd0ac3a376380495a01c50300217"
    ["2.111.0/arm64"]="d2aa4cdcba35eed7cd06999f7ecbe6b2200646085ec64ff22ab0a00f66953a36e4cd2567308590dc8cff0d613d6a332da545d79a842b28eadb9c37b0e1e60d10"
    ["2.110.0/amd64"]="d85c08c6e9353d898f8cbe3dc1b96c01825cc3cd54f5741b2540ddebd85156d8615a3cd8f9bf0bb3f13d95ccaefb7c5d1d8e05840dd50a33f1d657fed6858aba"
    ["2.110.0/arm64"]="3ba7315ae70c079ec592251018831b23367e5c1baba1141b3906c9bc585f65fdb375f81bb6575265428b8dcc9c21747a2a0b77292516ff5d8ba45f7e2aa6c4a2"
    ["2.109.0/amd64"]="ce1518a87ae55c928df29477fe0d5be08d56597b2be16479a33ec6142633bd0f52bfc7edb38582709588028affa10c6f830e912b0db10cfe221b40e56c1ac865"
    ["2.109.0/arm64"]="8e69b7ce836a9ce52dd44a4bb242250057047a7bf797d7a8dbe036625ea681e22468c6bace705dffdd79205a14e992cbf2e35fec8e582719954f5c4aa9c0d03c"
    ["2.108.0/amd64"]="b8cb50368a83a122ce6ae9be1cd92a199931b5dd9cfc759ccc2d0d31cf5ea3afcdc7039c1042a2c86167c18290285230dd62cea670ff21784aaa286928ec8008"
    ["2.108.0/arm64"]="c5eb2adf40e869eb5e59aa1ed8c72c53f4a08212efea5c227d7ff93ab5ff7439006ae54fcbf5d24386ceb0daf25d717474ecad73d41288b882f363d21372aba4"
    ["2.107.0/amd64"]="cf63d65e2539d1cbbd386d169d9dcb8c1454607f2370210cb71d974f9a8ffac82460364afd5c985ca75497d10e71fb5be943c4defe9bcea2160e46a3dda9507d"
    ["2.107.0/arm64"]="dfd737edd183724c1935add1fe42127ab4730563972c0a0fb14e16901a1afda4d96f2f38071da24b0ed5ae963366b8494e0ce9872bc2f11a067f60c5965412ac"
    ["2.106.0/amd64"]="69e5ec72a6e563d0f248ebf53e28267aebbf9b463aa1770ed63dcfdf8ad2a598e5cf87ac03ac42d860fe8a1db10946e00a4f913ea5b9df106d642a438366af98"
    ["2.106.0/arm64"]="caae829e60cc509e658183fec954ae6f0b699b9ad976cf4df1188f6d59df907f572d741e45fedda832ec370a81762a5a2c5e620420dc6d7ffc51ff8a7e4e2f3d"
    ["2.105.0/amd64"]="0065d73fd5615913adeb50be9564072f11b2d6a48952eb058ebf3eaf19e0f7c0f16f7e371ef2f8ef76a2a738625878244352aea26b8ff6f0559482f933fbcc56"
    ["2.105.0/arm64"]="a1905226c624a92ae1a537faf62c8c59df6c3275285e005a3aa20fde11bb5ddd15ae7fdfb8bded0996dcd516d3abf0e4d4743e21f3ec4a871ec3119ebb83f6ba"
    ["2.104.1/amd64"]="aef610e8adce44af98277155d1755541d41343e12d2b83b96ac2956f2e311a0f327f342ddd70e91aa0289afba2bea18a3476d70f8bd948e781173d916c636ea2"
    ["2.104.1/arm64"]="7fb315be21518d43f08c5019dda17f9f956a78b2e3b9ee78fc3c66460ab5a68a17fd36a55107db456689ae9ebf9b135a8f8e5fb599365ad939defcb38e38ecc7"
    ["2.104.0/amd64"]="a80ceb11562797c78ef705de372f3175f2d5bfb55b35283728e2d19e52039e3eb1a71a0a1b1fb571f4b930f94b90a0d5deb4a500c7d78ca7eaf1818abf113587"
    ["2.104.0/arm64"]="180c00815a9a6d6738e7276536cdaf5dfb25e4b33085a4df93ec24e3bee93b07a403160c399a075dcce414837cd23b5579a38a7237717c01431e35144a939ced"
    ["2.103.0/amd64"]="8afc229b24bd411f8312eea451ea6dbc873b6f7ea2311ff5de32e17c6c60cb1ed696de93386d951e8a2e9bb01f255457bdfb933b19053a8403eee6e9c5f589b4"
    ["2.103.0/arm64"]="eebc089438c9fcea750e1173f5b6298ed869fcb16c5e6447fd2a020326d6492f5cbe2c51fc9a52ebe70cbd05d8c3e6f783c5803d21b366871f13e815cd3a0147"
    ["2.102.0/amd64"]="59d833097639881e4b9a9ed19b8adab701120018f2b1b3255f842e481e1bf00e5bf8f74a7aa5c70fd2a7872aa7ae80fc0de9f60eb23c22c9d5b7202cb1dc8a56"
    ["2.102.0/arm64"]="21cb0e18eec23ebb077fce1727ef05ef0615f4b2b4b92fa2c61bf81cfd0bfb2124741be6fd1460533dc1058d750a89a0cb53178f79690212802406f99e995742"
    ["2.101.0/amd64"]="617fd503d8871ba5dfa29e3bdf4707a2c5e2b56f46f888f47e3a88816ebc6eb209a02e393ca9449f63c1ae66008ce58926f488d68c583c7793c4ab73de1e6de2"
    ["2.101.0/arm64"]="c58b36601453ca214b79715f7caea96468583349d9d98313bfb8c80a6da7ee5f804f3bbbd0ff909f422e8bb3c2ea2d63325e703d2c44533a01dff41ac2822ad0"
    ["2.100.0/amd64"]="b84f6f88e27cd3c78b710a7a3a73ab4adc8b8f1d24232e1a895aaa1c0141fb6dd53532aa8a6f7013ea45365beb0cb1df98b0d43eb5bd9352485a08698cd14776"
    ["2.100.0/arm64"]="32a6155de4303a53eb134d90888098579de95adf1f9d33ff527039dfc670c3527052cab38d9614e9f0eaafec4dfce1918bb1d1410de7f974b1e9d832e9cc7516"
    ["2.99.0/amd64"]="529daf0df16175ebca4ad341e36b3ffe7e08b0482f4c974e355ead8a2cd1752f116644282d6d3d4c22a0a99f52108d6c85866a5537bc493247287b7888203c60"
    ["2.99.0/arm64"]="324eb3d95a9bc49fd6aebc9d5ea15615b3e41d9ab9d017d2c550147ef51daefb445aeda065a52d0dc0bfe3d923f1f8579689425743c5fecc6b3f21fc6f8134fd"
    ["2.98.0/amd64"]="e196aab14bf2fe4600059201856ec7a07fab7c97e94e4d4bb5348a892e4a90757101292e3cbe04f5a4e56f60eac893accd615fe8de8ddeb53cb23e8868fefd00"
    ["2.98.0/arm64"]="860a013631fd5ee0817a032a28cafabf51dab9a1e58f3c8b0bb7f5652086eda7398b1bd2112bbc4ba58f0a32c5d38c1468446814fdd725797240e763116fdaa5"
    ["2.97.0/amd64"]="176a2f25fd1e3990e3b74cddafb0c6d73e7bc5eb1927b77244b84ec2c5f757c6d321a1c252f711f11bf85b440e1900deee37b27246ec51b86cc0b73762cbf4be"
    ["2.97.0/arm64"]="359ae7d35bb1cccc9d9240b05f0f729587086d9971bedd84678041bb71659c780ef79e0550c376e9fb27b69b798ceef3f6f5ae1e9533fb9890e8d92ab1c2ba22"
    ["2.96.0/amd64"]="9d64e4f0b87a5454e2613b0baea9ad6a3c031a9bafa59bcee501fbac6de443631f4848424ba10202237fafe1ea70fae695b924904fe0277deeab1d389cda59ea"
    ["2.96.0/arm64"]="43fd174c10ca40b9af254978ccbbea1ed3d208be3c14a72519f1f0d5409cfc612c0ef4d7bd09e0f734e207fa4edbc77af0d339fe1ae14db31caa570ff4af47e9"
    ["2.95.0/amd64"]="fb6cf3d029b758052eb18a0e35314948efdabe1b4a5912ad01923eaa9ca254d41c5382a0e6836f071b6d372c53f20ac9c03798b66e39363d7cc2a66639640cfb"
    ["2.95.0/arm64"]="c72259c2ff0b5fda3c3d6cce4e37381f1048d73fe709b34d6bcda1ea4e5dd0101d446b6bd84e8eac051f5476745f7dbd5dedbfca8387d8d3779abe929651bbff"
    ["2.94.0/amd64"]="6639544f7d2ec542a4cec98f42bae1bb8162c66c3b2bd53c10eff0295c31ba26c7466147f2119506084c0fccf92ae397f10b6b226527b871dfe6f73a32a5ee8c"
    ["2.94.0/arm64"]="6ab925a1184d27ce74714c95c986a265e2d22319848ba63870c92e4daf1c1ddc720766ba44ae2091b26e9895792149d1bd41172239a8a66a230b4ff4f2fc4263"
    ["2.93.0/amd64"]="825f3c0d0aae75dea1cdf47edeb5e30ccdeaa899d31f5d36a5b76bc38cb81c062d21fcdc1dc4463901c97fa70fdadc2fd08ccf9155cb180819d2c6c7d7fd9f0c"
    ["2.93.0/arm64"]="3dfadaff4991983fcfafc9464993cdca07576001e8d959dfcc25012406137e4084f75c2bb12d62e35e09d2dcccf5198b08652b78ad26e8a6e835d6383cb174f0"
    ["2.92.0/amd64"]="01cbd05b7072c616d9e1797aa270d690a623c04ac25738bef36389d28c92705c605fbbd6e8d82d360375c1323dbd7c5d8f4bb6fae051ac4b72fed77b33c5a4a8"
    ["2.92.0/arm64"]="19ce5c7e153959fbd4ae0d8c487f49bac761b818636bed8305d425d0ae56b79d07136f1352e6735a5feac4c60b0e2e6b7b1129afbcbd4805fa161e60a7e66b2e"
    ["2.91.0/amd64"]="583665916b95d7f77a4d5bfc3a26daf364638f6828bcb3a2266aacb29f57611d100d542de91b90b3344896f75d97abc2f65c6f1eb4818f2c95068ff6b11b00c7"
    ["2.91.0/arm64"]="46cfb6ca39ffa7d868b4996ea97388c0743790a4f22e21cc2d8a52be4b49bd03d50d3937dae3d821cae4d93d4c7c17914dc56f38515feb121ec53ccea0ba9a30"
    ["2.90.0/amd64"]="c6b17562ef4e861ad543655325d34e37a642dd34f15c3de9501fbbd83363ddfe899035dac5df8caacc7de297b931e5541ec32143b7a6e060f999ea756848c028"
    ["2.90.0/arm64"]="24517257925f9a973557292e739a8a9a9ec22f5eabcc052dfcd353341ca7f89a772bdd31d418c8e630aa88985656e686e6dfb52d3fd047999bd85e775713590c"
    ["2.89.0/amd64"]="0f7240cc0c286838142e301c72fe6420de9027920b08335b41b23f2affc0ba2d8d01521c0dd18d08cbed0cd1552a1f1a9e05296073d9e125c48a6a7614c0335f"
    ["2.89.0/arm64"]="7f03bd122b00fd5720992e65da1f962145a2ab6e4877f2e24e1e6e3c97665fb1cd6ee000edb6e252778179cfc772eb4befb710524173c826254899b00d1b2594"
    ["2.88.0/amd64"]="801a40291a3fd6af0a8360e06a2dfd748ab0273a7b664815547d1bbd43a5d36307573176ace6652d9692f6cf8b96fc921348b641fc578438e331b76e700b9285"
    ["2.88.0/arm64"]="772678515842ae9d91e2bc445f02afa6a1cf80b9a0cdbfe4c2bed17479224189526ae94f84764c81100db345acd71f33a19c6fe62901869616ed2679681abddb"
    ["2.87.0/amd64"]="cf4e81029d1b4a17c9de9781770ca29e2a2a0241ceed7d231332b1ac03803c8a042416a5f23a6863b678b6d784bad365ed67d1935ca510beee59fd94f493faa1"
    ["2.87.0/arm64"]="c9844d3e7ddb27f83e3ba3f2faa218ac62281ecb99170d8dea31a995c910315259cef25fcbd3a4546f8bfaa9a8487e8d04e105e5a65c48818bc0fea9211bb518"
    ["2.86.0/amd64"]="ce376c28242fb62d3d4ff182f96161dae33f01b8f8d2e72d5014ae28f9d7f4cbc7ed820c73e1e002f3487c9adf3e2708988f8e620c27c492bb6cdc890d33c2a1"
    ["2.86.0/arm64"]="225c6e428847e080754c397e622e4e016a3e7471d4ae10a13cdd6d96b00041b2e8a3f8db92a74b8dd5ab5e00e4f19355d5cb0d42bf9be7cf3b961dd706647247"
    ["2.85.0/amd64"]="e243f60b53cbce63a13a41ff1caa26104e6d48fb7b1852389340f8d15575fd08af681c958d5c503deb9053b9d785b4f6f462fd9abfbcaf7aaa2cebf1781bfca0"
    ["2.85.0/arm64"]="5ad710ea03a95fc795bb75ff3c845777469a2de3d1a42e9c8ee8ab23ea8882e71dc96c64502b01a6411315d8603148645933015808c8f7ba4c1dc76fb0be8c5c"
    ["2.84.0/amd64"]="abae87673c25de23a7e99d4cc0ecf1443a118dd9481ecfcce06019b6cd25b8e6ebafaadf44f8d29fbbca42ce851568413a371df2178fff72500a233788cfbaaf"
    ["2.84.0/arm64"]="d4f9c1697fe58a9ae054066d81c731a2ebe8cba3ee28f2d962727d8b11bea9a843b241cf97f7c38d7c4601b3307c1aea6a2bc7e64de5f7178aa5880345a61fb1"
    ["2.83.0/amd64"]="02a10d75249acea832f3f0ba0192c422ef0a2d77f131cad4f18d77c03c4fa40186c93283a3758802fccc2287a0be94c67912f9b5cfdd20f45c2c34e2678ca7d7"
    ["2.83.0/arm64"]="800abe4f6499763efa406d2e9397bbc963b8afe4211ca9edc8c6d5c4544fb46e246595921eb6ab06c1dd0bc7771f0e2386dfc46e8aff3ccdbac47b5dcbf97e3a"
    ["2.82.0/amd64"]="d0e50520ba1104f4bb8c896a2cf757218a1d0f3c90fe3cede4d5152e67df85762e41acfde46beb8a314b89869d2bc347d7d9c16c95c2c7570b32228fe5818068"
    ["2.82.0/arm64"]="d2cc577799cea1374c03e9c069c0f9ad6aaa2b1751a2dfb39ef5ab4d88e6182596b35723d0dac1f9dd5cb13ac70170105e155c7dd711d62e377ef7c09771b7e8"
    ["2.81.0/amd64"]="9adf728b79da2e8f7330834b805e30153b5fddb46f8de980c5fedd37f28e26a50afefd95db07ce7d78efec04607231f957b6a8076a0d5ba428432a2597fc5017"
    ["2.81.0/arm64"]="61cfc712674a591616d309237620562483c39360831d36fad5fccfdf20ff884d3d6b9c245aabc9ebec812ee41d46501be47ee87df105cadf6cb30e69a43e09e0"
    ["2.80.0/amd64"]="d174c3e6979d064d7f2c382725e12faa0cb6440ed9efb9f26981fd61bafafee95a998ea049363a9a074d98c72153ab0c322e0bc2a70c9d741a9adbf508cb4ae2"
    ["2.80.0/arm64"]="9092b69c71acc058929c9dc6211e97dd275c43612dbe34f0e35f8cd6f7df30353d8f226f883b8cc68f8ed31d68a1fcaad1f6cc2cdbb00c6a2fb8aee23c3b612b"
    ["2.79.2/amd64"]="c7b90e0301cf8ab213d0f00d225e8fee24a33ffbc83ddd72c55c3f826737ae06ef2b0029fde35b4f5b787dc2ad942169690ddbd46d82886253ea0747312015d8"
    ["2.79.2/arm64"]="b2c7271940cdd8e195df459250eb055a9edda255569e125dcb2f6935f9da590ba8b0bce46b2abfb624bd959aa63b8cc539556c1ede2bf7f548cbe0baaf058a49"
    ["2.79.1/amd64"]="ea5c1ce70dcfee5b49cd347ded9bb8661a9b67c8738b5350520810b30bea20c9039c90e214171c4d1869032ac582cdba6d7afe6175c787666e37a949ec4e19c7"
    ["2.79.1/arm64"]="f82f920c477a8bae773f02d0ea54902808b3cc9e973d5abacb49318f49237a42dda509da9b96df613a3d309485cf6b8341b4f471c718a1e087b48b261c57a360"
    ["2.79.0/amd64"]="af948d5bfb2bdf23284f7be0a104422a028e46c975fd30568f642aa51ed5cd5191653b87eb8219857fa8e8dfa63953870d9baeebd6d6020bfec2c4e042dec407"
    ["2.79.0/arm64"]="1ecbcade222321effdeea2d799ffc851474c39df7a897e5c116f4819f36ee8b2ea510e611fdfe7d2ce79aebf42772232974dbb57b5476a5282e06c51b5318222"
    ["2.78.10/amd64"]="c965192a19b04faaba028345c23f89fa3ef6f296cf1fb9cb62b41afcf55118628788451a0bc93047df8ca4661ed75cbf5748e4c5b9374d0f488f84b6fcb14b9b"
    ["2.78.10/arm64"]="b82487141f0d9cb2a1e8359111d5dc87dd4044e1a9beb6db6fe6ed610b4973416a587c472434433c769a779c67198181ccfe9d0d85375a2a855d0f779e45c2a7"
    ["2.78.9/amd64"]="e91f9e3bcf419288ebd29c574a68625ed0a417f81b09c60d0cda0d55c10b6b9f30c002f18e2a1ef8522da84dd41fb9d10631d0ed1eb10cf773eedcafa0b4f75a"
    ["2.78.9/arm64"]="db5262c1e504b31465bde71d85bd9ee362ccb94b7c468c4f43c2598fa8be7fbcdc96eb229f2422628a0a42866097b74f1ceceb2b3de8ccd409737c771fd2a9c6"
    ["2.78.8/amd64"]="75411ec449ea9144c1577188ed52328ac88fa4eba60f315867322fe8a7a05dd63418fdd585d90559c487eedda749186c2ffed0950b2bb3e5500229830e519463"
    ["2.78.8/arm64"]="cd03e8b97833f12ed4b12753bc11f23416ca780fc2aac2ebe92b815147dfab710904b0cc00eb245aa4741c18e8ec3ff163d17005c346dacb37c2b3500571e616"
    ["2.78.7/amd64"]="23aedf10f489d466af447b22e8ee213b3440cbe3c14a162ecb3f9c313fcaca0cd7ba3be38a5feecdae04a16f3ce41f47ac116dce598022b9ea114077ea89a781"
    ["2.78.7/arm64"]="8fef01552e7e0a7c88954e38102c85bd450ea89926e67edc19239684acf563af35c351d0c2d09ce232a5121bc48d2718df30b8d9b51cd1de574e9c063e9d5ed2"
    ["2.78.6/amd64"]="c998a3c85d3a41e8c3a41546cafb12c52d7ddc30a4570b65f29316b7f55a0b4c9fa7000be2d7095d85f7e2ee945a539a531367d6008c322f119358f6e26322b8"
    ["2.78.6/arm64"]="1823b687c50a867464e3a947d53b60f0d4170245df6e6d4e1054e0e91bef68db0aa4998553b189137391c5c85d19ffc1b766858fb82532c0d23c11adc0689047"
    ["2.78.5/amd64"]="75a410d2a136d8f5d3edb35421d7223ed17d4c3d269833331ddb3da8c03663db49e70c775e349f41a1ed3fbf3a56e7513b40bd3b70454c282255c1f396069ff6"
    ["2.78.5/arm64"]="950fd2e8c78dc088998d07a6c3b92b9df67f15bf3f9a46cbcbc29b41b6ebaa414bb7aaba3c71685feea51d12d48b74b243e013e3b17009a4bfc92bb54b16e168"
    ["2.78.4/amd64"]="7ab4a721a2333a6d7f407d01bb4942f1c1b6670cb88c7fde5826f197b9df21b215dc3cc6fc72cd6e5c8dd1a322ce2f826128e5cffa2b536276533ed50daea546"
    ["2.78.4/arm64"]="278aa833b5477070d3a65d8770cd908c928aa310d04f88df48059832ec083c5799251fc4987a0edd74bfaed2b1133fa9712844622e0bbf218dec7e4b986b60b5"
    ["2.78.3/amd64"]="becdc998cd67d7169d7b113c513ce4c6ee9abdf85f8060348058c86cb0ad225de1f2086d741f4e3e9967d3da0ed09d0398c304c1a78d434ec051a391f7871302"
    ["2.78.3/arm64"]="af298ae6c4f0079be2966c1a98106d99768be707e7472df5a86ed0d0e7581e9148eef848fef142a7fbe7bd6c200ecabde5a1027166bbc65de79652acd694f1b4"
    ["2.78.2/amd64"]="afe611354918cb94032c954427f9adde8ea1dd7b2ad1ffc53f45a09ff3ecb04eb2ff230cf408c39a4548cce41b0f8374d01ac67f05b096683e3491908e05d7c6"
    ["2.78.2/arm64"]="428d6ebdcb9301f4894e362bd4d7dfdbee48aa3d73ac86b1c515fed86d1c5523e4aa816d2bebbaa87c52a285b04eaccad04c99283bff019de4730dae468187dd"
    ["2.78.1/amd64"]="9a0e7efc6642f4eed941a868a12cebc293adf4bc318432e6f004115e8d21c24d0f6d085a712b201c2c32be429f3431c9ccd7759282dc979588e651f989a7ad5a"
    ["2.78.1/arm64"]="b9ab3116fb3d67e78df7903a8892bb719c912b3d24b867761a57c98bcc5d095a0d4e3c22697333170648c594b91a55efaa2ce8485e6c1e7dbc485ec0b4b6e9b3"
    ["2.78.0/amd64"]="7f7c952ae8cf15bbff3dba87f329d3939eb4bc8100a510202c390a1364a5738f1246d2cbcae54c408652ffce7ed554755b776146fa0535a9932dacef11cdfc84"
    ["2.78.0/arm64"]="351ae75bf06a4c99e4ebe2ad3113236c073547d1ad2c8ce784cc848ee91cd7291a3469b9368cd9e03375561bf5b8a9912302162381533e34169b99550fe42098"
    ["2.77.0/amd64"]="ab071d0c61194b72728b8938f44fe645ff5a76bf19bb62407cfb79b1b3ea5b4d1e68ef35190e51506427cd8a45eadfffe9285dee76562d615aaffe55f840ff1b"
    ["2.77.0/arm64"]="0653fa64d06a69e6a044638d22ca8277b81c1cb79baac9eb0abc3cad004d9d2c56557829434ab9caf9000f64842dfb97969dacaa9b65d1ff0c672be6f9bfbb65"
    ["2.76.1/amd64"]="058505ad51c235d74472b5e2422a6bbd3e97c6bfab893a2c59e3f3277c375980bda52cac76ab26b5c51aeb2d8b9801991defce873a66e63fb4f0c5631ee49bf6"
    ["2.76.1/arm64"]="7b02fd3d7ca15575684b1c0697576d03232f199cf0b0ca97f66589bfa02c3e0867b7954c64dc9cc0673e730aaffb2fc3db307ef3ec49dbfe02aec19bf0ec8b55"
    ["2.76.0/amd64"]="f2eb22d5b810e135e913d3ede260ab55b45755a13d6043eae5ebb046b5c48b340c198a151cf4ffdaaf723d3458aa78a07b9400fccd6f1c047c0aeb6a31bf7c4b"
    ["2.76.0/arm64"]="7c1915e3dd572459dff741e55ba41b28ed16d9bdc6502c85419a5aaad10d7eb3b11c88260b3326ec44566cc2ce9c66bf1f9867d7a0c1b51d545adc415af95799"
    ["2.75.1/amd64"]="ff2a1a17d173a7e5a50721d57a37e54e21e39962080a6576fab2eca7054100bdb0d9511487e929543b363096fe8b54f7a5055ba0a60f802e4f97be5f93d84410"
    ["2.75.1/arm64"]="fcc9a1b54743f4c1ce104a763d9d01a7aa709c409158dba822a776aece5680aa9047d08c6348df1074e50b18d0c4ca7d4b6a67bf3fc7dec8d56ce8ab9d367643"
    ["2.75.0/amd64"]="5425753e0392e91232e5b7f3ed82caea746a05a130b4e9daaabd568a74999cbf16c84324544ee406197d2fbb90f648a8c2f856d67ed47b59d377f8335fc3cdee"
    ["2.75.0/arm64"]="48f9921f9e689d374ec8ba8186b9eadb4607035cf68e6d28edbc6608af40322513f6213166804d39b05506b6be402e93f7462bb2998177b5edaf5ea36b81280c"
    ["2.74.1/amd64"]="30b5bd2bdd8aa8d3e63c385df258c7261bebe8060b4922d355668c538fa9fc4b612d91269e6ab858a7c3119585c13d53111b83b1c2d03c99b798e829ee8111a9"
    ["2.74.1/arm64"]="255dc8b3fdcbd4d6c7137dbc52c01741aedfe149443e0c4463206240b7d31b859dfde67b0eceeb3000050552c2eec3eee3ebfb10a5259f4311738374c73f6783"
    ["2.74.0/amd64"]="b2bbd4b5bcdcfb1c0be6f26dd91a18bd8a402878c71e984faad4c465eb585b10d69a7ebb76ccef081eb0fe9bf9693fc496d5423f4bd143497a5e2001185ade1a"
    ["2.74.0/arm64"]="c04ebca74c27587ad99c88cf0b5cafc676168ebbeb69d0a6dce75834ecd35bb2f78f17ad5f81789e4e994fc6ee17640f5a966aace394c1ee5f52180a5aa80a01"
    ["2.73.3/amd64"]="a9925a0b132bbd405757ce40d6767efe28172b34c0bc378580ca01c3b659c6c3d06a039e5dfa00c8ee695265a7c99d131a29912422abaf42d050f57af26827ac"
    ["2.73.3/arm64"]="9f95ca774fb2d397a2e27eb4cee06592125e827221fb564c72c7604c2f6c57464c8319fbab4ba99343a91d353978714f6fc41550eff0072f4943c6bf296e137c"
    ["2.73.2/amd64"]="7a15ac9753d0ec5edf0d2ffbaebd19d878ae4af77a8ffbc36cd8f08d891299e5c26cf95c76def52614a458eca4d195eccb353c37d7576b366653c0474264a0db"
    ["2.73.2/arm64"]="9fc4e273d5db3393ecfcff6cbb614ef6b1cc6491bfea1bff9a0125bc370ce004a21f81554939687bb69ac9fac5ebe256f50abfc81ab83f9202e043df0f5debd6"
    ["2.73.1/amd64"]="4e15d9a2beef05853889f57904b56c646c57bff177d36a22fc76504b0d4fc73f5ad4d722f3e4312e6fa928821e1505eb366909c143924c72c93d4e02cec9f569"
    ["2.73.1/arm64"]="16853f31b361f224f2de687390aa2703d5978ad429a5ce1bf80dd4f7569e847e97eba18551d1b8195ce48aae3e460794871dbad3fe32ef722498aa6c8ebf793f"
    ["2.73.0/amd64"]="06e4f8d53fc8683f19b5d9186505cc9e8a6fbf8d77daf5c1b11283305b7f975d936a3f98e8cefadd89d52254be9e7b011613508ee8917d9cd42d33ee05b79706"
    ["2.73.0/arm64"]="9c53e4867bb150e0eeac224dcf55d038b2f515b40da2e95793d171bf073215dd149a6f9a9df9fa253fc98648987f210ac5b3aa28ea31a23c95320400724ea73e"
    ["2.72.5/amd64"]="3b78727eb17ced8277cb29ce92bfa83608536d9a5d878d63f46946e3140c51fda7acd3dfa37f4f41cfac8407c620939daaac56037932a12f40fc1eed458944dd"
    ["2.72.5/arm64"]="816590d48873ff8cfbb7d5e502a129dbc5e7655038be007b3bc86ddaa5241254eec90b7cc5fcc2034a97ccf9e59f09b021df5d732ca032a61e6a786ae88edc0f"
    ["2.72.4/amd64"]="faa4158487fca53db60d1cdd83c599717d6c765622ccf4f42d63038ad3b4579b2b4b06307785ccd1c9da09f5d73128dc8595ba6daf19762dedd3a43de93ebf9c"
    ["2.72.4/arm64"]="c1859449ae6d9ad06ebea52f32df7efbad24613e5e1898fcdfeede18b601c66fb7f71b79d0f2df713a8c165d5f6181033d38d897e8e743a331b18a64e6d204cb"
    ["2.72.3/amd64"]="a9f938cc7910e1a6053212f89f8c5279c83eeb718fa815e4012216aef197f1bcc06036ed1b12872e0dbdc77e8d746cb701a34965556eb563a8f0280d5b523d4e"
    ["2.72.3/arm64"]="28d737691367eea749e16f27fba8f1c9430c128dff4ee85013212f6059478304b0919b227712119c093b80a3e70925dd03c7b42adcf487ce6616484c33264276"
    ["2.72.2/amd64"]="997fae25064791c289d6a56b9796953f850bb2bae498cca7c86162564e0be68db94dd4d63f13f7a0ee7576a6ff8400280feeb86dd5bdc7f157d8cb63d2f41f10"
    ["2.72.2/arm64"]="29c5167dd8cff14cff39a348fa3f148e9234c0016d0534d0d1c677112986e92ab183cfdb2f6259df6efcd62c2ef3bf597391eade95bc4b1b845706f25263d2fa"
    ["2.72.1/amd64"]="2ccee9fe16b60e2e9ddd9ab6c03507214c3e4d58c06221dbb057e81ca8a2bc8208473691df1ffb95097aeca0754ceb7784d49a20fc33e4d081ffb6f9a0ac2004"
    ["2.72.1/arm64"]="92ae2638f3e01426f418105c7dcde8cffeb9470f7ab4305d91e54f7a52235b9b1198e99715316106d969ddaeaf40b9f08aa0db0284d7b54c021596127cff1fb8"
    ["2.72.0/amd64"]="89c8aa0290690028262a00190e934fde830069e528020c7e626d4c42ed65463a20dd94af780855f7a9697caac5e13b530420767004dd33e395c3a592f3dea3e6"
    ["2.72.0/arm64"]="16b3225e3501b7d15344c9be1151311757f0b1fc7ea1d05cc9cf38d874e1aced9c00a2ac10afc022d91eeefe35b0690ca82fc5de82a09544b27d51fec4a59cbc"
    ["2.71.5/amd64"]="fb2c377d5807c8553ae315764f20d72f2f25fa9f5d46c7af02e17d4262f963dde50a4df24d62e8ffaae8544b72d19bb9b11d409da5864a5979a07c583e1222cc"
    ["2.71.5/arm64"]="198bd75f60b8bf3b91bf4f84baf8590104711e0b9dc4cd97fb17fa303e43d0a188a594d8a8a891aca80516a0a1265579427efbf714c06dfcda2654d60206a514"
    ["2.71.4/amd64"]="a6fc11b4be0e018264cb4b40c1f973b587408b4912900980ab34cafbdb3ac2b3940862eb7bd9c76ba9975b4ec1cea5e35e9ac4c7c9d0f96b51f2e1584068262c"
    ["2.71.4/arm64"]="0e1e475a7edfb01c6542005baa56f6ad8f90a6566da95756108968330cda0862ef2ba3549d94a87f9e679f8d0e1337bdcb18fa27f12a0e76e33b2063b6a7032c"
    ["2.71.3/amd64"]="a2bd1a3e7698770ce8819e7b65eb58bf53fa089669826fe570402b581e56f9c946ab8f25b5ad8ff4fb0481a26a532faac050dcb758e7016df791484449ef8803"
    ["2.71.3/arm64"]="bd621dd8bd562eba8c2fbb86d7ba1b79998a34716c7694f138c646e58758c25fedea048fe8213c68c2423fcbfb6b23897bbdb95bdafff1ac6172dfba9f82939d"
    ["2.71.2/amd64"]="eaabf086c262fa819ae0128dc251fdc0bae6443f517427f0bdbccf860bec1364be24c3ec9c8be75f64e58904c4aa84eb3949e665b2332afc0cf212b991a326b5"
    ["2.71.2/arm64"]="4fd0a00e1f19d68f5af2621acdfded080508a27b5a5debae9f850613d14cbab1f9fd12a6e6b77396bcbc9b1551599f2a28ccd4a09a985149f75077e9d0f74eae"
    ["2.71.1/amd64"]="380ab8608c328f6261dfa9114dab50b2bd330aacd847b806ec93e56ab06ea5e61749f2e9f3c9d470dffc064ff6bc23b0359ceee1e98553dd507a42b6cf7519f7"
    ["2.71.1/arm64"]="147b942245778191050965d6903a4630fbaac99a754f7054aa7bfa01db04a21cb3bccf5e5cc18ed01e629771a4c6a2cfc8608d23861ede0bbccf133f839eeda6"
    ["2.71.0/amd64"]="b4f9da1dc957e26e6c9607128dd95115e4616338c342568830280981c0cf47cca5c708ca18cf0c758ce0494a3f1b6b9513cb8788080554086424a46cdd000258"
    ["2.71.0/arm64"]="2e3252c8aa1fd99066914da0fb6ed6efa06d5b19cb090d08a7fee37ad9f53a9e2df5a6f4865709de86f65e53f01a778b32c0bf4dbd0bee150e6f5690a5075f74"
    ["2.70.0/amd64"]="0e53bc7300f1614f315fa4056074b3c97b86f530f1f3afbb6260116f60b14f1556fda3e43d8bce27e80cdf394deb5ec7ca24739f5232a2f43db9ea48e7c088f8"
    ["2.70.0/arm64"]="940ef18fc39af6d509b00df425d87c2844c45b3f73e7799d7237f50cd2b74cfa721969a1f917753bb16c2346c12622153c58e3b6750343e4273abaf4ec4dedd8"
)
# <<< checksum table <<<

orb_install_main
