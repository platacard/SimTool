# Release Distribution

This document describes how to publish SimTool for macOS through GitHub Releases and a Homebrew tap.

## Canonical Repositories

Defaults used by release scripts:

- Main repository: `platacard/SimTool`
- Homebrew tap: `platacard/homebrew-simtool`
- User tap command: `brew tap platacard/simtool`

Override these defaults with environment variables when needed, for example to
release a fork:

```sh
export SIMTOOL_GITHUB_OWNER=your-org
export SIMTOOL_GITHUB_REPO=SimTool
export SIMTOOL_TAP_OWNER=your-org          # defaults to SIMTOOL_GITHUB_OWNER
export SIMTOOL_TAP_REPO=homebrew-simtool
```

## Runtime Prerequisites

Users need:

- macOS 14 or newer.
- Xcode or Command Line Tools with simulator support.
- Installed iOS simulator runtimes for simulator commands.
- `xcode-select` pointing at the selected developer directory.
- AXe only for accessibility automation commands.

Homebrew does not install simulator runtimes or AXe automatically. Use `simtool doctor` after installation to inspect local dependencies.

## First-Time GitHub Setup

If the main GitHub repository does not exist yet:

```sh
gh auth login
gh repo create platacard/SimTool --public --source=. --remote=origin --push
```

If the Homebrew tap does not exist yet:

```sh
gh repo create platacard/homebrew-simtool --public
gh repo clone platacard/homebrew-simtool ../homebrew-simtool
```

If the tap already exists:

```sh
gh repo clone platacard/homebrew-simtool ../homebrew-simtool
```

## Release Flow

Choose a SemVer tag such as `v0.1.0`. One tag releases both the `simtool` CLI
and the logger libraries apps link, so bump the one release number first and
commit it: `SimToolNetworkLogger.version` in
`NetworkLogger/Sources/SimToolNetworkLogger/SimToolNetworkLoggerVersion.swift`
(the CLI reports the same number, `SimToolVersion.base`) and `version` / `url`
in `Formula/simtool.rb`. A test fails while the formula disagrees.

1. Check prerequisites:

```sh
export SIMTOOL_INTERNAL_DENYLIST=~/.config/simtool/internal-denylist
Scripts/check-release-prerequisites.sh
```

Besides the tools and GitHub access, this runs `Scripts/check-no-internal-refs.sh`:
a release publishes the tree as is, so it must not name anything internal to the
organization that publishes it — its apps, hosts, internal tools, issue keys,
people. Issue keys, home directories and email addresses are checked always. The
organization's own terms come from the file `SIMTOOL_INTERNAL_DENYLIST` points at
(one case-insensitive `grep -E` pattern per line); that list names the
organization, so it lives in private config, never in this repository. Set the
variable to `/dev/null` to release without one. The repository's own coordinates
(`$SIMTOOL_GITHUB_OWNER/$SIMTOOL_GITHUB_REPO` and the tap) are always allowed.

2. Package and smoke-test the binary:

```sh
Scripts/package-release.sh v0.1.0
```

This creates files under `.build/release-distribution/v0.1.0/`:

- `simtool-v0.1.0-macos-<arch>.tar.gz`
- `simtool-v0.1.0-macos-<arch>.tar.gz.sha256` — the archive's bare name, so
  `shasum -a 256 -c` works wherever both are downloaded
- `release-notes.md`

3. Publish the GitHub Release:

```sh
Scripts/publish-release.sh v0.1.0
```

Use `--dry-run` to inspect actions without publishing. Use `--update-existing` only when intentionally replacing release assets.

4. Generate and publish the Homebrew formula:

```sh
Scripts/update-homebrew-formula.sh v0.1.0 --tap-path ../homebrew-simtool --commit --push
```

The generated formula downloads the exact GitHub Release archive and verifies its SHA-256 checksum.

## User Installation

Homebrew, or mise straight from the GitHub Release (`mise use
github:platacard/SimTool@<version>`; see the README):

```sh
brew tap platacard/simtool
brew trust platacard/simtool   # recent Homebrew requires trusting a third-party tap before install
brew install simtool
simtool doctor
```

Upgrade:

```sh
brew update
brew upgrade simtool
```

Uninstall:

```sh
brew uninstall simtool
```

Source fallback:

```sh
swift build --package-path Tool
swift run --package-path Tool simtool doctor
```

## Validation

Before publishing a real release, run:

```sh
Scripts/check-no-internal-refs.sh
swift test
swift test --package-path Tool
swift build --package-path Tool -c release --product simtool
Scripts/package-release.sh v0.0.0
```

If a tap clone is available, validate the generated formula:

```sh
Scripts/update-homebrew-formula.sh v0.0.0 --tap-path ../homebrew-simtool
brew install --formula ../homebrew-simtool/Formula/simtool.rb
brew test simtool
```

Use a real published version for public formula validation because Homebrew formula URLs must point at reachable release assets.

## Rollback

If a release is invalid:

1. Delete or mark the GitHub Release as superseded:

```sh
gh release delete v0.1.0 --repo platacard/SimTool --cleanup-tag
```

2. Revert the Homebrew tap formula commit:

```sh
git -C ../homebrew-simtool revert HEAD
git -C ../homebrew-simtool push
```

3. Publish a fixed version with a new tag.
