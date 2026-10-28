# Automation from the CLI

```sh
swift run simtool input button home --json
swift run simtool input button app-switcher --json   # Home pressed twice
swift run simtool input keyboard hide --json   # show | hide | toggle the software keyboard
swift run simtool ax tree --json
swift run simtool ax tree --flat --labeled
swift run simtool ax find Continue --json
swift run simtool logs tail --lines 20 --seconds 2 --json
swift run simtool logs tail --app com.example.MyApp --lines 20 --seconds 2 --json
swift run simtool logs tail --app com.example.MyApp --stdout --seconds 4 --json
swift run simtool network snapshot --seconds 2 --limit 50 --json
```

The simulator's settings and Simulator.app's Debug menu, which Device Hub
(Xcode 27) left out — each prints the setting without a value, changes it with
one, and reports the change to the viewers watching the device:

```sh
swift run simtool settings --json                 # all of them, as the device reports them
swift run simtool ui appearance dark              # light | dark
swift run simtool ui text-size ax2                # simctl's sizes, xs…xxxl, ax1…ax5, bigger, smaller
swift run simtool ui contrast on                  # Increase Contrast
swift run simtool debug color-blended on          # slow-animations, color-blended, color-copies, color-misaligned, color-offscreen
swift run simtool debug memory-warning
swift run simtool biometrics enroll               # enroll | unenroll | match | nomatch
swift run simtool push --alert "Your order shipped" --app com.example.MyApp
swift run simtool status-bar clean                # 9:41, full Wi-Fi, charged; or --time, --battery-level…; clear
swift run simtool location route 37.3349,-122.0090 37.3318,-122.0312 --speed 15   # set <point> | clear
swift run simtool ui reduce-motion on             # reduce-transparency, button-shapes, voiceover
swift run simtool ui color-filter grayscale       # none, grayscale, protanopia, deuteranopia, tritanopia
swift run simtool ui liquid-glass tinted          # clear | tinted, iOS 26 and later
swift run simtool input rotate left               # right, portrait, landscape-left, landscape-right, upside-down
swift run simtool permissions --app com.example.MyApp            # every permission, as the device has it
swift run simtool permissions deny notifications --app com.example.MyApp   # grant | deny | reset | always (location)
swift run simtool keychain reset                  # add-cert <file> adds a certificate
swift run simtool app info --app com.example.MyApp --reveal data     # the card; --reveal bundle|data opens Finder
swift run simtool app install Build/MyApp.ipa     # an .app, an .ipa, or a tar of an .app
swift run simtool camera fixtures/code.png        # the camera shows an image; a .mov/.mp4 loops
swift run simtool camera webcam                   # the Mac's camera (--camera <name>); off; env
```

The colours are the guest render server's own debug options, which CoreSimulator
forwards (`-[SimDevice setCADebugOption:enabled:]`, by number); slow animations
is the darwin notification UIKit reads; a memory warning reaches every process as
memory pressure, which UIKit turns into `didReceiveMemoryWarning`. `match` and
`nomatch` answer a Face ID or Touch ID prompt the app already shows. simctl
cannot read a location back, so `simtool location` and the viewer show the one
SimTool last set. Naming any cellular field of the status bar makes simctl fill
in the rest — 5G, full bars, "Carrier" — so `clean` leaves them out.

The accessibility settings go through a helper SimTool builds and runs inside the
simulator, which calls the guest's own libAccessibility setters — the ones
Settings calls — so running apps follow at once; Liquid Glass is UIKit's
`UIViewGlassLegibilitySetting`. A rotation is the device-orientation event
Simulator.app sends; the picture is then read back from CoreDevice whenever the
guest says it turned, whoever turned it, so touches land where they point.
Permissions go through `simctl privacy` where it has them (camera and pasteboard
included), through the device's TCC database for Face ID, speech recognition and
tracking, and through SpringBoard's own record for notifications: SpringBoard
reads that only as it starts, so a notifications change resprings the simulator —
backboardd restarts and takes SpringBoard with it (restarting SpringBoard alone
would leave it unable to turn its interface until the simulator reboots).

Touches are played by SimTool's own HID helper as timed paths, in screen points
(the space `ax tree` reports frames in) — the same helper the viewer's live
finger uses:

```sh
swift run simtool input tap --label Continue
swift run simtool input long-press --id photo --duration 1.2
swift run simtool input scroll up --distance 300     # content moves 300 pt and stays
swift run simtool input fling up --speed fast        # lifted in motion, keeps going
swift run simtool input swipe --start-x 200 --start-y 700 --end-x 200 --end-y 300 --hold 0
swift run simtool input drag --start-x 200 --start-y 140 --end-x 200 --end-y 290
```

