// The device screen: H.264/AVCC over one long fetch, decoded with WebCodecs,
// painted on a canvas. The stream reconnects with backoff when the server goes
// away, and the page says what is happening instead of showing a frozen frame
// as "live". A simulator SimTool shut down is not a lost server: the page says
// it is off and offers to start it, and streams again once it is on.

const canvas = $("screenCanvas");
const canvasContext = canvas.getContext("2d", { alpha: false, desynchronized: true });
const maxCanvasDPR = 1.5;

const screenState = {
  width: 0,         // the picture's size in pixels (the stream's frame, turned as the screen reads)
  height: 0,
  points: null,     // screen size in points, once known (/config, else the AX root frame)
  display: null,    // the lit screen as /config describes it: id, rotation, points, cornerRadii
  fold: null,       // a foldable's fold as the device reports it: hingeDegrees, posture, panel, pose
  foldable: false,  // more than one screen: touches name the one shown
  rotation: 0,      // degrees the frame on the canvas is turned (the lit screen's, once frames match it)
  view3d: false,    // the stream is the folded device in 3D, not the lit screen
  view3dUnavailable: "",   // why the 3D preview cannot be shown, when it cannot
  projection: null, // where the lit panel lands on the 3D frame (Duo3DProjection)
  frameAspect: 0,   // the stage shape the 3D frames were asked for, width per unit of height
  connection: "connecting",  // connecting | live | reconnecting | offline | off | starting
  power: null,      // the simulator while it is not on: {state: off|starting, reason, title, detail}
  attempt: 0,
  retryAt: 0,
  changedAt: 0,     // performance.now() of the last frame that changed the picture
  shownAt: 0,       // performance.now() a frame that changed the picture was painted
  dataAt: 0,        // performance.now() of the last bytes of the stream
  stillBytes: Infinity,  // the smallest frame so far: what an unchanged screen costs
  stopped: null,    // why the server said it stopped ({title, detail}), until one answers again
  pace: null,       // the stream's settings and whether its link is full, as the server last said them
  streamDefaults: null   // the server's stream settings (/config), what a viewer gets unless it chose its own
};
const connectionListeners = [];
function onConnection(listener) { connectionListeners.push(listener); }

function setConnection(state, detail) {
  const changed = screenState.connection !== state;
  screenState.connection = state;
  app.dataset.conn = state;
  renderConnectionLabel();
  $("placeholder").hidden = state !== "connecting" || screenState.width > 0;
  if (detail) $("placeholder").textContent = detail;
  if (changed) for (const listener of connectionListeners) listener(state);
}

// A replay says Replay — and still says when the server is out of reach.
const CONNECTION_LABELS = { connecting: "Connecting…", live: "Live", reconnecting: "Reconnecting…", offline: "Offline", off: "Simulator off", starting: "Starting…" };
function renderConnectionLabel() {
  const link = CONNECTION_LABELS[screenState.connection];
  const label = app.dataset.mode === "replay" ? "Replay" + (screenState.connection === "live" ? "" : " · " + link) : link;
  $("connLabel").textContent = label;
  $("connLabel").parentElement.title = label;
  $("sbConn").textContent = label.replace(/…/g, "");
}

// ---- AVCC envelopes ----

// 5: the frame after it shows the screen as it was (the server's idle refresh).
const avccTags = { 1: "description", 2: "keyframe", 3: "delta", 4: "projection", 5: "repeat" };
class Demuxer {
  constructor() { this.buffer = new Uint8Array(0); }
  push(bytes) {
    const merged = new Uint8Array(this.buffer.length + bytes.length);
    merged.set(this.buffer);
    merged.set(bytes, this.buffer.length);
    this.buffer = merged;
    const chunks = [];
    let offset = 0;
    while (this.buffer.length - offset >= 4) {
      const length = new DataView(this.buffer.buffer, this.buffer.byteOffset + offset, 4).getUint32(0, false);
      if (length < 1) { offset += 4; continue; }
      if (this.buffer.length - offset - 4 < length) break;
      const type = avccTags[this.buffer[offset + 4]];
      if (type) chunks.push({ type, payload: this.buffer.slice(offset + 5, offset + 4 + length) });
      offset += 4 + length;
    }
    if (offset > 0) this.buffer = this.buffer.slice(offset);
    return chunks;
  }
}

function avcCodecString(description) {
  if (description.length < 4) return "avc1.42E01E";
  const hex = (byte) => byte.toString(16).padStart(2, "0");
  return "avc1." + hex(description[1]) + hex(description[2]) + hex(description[3]);
}

