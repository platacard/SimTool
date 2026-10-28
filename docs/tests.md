# Tests and sessions

Declarative YAML tests in `<project>/.simtool/tests/` drive the simulator
through the served accessibility tree: every step polls until its target
appears, so tests need no sleeps. Each run is recorded as a reviewable test
session — timestamped steps, a screen recording and the run's evidence — shown
in the web viewer's **Tests** tab, which also lists the tests with Run buttons,
live progress and each test's last outcome in words (*Bug reproduced*,
*Confirmed*, …), and keeps the recorded runs under **History**. A finished run's
recording plays in the screen's place — Replay is a mode of the whole viewer,
so the inspector stays usable — with each step marked on its scrubber, and
clicking a step seeks the video to that moment. While it plays, **Network**,
**Logs** and **State** show that run — its own `network.jsonl`, `logs.jsonl`
and `state.jsonl`, so a run reads the same long after its server is gone — cut
to the step under the playhead: from the moment the step began acting to the
moment the next one did, so a tap's window holds the requests and lines it
caused while the next step waited for them; State shows the models as they
stood at the end of that window and what changed inside it. A bar over each
list names the step and its span and switches to the whole run. In the
timeline every step says what it caused — *1 request · 277 log lines · 1 state
update* — and each count opens that list, held at that step.

```bash
swift run simtool test run .simtool/tests/my-test.yml
swift run simtool test run .simtool/tests/my-test.yml --json --repeat 5
swift run simtool test list --json
```

A running server is not a prerequisite: when none is running, `test run` starts
one on a free port and leaves it running — it is what serves the viewer, and the
run just recorded is what the viewer is opened to read; once nothing uses it for
the idle timeout it shuts the simulator down and stays up to start it again (see
[Simulators SimTool holds](usage.md#simulators-simtool-holds)). The run prints its address and how to stop it; `--stop-server`
stops it automatically, which is what a CI job wants. One already running for this project is reused and left alone; one
belonging to another checkout is not — the run says so and starts its own instead.
`test list` applies the same rule without the autostart: it reads a server started
for this project, or the one `--server` names, and never another checkout's
history.

A run started from the command line is visible in the viewer while it happens:
its session carries the test file, so the Tests tab follows the run, streams its
steps, and offers no Run button for a test that is already running.

`setup:` commands are told where the run's server is — `{server}` in the command,
`SIMTOOL_SERVER` and `SIMTOOL_SERVER_URL` in their environment — so a scenario
that needs a second launch does not have to write a port into the test file.

A test carries everything needed to stage its scenario, so it reproduces on
another machine: `launch:` (a named profile from `.simtool/config.yml` plus
inline argv/env), `reset:` (UserDefaults, data container, permission alerts,
locale) and `mocks:` (backend answers, applied before launch). See
`simtool test run --help` for the full file format.

When the project config says how to build the app, a run rebuilds it for the
run's simulator and reinstalls it first — only when the sources changed, since
the checksum cache decides — and before the recorder starts, together with
`reset:` and `setup:`. So the video
holds the run itself rather than minutes of an Xcode build, while the staging
still appears in the timeline and its logs are still captured. `--no-build`
judges whatever is already installed.

## Verdicts

A test that declares `kind: bug` or `kind: feature` and marks the assertions
that check its claim with `criterion:` gets a verdict instead of a bare
pass/fail — and a distinct exit code, so an agent can branch without parsing
output:

| Verdict | Exit | `kind: bug` | `kind: feature` |
|---|---|---|---|
| `satisfied` | 0 | not reproduced / fixed | feature confirmed |
| `unsatisfied` | 1 | bug reproduced | feature not confirmed |
| `inconclusive` | 2 | the run never reached a criterion | same |
| `infra` | 3 | the run cannot be trusted | same |

The point of the split is that a run which fell over while staging the scenario
proves nothing: reporting it as "the bug reproduces" sends someone to fix the
wrong thing. `infra` covers a run whose staging silently did not happen — a
`strict:` mock that never intercepted a call, an app that never picked up its
mock rules, a `reset:` that failed — and is never reported as a pass.

A run that never started uses the same scale rather than a bare failure: a test
that cannot run as written (unreadable file, parse error, unknown profile, a
`${VAR}` nothing defines) exits `2`, and an environment with nowhere to run it
exits `3`. So exit `1` always means a criterion did not hold.

A `bug` run stops at the first unmet criterion; a `feature` run reports every
criterion from one run. Tests with no `kind:` keep the old behaviour (0 or 1).
`--repeat N` runs the test N times and reports how many runs held the claim,
because an intermittent defect that passes once looks fixed.

## Evidence

Sessions persist under `<project>/.simtool/test-sessions/<session-id>/`
alongside the project the server was started for, and survive server restarts.
Besides `session.json` and `video.mp4`, a run writes what explains it — the
runner arms the log capture itself and scopes it to its own launches:
`logs.jsonl`, `network.jsonl` (with `mocked` and the rule id per event),
`state.jsonl`, `mocks.json` (what each declared rule actually did) and a
screenshot plus visible-element dump at the point of failure. `--evidence
none|failure|full` controls how much; `full` also captures every step.
`session.json` additionally records provenance: an inline copy of the test, the
app's bundle id and version, the device and runtime, the simtool version, and
the commit.

Every recorded run also writes `report.md` — the same run rendered for a person —
regardless of `--evidence`, which controls captures rather than that.

One session is active at a time; sessions can also be driven directly over HTTP
via `POST /api/v1/tests/start|entries|stop`.

## Sharing a test

The test is the artifact. It carries everything needed to stage its scenario, so
sending the `.yml` file is the whole handoff — to the agent that will fix the
bug, to a reviewer, to whoever tests the fix:

```bash
swift run simtool test run .simtool/tests/my-test.yml     # on the receiving side
```

Attach the two files next to the run when they help: `report.md` — the run
written for a person, with the claim, the verdict, the timeline and what the
receiver has to supply — and `video.mp4`.

What the receiver needs: `simtool`, a booted simulator, their own build of the
app (which is the point when verifying a fix), and any `${VAR}` the test refers
to without defining. A test that defines its `variables:` travels ready-to-run;
anything it leaves to the shell is checked before the simulator is touched, so a
missing account fails in a second rather than mid-run. `--var NAME=value`
overrides a value the test does define.

Do not forward the evidence files outside the team: `logs.jsonl`,
`network.jsonl` and `state.jsonl` hold the real traffic and log output of the
account the run used. `report.md` says so too.

`ax tree` and `ax find` omit the bulky raw AXe payload by default; pass `--raw`
(or `?raw=1` on `/api/v1/ax/tree` and `/api/v1/ax/find`) to include it. For the
cheapest screen summary use `ax tree --flat` (`?format=flat`) — a depth-annotated
node list with identifiers, labels, and frames — and add `--labeled`
(`&labeled=1`) to keep only nodes an agent can address. JSON output is
pretty-printed at a terminal and compact when piped.

`logs tail --app` accepts a bundle identifier, subsystem prefix, or process name.
For dotted bundle identifiers, SimTool also matches the final component as a
process name so app `print` output can be found more reliably.

By default `logs tail` samples only unified logging (OSLog). Add `--stdout` (with
`--app <bundle-id>`) to also capture the app's `print`/stdout output via
`simctl launch --console-pty` — this **terminates and relaunches the app** to
attach its console. Each captured line is tagged with its `source` (`oslog` or
`stdout`).
