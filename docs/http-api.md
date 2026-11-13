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
GET /stream.avcc?sid=<stream id>
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
GET /api/v1/app/install
POST /api/v1/app/launch
POST /api/v1/app/launched
GET /api/v1/network/condition
POST /api/v1/network/condition
DELETE /api/v1/network/condition
POST /api/v1/input/paste-image
POST /api/v1/photos
GET /api/v1/ax/tree?raw=1&format=flat&labeled=1
GET /api/v1/ax/raw
GET /api/v1/ax/find?q=<text>&raw=1
GET /api/v1/logs?lines=200&seconds=2
POST /api/v1/logs/capture
GET /api/v1/logs/capture?since=<cursor>&limit=500
POST /api/v1/logs/capture/stop
GET /api/v1/logs/simtool?since=<cursor>&limit=500
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
GET /api/v1/network/qr.png
GET /simtool-ca.cer
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

A server started with `serve --allow-origin <origin>` (repeatable) lets pages
on those origins frame the viewer and, from their own origin, `GET
/api/v1/status` and `POST /api/v1/device/wake` — answered with
`Access-Control-Allow-Origin: <origin>` and `Vary: Origin`; nothing else. The
page then carries `frame-ancestors <origins>` instead of `'none'` and no
`X-Frame-Options`. Keep the wake a simple request (no body, no custom
headers): there is no preflight to answer.

Every address the viewer uses — its files, the API, the stream, the input
socket — is relative to the page, so a reverse proxy may serve it under a path
of its own (`https://site/sim/` in front of the server's `/`; the page has to be
opened with the trailing slash). Such a proxy is a client that is not a
browser: it sends the server's own `Host` and none of the browser's page
headers (`Origin`, `Sec-Fetch-*`), and so it — not this server — decides which
pages may reach the device. It also has to pass the socket's upgrade and to
stream `/stream.avcc` and `/api/v1/events` without buffering them.

