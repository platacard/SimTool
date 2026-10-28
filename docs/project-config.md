# Project config, `run` and `open`

For a checked-out project you can record the simulator, app, build selection, and
deeplinks once in `.simtool/config.yml` at the project root, then drive everything
with one command. SimTool discovers the config by searching the working directory
and walking up to parent directories. The `.simtool` folder is automatically
git-ignored via its own auto-created `.gitignore`. Pass `--config <path>` to point
at a specific file; its directory then plays the `.simtool` role, so relative paths
in the config resolve against that directory's parent.

Run `simtool init` from the project root to scaffold a starter `.simtool/config.yml`:
it detects the `.xcworkspace`/`.xcodeproj` and scheme where it can, defaults
`simulator` to `booted`, creates the self-ignoring `.gitignore`, and leaves `# TODO`
fields (such as `bundleId`) for you to fill in. It refuses to clobber an existing
config unless you pass `--force`.

`init` also offers to install the two bundled **agent skills** — `simtool`
(build, launch, drive, mock, inspect) and `simtool-test` (write a verifying test
and drive it red to green) — Markdown briefs that teach a coding agent how to
work with your app through this CLI. Run interactively it asks where to put
them; pass `--skill local|global|none` to choose the tree up front and
`--skill-agent claude|codex|both` to choose the layout (`.claude/skills` or
`.codex/skills`):

| Scope | Destination | Applies to |
|---|---|---|
| `--skill local` | `<project>/.claude/skills/` (or `.codex/skills/`) | this checkout (commit it to share with the team) |
| `--skill global` | `~/.claude/skills/` (or `~/.codex/skills/`) | every project on this machine |
| `--skill none` | — | nothing installed |

Non-interactive runs (`--json`, or no TTY) default to `none`, so scripted `init`
never writes outside the project. Re-running `init` leaves an installed skill
alone once you have edited it — `--force` replaces it with the bundled version,
because the `simtool` skill has two placeholder sections, *Project options* and
*Launch argument catalog*, that you are expected to fill in with your
workspace/scheme and with the debug launch arguments your own app reads.

```sh
swift run simtool init --skill local                        # config + both skills for this project
swift run simtool init --skill global --skill-agent both    # …skills for both agents, everywhere
swift run simtool init --skill local --force                 # refresh config and skills from the bundled versions
```

```yaml
# .simtool/config.yml
simulator: "iPhone 16 Pro"          # UDID, name, or `booted` for the first booted simulator
bundleId: com.example.MyApp
build:
  workspace: MyApp.xcworkspace      # or `project: MyApp.xcodeproj`
  scheme: MyApp
  configuration: Debug              # optional, defaults to Debug
  # derivedDataPath: ./DerivedData  # optional
  # settings:                       # optional xcodebuild build settings for every build
  #   MACOSX_DEPLOYMENT_TARGET: "15.0"
  # builder: xcode-mcp              # optional: build in Xcode over MCP, not xcodebuild
  # timeout: 90m                    # optional: stop a build running longer (default: no limit)
server:                             # optional viewer settings
  host: 127.0.0.1                   # the address it listens on; 0.0.0.0 opens it to the network
  port: 3200
# idleTimeout: 30m                  # optional: shut the simulator down after this long unused (default 15m; off)
deeplinks:
  - name: Details
    url: myapp://items/42
  - name: Settings
    url: myapp://settings?section=general
profiles:                           # optional named launch recipes for tests
  staging-account1:
    arguments: [-UITesting, -Environment, staging, -AutoLogin, "${ACCOUNT1}"]
    env: { SOME_FLAG: "1" }         # exported to the app as SIMCTL_CHILD_*
    # deeplink: myapp://home        # opened once the app is running
```

A test refers to a profile by name (`launch: { profile: staging-account1 }`), so
the app-specific arguments — environment switches, a UI-testing master switch,
the shape of the login arguments — stay in the project config and out of every
test file.

A test that carries its own arguments can simply write the account into them
(`arguments: [-Environment, stable, -FastLoginPhone, "+52 971 624 9725"]`) — argv
reaches `simctl` as separate elements, so spaces need no escaping, and that is
the simplest form. `variables:` covers what inline argv cannot: parameterising a
*shared* profile, and stating a value once when both a `setup:` command and the
run's own launch need it.

```yaml
variables: { ACCOUNT: "+52 971 624 9725" }
launch: { profile: staging-account1 }     # whose argv refers to ${ACCOUNT}
```

`${VAR}` is resolved from `variables:` first, then from the process environment,
and `--var NAME=value` overrides both. The file beats the environment on purpose:
a stale `export` must not silently redirect a test to a different account. Keep a
value out of `variables:` when it must stay in the shell — a real credential,
anything for a production account. Either way an unresolved `${VAR}` fails the
run rather than expanding to nothing, because an empty account argument logs in
as nobody and the test then tests nothing.

`simulator:` is also the default device for **every** command, not just
`run`/`serve`/`open`. With several simulators booted and neither `--device` nor a
config to go by, commands fail instead of picking one: on a machine running
parallel checkouts, guessing means driving another one's simulator, where taps
land elsewhere and the accessibility tree merely looks stale.

Relative `workspace`/`project`/`derivedDataPath` paths resolve against the config
file's directory.

