# HTTP API

Local endpoints:

```text
GET /health
GET /config
GET /api/v1/status
GET /api/v1/devices
GET /api/v1/metrics
GET /api/v1/events (Server-Sent Events)
GET /stream.avcc
GET /stream.avcc?view=3d&theme=dark&bg=1b1d20&aspect=0.8
GET /stream.jpeg
GET /stream.mjpeg
POST /api/v1/input
GET /api/v1/input/stream (WebSocket)
GET /api/v1/device
POST /api/v1/device
POST /api/v1/device/wake
GET /api/v1/app?bundleId=<id>
POST /api/v1/app/reveal
POST /api/v1/app/install
POST /api/v1/input/paste-image
POST /api/v1/photos
GET /api/v1/ax/tree?raw=1&format=flat&labeled=1
GET /api/v1/ax/raw
GET /api/v1/ax/find?q=<text>&raw=1
GET /api/v1/logs?lines=200&seconds=2
POST /api/v1/logs/capture
GET /api/v1/logs/capture?since=<cursor>&limit=500
POST /api/v1/logs/capture/stop
GET /api/v1/network?seconds=2&limit=200
POST /api/v1/network/events
GET /api/v1/network/events?protocol=<name>&session=<id>&since=<iso8601>&limit=200
GET /api/v1/mocks
GET /api/v1/mocks/ack
GET /api/v1/activity?since=<revision>&limit=200
POST /api/v1/activity
GET /api/v1/tests/<session-id>/evidence/<file>
GET /api/v1/screenshot?maxDim=800&display=<screen>&bezel=1
GET /api/v1/recording
POST /api/v1/recording
POST /api/v1/recording/stop
GET /api/v1/recording/<id>/video
GET /api/v1/processes
POST /api/v1/processes/<pid>/kill
POST /api/v1/processes/kill-orphans
```

The API answers the viewer's own page and clients that are not browsers — the
CLI, `curl`, the app-side loggers posting from the simulator. A page on any
other origin is refused with 403 on every route: it reads no answer (there are
no CORS headers), cannot tap, mock or delete through a plain form-style POST,
cannot open the input socket, and cannot frame the viewer — a link elsewhere
opens it in a tab, nothing more. A `Host` other than an IP address, localhost
or `server.host` is refused too, so a DNS-rebinding page whose name resolves to
127.0.0.1 is not this server either. The viewer runs under a Content Security
Policy that allows only its own files from `/assets/`; nothing under `web/` may
be inline script or `<style>`.

`processes` lists every SimTool process on the Mac, as `simtool ps --json`
does; `processes/<pid>/kill` stops one as `simtool kill <pid>` does — 403 for a
PID that is not SimTool's, and 409 for the server's own PID unless the body is
`{"confirm": true}`, when it answers first and then stops.

`tests/<session-id>/evidence/<file>` serves a recorded run's evidence — only
the files its session lists (`network.jsonl`, `logs.jsonl`, `state.jsonl`,
failure screenshots…). Step times in a session carry milliseconds.

`activity` is what was done to the device and by whom — `agent` (the CLI, the
HTTP API), `test` (a YAML run) or `viewer` (a person at a SimTool page): every
input with the path its finger took in screen points, mocks armed and removed,
test runs and their steps. Each entry carries a `revision` that moves whenever
it changes (a tap opens, learns where it lands, finishes), so `since` the last
`revision` returns what changed, once per change — the same entries the event
stream's `activity` topic pushes; `run` is the test run driving
the device, while one is. `simtool input …`, `app launch` and `open` act on the
simulator in their own process and report themselves to every live server
streaming that device with `POST /api/v1/activity` — `{"kind", "title",
"detail", "gesture"}` opens an entry, `{"id", "status"}` finishes it — best
effort, never failing the command. A request that sends `X-SimTool-Source:
viewer` is the viewer's own; an input that names a `target` (a test step's
element) is called by it in the feed, never aimed by it.

`POST network/events` takes the batches an app's network logger sends and reads
them event by event: an event the server cannot read — from a newer logger —
is skipped and counted as `rejectedCount`, and the rest are kept. The server
keeps the newest 1,000 calls and, apart from them, the newest 3,000 stream
events. `GET network/events` returns both in the order they happened;
`protocol=` takes any protocol name, `session=` keeps one stream session.