// ---- Painting ----

let frameTimes = [];
let backing = { width: 0, height: 0 };

function updateBacking() {
  const rect = canvas.getBoundingClientRect();
  if (!rect.width || !screenState.width) return;
  const dpr = Math.min(window.devicePixelRatio || 1, maxCanvasDPR);
  backing = {
    width: Math.max(1, Math.min(screenState.width, Math.round(rect.width * dpr))),
    height: Math.max(1, Math.min(screenState.height, Math.round(rect.height * dpr)))
  };
}

function paint(frame) {
  // The stream carries the lit screen's framebuffer; a picture turned on it
  // (the open inner panel of an iPhone Duo) is turned back upright here.
  const rotation = screenState.view3d ? 0 : frameRotation(frame.displayWidth, frame.displayHeight, screenState.display);
  const quarter = rotation % 180 !== 0;
  const width = quarter ? frame.displayHeight : frame.displayWidth, height = quarter ? frame.displayWidth : frame.displayHeight;
  if (width !== screenState.width || height !== screenState.height || rotation !== screenState.rotation) {
    screenState.width = width;
    screenState.height = height;
    screenState.rotation = rotation;
    $("placeholder").hidden = true;
    fitDevice();
    updateBacking();
  }
  if (!backing.width) updateBacking();
  if (canvas.width !== backing.width || canvas.height !== backing.height) {
    canvas.width = backing.width;
    canvas.height = backing.height;
  }
  if (rotation === 0) {
    canvasContext.drawImage(frame, 0, 0, backing.width, backing.height);
  } else {
    const turn = canvasTurn(rotation, backing.width, backing.height);
    canvasContext.setTransform(turn.a, turn.b, turn.c, turn.d, turn.e, turn.f);
    canvasContext.drawImage(frame, 0, 0, turn.width, turn.height);
    canvasContext.setTransform(1, 0, 0, 1, 0, 0);
  }
}

// `changes`: the frame shows something new — the readout counts those; a
// still screen's refreshes are painted (sharper) but not counted.
function makeFramePainter() {
  let pending = null;
  let pendingChanges = false;
  let scheduled = false;
  function draw() {
    scheduled = false;
    const frame = pending, changes = pendingChanges;
    pending = null;
    pendingChanges = false;
    if (!frame) return;
    try { paint(frame); } finally { frame.close(); }
    if (changes) {
      screenState.shownAt = performance.now();
      frameTimes.push(screenState.shownAt);
    }
  }
  return {
    drawDecoded(frame, changes) {
      if (pending) pending.close();
      pending = frame;
      pendingChanges = pendingChanges || changes;
      if (!scheduled) { scheduled = true; requestAnimationFrame(draw); }
    }
  };
}

// fps as measured: frames painted in the last second that changed the screen.
// A still screen — refreshed by the server five times a second, each refresh
// marked as such — reads "idle", not a made-up number.
setInterval(() => {
  const now = performance.now();
  frameTimes = frameTimes.filter((time) => now - time < 1000);
  const text = screenState.connection !== "live" ? "— fps" : frameTimes.length ? frameTimes.length + " fps" : "idle";
  $("readFps").textContent = text;
}, 500);

// ---- The stream's settings ----
// What this viewer asks the server to encode its stream at — the frame rate,
// the bitrate, the picture's longest side — each left to the server unless
// chosen in the Device tab (Stream); kept in this browser. The settings hold
// for the stream's life: changing one starts a new stream.

const streamChoice = stored("stream.settings", {});   // { fps, kbps, px }, each optional

function streamSettingsQuery() {
  let query = "";
  for (const key of ["fps", "kbps", "px"]) {
    if (Number.isFinite(streamChoice[key])) query += "&" + key + "=" + streamChoice[key];
  }
  return query;
}

function chooseStreamSetting(key, value) {
  if (value == null) delete streamChoice[key]; else streamChoice[key] = value;
  store("stream.settings", streamChoice);
  restartStream();
}

function bitrateText(kbps) {
  return kbps >= 1000 ? (kbps / 1000).toFixed(kbps % 1000 ? 1 : 0) + " Mbit/s" : kbps + " kbit/s";
}

// ---- The stream's pace ----
// The server encodes the stream at its settings the whole time and paces its
// frames to this page's link: it encodes the screen as it is whenever the
// link has room, and learns that room from what the page says it received —
// on the live input socket, at most every 20 ms, the last count never held
// back (otherwise frames would wait for a word that never comes).

