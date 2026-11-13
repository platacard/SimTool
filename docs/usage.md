# The viewer and the server

The examples here and in the other docs run the CLI from a checkout, as `swift
run simtool …` inside `Tool/` (or `swift run --package-path Tool simtool …` from
the repo root). With `simtool` installed, drop `swift run`.

```sh
swift run simtool devices --json
swift run simtool serve --device <udid-or-name> --port 3200
```

Open `http://127.0.0.1:3200` after starting `serve` (the URL is printed on start),
or pass `--web` to open the browser viewer automatically.

The viewer is one window: the device on the left, the inspector on the right
(**Network**, **Logs**, **State**, **Accessibility**, **Device**, **Tests**, **Activity**), with a splitter
between them that remembers where you leave it; in a narrow pane the inspector
moves under the device instead of covering it. When the inspector is too narrow
for every tab, its tab strip scrolls sideways — with the wheel or the trackpad —
the tab you switch to comes into view, and a fade marks the side with more. Under the device are the rotate
and keyboard buttons, then its size in points, the frame rate (frames that
changed the screen in the last second; *idle* while it is still) and the
pointer's position in points; the status bar at the bottom holds the session's facts —
connection, device and runtime, UDID (click to copy), server, attached app, the
simtool version — and a narrow window drops the version, the UDID and the device
from it in that order. The server's address stays at any width: it opens the
list of SimTool processes.
The viewer follows the system's light or dark appearance; the sun / moon button
in the toolbar pins the other theme for this browser.
⇧⌘P opens a command palette with every action and test; the shortcuts follow
Simulator.app and Xcode — ⇧⌘H Home (a double-click on the Home button or ⌃⇧⌘H opens the
app switcher), ⌘S screenshot, ⌘R record video, ⌃⌘Z shake, ⌥⌘0 show or hide
the inspector — and ⌥1–7 switch inspector tabs, `/` filters the current list,
↑/↓ move through it and Shift-F10 opens a row's menu. When the server goes away
the viewer greys the last frame, says so, stops sending touches and reconnects
by itself; a restarted server is noticed and its lists are reloaded.

The toolbar saves a screenshot (⌘S) and records the screen (⌘R): recording, the
button turns into a red REC mark with the running time, and a click or ⌘R again
stops it and downloads the video (H.264 `.mp4`). The caret beside them picks the
frame for both — **Screen only**, or **With the device bezel**: the device drawn
around the screen as Simulator draws it, side buttons, rounded corners and the
Dynamic Island included, from the DeviceKit chrome Xcode installed on the Mac
(SimTool ships no Apple artwork; a device without one gets a plain drawn frame).
A screenshot with the bezel is a PNG with a clear background, a video one has a
white background. The recording runs on the server, so a reload keeps it and
every viewer shows it; the server keeps only the newest video. The caret's menu
also copies the screenshot and downloads the last video again.

On an iPhone Duo the bar under the device holds Closed, Book and Open and a
**3D** switch in place of the rotate button, and the fold shows beside its size
(`book · 130° · inner`). 3D shows the
device itself, folded as it is and animated as it folds, filling the stage
whatever its pose, its lit panel live on it, rendered on
the server with RealityKit from the device model Device Hub draws it with
(`V68.usdz`, read from the selected Xcode at run time — SimTool ships no Apple
asset) and streamed like the screen. Clicks and drags on its screen land on
that panel. Without the model — or with RealityKit's offscreen renderer
missing (macOS 14) or failing — the button says why and the viewer stays on
the flat screen; `simtool doctor` reports it as "iPhone Duo 3D preview".

What an agent or a test run does to the device shows as it happens. Every touch
from `simtool input`, the HTTP API or a YAML step is drawn on the screen in
course ink — a ring where the finger went down, a stroke to where it lifted, a
caption naming it (`Tap “General”`, `Scroll up 300 pt`) — and launches, typing,
mocks armed and test steps caption the top of the screen. The toolbar says who
is driving: **Test running · step 3 of 7**, or **Agent driving** for half a
minute after an agent's last action — and for as long as it says so, a frame
runs round the whole page: course ink for an agent, run ink (teal) for a test.
With nobody driving there is no frame. The last action and how long ago it was
stay under the device, and **Activity** (⌥6) lists every action with who did it
— **Agent**, **Test** or **User** — how long it took and whether it failed; a
click on a column's name sorts the list by it (time, who, action, result), a
second click turns the order round. What a person does by hand on the viewer's
screen is in the list too: a tap, a long press, a swipe or a drag, a pinch, and
a burst of typing as one `Type “…”` that grows while the keys keep coming —
measured in the screen's points, so a touch's row shows its path the same way.
A touch's row shows its path in points,
draws it again on the screen and copies as the `simtool input` command that
repeats it. A touch, key or button from the page while a test or an agent drives
the device — while the page is framed — asks first whether to take the device
over; **Take over** lets the person act until the agent or the test acts again,
and then the next input asks again. A touch by hand during a run is itself in
the feed.