`mocks/ack` reports the server's mock-rule generation and the newest one an app
has confirmed applying (learned from its poll). A run that declares `mocks:`
waits for the two to meet before its first step — otherwise the app can still be
answering from the real backend while the test believes it is mocked. Its
`logger` is the release the app's network logger reported with its last poll or
event batch (`version`, null for a logger before 1.0), and a `warning` when that
release is not the server's.

`/stream.avcc?view=3d` is a foldable's 3D preview in the screen stream's
envelopes, `theme` choosing the shell's finish, `bg` the backdrop's colour and
`aspect` the frame's shape (width per unit of height — the viewer's stage; the
long side is 1280 px), the device framed to fill it in every pose; before each frame whose map moved it sends an envelope tagged 4 with JSON
`{"pieces", "panel", "hinge", "width", "height"}` — per leaf of the lit panel
the frame corners it lands on and the part of the panel's framebuffer it shows.
It answers 503 with the reason when there is no 3D to show; `/config` says so
ahead in `view3d` (`available`, `reason`).

`screenshot` returns the full-resolution PNG by default; `maxDim` scales it so
the longest edge fits the given pixel size — agents reading the screen pay for
image pixels, and an 800px screenshot is still perfectly legible.
`bezel=1` draws the device around the screen (`simctl … --mask=black` for the
glass, the device type's DeviceKit chrome for the body and buttons).

`recording` records the screen the stream shows, one recording at a time:
`POST` (`{"bezel": true}` for the device around it) starts `simctl io
recordVideo`, `recording/stop` finalizes it and answers once it is saved —
`state` `ready` with `durationSeconds` and `byteCount`, or `failed` with the
`error` — and `recording/<id>/video` serves the mp4 (byte ranges included).
`GET` answers `{"current", "last"}`, which the event stream's `recording` topic
pushes whenever it changes. Only the newest video is kept, in a temporary
folder the server removes when it stops.

A device with more than one screen — the iPhone Duo, a cover panel and an inner
one that opens like a book — streams, screenshots and records the screen that is
lit, and follows it as the device folds. `/config` lists the screens under
`displays` (`id` as simctl names it — `primary`, `primary-1` —, `role` `cover` or
`inner`, the framebuffer `width`/`height`, the picture's `rotation` and its size
in `points`, `active`) and names the lit one in `activeDisplay`; the event
stream's `device` topic sends them again whenever they change. `screenshot`
takes `display=` (an `id`, a `role` or the screen number) for the screen that is
not lit — which reads black. The inner panel's framebuffer is portrait while it
shows a landscape picture: `rotation` 90, `points` 951 × 669.

The `logs/capture` routes drive a continuous capture (OSLog plus optional
stdout/`print`) into a bounded buffer that clients poll incrementally by cursor;
`GET /api/v1/logs` remains the one-shot bounded snapshot.

`/api/v1/events` pushes what the viewer's inspector shows as it changes — one
Server-Sent Events stream per page, with the topics `network`, `logs`, `state`,
`tests`, `launches`, `activity` (an entry of `/api/v1/activity` each time it
changes, with the log's `revision`) and `device` (the device's screens, as
`/config` lists them). It opens with a `snapshot` event holding all of them,
then sends each change once, with `id: <server instance>:<sequence>`. A client
that reconnects with `Last-Event-ID` (or `?lastEventId=`) gets the events it
missed; one whose id is too old, or from a previous run of the server, gets a
fresh snapshot instead. It is same-origin only: the stream sends no CORS headers.
The JSON routes above stay, and the viewer falls back to polling them while the
stream is down.

`POST /api/v1/input` takes an `action` — `tap`, `longPress`, `type`, `paste`,
`swipe`, `scroll`, `fling`, `drag`, `button`, `shake`, `terminate`, `launch`,
`software-keyboard`, `hardware-keyboard`, `pose`, `rotate` — plus that action's fields: `x`/`y` or
`id`/`label` for `tap` and `longPress` (`duration` for the press),
`startX`/`startY`/`endX`/`endY` with `velocity`, `duration`, `hold` (and `press`
for `drag`), `direction` with `distance` or `velocity` and an optional start
`x`/`y` for `scroll` and `fling`, `text` for `type` and `paste`, `enabled` for
`hardware-keyboard` (connect or disconnect it), `visible` for
`software-keyboard` (show or hide it and confirm it on screen; without it, a
toggle), `name` (`closed`, `book`, `open`) or `angle` (0–180) for `pose`,
`name` (`portrait`, `landscape-left`, `landscape-right`, `upside-down`, or
`left` / `right` for a quarter turn) for `rotate`.
Coordinates are screen points. Images go as the raw request body instead:
`POST /api/v1/input/paste-image` pastes one into the focused field, and
`POST /api/v1/photos` adds an image or a video to Photos. Both read the type from
`Content-Type` and an optional percent-encoded `X-SimTool-Filename` header.

`POST /api/v1/device` changes a setting of the device or acts on it, as one
activity entry, and answers with what the device reports afterwards in
`stdout`: `{"action": "appearance", "value": "light"|"dark"}`, `content-size`
(`value`: a size, `increment`, `decrement`), `increase-contrast` (`enabled`),
`debug` (`option`, `enabled`), `memory-warning`, `biometrics` (`value`:
`enroll`, `unenroll`, `match`, `nomatch`), `push` (`payload` with `aps`,
`bundleId` — the server's app by default), `status-bar` (`statusBar` with
`time`, `dataNetwork`, `wifiMode`, `wifiBars`, `cellularMode`, `cellularBars`,
`operatorName`, `batteryState`, `batteryLevel`; or `value: "clear"`) and
`location` (`location` with `waypoints` of `latitude`/`longitude` and, for a
route, `speed`, `interval` or `distance`; or `value: "clear"`). `GET
/api/v1/device` reads them all back — `appearance`, `contentSize`,
`increaseContrast`, `debug`, `biometrics` (`kind` face or touch, `enrolled`),
`statusBar` (the overrides in force), `location` (the one SimTool last set),
`accessibility` (`reduceMotion`, `reduceTransparency`, `buttonShapes`,
`voiceOver`, `colorFilter`, `liquidGlass`), `orientation` — and names in
`unavailable` whatever the device would not say, and why. More actions:
`accessibility` (`option`: `reduce-motion`, `reduce-transparency`,
`button-shapes`, `voiceover` with `enabled`, or `color-filter`, `liquid-glass`
with `value`), `permission` (`option`: a permission, `value`: `grant`, `deny`,
`reset`, `always` for location, `bundleId` — the server's app by default) and
`keychain` (`value`: `reset`, `add-cert`; `certificate`: the
file's bytes in base64). `GET /api/v1/app` is the app's card — `installed`,
`name`, `version`, `build`, `minimumOS`, `pid`, `bundlePath`, `dataContainer`,
`permissions` — for `bundleId` or the server's app; `POST /api/v1/app/reveal`
(`{"bundleId", "what": "bundle"|"data"}`) shows one in the Finder of the Mac the
server runs on; `POST /api/v1/app/install` installs the build in the body — an
`.ipa`, or a tar of an `.app` — and answers its `bundleId` and `name`.

`GET /api/v1/camera` is the simulator's camera: `source` (`none`, `image`,
`video`, `webcam`), `name` (the file's, or the Mac camera's), `apps` (each with
`bundleId`, `pid`, `capturing` — whether a capture session of it runs now) and `macCameras` (`id`,
`name`). `POST /api/v1/camera` takes an image or a video as the raw body, typed
by `Content-Type` or `X-SimTool-Filename`; `POST /api/v1/camera/webcam`
(`{"camera": id or a part of the name}`, optional) captures the Mac's camera
until another source or `DELETE /api/v1/camera`, which turns it off. Each
answers the new state.

`/api/v1/input/stream` is the viewer's live finger and keyboard: a WebSocket
taking one JSON frame per touch event, `{"t": "down"|"move"|"up", "x": 0.5,
"y": 0.7}` with coordinates as fractions of the screen, plus `x2`/`y2` for a
second finger and, on a foldable, `"d"` — the screen shown (`primary-1`) — and
one per key, `{"t": "keydown"|"keyup", "code": "KeyA"}` with
the browser's `KeyboardEvent.code`. Frames are never answered; moves are
coalesced, downs, ups and keys never dropped, and when the socket closes a
finger still down is lifted where it was and held keys are released.

`SimToolClient` exposes these routes as typed async Swift calls.
