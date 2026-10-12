<div align="center">
  <img align="center" width="250" src="assets/logos/jfrog-orb-256px.png" alt="JFrog Orb">
  <h1>CircleCI JFrog Orb</h1>
  <i>A CircleCI orb for streamlining JFrog CLI intallation and use.</i><br /><br />
</div>

[![CircleCI Build Status](https://circleci.com/gh/juburr/jfrog-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/jfrog-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/jfrog-orb.svg)](https://circleci.com/developer/orbs/orb/juburr/jfrog-orb) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/juburr/jfrog-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

This unofficial JFrog CLI orb facilitates the installation and execution of the JFrog CLI tool (`jf`) within CircleCI pipelines. An official JFrog Artifactory orb can be found at: [jfrog/artifactory-orb](https://circleci.com/developer/orbs/orb/jfrog/artifactory-orb). This one differs in its ability to provide version locking of the `jf` tool, providing more stable and consistent CI environment that won't break on a Friday night. This avoids install scripts that greedily fetch the latest version every time.

## Checksum verification

`install` downloads the Linux build of `jf` that matches the machine (`x86_64` → `jfrog-cli-linux-amd64`, `aarch64` → `jfrog-cli-linux-arm64`); other architectures and non-Linux machines fail with an error. It checks the SHA-512 checksum of the binary against a lookup table built into this orb, keyed by version and architecture, including binaries restored from the CircleCI cache. The `verify_checksums` parameter controls what happens when the requested `version` is missing from that table:

| `verify_checksums` | Listed version | Unlisted version |
| --- | --- | --- |
| `strict` (default) | Verified | Fails before downloading anything |
| `known_versions` | Verified | Installed **unverified**, with a warning |
| `"false"` | Not verified | Not verified (not recommended) |

If you pin a `jf` release newer than this orb knows about, upgrade the orb or contribute the checksum (see `src/scripts/install_hash.sh`). Use `known_versions` only as a temporary opt-out.

## Info for Security Teams

### Required external access

Hosts to allow if you run a locked-down, self-hosted CircleCI pipeline on-prem:

- **Installing `jf`** (`install`):
  - `releases.jfrog.io`: `jf` release downloads, from `https://releases.jfrog.io/artifactory/jfrog-cli/v2-jf/<version>/jfrog-cli-linux-<arch>/jf`.
  - `releases-cdn.jfrog.io`: `releases.jfrog.io` answers every download with an HTTP 302 redirect to a signed URL on this CDN host, which serves the binary. Allowing `releases.jfrog.io` alone is not enough.
  - With `caching` enabled (the default), `install` also uses CircleCI's cache storage through the built-in `restore_cache` and `save_cache` steps. On CircleCI cloud with self-hosted runners, that requires outbound HTTPS to `circleci-tasks-prod.s3.us-east-1.amazonaws.com` (see the [runner FAQ](https://circleci.com/docs/guides/execution-runner/runner-faqs/#what-connectivity-is-required)). On CircleCI server, caches go to your installation's own object storage instead. Set `caching: false` to avoid cache traffic entirely.
  - Nothing else. In particular, `install` never runs `jf`, so none of the hosts below are contacted during installation.
- **Running `jf` in your own steps** (the orb doesn't do this, but your firewall will see it):
  - The JFrog Platform or Artifactory URLs you configure `jf` to use.
  - `api.github.com`: most `jf` commands check `https://api.github.com/repos/jfrog/jfrog-cli/releases/latest` for a newer CLI release. `jf` records the check in its home directory and repeats it every 6 hours, so on a fresh CI machine it happens once per job. If the check is blocked, `jf` prints a warning and carries on. Set `JFROG_CLI_AVOID_NEW_VERSION_WARNING=true` to turn it off.

## Upgrade Notes

### v0.2.0: arm64 support

`install` now detects the machine architecture and installs `jfrog-cli-linux-arm64` on `aarch64` machines, verified against its own SHA-512 checksum. Every `jf` version in the checksum table (2.70.0 and later) has both amd64 and arm64 entries. Earlier releases installed the amd64 binary everywhere, which arm64 machines can't run natively. Other architectures and non-Linux machines now fail with an error instead of installing an amd64 binary. Cache keys now include the architecture, so the first run after upgrading downloads `jf` again.

### v0.2.0: checksum verification fails closed

`install` now defaults to `verify_checksums: strict`. If you install a `jf` version that this orb has no SHA-512 checksum for, the step fails instead of installing an unverified binary. Earlier releases defaulted to `known_versions`, which printed a warning and installed it anyway.

Pipelines that use the orb's default `jf` version, or any version in the checksum table, are unaffected. If you need a newer `jf` before the orb lists it, either upgrade the orb or opt out explicitly:

```yaml
- jfrog-orb/install:
    version: "2.130.0"
    verify_checksums: known_versions  # installs unlisted versions without verification
```