const receipt = { sid: null, total: 0, sentAt: -Infinity, timer: null };

function newStreamId() {
  if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
  return Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2) + Date.now().toString(36);
}

function noteReceived(sid, bytes) {
  if (receipt.sid !== sid) { receipt.sid = sid; receipt.total = 0; showPace(null); }
  receipt.total += bytes;
  // Said at once when the last count is old enough — a hidden tab's timers
  // fire once a second at best, so a timer still pending then is overtaken —
  // else once it is.
  const wait = receipt.sentAt + 20 - performance.now();
  if (wait <= 0) {
    clearTimeout(receipt.timer);
    sendReceipt();
  } else if (!receipt.timer) {
    receipt.timer = setTimeout(sendReceipt, wait);
  }
}

function sendReceipt() {
  receipt.timer = null;
  if (!receipt.sid) return;
  receipt.sentAt = performance.now();
  touchStream.report({ t: "got", s: receipt.sid, b: receipt.total });
}

// The socket came back: the server hears where the stream is at once.
function resendReceipt() { if (receipt.sid && !receipt.timer) sendReceipt(); }

// Shown while the link is full — frames held back because it still carried
// earlier ones — or while this viewer streams at settings of its own.
function showPace(pace) {
  if (pace && pace.s !== receipt.sid) return;
  screenState.pace = pace;
  const node = $("readPace");
  const defaults = screenState.streamDefaults;
  const own = !!(pace && defaults && (pace.fps !== defaults.fps || pace.kbps * 1000 !== defaults.bitrate || pace.px !== defaults.maxDimension));
  const shown = !!(pace && (pace.held || own) && screenState.connection === "live");
  node.hidden = !shown;
  node.classList.toggle("read-warn", !!(pace && pace.held));
  if (!shown) return;
  const settings = pace.fps + " fps · " + bitrateText(pace.kbps) + " · " + pace.px + " px";
  node.textContent = pace.held ? "link full" : settings;
  node.title = pace.held
    ? "This connection carries less than the stream is set to (" + settings + "): frames are skipped, each one shown fresh. Lighter settings: the Device tab, Stream."
    : "This viewer's own stream settings (the Device tab, Stream): " + settings;
}
onConnection(() => showPace(screenState.pace));

// A live screen gets something at least five times a second — a still one
// its refreshes. Silence for longer is a connection that stopped moving (a
// socket left half-open by a sleeping Mac, a stalled proxy): ask again.
const STREAM_SILENCE_MS = 5000;
setInterval(() => {
  if (screenState.connection !== "live" || screenState.view3d || document.hidden) return;
  if (performance.now() - (screenState.dataAt || 0) < STREAM_SILENCE_MS) return;
  setMessage("The video stream went silent — reconnecting", "err");
  restartStream();
}, 1000);

// ---- Connection loop ----

let streamAbort = null;
let retryTimer = null;
let streamGeneration = 0;   // a newer run makes an older one's errors irrelevant
const reconnectListeners = [];
function onReconnect(listener) { reconnectListeners.push(listener); }