On an iPhone Duo every touch — the CLI's, the API's, a test's and the viewer's
live finger — lands on the panel that is lit, in points of its picture as a
screenshot and `ax tree --json`/`--flat` show it: the open inner panel reads
951 × 669 pt (landscape) although its framebuffer is portrait, and SimTool turns
each point onto it. The accessibility frames are put on that picture too: an app
built against an older SDK runs in a compatibility window — in the middle of the
open panel, at the cover's leading edge — and reports frames from the window's
corner, and SpringBoard reports its alerts on the panel upright; SimTool moves
both to where they show (the window's place is read off a screenshot once per
app process and panel), so a tap by id or label lands on the element. The viewer shows the lit panel upright, with its own corners, and
follows it as the device folds. The inner panel takes SimTool's own Indigo touches (target
`0x40000003`); the cover is touched through the simulator's HID daemon,
dtuhidd, as Device Hub does — while dtuhidd runs, SimulatorHID keeps the cover's
own touch screen stood down, and an Indigo event sent into it would abort
backboardd.

An iPhone Duo folds from the CLI, the API, a test and the bar under the device in the viewer:

```sh
swift run simtool input pose book      # closed | book | open | a hinge angle 0–180
swift run simtool input pose           # the fold now: open · 180°, inner panel lit
```

Closed (0°) lights the cover; book (130°) and open (180°) the inner panel. The
hinge is swept there as a hand would fold it — SpringBoard folds with
hysteresis, and a jump can leave the panel that was lit — by a helper SimTool
runs inside the simulator, which posts the hinge the way Device Hub's slider
does. A pose returns once the device reports it: the hinge as the guest's
motion service took it and the panel CoreDevice says is lit; one the device does
not take is an error naming what it reports instead. The fold is read back
continuously too — Device Hub's own slider included: `/config` and the event
stream's `device` topic carry it as `fold` (`hingeDegrees`, `pose`, SpringBoard's
`posture`, the lit `panel`), the viewer shows it beside the device's size, under
its Closed / Book / Open buttons, and the activity feed has a pose's result, or a
fold made elsewhere, as an entry. YAML tests take a `pose:` step.

