// Viewers on other devices — an iPhone, an iPad, another Mac on the same
// Wi-Fi, through the network door (HTTPS) — and the
// Mac's own viewer showing them the way in:
// - a phone-sized window shows the device alone; the inspector is a tap away;
// - the phone's own on-screen keyboard types into the simulator;
// - one finger at a time reaches the device, and a touch that did not is said so;
// - over the network, the round trip to the server reads under the device;
// - Network in the status bar: the addresses, a QR code to scan and SimTool's
//   certificate;
// - the palette measures input → screen latency.

const remote = {
  network: null,       // /config's `network`: urls, certificate, certificateFingerprint
  overNetwork: location.protocol === "https:",
  roundTrips: [],      // the last round trips, ms
  busySaidAt: 0,
  probing: false,
  lastLatency: null    // the last measurement: {median, min, max, samples, roundTrip}
};

// ---- A phone-sized window ----

const COMPACT_BELOW = 600;

function compactWanted() {
  const coarse = window.matchMedia && window.matchMedia("(pointer: coarse)").matches;
  return window.innerWidth < COMPACT_BELOW || (coarse && Math.min(window.innerWidth, window.innerHeight) < COMPACT_BELOW);
}

// The inspector's open or closed is remembered apart for a phone-sized
// window, where it starts closed (`inspectorStateKey`).
function layoutCompact() {
  const compact = compactWanted();
  if (app.classList.contains("compact") !== compact) {
    app.classList.toggle("compact", compact);
    setInspectorOpen(stored(inspectorStateKey(), !compact));
    fitDevice();
  }
  // The on-screen keyboard shrinks what is visible, not the layout: the page
  // follows what is visible, so the device stays in view above the keyboard.
  app.style.height = compact && window.visualViewport ? Math.round(window.visualViewport.height) + "px" : "";
}
window.addEventListener("resize", layoutCompact);
if (window.visualViewport) window.visualViewport.addEventListener("resize", layoutCompact);
// A window that took its size after the page loaded sends no resize.
new ResizeObserver(layoutCompact).observe(document.documentElement);
// A phone opens on the device alone; the inspector toggle brings the rest.
if (compactWanted()) {
  app.classList.add("compact");
  inspector.open = stored(inspectorStateKey(), false);
}
layoutCompact();

// ---- Another viewer's finger ----

function anotherViewerTouching() {
  const at = Date.now();
  if (at - remote.busySaidAt < 3000) return;
  remote.busySaidAt = at;
  toast("Someone else is touching the device — your touch goes through once they lift their finger", { error: true });
}

// ---- The round trip, over the network ----

function noteRoundTrip(ms) {
  remote.roundTrips.push(ms);
  if (remote.roundTrips.length > 10) remote.roundTrips.shift();
  renderRoundTrip();
}

function median(values) {
  const sorted = values.slice().sort((a, b) => a - b);
  return sorted.length ? sorted[Math.floor(sorted.length / 2)] : 0;
}

function renderRoundTrip() {
  const node = $("readRtt");
  const shown = remote.overNetwork && remote.roundTrips.length > 0 && screenState.connection === "live";
  node.hidden = !shown;
  if (shown) node.textContent = "rtt " + Math.round(median(remote.roundTrips)) + " ms";
}
setInterval(() => {
  if (remote.overNetwork && screenState.connection === "live" && !document.hidden) touchStream.ping();
}, 2000);
onConnection(renderRoundTrip);

// ---- The phone's own keyboard ----
// A hidden field takes the on-screen keyboard's text, and each character goes
// to the device as the key a US keyboard types it with (Shift when it needs
// it); what has no such key is pasted. The field stays empty but for one
// character, so Backspace always has something to delete.

const SOFT_TYPING_REST = "​";
const usKeys = (() => {
  const keys = {};
  for (const letter of "abcdefghijklmnopqrstuvwxyz") {
    keys[letter] = ["Key" + letter.toUpperCase(), false];
    keys[letter.toUpperCase()] = ["Key" + letter.toUpperCase(), true];
  }
  for (const digit of "0123456789") keys[digit] = ["Digit" + digit, false];
  [...")!@#$%^&*("].forEach((character, digit) => { keys[character] = ["Digit" + digit, true]; });
  const pairs = [["Minus", "-", "_"], ["Equal", "=", "+"], ["BracketLeft", "[", "{"], ["BracketRight", "]", "}"], ["Backslash", "\\", "|"],
    ["Semicolon", ";", ":"], ["Quote", "'", "\""], ["Comma", ",", "<"], ["Period", ".", ">"], ["Slash", "/", "?"], ["Backquote", "`", "~"]];
  for (const [code, plain, shifted] of pairs) { keys[plain] = [code, false]; keys[shifted] = [code, true]; }
  // What the phone's smart punctuation turns quotes into.
  keys["’"] = keys["‘"] = ["Quote", false];
  keys["“"] = keys["”"] = ["Quote", true];
  keys[" "] = ["Space", false];
  keys["\n"] = ["Enter", false];
  return keys;
})();