`simtool run` reads the config, boots the configured simulator if needed, builds
for that simulator only (reusing the checksum cache), installs, and launches the
app, then starts the viewer server and prints its URL (`Open http://…`, or the
`url` field with `--json`) — handy for scripts that open the page themselves.
Pass `--web` to also open the browser viewer. It runs in the foreground like
`serve` (Ctrl-C stops it), or pass `--detach` to leave the viewer server running
in the background once the app is launched — build and launch still report in
the foreground, and the printed session (`url` with `--json`) is ready to open.

```sh
swift run simtool run            # server only; open the printed URL yourself
swift run simtool run --web      # …and open the browser viewer
swift run simtool run --detach   # build, launch, leave the server in the background
swift run simtool run --device booted        # run on the first booted simulator
swift run simtool run --device "iPhone 16"   # …or a specific UDID/name, overriding the config
swift run simtool run --config path/to/.simtool/config.yml
```

`run` enables the app-side SimTool network and state loggers by default so the
viewer's Network and State panels work out of the box — it exports
`SIMTOOL_NETWORK_LOGGER`, `SIMTOOL_STATE_LOGGER`, and `SIMTOOL_SERVER_URL` to the
app (via the `SIMCTL_CHILD_` prefix, so they also survive the server's
stdout-capture relaunch). Both are inert for apps that do not link the
corresponding logger package and are compiled out of Release builds. Turn them
off with `--no-network` / `--no-state` or `networkLogger: false` /
`stateLogger: false` in the config.

`serve --app <bundle-id>` arms the same loggers, pointed at itself, for the app
it launches — its stdout-capture relaunch and the viewer's Launch / Relaunch —
with the same `--no-network` / `--no-state` and config switches. An installed
build served this way fills the Network and State panels without `run`.

The source fingerprint hashes only git-tracked (and untracked-but-not-ignored)
files when the project is in a git work tree, falling back to a filesystem walk
otherwise. This keeps gitignored, generated artifacts — Tuist's `Derived/`,
SPM checkouts — out of the checksum, so they don't spuriously invalidate the
cache. Untracked build directories stay out even when `.gitignore` misses them:
anything git does not track under a directory named `DerivedData`, `build`,
`Build`, `.build`, `.swiftpm`, `.simtool` or `xcuserdata`, and the configured
`derivedDataPath` under any name. A tracked file counts wherever it sits — an
xcconfig committed under `Build/` is a source. So does configuration kept out of
git on purpose — an ignored `.env`, `.xcconfig`, `.plist`, `.json`,
`.entitlements` or `.xcprivacy` file such as a secrets xcconfig or
`GoogleService-Info.plist` — unless it lies inside an ignored directory, which is
never read.

What it hashes is what a build compiles, links or copies into the app: code,
headers and build configuration (`.xcconfig`, `.xcfilelist`, `.entitlements`,
`.xcprivacy`, schemes, package manifests and pins), resources — images, video,
audio, animations (`.lottie`, `.riv`), fonts, interface files (`.storyboard`,
`.xib`, `.nib`), strings and String Catalogs (`.xcstrings`), data (`.json`,
`.plist`, `.bin`, `.txt`, `.proto`…), models, certificates — every file inside
asset catalogs, `.lproj`, `.bundle`, `.framework`/`.xcframework` and other
package directories, and shell scripts, as what run-script phases run.
Documentation (`.md`) and scripts in other languages are left out: their edits
would only cost rebuilds.

The workspace or project being built — and every project the workspace
references in its `contents.xcworkspacedata` — is hashed even when git ignores
it, as a generated one usually is: it is what xcodebuild builds, and the same
tracked inputs can generate another one (generator flags, a binary cache, a
generator update). Hashing is by content, so regenerating an identical project
does not invalidate the cache.

Content hashes are remembered between runs in `.simtool/build/input-hashes.tsv`,
keyed by each file's size, modification and change times and inode: a file is
read again only when one of those changed, so checking a large project's
sources costs a `stat` per file rather than reading all of them. The change
time cannot be set back, so content rewritten behind restored timestamps is
still seen; a file changed within two seconds of its hashing is read again
next time.

`run --force` skips the checksum cache: it always builds (xcodebuild, or Xcode
with `xcode-mcp`) and reinstalls the app. Use it when a dependency the fingerprint cannot see
changed — e.g. a local package outside the project root, or a Tuist binary
cache that went stale (then regenerate with `tuist generate` first).

`simtool checksum` records the source checksum for an app you built outside
SimTool — typically from an Xcode post-build phase — so the next `simtool run`
sees a cache hit and reuses that `.app` instead of re-running xcodebuild. It
reads the same `.simtool/config.yml` as `run` (so the recorded checksum and its
cache key match what `run` looks up) and writes the metadata against the built
bundle. The bundle path defaults to `$BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME`
(set inside Xcode build phases); pass `--app-path` to override. A build phase
runs before Xcode signs the bundle, which rewrites it, so the bundle's stamp is
taken when a later `run` first reuses it — provided the bundle settled within
ten minutes of the record; changed later than that, it is another build.

```sh
# As an Xcode "Run Script" post-build phase, from $SRCROOT:
simtool checksum --config "$SRCROOT/.simtool/config.yml"

# Or standalone, pointing at a built bundle:
swift run simtool checksum --app-path /path/to/MyApp.app --json
```

`simtool open` opens a configured deeplink on the configured simulator via
`xcrun simctl openurl`. Pass a deeplink `name` to open it directly, or omit it to
choose interactively. `--json` prints a structured result.

```sh
swift run simtool open                 # interactive picker
swift run simtool open Details         # open by name
swift run simtool open Settings --json
```