On the viewer's screen the mouse is a finger: it goes down on press, follows the
pointer and lifts on release, so holding is a long press, holding and moving
drags (icons, list reordering), and the release decides between a scroll that
stops where the finger did and a fling. A dot marks the finger at once, ahead of
the video; a ring around it says it has been held long enough for a long press.
The wheel or trackpad scrolls by dragging a finger too. Hold Option to add a
second finger mirrored through the screen center — spreading or circling the
pointer pinches or rotates — and Option-Shift to move both fingers together.

The keyboard works as in Simulator.app, from one keyboard button under the device.
Its menu shows or hides the software keyboard (Toggle Software Keyboard) and
connects the Mac keyboard — a switch beside it says whether it is connected.
Connected, or with ⇧⌘K, the Mac keyboard types into the simulator and its
hardware keyboard is connected (Connect Hardware Keyboard), so iOS keeps the
software keyboard out of the way until the menu or ⌘K brings it back; the
button turns course ink while it lasts. Keys travel as physical keys — the simulator's own layout
decides the character — with modifiers, arrows, ⌫, ⏎, Tab and Esc, which iOS
uses; ⇧⌘K leaves the mode, and ⌘V pastes the Mac clipboard as text. A ring
around the screen shows the keys go to the device, and the keyboard button's tip
says so; the ring turns dashed while they go elsewhere — to a SimTool field such as the
inspector filter, which keeps its keys, or to another window. Off, the keyboard belongs to the page and the
browser. Keys reach the simulator in a few milliseconds over the same helper as
the finger; ⌘W, ⌘T and ⌘Q stay with the browser. Agents show and hide the
software keyboard with `simtool input keyboard show|hide` and YAML tests with a
`keyboard: show|hide` step; both confirm the keyboard on screen (or off it)
through the accessibility tree, and `show` fails when no text field is focused.

`serve` runs fully headless: when `--device`, `--host`, or `--port` are omitted
it falls back to `simulator:` and `server:` from `.simtool/config.yml` (when one
is discovered, or passed via `--config`), and boots the target simulator via
`simctl` if it is not running yet — no Simulator.app window is ever opened; watch
the device in the web viewer instead. With `--detach --json` the started session
is printed as JSON whose `url` field is the viewer address, ready to feed into a
browser or another tool.

Run `simtool` with no subcommand (or `simtool interactive`) in a terminal to
pick and open configured deeplinks in a loop. Requires a `deeplinks:` list in
`.simtool/config.yml`; select `Exit` or press Ctrl+C to leave. Non-interactive
callers should keep using explicit subcommands such as `simtool devices` —
bare `simtool` no longer defaults to `devices`.

For detached agent usage:

```sh
swift run simtool serve --detach --json --port 3200
swift run simtool status --json
swift run simtool kill <session-id> --json
```

## The viewer on other devices

An iPhone, an iPad or another Mac on the same Wi-Fi can open the viewer of a
Mac that runs `simtool serve`, watch the simulator at up to 60 fps and drive
it with touch and keys. It is off by default (and needs macOS 15 or later);
open the server to the network with

```sh
simtool serve --network            # or server.network: true in .simtool/config.yml
```

A `--host` (or `server.host`) other devices reach — `0.0.0.0`, a LAN address —
opens it the same way: SimTool never answers the network over plain HTTP. On
start it prints where the network opens it:

```text
Open http://127.0.0.1:3200
On the network: https://my-mac.local:3200/  ·  https://192.168.1.27:3200/
First time on a device: open http://my-mac.local:3200/ to install SimTool's certificate
Its SHA-256 fingerprint, to compare on the device before trusting it: 1F 94 A4 …
```

