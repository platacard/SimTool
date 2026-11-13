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

### Several simulators

One server serves one simulator, so a Mac shared by several people at once
runs several: a simulator of its own each (`SimTool Remote`, `SimTool Remote
2`…, slimmed before their first boot), a LaunchAgent each (`dev.simtool.remote`,
`dev.simtool.remote.2`…) on a port each (3270, 3271…), all with `--asleep`
added to the arguments above. A restart of the Mac or of the agents then boots
nothing: each simulator boots when someone starts it and goes off again after
the idle timeout. Whoever hands them out — a person, a web page — decides who
gets which port.

Measured on 2026-11-12 on the same Mac mini (M2, 8 GB), slim iPhone 17 Pro
simulators on iOS 26.4, Settings open in each, the viewers far away over a VPN:

| | Memory free | Swap used | CPU idle | Each viewer, median fps |
|---|---|---|---|---|
| None on | 76–80 % | — | — | — |
| One on, its first boot (26 s, load 6) | 71 % | — | — | — |
| Four on, nobody watching | 42 % | 0.6 GB | — | — |
| Two watched, each dragging a list | — | — | — | 36–39 |
| Four watched, each dragging a list | 25 % | 0.9 GB | 60 % | 14–16 |

A site that hands them out can show each viewer inside its own page, the
browser talking to the simulator's server directly — the shortest way for the
stream: add `--network` and `--allow-origin https://site.example` to the
servers people should reach (see *A site in front of it* in
[usage](usage.md#the-viewer-on-other-devices)), allow `simtool` through the
firewall once per new binary (`sudo /usr/libexec/ApplicationFirewall/socketfilterfw
--add <path to simtool>` and `--unblockapp`), and give each tester SimTool's
certificate once (the plain-HTTP page on the server's port has it). When the
site's own servers can reach the shared Mac instead, it can proxy the viewer
under its own address with the SSH key described below.

Memory runs out before the CPU does: four simulators fit an 8 GB Mac with
nothing else to do, not beside a build. Two is the comfortable number on a Mac
that also runs CI; a Mac with 16 GB or more takes four. The viewer shows it as
it goes: the server's address in the status bar opens the Mac's memory and CPU
with every simulator booted on it — a CI job's too — read-only over the
network.

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

`permitopen` limits where the key's `-L` forwarding may connect, not what
else `port-forwarding` lets it do: it may still forward a remote port (`-R`) on
that user's loopback and reach Unix sockets that user can open. Where that
matters, turn them off for the whole Mac in `sshd_config`
(`AllowStreamLocalForwarding no`, `PermitListen none`) or give the site a user
of its own; and take the line out once the site no longer uses it.

The site proxies the viewer under a path of its own (see the
[HTTP API](http-api.md) on proxies) and installs the build someone picks with
`POST /api/v1/app/install` and a URL: the shared Mac downloads it itself, so a
build of gigabytes never passes through the site. Nothing on the shared Mac
listens beyond loopback, and no firewall rule changes.

## Over a slow or far link

Each viewer's stream is encoded at fixed settings — 60 fps, 6 Mbit/s and
1280 px unless the server was started with `--stream-fps`, `--stream-bitrate`
or `--stream-max-size`, or the viewer chose its own in the Device tab
(**Stream**). Neither the link nor what the screen shows lowers them. What
follows the link is only how many frames go: the server learns from the page
how much of the stream has arrived and encodes the screen as it is whenever
the link has room for a frame, so a link that carries the stream gets every
frame, and a slower one gets fewer, each of them fresh, never a backlog (see
`/stream.avcc?sid=` in the [HTTP API](http-api.md)). The readout under the
device then says **link full**; lighter settings in the Device tab bring the
frames back.

Measured on 2026-11-13 on a MacBook, the viewer in headless Chrome reaching
the server through a proxy that delays each way by 150 ms plus a swing of
0–120 ms over 3 s (a round trip of 300–540 ms, as on a corporate VPN), the
simulator showing an animation that changes every frame:

| | Viewer, median fps (min–max) | The stream |
|---|---|---|
| Before: the stream's settings followed the link | 3 (1–7) | 250–530 kbit/s, 720 px, at most 8 fps |
| Fixed settings, the link unlimited | 55 (51–59) | 60 fps, 6 Mbit/s, 1280 px; the server encodes 58 a second |
| Fixed settings, the link held to 2 Mbit/s | 13 (4–17), **link full** | 60 fps, 6 Mbit/s, 1280 px |
| The same link, the viewer's own 1 Mbit/s | 53 (48–59) | 60 fps, 1 Mbit/s, 1280 px |

On a steady 300 ms round trip both reached about 56 fps: it was the swing
that the old settings took for a slow link, cutting them to their floor.

## Restart, update, remove

```sh
# restart (and pick up a new binary put at bin/simtool)
launchctl kickstart -k gui/$(id -u)/dev.simtool.remote
tail -f ~/simtool-remote/logs/serve.log

# stop until the next login or reboot
launchctl bootout gui/$(id -u)/dev.simtool.remote

# remove everything (with several simulators: every dev.simtool.remote* agent and simulator)
launchctl bootout gui/$(id -u)/dev.simtool.remote
rm ~/Library/LaunchAgents/dev.simtool.remote.plist
UDID=…   # the simulator's, from `xcrun simctl list devices`
xcrun simctl delete "$UDID"
rm -rf /private/var/tmp/com.apple.CoreSimulator.SimDevice.$UDID   # its slim list: delete leaves it
rm -rf ~/simtool-remote
rm -rf ~/Library/Caches/SimTool/builds   # builds fetched from a URL, one folder per simulator
# and the site's key, if one was added: its line in ~/.ssh/authorized_keys
```

To replace the binary while the server runs, copy the new one next to it and
move it over (`mv bin/simtool.new bin/simtool`) — the running process keeps
the old file — then `kickstart -k`.
