# Building and launching apps

Build an iOS simulator app from an Xcode workspace or project:

```sh
swift run simtool app build --workspace MyApp.xcworkspace --scheme MyApp --json
swift run simtool app build --project MyApp.xcodeproj --scheme MyApp --configuration Debug --json
swift run simtool app build --device <udid-or-name> --workspace MyApp.xcworkspace --scheme MyApp
```

Inside a project with a `.simtool/config.yml`, `app build`, `app launch` and
`app test` need neither: without `--workspace` or `--project` they build the app
from the config's `build:` block — the one `run` builds, from the same cache —
and `--scheme`, `--configuration`, `--derived-data-path`, `--build-setting` and
`--builder` each override just their key:

```sh
swift run simtool app launch
swift run simtool app build --configuration Release --json
```

Without `--device` the build targets any iOS simulator, so xcodebuild compiles
every simulator architecture (arm64 and x86_64); with it, only that simulator's —
noticeably faster. `app launch`, `run` and `test run` always build for the
simulator they install on, resolved before the build (`--device`, then
`simulator:` from the config, then the booted one — `booted` becomes a UDID
too). The target is not part of the cache key: a build for one simulator, for
another or for any is reused by all of them.

A project that only builds with extra xcodebuild settings — say a deployment
target its generated dependencies miss — gets them from `build.settings` in
`.simtool/config.yml` ([project config](project-config.md)) on every build of that workspace or project, or
per command with repeatable `--build-setting KEY=VALUE` on `app build`,
`app launch` and `app test`:

```sh
swift run simtool app build --workspace MyApp.xcworkspace --scheme MyApp \
  --build-setting MACOSX_DEPLOYMENT_TARGET=15.0
```

A flag wins over the config for the same key. Settings are part of the build
cache key, so a build with other settings never reuses a cached one.

A build runs as long as it takes: a cold build of a large project, sharing the
machine with other builds, can take well over an hour, and stopping one that is
merely slow throws its work away. To bound it anyway, set `build.timeout` in the
config (`2700`, `45m`, `1.5h`) or pass `--build-timeout` to `run`, `app build`,
`app launch` or `app test` (`0` lifts a configured limit); a build that runs
past it is stopped and fails. It applies to xcodebuild and to Xcode's build
with `xcode-mcp` alike, and is not part of the cache key.

Naming the configured workspace or project with `--workspace` / `--project`
still builds the configured app: the command takes `build.settings`,
`build.builder`, `build.derivedDataPath` and `build.timeout` from the config,
so it lands in the DerivedData `run` builds into and shares its cache entry
instead of starting a second cold build. A build of any other workspace or
project takes none of them.

## Building in Xcode over MCP

Xcode 27 offers its build to agents as MCP tools (`xcrun mcpbridge`), and SimTool
can build through them instead of running xcodebuild: set `builder: xcode-mcp`
in the config's `build:` block, or pass `--builder xcode-mcp` to `run`,
`app build` or `app launch` (`--builder xcodebuild` switches back for one
command). Xcode keeps the workspace loaded between builds and builds where a
build from its own UI would, so a build there is often far faster than a cold
xcodebuild.

```sh
swift run simtool run --builder xcode-mcp
swift run simtool app build --workspace MyApp.xcworkspace --scheme MyApp --builder xcode-mcp --json
```

SimTool opens the workspace or project in Xcode, makes the scheme active,
selects the simulator's run destination — Xcode lists simulators by name and
iOS version; without a device, "Any iOS Simulator Device" — builds, and asks
Xcode where the `.app` landed. The workspace stays open for the next build;
`xcrun mcp-server stop` closes Xcode's background service and everything it
opened.

Xcode decides the build itself: the scheme's Run configuration, the project's
own settings, and where it builds — the DerivedData its own build location
settings name. That is not necessarily a folder of its own: with Xcode set to
put build products next to the workspace (Settings → Locations → Advanced),
xcodebuild's products land in the very same place, whatever `-derivedDataPath`
says. So an Xcode build leaves the config's `derivedDataPath` and `settings` out
(they still apply to xcodebuild), refuses `--derived-data-path` and
`--build-setting`, and fails when the scheme's Run configuration is not the
`configuration` asked for. Its builds get a cache entry of their own, and
whichever builder last wrote a shared `.app`, the other's cache entry sees the
bundle changed and builds again rather than reusing it.

The first time, Xcode asks you to approve SimTool as an agent and to let it
open the project's folder — from the Xcode MCP menu bar icon, or with
`sudo xcrun mcp-server approve <id>` for a request `xcrun mcp-server status`
lists. A build left waiting fails after about a minute with that hint; approve
and run it again. Xcode ties the approval to the `simtool` binary: an unsigned
one, such as a Homebrew build, is trusted for 24 hours at a time and once more
after each upgrade.

Launch builds only when the build-input checksum changes. If the checksum matches
the last successful build, SimTool reuses the cached `.app`; if the selected
simulator does not have that build installed yet, SimTool installs it before
launching. Checksum metadata is stored in `.simtool/build/` inside the project;
build products (DerivedData) stay in `~/Library/Caches/SimTool`.