YAML tests change the device's settings with steps too — `appearance: dark`,
`textSize: ax2`, `contrast: on`, `biometrics: match`, `push: { aps: { alert: "…" } }`
(to the test's app), `location: "37.33,-122.01"` (or a `route:`), `statusBar:
clean`, `permission: { camera: deny }`, `rotate: landscape-left` — where the
scenario needs them, so a Face ID prompt is answered after the tap that raised
it. A permission step that ends the app, as iOS does, relaunches it the way the
run launched it. `reset.permissions` pre-answers notifications, camera, Face ID,
speech and tracking too.

Directions are the way the finger moves: `scroll up` drags the content up,
revealing what is below. A `scroll` (and a `swipe`, unless `--hold 0`) slows
down and rests a quarter second before lifting, which leaves the content where
the finger stopped; a `fling` lifts in motion. A `drag` presses 0.8 s until the
item lifts, carries it at 300 pt/s and rests 0.5 s before dropping it — list
reordering and moving items. A `long-press` shorter than ~0.6 s warns that it may
land as a tap. `POST /api/v1/input` takes the same gestures (`scroll`, `fling`,
`drag`, and `swipe` with `velocity`/`hold`), and YAML tests have `scroll:`,
`fling:` and `drag:` steps.

A touch fails rather than answering `ok` when iOS has dropped the touch screen
for the current boot. iOS 26.4 and 27 do that when the simulator's HID daemon
(dtuhidd) starts before anything has touched the screen; the helper claims the
screen as it starts, so only a tool that reached the device before SimTool can
cause it. The error gives the command to reboot the simulator, which brings
touches back.

`input type` reaches only characters on a US keyboard. For anything else —
Cyrillic, accents, emoji, several lines — use `input paste`: it puts the text on
the simulator clipboard and presses ⌘V in the focused field.

```sh
swift run simtool input paste "Привет, señor 🎉" --json
printf 'line one\nline two' | swift run simtool input paste --stdin
swift run simtool input paste --image screenshot.png
```

Paste grants the foreground app "Paste from Other Apps" (`simctl privacy …
grant pasteboard`), so iOS does not ask "Allow Paste?" each time; iOS still
shows its "… pasted from …" banner for a few seconds, over the top of the
screen. It fails when no text field changed and no keyboard is up — tap a text
field first. `--image` pastes an image the same way (Xcode 27 or newer); only
fields that take images react — a text view with attributed editing, notes or
chat composers — while a plain text field ignores it. From Xcode 27 on, the
simulator clipboard belongs to CoreDevice and `simctl pbcopy` is silently
ignored; SimTool writes through `devicectl device pasteboard copy` and falls
back to `simctl pbcopy` (text only) on older Xcode.

In the browser viewer, ⌘V anywhere on the page outside its own fields pastes
the Mac clipboard — text, or an image when it holds no text — into the
simulator. Right-clicking the device screen opens a menu with the same
**Paste** (it asks the browser for clipboard access), **Add clipboard image to
Photos** and **Add files to Photos…** (images and videos) — both put the media
in the simulator's Photos library (`simctl addmedia`), where a photo picker
offers it — **Save** or **Copy screenshot** and **Record video**. While the Accessibility tab
picks elements, a right-click opens the element's menu instead.

The **Device** tab (⌥7) — its sections start folded and stay as you leave them —
is what Simulator.app kept in its menus and Device Hub dropped, as the device
reports it: the appearance, the text size (Dynamic Type)
and Increase Contrast; the render server's debug colours — Color Blended
Layers, Copied Images, Misaligned Images, Off-screen Rendered — and Slow
Animations, each a switch, with Simulate memory warning beside them; Face ID or
Touch ID (whichever the device has): enrolled or not, and a matching or
non-matching face or finger for the prompt on screen; status bar overrides (a
9:41 preset for screenshots, or time, battery and network one by one); the
simulated location — a point or a route — and a push notification with its JSON
payload. It also holds the accessibility settings Simulator.app reached through
Settings — Reduce Motion, Reduce Transparency, Button Shapes, VoiceOver, Color
Filters (apps read the filter; the simulator's screen shows none) and Liquid
Glass clear or tinted —, the orientation, the app under test's card (version
and build, minimum iOS, its process, its bundle and data container with
Reveal in Finder and Copy), each of its privacy permissions as a choice —
notifications too —, and the keychain: reset it (a proxy such as Proxyman
installs its own root certificate). Each change is an entry in Activity; the
tab reads the device again after it, every few seconds while it is open, and
whenever an agent or a test changes a setting. The command palette has them
too. The rotate button under the device turns it left (⌘←; ⌘→ turns it right), and the stream, touches,
accessibility frames and screenshots follow the turned picture. Files dropped
on the screen go where Simulator.app sent them: images and videos to Photos, an
`.app` bundle or an `.ipa` installed on the device.

**The camera.** The simulator has none, so SimTool gives one to the apps it
launches — `simtool app launch`, `simtool run`, the viewer's Launch and
Relaunch, test runs: it loads a small library of its own into the app
(`DYLD_INSERT_LIBRARIES`, built for the simulator on first use) that answers
AVFoundation's camera with a back and a front camera whose picture is an image,
a video played in a loop, or the Mac's webcam. Previews
(`AVCaptureVideoPreviewLayer`), video frames (`AVCaptureVideoDataOutput`, in
the pixel format the app asks for), photos (`AVCapturePhotoOutput`), QR and
barcode scanning (`AVCaptureMetadataOutput`, read with Vision) all see it.
`UIImagePickerController`'s camera is not live: its own camera screen runs a
capture pipeline SimTool does not reach (on the simulator its preview stays grey
and its shutter does nothing), so the picker answers its delegate with the
current picture, as if the photo were taken and Use Photo tapped — at once when
the app presents it, as soon as it shows when it comes inside a SwiftUI
`.sheet` or `.fullScreenCover`. An app that needs a live camera screen gets one
by building it on `AVCaptureSession`. A new picture reaches running
apps at once; an app launched while the camera was off gets it at its next
launch. The Device tab's Camera section takes an image or a video, or the
Mac's camera, and lists the apps that have it; the server runs the webcam
(macOS asks once, for the app that started simtool). An app run from Xcode
gets the camera with the variables `simtool camera env` prints, in its scheme's
environment.

The **Accessibility** tab shows the served accessibility tree, with anonymous
containers folded away, and picks elements on the screen: the picked element is
drawn with its distances to the screen edges and to the element under the
pointer, in points, next to rulers along the screen. Its details offer it as a
YAML step (`- tap: { id: About }`) and as a `simtool input tap` command.

**Annotate** in the toolbar (or `A`) turns the screen into a place to leave
notes for an agent: no click, scroll or key reaches the device while it is on.
Click an element — or drag a rectangle around something without accessibility —
write what should change, mark it **Change** or **Question**, and **Add** (⌘↵);
from the keyboard, the arrows walk the screen's elements, Enter annotates one
and R marks a region. Each note leaves a numbered pin, shown while its element is
still where it was, and the Accessibility tab's **Annotations** view lists them
to edit or delete. They stay in the browser for that simulator until cleared,
and **Copy all** puts them on the clipboard as one prompt:

```
SimTool annotations — 2 items · com.example.app · iPhone 17 Pro (iOS 26.4)

1. [Change] Button "Transfer" (id: home.transfer, frame 16,540 361×52)
   Make it the secondary style.
2. [Question] StaticText "Bienvenido" (frame 24,180 200×20)
   Where does this text come from — a localization key?
```