async function runStream() {
  if (typeof VideoDecoder === "undefined") {
    setConnection("offline", "This browser cannot decode the stream (WebCodecs VideoDecoder is unavailable). Use a current Chrome or Safari.");
    $("veilTitle").textContent = "This browser cannot show the stream";
    $("veilText").textContent = "WebCodecs VideoDecoder is unavailable — open the viewer in a current Chrome or Safari.";
    $("reconnectNow").hidden = true;
    return;
  }
  clearTimeout(retryTimer);
  const generation = ++streamGeneration;
  streamAbort = new AbortController();
  const wasReconnecting = screenState.attempt > 0;
  // While the simulator is off, the recheck asks quietly: the veil and the
  // greyed last frame stay until the answer says otherwise — no blink.
  if (!wasReconnecting && !screenState.power) setConnection("connecting");
  let decoder = null;
  try {
    const controller = streamAbort;
    const view3d = screenState.view3d;
    // The screen at this viewer's settings, paced to its link (`?sid=…`, with
    // `fps`, `kbps`, `px` when chosen), or the folded device in 3D (`?view=3d…`).
    const sid = view3d ? null : newStreamId();
    const response = await fetch("stream.avcc" + (view3d ? streamQuery3D() : "?sid=" + sid + streamSettingsQuery()), { signal: controller.signal, cache: "no-store" });
    // No 3D to show (no model, the renderer failed): the flat screen, and why.
    if (view3d && response.status === 503) {
      let reason = "the 3D preview is unavailable";
      try { reason = (await response.json()).error || reason; } catch (_) {}
      leave3D(reason);
      return;
    }
    // The simulator is off: the server says so, and the page waits for it.
    if (response.status === 409) {
      let refusal = null;
      try { refusal = await response.json(); } catch (_) {}
      if (generation !== streamGeneration) return;   // a newer stream knows better
      if (refusal && refusal.power) { applyPower(refusal.power); return; }
    }
    if (!response.ok || !response.body) throw new Error("the server answered " + response.status);
    const demuxer = new Demuxer();
    screenState.stillBytes = Infinity;
    const painter = makeFramePainter();
    let timestamp = 0;
    // Which decoded frames changed the screen, by timestamp; the server marks
    // the ones that do not (an older one never does: the size guess stands in).
    const changing = new Map();
    let marked = false, nextRepeats = false;
    decoder = new VideoDecoder({
      output(frame) {
        const changes = changing.get(frame.timestamp) !== false;
        changing.delete(frame.timestamp);
        painter.drawDecoded(frame, changes);
      },
      error(error) { setMessage("Video decoder error: " + error.message + " — reconnecting", "err"); controller.abort(); }
    });
    const reader = response.body.getReader();
    screenState.dataAt = performance.now();
    screenState.attempt = 0;
    screenState.stopped = null;
    screenState.power = null;
    showVeilAction("reconnect");
    setConnection("live");
    if (wasReconnecting) for (const listener of reconnectListeners) listener();
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      if (!value) continue;
      screenState.dataAt = performance.now();
      if (sid) noteReceived(sid, value.byteLength);
      for (const chunk of demuxer.push(value)) {
        if (chunk.type === "repeat") {
          marked = true;
          nextRepeats = true;
        } else if (chunk.type === "projection") {
          try { screenState.projection = JSON.parse(new TextDecoder().decode(chunk.payload)); } catch (_) {}
        } else if (chunk.type === "description") {
          if (decoder.state === "closed") throw new Error("the decoder closed");
          decoder.configure({ codec: avcCodecString(chunk.payload), description: chunk.payload, optimizeForLatency: true, hardwareAcceleration: "prefer-hardware" });
        } else if (decoder.state === "configured") {
          screenState.stillBytes = Math.min(screenState.stillBytes, chunk.payload.byteLength);
          const changes = marked ? !nextRepeats : frameChangesScreen(chunk.type, chunk.payload.byteLength, screenState.stillBytes);
          nextRepeats = false;
          if (changes) screenState.changedAt = performance.now();
          try {
            decoder.decode(new EncodedVideoChunk({ type: chunk.type === "keyframe" ? "key" : "delta", timestamp, data: chunk.payload }));
            changing.set(timestamp, changes);
            if (changing.size > 120) changing.delete(changing.keys().next().value);
            timestamp += 16667;
          } catch (_) {}
        } else {
          nextRepeats = false;
        }
      }
    }
    throw new Error("the stream ended");
  } catch (error) {
    if (decoder && decoder.state !== "closed") { try { decoder.close(); } catch (_) {} }
    if (generation === streamGeneration) scheduleReconnect(error);
  }
}

function scheduleReconnect(error) {
  showVeilAction("reconnect");
  screenState.attempt += 1;
  const delay = Math.min(5000, 500 * Math.pow(2, screenState.attempt - 1));
  screenState.retryAt = performance.now() + delay;
  setConnection(screenState.attempt > 6 ? "offline" : "reconnecting");
  $("veilTitle").textContent = screenState.stopped ? screenState.stopped.title
    : screenState.attempt > 6 ? "simtool is not answering" : "Connection to simtool lost";
  updateVeilCountdown();
  if (error && screenState.attempt === 1) setMessage("Video stream lost (" + error.message + ") — reconnecting", "err");
  retryTimer = setTimeout(runStream, delay);
}

function updateVeilCountdown() {
  if (screenState.connection !== "reconnecting" && screenState.connection !== "offline") return;
  const seconds = Math.max(0, Math.ceil((screenState.retryAt - performance.now()) / 1000));
  const retrying = "retrying in " + seconds + " s (attempt " + screenState.attempt + ")";
  $("veilText").textContent = screenState.stopped ? screenState.stopped.detail + " · " + retrying : "Showing the last frame · " + retrying;
}