This Mac keeps the plain address — the viewer, the CLI and the loggers in the
simulator work as before. Its viewer gains **Network** in the status bar: a QR
code of the address (a phone's camera opens it), the addresses and SimTool's
certificate with its fingerprint.

**Why HTTPS.** The viewer decodes the stream with WebCodecs, which browsers
give only to a secure page — HTTPS, or localhost. Opened as `http://<ip>` on
another device it would say *This browser cannot show the stream*. So the
server's port answers the network over HTTPS with a certificate SimTool issues
for this Mac's Bonjour name (`<name>.local`) and its addresses, from its own
certificate authority, made once per Mac in `~/Library/Application
Support/SimTool/network/` (its private key never leaves the Mac). A device
trusts that authority once:

1. Open `http://<mac>.local:<port>/` on the device — plain HTTP from the network
   gets a page with the steps and the certificate, nothing else.
2. **iPhone, iPad** (Safari): allow the download; Settings → *Profile
   Downloaded* → Install; then Settings → General → About → Certificate Trust
   Settings → turn on *SimTool local CA*. **Mac**: open the downloaded file,
   then in Keychain Access *SimTool local CA* → Trust → *Always Trust*.
   **Android** (Chrome): Settings → Security → Encryption & credentials →
   Install a certificate → CA certificate. The certificate came over plain
   HTTP, so before turning its trust on compare its SHA-256 fingerprint — on
   an iPhone in the profile's *More Details* — with the one `serve` prints and
   **Network** shows.
3. Scan the QR code, or open `https://<mac>.local:<port>/`. A device that
   does not resolve `.local` names (some Android versions) uses the address
   instead.

The authority can vouch only for `.local` names, `localhost` and private,
link-local and CGNAT addresses (X.509 name constraints): a copy of its key
could not impersonate a public site to a device that trusts it. The server's
certificate is issued again at every start for the names and addresses the
Mac has then — if its address changes while the server runs, use the `.local`
name or restart it. A certificate your company's browsers already trust — a
CI Mac's DNS name — replaces SimTool's: `server.tls.certificate` and
`server.tls.key` (PEM) in the [project config](project-config.md), and then
devices install nothing.

**What it exposes.** Anyone who reaches the port gets what the viewer gives
this Mac: the screen, touch and keys, the inspector — the app's requests and
logs (tokens of the accounts it uses included), state, accessibility —,
screenshots and recordings, installing an app, test runs and the list of
SimTool processes. SimTool asks for no password: who may reach the port is
the network's to decide — open it on a Wi-Fi or a VPN of people who may see
all that, or behind a sign-in in front of it. Pages on other sites still
cannot read or drive it (the same-origin rules above hold on HTTPS too).

**A site in front of it.** A page that hands out simulators — a team's own
site with its sign-in — can show the viewer inside itself:

```sh
simtool serve --network --allow-origin https://site.example   # repeat for more sites
```

A page on an allowed origin may frame the viewer (`frame-ancestors` names it),
read `GET /api/v1/status` and start the simulator (`POST
/api/v1/device/wake`) from its own origin, with CORS; every other route stays
closed to it, and every other site is refused as before. The browser talks to
the server directly, so the stream takes the shortest way. The site's own
rules — who may use which simulator — hold only as far as the network does:
the port still answers anyone who reaches it.

**macOS Firewall.** With the firewall on, macOS asks once whether `simtool`
may accept incoming connections (each new build asks again: SimTool is not
signed by a known developer); until it is allowed, a device on the network
just waits — in stealth mode nothing says why. `serve` prints a reminder
while the firewall has no rule for it; System Settings → Network → Firewall
→ Options lists and changes it.

**On a phone** the viewer shows the device alone, as large as the screen
allows; the inspector button brings the rest and is remembered. A finger is a
finger: tap, hold, drag, fling; two fingers pinch, rotate or pan together.
The keyboard button's **Type with this device's keyboard** raises the phone's
own keyboard: characters go to the simulator as the keys of a US keyboard
(Shift when needed), what has no such key is pasted, ⌫ and ⏎ work; **Connect
this device's keyboard** sends a hardware keyboard's keys (an iPad's) as on a
Mac. Over the network the readout under the device adds the round trip to the
server (`rtt 4 ms`).

**Several viewers** may be open at once, here and on other devices; each gets
the stream. One finger reaches the device at a time: a touch that starts
while another viewer's finger is down does not land, and its viewer says so —
the next one after that finger lifts does. Keys are not held back.

**A slow or far link** — a phone on weak Wi-Fi, a colleague across a VPN —
gets a stream paced to it: the page tells the server how much of the stream
has arrived, and the server encodes the screen as it is whenever that link
has room, at the bitrate, frame rate and size it carries, instead of piling
frames up in buffers on the way. The readout under the device shows the
bitrate while the link holds it below full quality. A viewer on this Mac or a
good LAN keeps the full 60 fps stream. [SimTool on a shared
Mac](remote.md) runs a CI Mac's simulator for people elsewhere this way, and
has the measurements.

**Measuring.** The fps readout counts frames that changed the screen; the
command palette (⇧⌘P, or the Commands button) has **Measure input → screen
latency**: on a scrollable list (Settings) it drags the screen a little eight
times and times each first move from the page to a changed frame painted
there — the network both ways, the device, the app redrawing, encoding and
decoding. Measured on 2026-11-12 (MacBook, Xcode 27.2, iPhone 17 Pro simulator
on iOS 26.4; two viewers at once through the network door at the Mac's Wi-Fi
address, from the Mac itself, so without a radio hop): 60 fps on both while a
finger dragged the Settings list (59–60 steady), input → screen 32–43 ms
median (16–58 ms), round trip 1 ms. On Wi-Fi add the round trip the readout
shows on the device.

## SimTool processes

Every SimTool server registers itself, whichever `simtool` binary started it —
a Homebrew install, another checkout's debug build — and runs helpers of its
own: the HID and fold helpers SimTool compiles into
`~/Library/Caches/SimTool/SimulatorHelpers`, the `simctl spawn` that runs one
inside the simulator, its log streams. `simtool ps` lists them all, each server
with what runs for it, besides the reaper and running commands; an **orphan** is
a helper whose server or command is gone, which nothing will stop.

```sh
swift run simtool ps                  # every SimTool process on this Mac
swift run simtool ps --json           # the same, for an agent
swift run simtool kill <pid>          # one process and what runs for it
swift run simtool kill --orphans      # every orphan
```

`kill <pid>` takes only a PID `ps` lists — another process is refused. A server
stops through its session, as `kill <session-id>` stops it: SIGTERM, so it shuts
its simulator down, and SIGKILL if it will not go; anything else gets SIGTERM,
then SIGKILL. Its helpers and children go with it. In the viewer, the server's
address in the status bar (or **SimTool processes** in the command palette)
opens the same list, refreshed every two seconds, with **Kill** on each row and
**Kill all orphans**; stopping a server, a command or the reaper asks first, and
stopping the viewer's own server says the page will lose its device.

## Simulators SimTool holds

A booted simulator with its app burns a core or so doing nothing, so nothing
SimTool brings up stays booted once the work is done. SimTool **holds** a
simulator it boots — `serve`, `run`, a test run's server, `open`, or any command
pointed at a simulator that is shut down, which boots it first — and one a SimTool
server runs on, whoever booted it (a script's `xcrun simctl boot` ahead of
`serve` included). What it holds, it shuts down:

- **when its server stops** — Ctrl-C, `simtool kill`, a SIGTERM — unless another
  SimTool server is still on it;
- **when nothing has used it for the idle timeout** — 15 minutes by default. Use
  is a command or an agent's request, a test run in progress, a screen recording,
  or a person in the viewer: a touch, a key, the pointer moving over the page. A
  viewer tab left open is not use — its own streams and polls do not count, nor
  do the app's loggers posting events. The server shuts the simulator down and
  **stays up** — see *A server with its simulator off* below;
- **when it was left behind** — booted by a command, or its server SIGKILLed — by
  the reaper: `simtool reap --watch`, started in the background while SimTool
  holds any simulator, which exits once it holds none. Stopping the reaper (a
  SIGTERM, `pkill simtool`) shuts down what only it was watching, unless a
  command used it in the last minute and a half.

A simulator SimTool never booted or served — an Xcode run, a Device Hub window —
is never shut down, nor one an `xcodebuild` is running on (by `id=` or `name=` in
its destination), until that run ends. A hold covers one boot: a simulator shut
down and booted again outside SimTool is no longer SimTool's.

```sh
swift run simtool serve --idle-timeout 1h        # this server; `off` keeps it up
SIMTOOL_IDLE_TIMEOUT=30m swift run simtool run   # whatever this shell starts
swift run simtool reap --dry-run                 # what SimTool holds, and for how long unused
swift run simtool reap                           # shut down what is idle, now
swift run simtool reap --all                     # shut down everything SimTool holds, now
```

The timeout comes from `--idle-timeout` (`serve`, `run`), then
`SIMTOOL_IDLE_TIMEOUT`, then `idleTimeout:` in `.simtool/config.yml` — which
`simtool init` writes, commented out. A running server reads it again every
15 s, so an edited `idleTimeout:` applies without a restart (unless the flag or
the variable set it; a config that does not read keeps the last value). A command
that boots a simulator says so on stderr, with when SimTool will shut it down
again. Holds live in `$TMPDIR/simtool/simulators` (one JSON file per simulator,
plus the reaper's `reaper.log`), so every SimTool process sees them.

### A server with its simulator off

A simulator burns the CPU; a server waiting for requests does not. So when its
simulator goes unused for the idle timeout, the server shuts it down and keeps
running on the same port, with the same session, logs, network capture and
recordings. The viewer keeps the last frame, says the simulator is off and why,
and offers **Start simulator**; the status bar reads *Simulator off*. The
simulator comes back on — and the viewer streams it again by itself — when:

- someone presses **Start simulator** (`POST /api/v1/device/wake`), which
  boots it and answers once the server streams it;
- an agent or the CLI sends the server a request that acts on the device
  (`input`, `ax`, `screenshot`, `app`, `tests/run`, …): the server boots it
  first and then answers, so a script never sees the gap. What the viewer
  asks by itself is answered 409 with the simulator's state instead —
  an open tab never boots anything;
- a SimTool command boots it — `simtool input …`, `app launch`, another
  server: the server takes on that boot within a few seconds. A boot started
  outside SimTool — Xcode, `xcrun simctl boot` — it leaves alone until someone
  presses Start, and the viewer says the simulator is on outside SimTool: a
  server left running for days must not take a person's Xcode run and shut it
  down when it looks unused.

A server started with `serve --asleep` begins that way: it answers at once
with its simulator off and boots it on the first Start or request that needs
it — for several servers on one Mac, which then do not all boot together after
a restart. A simulator that is already on when it starts is taken on as usual.

The app comes back with it. A simulator that went off took its apps along,
so once the server has the simulator on again it launches the app that was
running when it went off — the last one launched through SimTool (the viewer's
Launch, its stdout capture, `simtool app launch`, a test run), else the
server's own `--app` — the same way it was launched: the same arguments and
variables, the loggers armed, the camera and the network conditions as they are
now. So Network, Logs and State pick up where they stopped. Whether it was
running is asked of the simulator as SimTool shuts it down; shut down outside
SimTool, it is already gone, and the server's last look at the app's process
(every 15 s) decides. An app terminated through SimTool stays down; nothing is
launched over a test run, over an app someone launched since, or when the app
already runs. Activity says so: **SimTool** · *Relaunch <app>*. A Mac that
sleeps does not take the simulator down — the app simply carries on.

`GET /config` and `GET /api/v1/status` carry `power`: `on`, `off` (with
`reason` — `idle`, `released`, `shutdown`, `outside`, `failed` — and what the
viewer says) or `starting`. A request that waits for a start gets 503 after
150 s if the simulator is still booting; the start goes on. A simulator shut down outside SimTool turns the server
off the same way, instead of stopping it. Two servers on one simulator: the
first to go idle lets go of it (`released`), the last one shuts it down. A
server with its simulator off holds no simulator — the reaper, `reap` and
another server stopping on it go by the servers that are on — and stopping it
(`simtool kill`, a SIGTERM) leaves the simulator as it is.

A boot SimTool starts itself that comes up with its touch screen stood down —
on Xcode 27 a simulator booted after it sat off for a while often starts its
HID daemon a moment too late, and every touch of that boot would be lost — is
booted again at once, which comes up right.

## The Network and Logs tabs

The viewer's **Network** tab is a Proxyman-style inspector beside the live
stream: requests in columns that sort on a click and that you arrange as in
Logs (below: drag a name to move, an edge to size, right-click the header to
show or hide), quick filters (a protocol — HTTP, gRPC and every other one the
app reported — problems — failed calls and broken streams in red, 4xx,
client-side gRPC codes and refused subscriptions in amber — and mocked calls),
pause and clear, and a detail pane under the list. Its head says the
status (`404 Not Found`, gRPC codes by name), the duration, what was sent and
received and when; under it **Request** and **Response** — as tabs, or **Side
by side** — each in sections that fold and stay folded: the request's URL or
gRPC service and method, its query parameters, then the body, then the headers
or metadata; the response's errors first, then its body and headers. A body is
a tree that folds — JSON, or the protobuf text format gRPC loggers print — or
**Raw** text; a preview the app's logger cut short says so and reads as far as
it goes. **Copy as cURL** / **grpcurl** and **Copy as YAML mock** (a `mocks:`
entry that answers the call the same way in a test) sit beside it.

A stream session is one row: its state (connecting, open with how many
channels, closed with its code, failed) and how long it has run. Its
**Messages** are every event of the session in order — ↑ sent, ↓ received, and
what became of the connection and its channels — with the picked one's payload
under them (↑ ↓ step through them); **Connection** has its URL, subprotocol,
handshake headers, channels and lifecycle. A call of a protocol SimTool does
not know reads as the app reported it: its operation, target, status, headers,
metadata and bodies.

The search field reads URLs, methods, statuses, hosts, channels, headers, bodies
and stream payloads — `url:`, `method:`, `status:`, `host:`, `channel:`,
`header:` or `body:` narrows it to one —
marks what it found in the list and the detail, tags a call found only in its
headers or body with where (`response body`), opens the side it is on, and
steps through the marks with ↑ ↓. It updates live from the events endpoint.

The **Logs** tab is a live log inspector with level toggles, free text and
field filters (`subsystem:`, `category:`, `process:`), follow mode — scrolling
up to read turns it off, scrolling back to the end turns it on — and clear; a
line is red only when its level is Error or Fault. Its columns are yours: drag a
column's name to move it and its right edge to size it (double-click the edge
resets it; ⌥← ⌥→ and ←/→ on the edge do the same from the keyboard), and
right-click the header to show **Category** and **Process** or reset them —
the viewer keeps the layout for this browser. When scoped to an app it
captures both the app's OSLog and its `print`/stdout output (via
`--console-pty`), polling the capture endpoint incrementally by cursor; no app
instrumentation is required.

Both inspectors group entries by **app launch**: the server detects each launch
of the inspected app from the OSLog process id (and from network-logger
batches), and the logs and network lists draw an `App launch · <time> · pid <n>`
divider wherever the launch changes. So when you fully kill and relaunch the
app, its new logs and requests keep streaming below a fresh divider while earlier
launches stay above (for the life of the server). Only the current launch is
open: an earlier one's divider is folded, and a click on it — or ← / → on a row,
or its menu — opens or folds it. What you open or fold stays so; a launch you
never touched folds by itself once a newer one starts. OSLog
(`os.Logger`/`NSLog`) and network events continue across such a relaunch;
`print`/stdout does **not** — it is only captured while SimTool itself launches
the app with `--console-pty`, so after an icon-tap or Xcode relaunch only OSLog
remains for that source.

**App · SimTool** at the left of the Logs toolbar switches to SimTool's own
log: what the server did and what failed inside it — the simulator going off
and on and why, an app relaunched after it (or why not), a log capture that
did not start again, a viewer that reads the video slower than the screen
changes or stopped reading, a request it could not answer (`Error`), with the
helpers' and the lease's details at `Debug`. It is kept apart from the app's
lines — `simtool logs` and the capture routes never mix them in — needs no
attached app, and works with the same levels, filter, columns and Clear; the
button carries a red dot while it holds errors. The server keeps the newest
2,000 lines while it runs; `--verbose` also writes them to stderr.

Start the server with `--app <bundle-id>` to scope log capture to one app. The
server then captures that app's OSLog **and** `print`/stdout (instead of
flooding with system-wide OSLog), advertises the app via `/config`, and the
viewer's Logs tab captures it from the start. Capturing relaunches the app
once (to attach its console); after that, opening or closing the panel does
**not** restart it — the server-owned capture stays alive and reopening reuses
it:

```sh
swift run simtool serve --device <udid-or-name> --app com.example.MyApp
```