const softTyping = el("textarea", {
  class: "soft-typing", rows: "1", "aria-label": "Type into the simulator",
  autocomplete: "off", autocorrect: "off", autocapitalize: "none", spellcheck: "false"
});
document.body.append(softTyping);
let softComposing = false;

const touchScreen = () => (navigator.maxTouchPoints || 0) > 0 || (window.matchMedia && window.matchMedia("(pointer: coarse)").matches);

function pressOnDevice(code, shift, character) {
  if (shift) touchStream.key({ t: "keydown", code: "ShiftLeft" });
  touchStream.key(character ? { t: "keydown", code, k: character } : { t: "keydown", code });
  touchStream.key({ t: "keyup", code });
  if (shift) touchStream.key({ t: "keyup", code: "ShiftLeft" });
}

// Text goes out in the order it was typed: keys after a paste wait for it.
let softTypingQueue = Promise.resolve();

function typeOnDevice(text) {
  if (!text || !manualInputAllowed()) return;
  const runs = [];
  for (const character of text) {
    const key = usKeys[character];
    const last = runs[runs.length - 1];
    if (!key) {
      if (last && last.paste != null) last.paste += character;
      else runs.push({ paste: character });
    } else {
      runs.push({ key, character });
    }
  }
  softTypingQueue = softTypingQueue.then(async () => {
    for (const run of runs) {
      if (run.paste != null) {
        try { await postInput({ action: "paste", text: run.paste }); } catch (error) { fail("Typing failed", error); }
      } else {
        pressOnDevice(run.key[0], run.key[1], run.character.length === 1 ? run.character : null);
      }
    }
  });
}

// Whether the phone's typing connected the keyboard itself — and so lets it go.
let softTypingConnected = false;

function restSoftTyping() {
  softTyping.value = SOFT_TYPING_REST;
  try { softTyping.setSelectionRange(1, 1); } catch (_) {}
}

// From a tap: only a tap may bring the on-screen keyboard up.
function startSoftTyping() {
  restSoftTyping();
  softTyping.focus();
  app.classList.add("soft-typing-on");
  // The device's own keyboard steps aside while the phone's types, as with a Mac keyboard.
  if (!keyboardBridge.enabled) {
    softTypingConnected = true;
    setKeyboardMode(true);
  }
}

softTyping.addEventListener("blur", () => {
  app.classList.remove("soft-typing-on");
  if (softTypingConnected && keyboardBridge.enabled) setKeyboardMode(false);
  softTypingConnected = false;
});
softTyping.addEventListener("beforeinput", (event) => {
  const type = event.inputType || "";
  if (softComposing || type === "insertCompositionText") return;
  if (type === "insertText" || type === "insertReplacementText") {
    typeOnDevice(event.data || (event.dataTransfer && event.dataTransfer.getData("text/plain")) || "");
  } else if (type === "insertLineBreak" || type === "insertParagraph") {
    if (manualInputAllowed()) pressOnDevice("Enter", false);
  } else if (type.startsWith("delete") && type.endsWith("Backward")) {
    if (manualInputAllowed()) pressOnDevice("Backspace", false);
  } else if (type === "insertFromPaste") {
    typeOnDevice(event.dataTransfer ? event.dataTransfer.getData("text/plain") : "");
  } else {
    return;
  }
  event.preventDefault();
});
softTyping.addEventListener("compositionstart", () => { softComposing = true; });
softTyping.addEventListener("compositionend", (event) => {
  softComposing = false;
  typeOnDevice(event.data || "");
  restSoftTyping();
});
// Whatever got past the handlers above (a keyboard that does not say what it inserts) is reset.
softTyping.addEventListener("input", () => { if (!softComposing) restSoftTyping(); });

// ---- Network: how other devices open this server ----

