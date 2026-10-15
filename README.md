<div align="center">

<img src="assets/logos/jfrog-orb-512px.png" width="240" alt="jfrog-orb logo: a green frog riding a ringed orb, with the words Build, Package, Deploy">

# CircleCI JFrog Orb

**Install a pinned, checksum-verified JFrog CLI (`jf`) in your CircleCI pipelines with one line of YAML.**

[![CircleCI Build Status](https://circleci.com/gh/juburr/jfrog-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/jfrog-orb)
[![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/jfrog-orb.svg)](https://circleci.com/developer/orbs/orb/juburr/jfrog-orb)
[![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://github.com/juburr/jfrog-orb/blob/main/LICENSE)
[![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)
<br>
[![Checksums: SHA-512](https://img.shields.io/badge/checksums-SHA--512-3ad466.svg?labelColor=1b2a22)](#-checksum-verification)
[![Architectures: amd64 | arm64](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-3ad466.svg?labelColor=1b2a22)](#supported-platforms)
[![Root: not required](https://img.shields.io/badge/root-not%20required-3ad466.svg?labelColor=1b2a22)](#-parameters)

[Quick start](#-quick-start) •
[Examples](#-examples) •
[Parameters](#-parameters) •
[Checksums](#-checksum-verification) •
[Security teams](#-info-for-security-teams) •
[Upgrade notes](#-upgrade-notes)

</div>

---

Install scripts that fetch the latest `jf` on every run make CI change underneath you, and the breakage tends to show up on a Friday night. This unofficial orb installs the exact `jf` version you ask for, checks the binary against a SHA-512 checksum built into the orb, and caches it, so every run uses the same CLI.

> [!NOTE]
> JFrog publishes an official orb, [jfrog/artifactory-orb](https://circleci.com/developer/orbs/orb/jfrog/artifactory-orb). This one is narrower: it pins and verifies the `jf` binary and leaves the `jf` commands up to you.

## ✨ Why this orb?

<table>
  <tr>
    <td width="33%" valign="top">
      <h3>📌 Version pinned</h3>
      Installs the <code>jf</code> release you name, never "latest". Upgrade when you decide to, not when JFrog ships.
    </td>
    <td width="33%" valign="top">
      <h3>🔐 Checksum verified</h3>
      Every binary, downloaded or restored from cache, is checked against a SHA-512 table in the orb. Unknown versions fail by default.
    </td>
    <td width="33%" valign="top">
      <h3>⚡ Cached</h3>
      The binary is stored in the CircleCI cache, keyed by version and architecture, so later runs skip the download.
    </td>
  </tr>
  <tr>
    <td width="33%" valign="top">
      <h3>🦾 amd64 and arm64</h3>
      Detects the machine and installs the matching Linux build, including on CircleCI's <code>arm.*</code> resource classes.
    </td>
    <td width="33%" valign="top">
      <h3>🔓 No root needed</h3>
      Installs to <code>/home/circleci/bin</code> by default, which is already on <code>PATH</code> in CircleCI convenience images.
    </td>
    <td width="33%" valign="top">
      <h3>🧱 Firewall friendly</h3>
      Every host the install contacts is <a href="#required-external-access">documented</a>, for locked-down self-hosted runners.
    </td>
  </tr>
</table>

## 🚀 Quick start

Add the orb and call `install` before any step that uses `jf`:

```yaml
version: 2.1

orbs:
  jfrog-orb: juburr/jfrog-orb@0.2

jobs:
  publish:
    docker:
      - image: cimg/base:current
    steps:
      - checkout
      - jfrog-orb/install
      - run: jf --version

workflows:
  main:
    jobs:
      - publish
```

That's it. `jf` is on your `PATH`, verified, and cached for the next run.

## 📚 Examples

<details open>
<summary><b>Pin a specific <code>jf</code> version</b></summary>

```yaml
steps:
  - jfrog-orb/install:
      version: "2.125.0"
```

</details>

<details>
<summary><b>Connect to Artifactory and upload a build</b></summary>

Store `JFROG_URL` and `JFROG_ACCESS_TOKEN` in a [CircleCI context](https://circleci.com/docs/contexts/), then configure `jf` non-interactively:

```yaml
jobs:
  upload:
    docker:
      - image: cimg/base:current
    steps:
      - checkout
      - jfrog-orb/install
      - run:
          name: Configure jf
          command: |
            jf config add ci \
              --url="${JFROG_URL}" \
              --access-token="${JFROG_ACCESS_TOKEN}" \
              --interactive=false
      - run: jf rt ping
      - run: jf rt upload "dist/*" my-generic-repo/

workflows:
  main:
    jobs:
      - upload:
          context: jfrog
```

</details>

<details>
<summary><b>Run on an arm64 machine</b></summary>

No extra parameters. The orb sees `aarch64` and installs `jfrog-cli-linux-arm64`, verified against its own checksum. On `machine` executors, `/home/circleci/bin` may not exist yet, so create it and add it to `PATH` first:

```yaml
jobs:
  build-arm:
    machine:
      image: ubuntu-2404:current
    resource_class: arm.medium
    steps:
      - run:
          name: Prepare install path
          command: |
            mkdir -p /home/circleci/bin
            echo 'export PATH="/home/circleci/bin:${PATH}"' >> "${BASH_ENV}"
      - jfrog-orb/install
      - run: jf --version
```

</details>

<details>
<summary><b>Install somewhere else, or skip the cache</b></summary>

```yaml
steps:
  - jfrog-orb/install:
      install_path: /home/circleci/.local/bin  # must exist and be writable, no trailing slash
      caching: false                           # always download, never touch the CircleCI cache
```

</details>

## 🔧 Parameters

The orb has one command, `install`.

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `version` | string | `2.125.0` | The `jf` version to install. |
| `verify_checksums` | enum | `strict` | `strict`, `known_versions`, or `"false"`. See [Checksum verification](#-checksum-verification). |
| `install_path` | string | `/home/circleci/bin` | Directory to install `jf` into. Pick one that doesn't need root, with no trailing slash. |
| `caching` | boolean | `true` | Restore and save the `jf` binary with the CircleCI cache. |

### Supported platforms

| Platform | Supported | `jf` build installed |
| --- | :---: | --- |
| Linux `x86_64` | ✅ | `jfrog-cli-linux-amd64` |
| Linux `aarch64` | ✅ | `jfrog-cli-linux-arm64` |
| Other architectures, macOS, Windows | ❌ | Fails with an error instead of installing the wrong binary |

The checksum table lists every `jf` release from 2.70.0 through 2.125.0, the default `version`, on both architectures. Newer releases fail in `strict` mode until the orb adds their checksums (see [Contributing](#-contributing)).

## 🔐 Checksum verification

```mermaid
flowchart LR
    R["Restore cache<br/>(if caching)"] --> A["Detect OS and<br/>architecture"]
    A --> B{"Checksum in the<br/>orb's table?"}
    B -- "no (strict)" --> X["❌ Fail before<br/>downloading from JFrog"]
    B -- yes --> C{"jf restored<br/>from cache?"}
    C -- yes --> E["Verify SHA-512"]
    C -- no --> D["Download from<br/>releases.jfrog.io"]
    D --> E
    E -- mismatch --> Y["❌ Fail"]
    E -- match --> F["✅ Install jf"]
```

`install` downloads the Linux build of `jf` that matches the machine (`x86_64` → `jfrog-cli-linux-amd64`, `aarch64` → `jfrog-cli-linux-arm64`); other architectures and non-Linux machines fail with an error. It checks the SHA-512 checksum of the binary against a lookup table built into this orb, keyed by version and architecture, including binaries restored from the CircleCI cache. The `verify_checksums` parameter controls what happens when the requested `version` is missing from that table:

| `verify_checksums` | Listed version | Unlisted version |
| --- | --- | --- |
| `strict` (default) | ✅ Verified | ❌ Fails before downloading from JFrog |
| `known_versions` | ✅ Verified | ⚠️ Installed **unverified**, with a warning |
| `"false"` | ⚠️ Not verified | ⚠️ Not verified (not recommended) |

> [!TIP]
> If you pin a `jf` release newer than this orb knows about, upgrade the orb or [contribute the checksum](#-contributing). Use `known_versions` only as a temporary opt-out.

## 🧱 Info for Security Teams

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

## 📦 Upgrade Notes

### v0.2.0: arm64 support

`install` now detects the machine architecture and installs `jfrog-cli-linux-arm64` on `aarch64` machines, verified against its own SHA-512 checksum. Every `jf` version in the checksum table (2.70.0 and later) has both amd64 and arm64 entries. Earlier releases installed the amd64 binary everywhere, which arm64 machines can't run natively. Other architectures and non-Linux machines now fail with an error instead of installing an amd64 binary. Cache keys now include the architecture, so the first run after upgrading downloads `jf` again.

### v0.2.0: checksum verification fails closed

> [!IMPORTANT]
> `install` now defaults to `verify_checksums: strict`. If you install a `jf` version that this orb has no SHA-512 checksum for, the step fails instead of installing an unverified binary. Earlier releases defaulted to `known_versions`, which printed a warning and installed it anyway.

Pipelines that use the orb's default `jf` version, or any version in the checksum table, are unaffected. If you need a newer `jf` before the orb lists it, either upgrade the orb or opt out explicitly:

```yaml
- jfrog-orb/install:
    version: "2.130.0"
    verify_checksums: known_versions  # installs unlisted versions without verification
```

## 🤝 Contributing

New `jf` releases need a checksum entry before `strict` mode will install them. To add one:

1. Generate entries for both architectures. The script checks each download against the SHA-256 that Artifactory recorded before printing its SHA-512. It needs `curl` and `jq`.
   ```bash
   bash src/scripts/install_hash.sh -v 2.130.0
   ```
2. Paste the output into the `sha512sums` table in [`src/scripts/install.sh`](src/scripts/install.sh).
3. Run the tests. Downloads are stubbed, so no network access is needed.
   ```bash
   bash test/install_test.sh
   ```
4. Open a pull request.

Issues and feature requests are welcome in [GitHub Issues](https://github.com/juburr/jfrog-orb/issues).

## 📄 License

[MIT](LICENSE) © Justin Burr