// The server is about to stop and says why, so the veil can say that instead
// of only that the connection went — or its simulator went off, is starting,
// or is on again.
function applyServerTopic(payload) {
  if (payload && payload.power) { applyPower(payload.power); return; }
  if (!payload || !payload.stopping) return;
  screenState.stopped = { title: payload.title, detail: payload.detail };
}

// ---- The simulator off ----
// SimTool shuts down a simulator nobody used for its idle timeout; the server
// stays. The page says so on the last frame and offers Start; once the
// simulator is on — started here, by a command, by anyone — it streams again.

// In case the word that it is on never came — or a stale "starting" outran it.
const POWER_RECHECK_MS = { off: 15000, starting: 5000 };

function applyPower(power) {
  if (!power || !power.state) return;
  const was = screenState.power;
  if (power.state === "on") {
    if (!was) return;
    screenState.power = null;
    // A reconnect: the lists and the log capture start over as after a lost server.
    screenState.attempt = Math.max(1, screenState.attempt);
    restartStream();
    return;
  }
  screenState.power = power;
  clearTimeout(retryTimer);
  // The stream that ends as it goes off is not a lost connection.
  streamGeneration += 1;
  if (streamAbort) streamAbort.abort();
  setConnection(power.state);
  const starting = power.state === "starting";
  $("veilIcon").setAttribute("href", starting ? "#i-relaunch" : "#i-moon");
  $("veilTitle").textContent = power.title || (starting ? "Starting the simulator…" : "The simulator is off");
  $("veilText").textContent = power.detail || "";
  showVeilAction(starting ? "starting" : "start");
  retryTimer = setTimeout(runStream, POWER_RECHECK_MS[power.state] || POWER_RECHECK_MS.off);
}

// The veil's one button: Reconnect for a lost server, Start for a simulator that is off.
function showVeilAction(action) {
  $("reconnectNow").hidden = action !== "reconnect";
  $("startDevice").hidden = action === "reconnect";
  $("startDevice").disabled = action === "starting";
  $("startDevice").textContent = action === "starting" ? "Starting…" : "Start simulator";
  if (action === "reconnect") $("veilIcon").setAttribute("href", "#i-offline");
}

async function startDevice() {
  const name = deviceInfo.name || "the simulator";
  applyPower({ state: "starting", title: "Starting " + name + "…", detail: "Booting the simulator — this takes up to a minute." });
  try {
    applyPower(await apiJSON("api/v1/device/wake", { method: "POST" }));
  } catch (error) {
    // The server says why it stays off; a lost server is the stream's to report.
    if (screenState.power) applyPower({ state: "off", reason: "failed", title: name + " did not start", detail: error.message });
  }
}
$("startDevice").addEventListener("click", startDevice);
setInterval(updateVeilCountdown, 500);

function restartStream() {
  clearTimeout(retryTimer);
  if (streamAbort) streamAbort.abort();
  runStream();
}

$("reconnectNow").addEventListener("click", restartStream);

// The page went to sleep with the tab hidden for long: a stale socket can sit
// half-open. Coming back, make sure the stream is still flowing.
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && screenState.connection !== "live" && screenState.connection !== "connecting") restartStream();
});

// ---- Fitting the device into the stage ----

function fitDevice() {
  const area = $("deviceArea").getBoundingClientRect();
  const aspect = screenState.width && screenState.height ? screenState.width / screenState.height : 402 / 874;
  // The 3D frame is drawn at the stage's shape with its own margin: it takes
  // the whole stage. The screen leaves room for the rulers — on a phone,
  // which shows no rulers, room for nothing but the corners.
  const inset = screenState.view3d ? { x: 0, y: 0 } : app.classList.contains("compact") ? { x: 8, y: 8 } : { x: 64, y: 48 };
  const maxW = Math.max(120, area.width - inset.x), maxH = Math.max(160, area.height - inset.y);
  let height = maxH, width = height * aspect;
  if (width > maxW) { width = maxW; height = width / aspect; }
  const device = $("device");
  device.style.setProperty("--dev-w", Math.floor(width) + "px");
  device.style.setProperty("--dev-h", Math.floor(height) + "px");
  // The screen's own corner radii from its device type, in proportion — the
  // Duo's cover is tight on the hinge side; else ~55 pt on a 402 pt wide phone.
  device.style.setProperty("--dev-radius", screenState.view3d ? "0px" : screenRadius(screenState.display, width) || Math.round(width * 0.137) + "px");
  updateBacking();
  updateReadoutSize();
  if (typeof drawRulers === "function") drawRulers();
}

