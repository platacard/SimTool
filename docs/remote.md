# SimTool on a shared Mac

A Mac that runs other work — a CI runner in the office, a build machine — can
also keep a simulator for people elsewhere: `simtool serve` under launchd, a
simulator of its own, and the viewer opened from another Mac through an SSH
tunnel or a VPN. This page is the runbook: setting it up without disturbing
what already runs there, reaching it, what it costs the machine, restarting and
removing it.

## What it costs the machine

Measured on 2026-11-12 on a Mac mini (M2, 8 GB, macOS 26.4, Xcode 27.2) that
runs GitLab CI jobs, with an iPhone 17 Pro simulator on iOS 26.4, `top` over
10 s, CPU as a share of one core:

| State | `simtool` | Video encoder | Simulator | Memory free |
|---|---|---|---|---|
| Asleep — simulator off, nobody watching | 0.1 % · 14 MB | — | — | 75 % |
| Simulator on, nobody watching | 0.3 % · 11 MB | — | 3 % · ~2.6 GB | 51 % |
| A viewer dragging a list, ~40 fps | 7 % · 30 MB | 3 % | 42 % · ~2.5 GB | 53 % |

- **A booted simulator is mostly memory**: about 2 GB of an 8 GB Mac. On a
  machine that also builds, that is what to watch; the idle timeout (below)
  gives it back when nobody uses the device, and a slim simulator (below)
  keeps a fraction of it.
- **The first boot of a new simulator is expensive**: its media analysis took
  five cores for about a minute and a half (load average 48). Slim it before
  its first boot, and boot it once while the machine is idle.