A server open to the network (`serve --network`, see
[The viewer on other devices](usage.md#the-viewer-on-other-devices)) answers
the same routes on the same port in two ways: from this Mac's loopback, plain
HTTP as above; from any address, HTTPS — the network door, with no password
of its own (the network decides who reaches it). Behind that door the pages'
origin is `https://`, the socket `wss://`, and the Mac's Bonjour name and its
certificate's names count as this server's hosts. Plain HTTP from the
network gets a page pointing to HTTPS, SimTool's certificate at
`/simtool-ca.cer`, and `403` for everything else. `/config` carries `network`
— the HTTPS addresses, the certificate's path and SHA-256 fingerprint — and
`/api/v1/network/qr.png` is the first address as a QR code.

Behind the door the routes that act on the Mac rather than the simulator
answer `403`: `processes` (listing and stopping SimTool's processes),
`camera/webcam`, `app/reveal` and `app/install` with a URL (an upload in the
body stays open). The door keeps a browser's connection across requests
(idle for 15 s, it is closed) and refuses, before the server reads it, a
request body over 512 MB (`413`), one sent without a length (`411`) and a head
over 64 KB (`431`).

`processes` lists every SimTool process on the Mac, as `simtool ps --json`
does; `processes/<pid>/kill` stops one as `simtool kill <pid>` does — 403 for a
PID that is not SimTool's, and 409 for the server's own PID unless the body is
`{"confirm": true}`, when it answers first and then stops.

`tests/<session-id>/evidence/<file>` serves a recorded run's evidence — only
the files its session lists (`network.jsonl`, `logs.jsonl`, `state.jsonl`,
failure screenshots…). Step times in a session carry milliseconds.

`activity` is what was done to the device and by whom — `agent` (the CLI, the
HTTP API), `test` (a YAML run) or `viewer` (a person at a SimTool page, shown
as **User**): every input with the path its finger took in screen points, mocks
armed and removed, test runs and their steps — and what a person does by hand
over the input stream below: each gesture once its finger lifts (`tap`,
`long-press`, `swipe`, `drag`, `pinch`) and a burst of typing as one `type`
entry that grows while the keys keep coming. Each entry carries a `revision` that moves whenever
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

`/stream.avcc` is the screen as H.264 in envelopes — a 4-byte big-endian
length, a tag, the payload: 1 the decoder's configuration (avcC), 2 a
keyframe, 3 a delta frame. A still screen is refreshed five times a second;
each refresh comes after an empty envelope tagged 5, so a reader can tell the
frames that change the screen from the ones that repeat it (one that does not
know the tag skips it). Every viewer has a queue of its own: one that reads
slower than the screen changes skips frames up to the next keyframe — which the
server sends as soon as it has caught up — instead of holding the others back,
and one that stops reading for 10 s is disconnected. `GET /api/v1/metrics`
counts those skips in `skippedForSlowClients`.

`/stream.avcc?sid=<id>` — 8 to 64 letters, digits and dashes the reader makes
up — is the reader's own stream, as the viewer opens it: an encoder of its own
at the server's stream settings (`serve --stream-fps`, `--stream-bitrate`,
`--stream-max-size`; 60 fps, 6 Mbit/s and 1280 px unless set — `/config` has
them in `stream.defaults`), or at the reader's own when it adds `fps` (1–60),
`kbps` and `px` (the picture's longest side), each optional and each brought
into range. The settings hold for the stream's life: neither the link nor what
the screen shows changes them. The reader says on its `/api/v1/input/stream`
socket how many bytes of that stream it has received, `{"t": "got", "s":
"<id>", "b": 123456}`, every few tens of milliseconds while bytes come (never
holding the last count back). With that the server sees what is really on its
way — a slow link's frames otherwise wait unseen in socket buffers, an SSH
tunnel's, a VPN's — and paces the frames, not the settings: it encodes the
screen as it is whenever the link has room for a frame (what the link carries
in its own delay, and a little more). A link that carries the stream gets
every frame the screen makes, up to the frame rate; a slower one gets fewer,
each of them fresh, never a backlog. What the link carries is learnt from the
link alone, while it is what holds frames back: it drops to what the link
delivered when frames waited on the way and the link delivered less than
allowed, and rises otherwise; a far viewer starts at a 2 Mbit/s window, and
every 8 s a stream the window holds back drains once so its next frame
measures the link's own delay. The socket answers the first count, and again
whenever the link turns full or clears, with `{"t": "pace", "s": "<id>",
"fps": 60, "kbps": 6000, "px": 1280, "held": false}` — the settings, and
whether frames were held back lately for a link slower than the stream. A
reader that stops saying what it got for 2 s gets a frame a second.
`pacedViewers` in the metrics lists each such stream: `fps`, `bitrate`,
`maxDimension` (its settings), `linkBitrate` (the most its link delivered
lately), `delayMs` (the quickest a frame went and the word came back),
`inFlightBytes`, `encodedFrames`, `skippedFrames` (screens not encoded because
the link still carried earlier frames), `sentBytes`; the other counts are the
shared stream's, which the `--stream-…` settings set too.

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
`GET /api/v1/logs` remains the one-shot bounded snapshot. `logs/simtool` is
SimTool's own log in the same shape (`source` `simtool`, `level` `Debug`,
`Info` or `Error`, the area in `subsystem`) — the server's newest 2,000 lines,
numbered apart from the app's.

`/api/v1/events` pushes what the viewer's inspector shows as it changes — one
Server-Sent Events stream per page, with the topics `network`, `logs`,
`simtoolLogs` (SimTool's own lines, as `logs`), `state`,
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

With a JSON body it names a build at a URL instead, fetched by the Mac the
server runs on — a CI archive in a bucket never passes through whoever asked:

```json
{"url": "https://storage.example/builds/main/app-build.zip",
 "headers": {"Authorization": "Bearer …"},
 "app": "MyApp Debug.app", "clean": false,
 "launch": {"arguments": ["-Environment", "stable"], "environment": {}},
 "label": "main · 1a2b3c4 · who asked"}
```

`headers` go to that URL's origin alone — a redirect to another host gets none
of them, one from https to http is refused — and are never logged or answered
back. A build over 8 GB, or larger than the disk has room for (twice its size
and 2 GB more: the archive and the app from it), is not downloaded. An archive
naming a place outside itself (`..`, an absolute path), or whose app holds a
link out of the app, is refused. `app`
picks the bundle when the archive (zip or tar) holds several — a build and its
UI-test runner — wherever it is nested; only that bundle is unpacked. `clean`
removes the app and its data first; `launch` launches it once installed, and
remembers the launch as `app/launched` does. The request only starts a job and
answers `202` with it (`409` with the running one: one install at a time);
`GET /api/v1/app/install` follows it — `{"state": "idle"}` before any — with
`state` (`downloading`, `unpacking`, `installing`, `launching`, `done`,
`failed`), `source` (the URL without its query), `app`, `label`,
`receivedBytes`, `totalBytes`, `cached`, `bundleId`, `name`, `version`,
`build`, `pid`, `error`, `startedAt` and `finishedAt`. The job starts the
simulator if it is off and counts as use while it runs, so the server does not
put the device to sleep under it. A build fetched before (the same URL without
its query, the same `app`) installs again without a download while its host
says it is the same — the same `ETag`, or the same `Last-Modified` where there
is none, asked with a one-byte range request; a host that says neither gets
downloaded again. Each server keeps its two newest in
`~/Library/Caches/SimTool/builds/<simulator>/`. The activity feed shows the job
as one `install` entry whose detail follows its progress.

`POST /api/v1/app/launch` (`{"bundleId", "arguments", "environment"}`)
launches an installed app — terminating it first if it runs — with the
server's loggers, camera and network conditions, and answers its `pid`; the app
comes back that way when the simulator does.
`POST /api/v1/app/launched` (`{"bundleId", "arguments", "environment", "pid"}`)
tells the server about a launch made outside it — `simtool app launch` and
test runs send it — so that, if the simulator goes off and on again, the server
launches the app the same way (see *A server with its simulator off* in
[usage](usage.md)).

`GET /api/v1/camera` is the simulator's camera: `source` (`none`, `image`,
`video`, `webcam`), `name` (the file's, or the Mac camera's), `apps` (each with
`bundleId`, `pid`, `capturing` — whether a capture session of it runs now) and `macCameras` (`id`,
`name`). `POST /api/v1/camera` takes an image or a video as the raw body, typed
by `Content-Type` or `X-SimTool-Filename`; `POST /api/v1/camera/webcam`
(`{"camera": id or a part of the name}`, optional) captures the Mac's camera
until another source or `DELETE /api/v1/camera`, which turns it off. Each
answers the new state.

`GET /api/v1/network/condition` is the network the apps SimTool launches on
this simulator are held to: `condition` (null when off; else `profile`,
`title`, `downKbps`, `upKbps`, `downDelayMs`, `upDelayMs`, `downLoss`,
`upLoss` in percent, and `summary`), `apps` (`bundleId`, `pid`, `connections`
relayed) and `presets`. `POST /api/v1/network/condition` takes a preset
(`{"profile": "3g"}` — `3g`, `dsl`, `edge`, `lte`, `very-bad`, `wifi`,
`loss-100`, `off`), its numbers overridden by any given, or a custom link
(`{"downKbps", "upKbps", "delayMs" or "downDelayMs"/"upDelayMs", "loss" or
"downLoss"/"upLoss"}`); `"relaunch": true` launches the server's app again — as
it was last launched — when it does not have the conditions yet.
`DELETE /api/v1/network/condition` turns them off. Each change is an activity
(`network-condition`) and answers the new state.

`/api/v1/input/stream` is the viewer's live finger and keyboard: a WebSocket
taking one JSON frame per touch event, `{"t": "down"|"move"|"up", "x": 0.5,
"y": 0.7}` with coordinates as fractions of the screen, plus `x2`/`y2` for a
second finger and, on a foldable, `"d"` — the screen shown (`primary-1`) — and
one per key, `{"t": "keydown"|"keyup", "code": "KeyA"}` with
the browser's `KeyboardEvent.code` — a keydown may add `"k": "a"`, the
character the viewer's keyboard typed, which only the activity feed reads (the
device's own layout decides what lands). Moves are coalesced, downs, ups and
keys never dropped, and when the socket closes a finger still down is lifted
where it was and held keys are released. Input frames are not answered; two
messages come back: `{"t": "pong", "id": 7}` for `{"t": "ping", "id": 7}` — a
viewer times its round trip with it — and `{"t": "busy"}` for a gesture that
did not reach the device because another viewer's finger was down (one finger
at a time across every open viewer; a finger silent for 5 s lets go). The
socket also carries a reader's own stream's `got` and `pace`
(`/stream.avcc?sid=` above).

`SimToolClient` exposes these routes as typed async Swift calls.