function updateReadoutSize() {
  const points = screenState.points;
  if (points) $("readSize").textContent = Math.round(points.width) + " × " + Math.round(points.height) + " pt";
  else if (screenState.width) $("readSize").textContent = screenState.width + " × " + screenState.height + " px";
}

new ResizeObserver(() => { fitDevice(); reframe3D(); }).observe($("deviceArea"));

// ---- The 3D preview ----
// A foldable can be shown as the folded device in 3D, rendered on the server
// from the device model in the user's Xcode, its lit panel live on it. The
// frame is drawn on the stage's own colour, in the page's theme.

function stageAspect() {
  const area = $("deviceArea").getBoundingClientRect();
  return area.width > 0 && area.height > 0 ? area.width / area.height : 1;
}

function streamQuery3D() {
  const stage = getComputedStyle($("stage")).backgroundColor;
  screenState.frameAspect = stageAspect();
  return "?view=3d&theme=" + shownTheme() + "&bg=" + cssColorHex(stage) + "&aspect=" + screenState.frameAspect.toFixed(3);
}

// A stage that changed shape for good — the window or the inspector resized,
// and stayed so for a moment — asks for frames of its new shape.
let reframeTimer = 0;
function reframe3D() {
  clearTimeout(reframeTimer);
  if (!screenState.view3d || !stageReframes(screenState.frameAspect, stageAspect())) return;
  reframeTimer = setTimeout(() => {
    if (screenState.view3d && stageReframes(screenState.frameAspect, stageAspect())) restartStream();
  }, 500);
}

function setView3D(on) {
  if (on && (!screenState.foldable || screenState.view3dUnavailable)) return;
  if (screenState.view3d === on) return;
  screenState.view3d = on;
  screenState.projection = null;
  app.dataset.view = on ? "3d" : "screen";
  store("view3d", on ? "1" : "0");
  if (typeof renderFold === "function") renderFold();
  restartStream();
}

// The 3D stream refused or ended for good: back to the flat screen, saying why.
function leave3D(reason) {
  screenState.view3dUnavailable = reason;
  screenState.view3d = false;
  screenState.projection = null;
  app.dataset.view = "screen";
  if (typeof renderFold === "function") renderFold();
  toast("3D preview unavailable — " + reason, { error: true });
  restartStream();
}

// A theme switch redraws the 3D frame on the new stage colour.
function restyle3D() {
  if (screenState.view3d) restartStream();
}

// The device's screens from /config or the event stream's `device` topic: the
// lit one sets the points, the corners and how its frames turn.
// A server that names no screens (an older one, or a device whose type could
// not be read) is a phone with one: no fold to show.
function applyDisplays(displays, activeDisplay) {
  const list = Array.isArray(displays) ? displays : [];
  const lit = list.find((display) => display.id === activeDisplay) || list.find((display) => display.active) || list[0] || null;
  screenState.foldable = list.length > 1;
  screenState.display = lit;
  if (lit && lit.points && lit.points.width && lit.points.height) screenState.points = { x: 0, y: 0, width: lit.points.width, height: lit.points.height };
  touchStream.setDisplay(screenState.foldable ? lit.id : null);
  // The page was left on a foldable in 3D and the server now runs a phone.
  if (!screenState.foldable && screenState.view3d) {
    screenState.view3d = false;
    screenState.projection = null;
    app.dataset.view = "screen";
    restartStream();
  }
  fitDevice();
  updateReadoutSize();
  if (typeof renderFold === "function") renderFold();
}

// Pointer position in points (or pixels until the point size is known).
function pointerReadout(clientX, clientY) {
  const rect = canvas.getBoundingClientRect();
  let fx = (clientX - rect.left) / rect.width, fy = (clientY - rect.top) / rect.height;
  if (fx < 0 || fy < 0 || fx > 1 || fy > 1) return "";
  // On the 3D device: the point of the lit panel under the pointer, if any.
  if (screenState.view3d) {
    const fingers = deviceFingers({ x: fx, y: fy });
    if (!fingers) return "";
    fx = fingers.first.x;
    fy = fingers.first.y;
  }
  if (screenState.points) return "x " + Math.round(fx * screenState.points.width) + "  y " + Math.round(fy * screenState.points.height) + " pt";
  if (screenState.width) return "x " + Math.round(fx * screenState.width) + "  y " + Math.round(fy * screenState.height) + " px";
  return "";
}