```sh
swift run simtool app launch --device <udid-or-name> --workspace MyApp.xcworkspace --scheme MyApp --json
swift run simtool app launch --device <udid-or-name> --workspace MyApp.xcworkspace --scheme MyApp --json
```

A cache hit also needs the `.app` to still be the one that build produced.
One bundle path is often written by more than one build — a build with other
`--build-setting`s into the same DerivedData, Xcode (with `xcode-mcp` or from
its UI) when its build location settings put products next to the workspace,
another checkout's identity sharing a configured `derivedDataPath` — so SimTool
records a stamp of the bundle (every file's size and modification time) with
each build and checks it before reusing one. A bundle rebuilt since by anything
else is a cache miss, and a device whose installed build is not that very
bundle gets it reinstalled. The install holds the build's lock (below), so no
other build rewrites the bundle while it is copied, and refuses a bundle that
has changed since its build.

Each xcodebuild run writes its full log to `.simtool/build/<key>.log` beside the
cache metadata (`<key>-test.log` for `app test`), replacing the previous one for
the same build; a failure names it (`Full log: …`) after the errors it picked
out, and `--json` reports it as `logPath` (Xcode's own log with `xcode-mcp`).
Only the end of the output is kept in memory, and run-script phases leave the
build environment out of it (`-hideShellScriptEnvironment`). The built `.app`
is located from that log — where the build wrote it, whichever products
directory Xcode's build location settings chose — so locating it costs no
second xcodebuild run; only when the log cannot tell is xcodebuild asked for
its build settings.

Two builds never write one DerivedData at once — two xcodebuild runs there fail
with "database is locked". A build (and `app test`) takes a lock on its
DerivedData and on the project's directory, where Xcode's build location
settings can put products whatever `-derivedDataPath` says; a second build —
`test run` in one terminal while `run` builds in another — waits for the first
and says whom it waits for (on the progress line, or on stderr with `--json`).
If the build it waited for was of the same sources, it reuses that one instead
of building again. The locks live in `~/Library/Caches/SimTool/app-builds/locks`
and vanish with the process that holds them, so a killed build leaves none
behind. Nor does an interrupted one leave its xcodebuild running: xcodebuild
runs in a process group of its own that Ctrl-C at the terminal does not reach,
so SimTool, interrupted, interrupts it (and what it started) and waits for it
to cancel before exiting — and before letting go of the lock. The same happens
past a build's time limit; either way the log ends with `** BUILD INTERRUPTED **`.
A second Ctrl-C does not wait for the cancel: it kills the build outright.

The managed cache in `~/Library/Caches/SimTool` keeps one DerivedData per
build identity without a configured `derivedDataPath` — gigabytes each — and no
build removes one, so they outlive the worktrees and checkouts they were built
for. `simtool app cache prune` clears them out: an entry goes when the workspace
or project it was built from no longer exists, when no build has used it for
`--older-than <days>`, or with `--all`; one a running build uses stays. It is a
dry run that lists what would go and the space it frees until you pass
`--delete`. A `derivedDataPath` set in a project's config is the project's own
and never touched.

```sh
swift run simtool app cache prune                       # what would go, and how much
swift run simtool app cache prune --older-than 30 --delete
```

Pass runtime flags to the launched app with repeatable `--env KEY=VALUE`
options. This is useful for enabling app-side SimTool diagnostics:

```sh
swift run simtool serve --detach --json --port 3311
swift run simtool app launch \
  --device <udid-or-name> \
  --workspace MyApp.xcworkspace \
  --scheme MyApp \
  --env SIMTOOL_NETWORK_LOGGER=1 \
  --env SIMTOOL_SERVER_URL=http://127.0.0.1:3311 \
  --json
swift run simtool network events --server http://127.0.0.1:3311 --json
swift run simtool network events --server http://127.0.0.1:3311 --protocol websocket --session <id>
```

Pass launch **arguments** (argv) to the app — as opposed to environment
variables — by listing them after a `--` terminator. They are forwarded verbatim
after the bundle id and reach the app through `CommandLine.arguments` (and the
`NSArgumentDomain` of `UserDefaults`), which is how most debug/test launch flags
are wired:

```sh
swift run simtool app launch \
  --device <udid-or-name> \
  --workspace MyApp.xcworkspace \
  --scheme MyApp \
  -- -DebugFlag 1234 -SomeDebugFlag YES
```

`app launch` always cold-launches with `--terminate-running-process`, so launch
arguments and `SIMCTL_CHILD_*` environment take effect even when the app is
already running.

After editing source, resources, project metadata, or common app configuration
files, the checksum changes and the next launch performs a new simulator build:

```sh
swift run simtool app launch --device <udid-or-name> --workspace MyApp.xcworkspace --scheme MyApp --json
```

Run XCTest or UI test schemes on a resolved simulator with `app test`:

```sh
swift run simtool app test --device <udid-or-name> --workspace MyApp.xcworkspace --scheme MyAppUITests --json
swift run simtool app test --device <udid-or-name> --project MyApp.xcodeproj --scheme MyAppTests --configuration Debug --json
```
