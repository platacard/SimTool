# Model state inspector (`@SimToolDebugState`)

Stream your `@Observable` models' state to the SimTool web UI in debug builds.
Annotate the model and register the instance once:

```swift
import SimToolStateLogger

@Observable                      // optional — see polling below
@SimToolDebugState
final class AppModel {
    var count = 0
    var coords = Coords()        // @SimToolDebugState struct → expands
}

@SimToolDebugState
struct Coords { var x = 0.0 }

// register once (name defaults to the type name):
SimToolState.track(model)
// or chain it where the instance is created — works from DI factories too:
let model = AppModel().simToolTracked()
// plain (non-@Observable) classes are polled (default 1 s); tune with poll:
SimToolState.track(legacy, poll: .milliseconds(250))
```

Add the package to your app (debug configurations only is fine):

```swift
.package(path: "path/to/SimTool/StateLogger"),
// target dependency:
.product(name: "SimToolStateLogger", package: "StateLogger"),
```

The logger is inert unless the app is launched with `SIMTOOL_STATE_LOGGER=1` and
`SIMTOOL_SERVER_URL` (SimTool's app-launch flow sets these). Every change — from
methods, SwiftUI bindings, or async tasks — is debounced (~100 ms) and pushed to
the **State** tab: latest snapshot per model as an expandable tree, plus a diff
history. Notes:

- Requires iOS 17+ for the tracker. `@Observable` classes stream per-transition
  diffs via observation tracking; plain classes auto-fall back to polling
  (1 s default; pass `poll:` to tune — transitions shorter than the interval
  are not captured). Structs cannot be tracked top-level; annotate them to
  expand inside a tracked model. `track` is idempotent per instance and
  `name:` defaults to the type name.
- Snapshots include stored properties only, and only **scalars and collections of
  scalars** (Bool/numbers/String/Date/URL). Nested structs and classes render as a
  `"<TypeName>"` placeholder — annotate the nested class with `@SimToolDebugState`
  too if you want its contents. `@ObservationIgnored` properties appear in
  snapshots (as scalars or placeholders) but do not trigger updates.
- If a tracked model is also nested inside another tracked model (e.g.
  `ScreenModel.counter` where both are tracked), the change history shows
  only the parent's entry (`counter.state.filling: …`) — the child's standalone
  entries would duplicate it, so they are hidden while the parent is alive. The
  child still gets its own card in the model list.
- No method attribution: events tell you *what* changed, not *which method* changed it.
- Snapshots over 256 KB are replaced with a truncation marker.