function applyNetwork(network) {
  remote.network = network || null;
  const button = $("sbNetwork");
  button.hidden = !remote.network && !remote.overNetwork;
  button.textContent = remote.overNetwork ? "Over the network" : "Network";
  button.dataset.tip = remote.overNetwork
    ? "This viewer reaches SimTool over the network — addresses, QR code"
    : "Open this simulator on another device — addresses, QR code";
}

function openNetworkDialog() {
  const network = remote.network;
  if (!network) return;
  $("networkQr").src = "api/v1/network/qr.png?at=" + Date.now();
  const list = $("networkUrls");
  list.textContent = "";
  for (const url of network.urls) {
    const row = el("div", { class: "network-url" });
    row.append(el("code", { class: "mono" }, url));
    const copy = el("button", { class: "btn btn-sm", type: "button" }, "Copy");
    copy.addEventListener("click", () => copyText(url, "Address copied"));
    row.append(copy);
    list.append(row);
  }
  $("networkCert").hidden = !network.certificate;
  const plain = network.urls.length ? network.urls[0].replace(/^https:/, "http:") : "";
  $("networkCertPlain").textContent = plain;
  $("networkFingerprint").textContent = network.certificateFingerprint || "";
  $("networkScrim").hidden = false;
  $("networkClose").focus();
}

function closeNetworkDialog() {
  if ($("networkScrim").hidden) return false;
  $("networkScrim").hidden = true;
  $("sbNetwork").focus();
  return true;
}

$("sbNetwork").addEventListener("click", openNetworkDialog);
$("networkClose").addEventListener("click", closeNetworkDialog);
$("networkScrim").addEventListener("mousedown", (event) => { if (event.target === $("networkScrim")) closeNetworkDialog(); });
$("networkScrim").addEventListener("keydown", (event) => { if (event.key === "Escape") { event.preventDefault(); closeNetworkDialog(); } });

// ---- Input → screen latency ----
// Drags the screen a little, eight times, where it stands still, and times
// each first move from leaving this page to a changed frame painted here:
// the network both ways, the device, its app redrawing, the encoder and the
// decoder. Over a scrollable list (Settings) the content follows the finger
// at once; a screen where nothing moves under the finger measures nothing.

const PROBE_AT = { x: 0.5, y: 0.6 };
const PROBE_DRAG = 0.08;

function pause(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

async function waitUntil(test, timeoutMs) {
  const deadline = performance.now() + timeoutMs;
  while (performance.now() < deadline) {
    if (test()) return true;
    await pause(4);
  }
  return false;
}

async function measureLatency(rounds) {
  if (remote.probing || !canTouch() || !manualInputAllowed()) return null;
  remote.probing = true;
  const samples = [];
  toast("Measuring input → screen: SimTool drags the screen a little " + (rounds || 8) + " times — keep your hands off it");
  try {
    for (let round = 0; round < (rounds || 8); round += 1) {
      // A screen at rest: nothing changed for a moment — and again once the
      // finger is down, which may highlight the row under it.
      await waitUntil(() => performance.now() - (screenState.shownAt || 0) > 350, 3000);
      touchStream.down(PROBE_AT);
      await pause(120);
      await waitUntil(() => performance.now() - (screenState.shownAt || 0) > 300, 1500);
      const sentAt = performance.now();
      touchStream.moveNow({ x: PROBE_AT.x, y: PROBE_AT.y - PROBE_DRAG });
      const moved = await waitUntil(() => (screenState.shownAt || 0) > sentAt, 2000);
      if (moved) samples.push(screenState.shownAt - sentAt);
      touchStream.moveNow(PROBE_AT);
      await pause(120);
      touchStream.up(PROBE_AT);
      await pause(450);
    }
  } finally {
    remote.probing = false;
  }
  if (!samples.length) {
    toast("Nothing moved under the probe — open a scrollable list (Settings) and measure again", { error: true });
    return null;
  }
  const sorted = samples.slice().sort((a, b) => a - b);
  const result = {
    median: Math.round(median(sorted)), min: Math.round(sorted[0]), max: Math.round(sorted[sorted.length - 1]),
    samples: sorted.map(Math.round), roundTrip: remote.roundTrips.length ? Math.round(median(remote.roundTrips)) : null
  };
  remote.lastLatency = result;
  toast("Input → screen: " + result.median + " ms median (" + result.min + "–" + result.max + " ms, " + sorted.length + " drags)"
    + (result.roundTrip != null ? " · network round trip " + result.roundTrip + " ms" : ""), { icon: "check" });
  return result;
}