- **A slim simulator** (`simtool device slim`, [automation](automation.md#a-slim-simulator))
  runs without widgets, Siri, Spotlight, iCloud, photo analysis and the rest
  of what an app under test does not need. Measured on a MacBook on
  2026-11-12 with the same device and runtime: about 85–97 processes and
  0.8–1.4 GB against 220–290 and 3.2–4.6 GB stock, and a reboot taking a third
  of the CPU (39 against 124 CPU-seconds in its first 90 s). Apps, touches,
  keys, the network and the app's keychain work as before.
- Nobody watching, the stream costs nothing: the encoder runs only while a
  viewer is connected.

## Set it up

Everything lives in one directory of the user that runs the simulators (the
user CI runs as is fine), and nothing global changes: no package manager, no
system settings, no firewall rule.

1. **The binary.** Put `simtool` in its own directory, say
   `~/simtool-remote/bin/` — a release archive, or a build of your own (`swift
   build --package-path Tool -c release --product simtool`). It needs the Xcode
   `xcode-select` points at, nothing else.
2. **A simulator of its own, with a name nothing else uses.** CI scripts find
   their devices by name (`iPhone 17`, `iPhone 16 Pro`…); a device they never
   ask for is never booted, erased or shared by them:

   ```sh
   xcrun simctl create "SimTool Remote" \
     com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
     com.apple.CoreSimulator.SimRuntime.iOS-26-4
   ```

   Slim it before its first boot — it then skips most of what a first boot
   does — and boot it once while the machine is idle (see above):

   ```sh
   ~/simtool-remote/bin/simtool device slim --device "SimTool Remote"
   ```

   It keeps push notifications, universal links, StoreKit, the photo picker,
   Contacts and Calendar on; `--keep <category>` leaves more on. A booted
   simulator is shut down and booted again to slim it. A job that runs
   `xcrun simctl shutdown all` still turns it off: the viewer then says the
   simulator is off and its **Start** boots it again (still slim).
3. **launchd.** A LaunchAgent of that user, so the server runs in the same
   session as the simulators, starts with it after a reboot, and comes back if
   it crashes — `~/Library/LaunchAgents/dev.simtool.remote.plist`:

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
     <key>Label</key><string>dev.simtool.remote</string>
     <key>ProgramArguments</key>
     <array>
       <string>/Users/user/simtool-remote/bin/simtool</string>
       <string>serve</string>
       <string>--device</string><string>UDID-OF-THE-SIMULATOR</string>
       <string>--port</string><string>3270</string>
       <string>--idle-timeout</string><string>15m</string>
     </array>
     <key>WorkingDirectory</key><string>/Users/user/simtool-remote</string>
     <key>EnvironmentVariables</key>
     <dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
     <key>RunAtLoad</key><true/>
     <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
     <key>ThrottleInterval</key><integer>60</integer>
     <key>LowPriorityIO</key><true/>
     <key>StandardOutPath</key><string>/Users/user/simtool-remote/logs/serve.log</string>
     <key>StandardErrorPath</key><string>/Users/user/simtool-remote/logs/serve.log</string>
   </dict>
   </plist>
   ```

   ```sh
   plutil -lint ~/Library/LaunchAgents/dev.simtool.remote.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.simtool.remote.plist
   launchctl print gui/$(id -u)/dev.simtool.remote | grep -E 'state|pid'
   ```

   `bootstrap` works over SSH too, as long as that user is logged in at the
   console — a CI Mac that logs its user in automatically is. The server
   listens on `127.0.0.1` only: nothing on the network reaches it until you
   choose how (next section). It boots the simulator when it starts, shuts it
   down after `--idle-timeout` without a viewer or a request, and boots it
   again when someone presses **Start** or a request needs it; a crash brings
   it back within a minute (`ThrottleInterval`), adopting the simulator that is
   still on.

## Reach it

**Through SSH** — nothing to install or open on the shared Mac, no
certificate: forward the port and open it on your own Mac.

```sh
ssh -N -L 3270:127.0.0.1:3270 user@shared-mac.example
# then open http://localhost:3270 in Chrome or Safari
```

`localhost` is a secure page for the browser, so the stream decodes as on the
shared Mac itself. Anyone with SSH access to that user can do the same.

**Over the network**, without SSH: start the server with `--network` (or
`server.network: true`) and give it a certificate your company's browsers
already trust for the Mac's DNS name — `server.tls.certificate` and
`server.tls.key` in the [project config](project-config.md);
otherwise every device installs SimTool's own authority first ([the viewer on
other devices](usage.md#the-viewer-on-other-devices)). The port then listens
on every interface: the macOS firewall has to allow `simtool` (each new build
asks again — on a machine nobody sits at, someone with admin rights adds it:
`sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add <path to simtool>
--unblockapp <path to simtool>`), and the network has to let the VPN reach that
port. SimTool asks for no password: anyone who reaches the port drives the
device and sees the app's traffic.

**Behind a web site of your own**, for people who should get a device
without SSH or a certificate to install: the site keeps its own sign-in,
domain and certificate, and reaches the server through an SSH key that can do
nothing but open the server's port — one line in that user's
`~/.ssh/authorized_keys`:

```text
restrict,port-forwarding,permitopen="127.0.0.1:3270",command="/usr/bin/false" ssh-ed25519 AAAA… my-site
```

The site proxies the viewer under a path of its own (see the
[HTTP API](http-api.md) on proxies) and installs the build someone picks with
`POST /api/v1/app/install` and a URL: the shared Mac downloads it itself, so a
build of gigabytes never passes through the site. Nothing on the shared Mac
listens beyond loopback, and no firewall rule changes.

## Over a slow or far link

A viewer away from the shared Mac — across a VPN, an ocean — gets a stream
paced to its link: the server learns from the page how much of the stream has
arrived, encodes the screen as it is whenever the link has room for a frame,
and sets the bitrate, frame rate and picture size the link carries (see
`/stream.avcc?sid=` in the [HTTP API](http-api.md)). The readout under the
device shows the bitrate while the link holds it below full quality
(`1.1 Mbit/s`; its tooltip has the picture's size and frame cap).

Measured on 2026-11-12 from a MacBook through an SSH tunnel to the Mac mini
above, over a corporate VPN with a 300–380 ms round trip whose throughput
swung between 0.6 and 9 Mbit/s and stalled for seconds at times, a finger
dragging the Settings list:

| | Before pacing | Paced |
|---|---|---|
| Frames while dragging | 12–34 fps for a few seconds, then 1–4 fps | 40–49 fps once the link carried 6 Mbit/s; 10–20 fps at about 1 Mbit/s; 7 (up to 22) at 0.5–0.6 |
| Input → screen (median, 8 drags) | 433 ms (15–740) | 212–219 ms (131–412), on the slowest link too |
| After the link stalled | backlog of seconds, keyframes asked for again and again | one bitrate cut; full rate again about 10 s after the link came back |

A far viewer starts at 1 Mbit/s and 960 px and climbs while nothing waits on
the way; the stream's latency stays near the link's round trip instead of
growing with a backlog.

## Restart, update, remove

```sh
# restart (and pick up a new binary put at bin/simtool)
launchctl kickstart -k gui/$(id -u)/dev.simtool.remote
tail -f ~/simtool-remote/logs/serve.log

# stop until the next login or reboot
launchctl bootout gui/$(id -u)/dev.simtool.remote

# remove everything
launchctl bootout gui/$(id -u)/dev.simtool.remote
rm ~/Library/LaunchAgents/dev.simtool.remote.plist
UDID=…   # the simulator's, from `xcrun simctl list devices`
xcrun simctl delete "$UDID"
rm -rf /private/var/tmp/com.apple.CoreSimulator.SimDevice.$UDID   # its slim list: delete leaves it
rm -rf ~/simtool-remote
rm -rf ~/Library/Caches/SimTool/builds   # builds fetched from a URL
# and the site's key, if one was added: its line in ~/.ssh/authorized_keys
```

To replace the binary while the server runs, copy the new one next to it and
move it over (`mv bin/simtool.new bin/simtool`) — the running process keeps
the old file — then `kickstart -k`.
