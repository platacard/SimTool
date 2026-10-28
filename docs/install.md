# Installing SimTool

Releases ship one prebuilt binary, for **Apple silicon Macs (arm64)**; on an
Intel Mac, build from source (below). Install it with Homebrew, or with mise to
pin the version per project.

## Homebrew

```sh
brew tap platacard/simtool
brew trust platacard/simtool   # recent Homebrew requires trusting a third-party tap before install
brew install simtool
simtool doctor
```

Upgrade or remove:

```sh
brew update
brew upgrade simtool
brew uninstall simtool
```

## mise

[mise](https://mise.jdx.dev) installs the same release binary straight from
GitHub Releases, and a project can pin the version in its repository, so every
developer and every checkout of it runs the same CLI:

```sh
mise use github:platacard/SimTool@1.0.0
```

That writes the pin into the project's `mise.toml`:

```toml
[tools]
"github:platacard/SimTool" = "1.0.0"
```

Anyone working in the project then runs `mise install` (after `mise trust` the
first time they meet its config), and `simtool` is that version inside the
project — through mise's shims or activated shell, or explicitly as
`mise exec -- simtool …`. mise picks the `macos-arm64` asset, drops the tag's
`v` and finds `bin/simtool` in the archive on its own; no backend options are
needed.

## Manual download

Each [release](https://github.com/platacard/SimTool/releases) carries
`simtool-vX.Y.Z-macos-arm64.tar.gz` (the binary is `bin/simtool` inside) and its
`.sha256`. Check a download from the directory holding both:

```sh
shasum -a 256 -c simtool-vX.Y.Z-macos-arm64.tar.gz.sha256
```

Runtime prerequisites:

- macOS 14 or newer.
- Xcode or Command Line Tools with installed simulator runtimes.
- `xcode-select` pointing at the selected developer directory.
- AXe for accessibility automation commands such as `ax` and accessibility-based `input` actions.

Source fallback for development:

```sh
swift build --package-path Tool
swift run --package-path Tool simtool doctor
```
