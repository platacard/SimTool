// Annotations: notes for an agent, pinned to what the screen shows. In
// annotation mode a click picks the element under it — the Accessibility
// tab's pick, with its outlines and redlines — and a drag marks a region where
// nothing has accessibility; a popover takes the words and whether they ask
// for a change or a question. Each note keeps a snapshot of its element, so it
// means the same after the screen has moved on; its pin shows only while that
// element is still there. The list is the Accessibility tab's other view; it
// stays in this browser, per simulator, until cleared, and Copy all puts it on
// the clipboard as one prompt (annotationsPrompt in logic.js). Nothing here
// touches the device: while the mode is on, neither clicks nor keys reach it.

const NOTE_DRAG_PX = 6;       // CSS px a press travels before it marks a region
const NOTE_REGION_MIN = 4;    // pt: a smaller region is a click
const NOTE_NUDGE_PT = 8;      // a region marked from the keyboard moves or grows this much; ⌥ by 1
const NOTE_INSIDE_KEPT = 50;  // a region keeps at most this many of the elements it holds

const annotate = {
  on: false,
  items: [],            // in order: { id, kind, text, element } or { id, kind, text, region, inside }
  udid: null,           // the simulator the list belongs to
  kind: "change",       // the popover's last choice
  hover: null,          // AX key under the pointer
  cursor: null,         // AX key the keyboard stands on
  press: null,          // a press on the screen: { pointerId, clientX, clientY, start }
  region: null,         // a region being marked, in points
  draft: null,          // the open popover: { item, opener, text, kind, firstKind }
  selected: null,       // the id selected in the list
  onScreen: new Map()   // id → its element's AX node (null for a region) while the screen shows it
};

const SCREEN_LABEL = canvas.getAttribute("aria-label");
const NOTE_SCREEN_LABEL = "Simulator screen, annotating: nothing reaches the device. Click an element or drag a region; from the keyboard, the arrows move between elements, Enter annotates one, R marks a region, Esc stops.";

function annotateActive() {
  return annotate.on && app.dataset.mode !== "replay";
}

// The tree is read while annotating and with the Accessibility tab in view:
// it says which notes' elements the screen still shows.
function notesTreeFresh() {
  return !!ax.tree && !ax.error && (annotateActive() || (inspector.open && inspector.tab === "ax"));
}

function showNotesList() {
  if (ax.view !== "notes") setAxView("notes");
  if (inspector.tab !== "ax") setTab("ax");
}

function setAnnotating(on) {
  if (on && app.dataset.mode === "replay") { setMessage("Annotations are made on the live screen — go back to live first"); return; }
  if (annotate.on !== on) {
    annotate.on = on;
    annotate.press = annotate.region = annotate.hover = annotate.cursor = null;
    if (on) { endTouch(); endWheelDrag(); hideDots(); } else closeNotePop(false);
    if (on) canvas.tabIndex = 0; else canvas.removeAttribute("tabindex");
    canvas.setAttribute("aria-label", on ? NOTE_SCREEN_LABEL : SCREEN_LABEL);
    if (on && inspector.open) showNotesList();
    if (on) poller.poke("ax");
    updateAxMode();
    renderNotes();
  }
  if (on) canvas.focus({ preventScroll: true });
}

// ---- The list, per simulator, in this browser ----

function newNoteId() {
  return Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 7);
}

// A server for another simulator brings its own list; notes made before the
// page knew which simulator it shows join it.
function loadNotes(udid) {
  if (!udid || udid === annotate.udid) return;
  const early = annotate.udid ? [] : annotate.items;
  if (annotate.udid) closeNotePop(false);
  annotate.udid = udid;
  const kept = stored("annotations." + udid, []);
  annotate.items = (Array.isArray(kept) ? kept : []).filter((item) => item && item.id && (item.element || item.region)).concat(early);
  annotate.selected = null;
  if (early.length) store("annotations." + udid, annotate.items);
  refreshNotesOnScreen();
  renderNotes();
}

function saveNotes() {
  if (annotate.udid) store("annotations." + annotate.udid, annotate.items);
  refreshNotesOnScreen();
  renderNotes();
}

// Which notes' targets the screen shows now, by the last tree read.
function refreshNotesOnScreen() {
  annotate.onScreen = new Map();
  if (!ax.tree) return;
  const nodes = [...ax.nodes.values()];
  for (const item of annotate.items) {
    if (item.region) { if (annotationOnScreen(item, nodes)) annotate.onScreen.set(item.id, null); }
    else {
      const node = annotationNode(item.element, nodes);
      if (node) annotate.onScreen.set(item.id, node);
    }
  }
}

// A new tree: pins follow what is on the screen now (called by loadAx).
function notesTreeLoaded() {
  refreshNotesOnScreen();
  if (annotate.hover != null && !ax.nodes.has(annotate.hover)) annotate.hover = null;
  if (annotate.cursor != null && !ax.nodes.has(annotate.cursor)) annotate.cursor = null;
  renderNotePins();
}

function noteContext() {
  return { app: deviceInfo.app, device: deviceInfo.name, os: runtimeName(deviceInfo.runtime) };
}

function noteTargetText(item) {
  if (!item.region) return annotationElementText(item.element, false);
  return "Region " + annotationFrameText(item.region) + " · " + plural((item.inside || []).length, "element", "elements");
}

function copyNotes() {
  const count = annotate.items.length;
  if (!count) { setMessage("No annotations to copy yet — press A and click an element on the screen"); return; }
  copyText(annotationsPrompt(annotate.items, noteContext()), "Copied " + plural(count, "annotation", "annotations") + " as one prompt");
}

async function clearNotes() {
  const count = annotate.items.length;
  if (!count) return;
  const sure = await confirmDestructive("Clear all annotations?", plural(count, "annotation", "annotations") + " on " + (deviceInfo.name || "this simulator") + " will be deleted. Copy all first if the agent still needs them.", "Clear all");
  if (!sure) return;
  closeNotePop(false);
  annotate.items = [];
  annotate.selected = null;
  saveNotes();
  toast("Annotations cleared", { icon: "trash" });
}

function deleteNote(id) {
  const index = annotate.items.findIndex((item) => item.id === id);
  if (index < 0) return;
  const wasSelected = annotate.selected === id;
  const focusList = notesListNode.contains(document.activeElement);
  const [item] = annotate.items.splice(index, 1);
  if (annotate.draft && annotate.draft.item.id === id) closeNotePop(false);
  saveNotes();
  const next = annotate.items[Math.min(index, annotate.items.length - 1)];
  if (wasSelected) notesList.select(next ? next.id : null, { focus: focusList });
  else if (focusList) notesList.focus();
  toast("Annotation " + (index + 1) + " deleted", {
    icon: "trash", duration: 6000,
    action: { label: "Undo", run: () => {
      if (annotate.items.some((other) => other.id === item.id)) return;
      annotate.items.splice(Math.min(index, annotate.items.length), 0, item);
      saveNotes();
    } }
  });
}

// ---- Marking on the screen ----

function notePointAt(clientX, clientY) {
  const point = axPointAt(clientX, clientY), screen = screenState.points;
  if (!point) return null;
  return {
    x: Math.min(screen.x + screen.width, Math.max(screen.x, point.x)),
    y: Math.min(screen.y + screen.height, Math.max(screen.y, point.y))
  };
}

function noteRegionBetween(a, b) {
  return { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(a.x - b.x), height: Math.abs(a.y - b.y) };
}

// The element a click means: the pick's, but never the app itself. A hairline
// or an anonymous group under the pointer leads the pick up to the app; the
// smallest element with a name there is what was meant.
function noteElementAt(clientX, clientY) {
  const node = axHitTest(clientX, clientY);
  if (node && node._depth > 0) return node;
  const point = axPointAt(clientX, clientY), screen = screenState.points;
  let best = null, bestArea = Infinity;
  for (const other of point ? ax.nodes.values() : []) {
    if (!axHasFrame(other) || axIsAnonymous(other) || other._depth === 0) continue;
    const f = other.frame;
    if (f.width > screen.width * 1.05 || f.height > screen.height * 1.05) continue;
    if (point.x < f.x || point.x > f.x + f.width || point.y < f.y || point.y > f.y + f.height) continue;
    if (f.width * f.height <= bestArea) { bestArea = f.width * f.height; best = other; }
  }
  return best;
}

// What the overlay draws while annotating: the region being marked or the
// popover's target as the picked box, and the element under the pointer.
function annotateMarks() {
  const frameOf = (key) => {
    const node = key != null ? ax.nodes.get(key) : null;
    return node && axHasFrame(node) ? node.frame : null;
  };
  const draft = annotate.draft;
  const selected = annotate.region || (draft ? draft.item.region || draft.item.element.frame : null) || frameOf(annotate.cursor);
  const hover = frameOf(annotate.hover);
  return { selected, hover: hover && hover !== selected ? hover : null };
}

// A press on the screen in annotation mode: a click picks an element, a drag
// marks a region. Neither reaches the device.
function notePointerDown(event) {
  event.preventDefault();
  if (screenState.view3d) { setMessage("Annotations mark the flat screen — leave the 3D view first"); return; }
  if (!screenState.points) { setMessage("The screen's size is not known yet — try again in a moment"); return; }
  try { canvas.setPointerCapture(event.pointerId); } catch (_) {}
  canvas.focus({ preventScroll: true });
  annotate.press = { pointerId: event.pointerId, clientX: event.clientX, clientY: event.clientY, start: notePointAt(event.clientX, event.clientY) };
  annotate.cursor = null;
}

function notePointerMove(event) {
  const press = annotate.press;
  if (press && press.pointerId === event.pointerId) {
    if (!annotate.region && Math.hypot(event.clientX - press.clientX, event.clientY - press.clientY) < NOTE_DRAG_PX) return;
    annotate.region = noteRegionBetween(press.start, notePointAt(event.clientX, event.clientY));
    annotate.hover = null;
    drawRedlines();
    return;
  }
  noteHoverAt(event.clientX, event.clientY);
}

function noteHoverAt(clientX, clientY) {
  const node = clientX == null || screenState.view3d ? null : noteElementAt(clientX, clientY);
  const key = node ? node._key : null;
  if (key !== annotate.hover) { annotate.hover = key; drawRedlines(); }
}

// Whether the press was annotation mode's.
function notePointerUp(event) {
  const press = annotate.press;
  if (!press || press.pointerId !== event.pointerId) return false;
  annotate.press = null;
  const region = annotate.region;
  annotate.region = null;
  if (region) {
    if (region.width >= NOTE_REGION_MIN && region.height >= NOTE_REGION_MIN) openNoteForRegion(region, canvas);
    else drawRedlines();
    return true;
  }
  const node = noteElementAt(event.clientX, event.clientY);
  if (node) openNoteForNode(node, canvas);
  else setMessage(ax.error ? ax.error : ax.tree ? "Nothing here has accessibility — drag a rectangle to mark the region" : "Reading the accessibility tree…");
  return true;
}

function notePointerCancel(event) {
  if (!annotate.press || annotate.press.pointerId !== event.pointerId) return;
  annotate.press = null;
  annotate.region = null;
  drawRedlines();
}

// ---- Marking from the keyboard ----
// The screen takes focus in annotation mode: the arrows walk the elements in
// reading order and Enter annotates the one they stand on; R marks a region
// there, which the arrows move, ⇧ with the arrows resizes and Enter annotates.

function noteKeyboardOrder() {
  const screen = screenState.points;
  if (!screen) return [];
  return axReadingOrder([...ax.nodes.values()].filter((node) => axHasFrame(node) && !axIsAnonymous(node) && node._depth > 0 &&
    node.frame.width <= screen.width * 1.05 && node.frame.height <= screen.height * 1.05));
}

function startKeyboardRegion() {
  const screen = screenState.points;
  const node = annotate.cursor != null ? ax.nodes.get(annotate.cursor) : null;
  const side = Math.round(screen.width / 2);
  const frame = node && axHasFrame(node) ? node.frame : { x: screen.x + side / 2, y: screen.y + (screen.height - side) / 2, width: side, height: side };
  annotate.region = { x: frame.x, y: frame.y, width: frame.width, height: frame.height };
  annotate.cursor = null;
  setMessage("Marking a region: the arrows move it, ⇧ with the arrows resizes it, ⌥ by 1 pt — Enter annotates it, Esc drops it", "sticky");
  drawRedlines();
}

function nudgeKeyboardRegion(event) {
  const region = annotate.region, screen = screenState.points;
  const step = event.altKey ? 1 : NOTE_NUDGE_PT;
  const delta = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] }[event.key];
  if (!delta) return false;
  const right = screen.x + screen.width, bottom = screen.y + screen.height;
  if (event.shiftKey) {
    region.width = Math.max(NOTE_REGION_MIN, Math.min(right - region.x, region.width + delta[0]));
    region.height = Math.max(NOTE_REGION_MIN, Math.min(bottom - region.y, region.height + delta[1]));
  } else {
    region.x = Math.max(screen.x, Math.min(right - region.width, region.x + delta[0]));
    region.y = Math.max(screen.y, Math.min(bottom - region.height, region.y + delta[1]));
  }
  drawRedlines();
  return true;
}

canvas.addEventListener("keydown", (event) => {
  if (!annotateActive() || event.metaKey || event.ctrlKey || event.isComposing || annotate.press) return;
  if (!screenState.points || screenState.view3d) return;
  let handled = true;
  if (annotate.region) {
    if (event.key === "Enter") { const region = annotate.region; annotate.region = null; setMessage(""); openNoteForRegion(region, canvas); }
    else if (event.key === "Escape") { annotate.region = null; setMessage(""); drawRedlines(); }
    else handled = nudgeKeyboardRegion(event);
  } else {
    const order = noteKeyboardOrder();
    const index = order.findIndex((node) => node._key === annotate.cursor);
    let next;
    if (event.key === "ArrowDown" || event.key === "ArrowRight") next = order[index < 0 ? 0 : Math.min(order.length - 1, index + 1)];
    else if (event.key === "ArrowUp" || event.key === "ArrowLeft") next = order[index < 0 ? order.length - 1 : Math.max(0, index - 1)];
    else if (event.key === "Home") next = order[0];
    else if (event.key === "End") next = order[order.length - 1];
    else if (event.key === "Enter") {
      const node = index >= 0 ? order[index] : null;
      if (node) openNoteForNode(node, canvas);
      else setMessage(order.length ? "Move to an element with the arrow keys first" : "No element on the screen has accessibility — R marks a region");
    } else if (event.code === "KeyR" && !event.altKey && !event.shiftKey) startKeyboardRegion();
    else if (event.key === "Escape" && annotate.cursor != null) { annotate.cursor = null; drawRedlines(); }
    else handled = false;
    if (next) {
      annotate.cursor = next._key;
      setMessage(annotationElementText(axSnapshot(next)));
      drawRedlines();
    }
  }
  if (handled) { event.preventDefault(); event.stopPropagation(); }
});

// ---- The popover: the words, Change or Question, Add ----

const notePop = $("notePop");
const notePopText = $("notePopText");

function openNoteForNode(node, opener) {
  openNotePop({ id: newNoteId(), kind: annotate.kind, text: "", element: axSnapshot(node) }, opener);
}

function openNoteForRegion(region, opener) {
  const frame = { x: Math.round(region.x), y: Math.round(region.y), width: Math.round(region.width), height: Math.round(region.height) };
  const inside = axElementsInside([...ax.nodes.values()], frame).slice(0, NOTE_INSIDE_KEPT).map(axSnapshot);
  openNotePop({ id: newNoteId(), kind: annotate.kind, text: "", region: frame, inside }, opener);
}

function editNote(id, opener) {
  const item = annotate.items.find((candidate) => candidate.id === id);
  if (item) openNotePop(item, opener);
}

function openNotePop(item, opener) {
  closeNotePop(false);
  const kind = item.kind === "question" ? "question" : "change";
  annotate.draft = { item, opener: opener || document.activeElement, text: item.text || "", kind, firstKind: kind };
  const index = annotate.items.findIndex((candidate) => candidate.id === item.id);
  $("notePopNum").textContent = String(index >= 0 ? index + 1 : annotate.items.length + 1);
  $("notePopTitle").textContent = noteTargetText(item);
  $("notePopTitle").title = item.region ? noteTargetText(item) : annotationElementText(item.element);
  $("notePopSave").firstChild.textContent = index >= 0 ? "Save " : "Add ";
  notePopText.value = item.text || "";
  notePop.hidden = false;
  syncNotePop();
  placeNotePop();
  notePopText.focus();
  notePopText.setSelectionRange(notePopText.value.length, notePopText.value.length);
  drawRedlines();
}

function syncNotePop() {
  const draft = annotate.draft;
  if (!draft) return;
  for (const button of $("notePopKind").querySelectorAll("[data-kind]")) button.setAttribute("aria-pressed", String(button.dataset.kind === draft.kind));
  $("notePopNum").classList.toggle("question", draft.kind === "question");
  notePopText.placeholder = draft.kind === "question" ? "Ask the agent about this…" : "Describe what the agent should change here…";
  $("notePopSave").disabled = !notePopText.value.trim();
}

function notePopPristine() {
  const draft = annotate.draft;
  return !draft || (notePopText.value === draft.text && draft.kind === draft.firstKind);
}

function closeNotePop(restoreFocus) {
  const draft = annotate.draft;
  if (!draft) return false;
  annotate.draft = null;
  notePop.hidden = true;
  drawRedlines();
  if (restoreFocus !== false && draft.opener && draft.opener.isConnected && draft.opener.focus) draft.opener.focus({ preventScroll: true });
  return true;
}

function saveNotePop() {
  const draft = annotate.draft;
  if (!draft) return;
  const text = notePopText.value.trim();
  if (!text) { notePopText.focus(); return; }
  const item = { ...draft.item, kind: draft.kind, text };
  annotate.kind = draft.kind;
  // A note deleted while its popover was open comes back as a new one.
  const index = annotate.items.findIndex((candidate) => candidate.id === item.id);
  if (index >= 0) annotate.items[index] = item; else annotate.items.push(item);
  closeNotePop();
  saveNotes();
  if (index < 0 && !annotateActive()) toast("Annotation " + annotate.items.length + " added", { icon: "note" });
}

// Beside the device when there is room, level with what it is about; else
// under it, or over it at the window's end.
function placeNotePop() {
  const draft = annotate.draft;
  if (!draft) return;
  const box = notePop.getBoundingClientRect(), screenRect = canvas.getBoundingClientRect();
  const target = noteClientRect(draft.item.region || draft.item.element.frame) || screenRect;
  const gap = 12, margin = 8;
  let left = null, top;
  if (innerWidth - screenRect.right >= box.width + gap + margin) left = screenRect.right + gap;
  else if (screenRect.left >= box.width + gap + margin) left = screenRect.left - gap - box.width;
  if (left != null) top = target.top + target.height / 2 - box.height / 2;
  else {
    left = target.left + target.width / 2 - box.width / 2;
    const below = target.top + target.height + gap;
    top = below + box.height <= innerHeight - margin ? below : target.top - gap - box.height;
  }
  notePop.style.left = Math.round(Math.max(margin, Math.min(left, innerWidth - box.width - margin))) + "px";
  notePop.style.top = Math.round(Math.max(margin, Math.min(top, innerHeight - box.height - margin))) + "px";
}

// A frame in points, where the screen shows it in the window.
function noteClientRect(frame) {
  const screen = screenState.points;
  if (!screen || !frame) return null;
  const rect = canvas.getBoundingClientRect();
  const sx = rect.width / screen.width, sy = rect.height / screen.height;
  return { left: rect.left + (frame.x - screen.x) * sx, top: rect.top + (frame.y - screen.y) * sy, width: frame.width * sx, height: frame.height * sy };
}

$("notePopKind").addEventListener("click", (event) => {
  const button = event.target.closest("[data-kind]");
  if (!button || !annotate.draft) return;
  annotate.draft.kind = button.dataset.kind;
  syncNotePop();
});
notePopText.addEventListener("input", syncNotePop);
$("notePopCancel").addEventListener("click", () => closeNotePop());
$("notePopSave").addEventListener("click", saveNotePop);
// The popover keeps its keys: ⌘↵ adds, Esc cancels, Tab stays inside, and
// none of the page's shortcuts fire while typing in it.
notePop.addEventListener("keydown", (event) => {
  if (event.isComposing) return;
  if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); closeNotePop(); return; }
  if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) { event.preventDefault(); event.stopPropagation(); saveNotePop(); return; }
  if (event.key === "Tab") {
    const stops = [...notePop.querySelectorAll("textarea, button:not([disabled])")];
    const index = stops.indexOf(document.activeElement);
    event.preventDefault();
    stops[(index + (event.shiftKey ? stops.length - 1 : 1) + stops.length) % stops.length].focus();
  }
  event.stopPropagation();
});
// A click elsewhere drops a popover nothing was written in. Words not added yet
// stay until Add or Cancel; a click on the screen then goes back to them.
document.addEventListener("pointerdown", (event) => {
  if (!annotate.draft || notePop.contains(event.target)) return;
  if (notePopPristine()) { closeNotePop(false); return; }
  if (event.target === canvas || event.target.closest(".note-layer")) {
    event.preventDefault();
    event.stopPropagation();
    notePopText.focus();
  }
}, true);
window.addEventListener("resize", placeNotePop);

// ---- Pins on the screen ----

function renderNotePins() {
  const layer = $("noteLayer");
  const screen = screenState.points;
  if (!annotateActive() || !screen || !ax.tree) { if (layer.firstChild) layer.innerHTML = ""; return; }
  const at = (value, origin, size) => (value - origin) / size * 100;
  let html = "";
  annotate.items.forEach((item, index) => {
    if (!annotate.onScreen.has(item.id)) return;
    const frame = item.region || item.element.frame;
    const left = at(frame.x, screen.x, screen.width), top = at(frame.y, screen.y, screen.height);
    const selected = item.id === annotate.selected ? " selected" : "";
    html += '<div class="note-frame' + (item.region ? " region" : "") + selected + '" style="left:' + left + "%;top:" + top + "%;width:" + (frame.width / screen.width * 100) + "%;height:" + (frame.height / screen.height * 100) + '%"></div>';
    // The pin sits on the frame's corner, kept clear of the screen's edge.
    html += '<button type="button" tabindex="-1" class="note-pin' + (item.kind === "question" ? " question" : "") + selected + '" data-note="' + escapeHTML(item.id) + '"' +
      ' style="left:' + Math.min(96, Math.max(4, left)) + "%;top:" + Math.min(98, Math.max(2, top)) + '%" title="' + escapeHTML((index + 1) + ". " + ANNOTATION_KINDS[item.kind] + ": " + item.text) + '">' + (index + 1) + "</button>";
  });
  layer.innerHTML = html;
}

$("noteLayer").addEventListener("click", (event) => {
  const pin = event.target.closest("[data-note]");
  if (!pin || !notePopPristine()) return;
  if (inspector.tab === "ax" && ax.view === "notes") notesList.select(pin.dataset.note, { scroll: true });
  editNote(pin.dataset.note, canvas);
});

// ---- The list: the Accessibility tab's Annotations view ----
// Its toolbar buttons and list sit beside the tree's in the same panel and
// share its guide and detail; renderAx shows one view's.

const notesToggle = el("button", { class: "toggle toggle-sm", type: "button", "aria-pressed": "false", "data-tip": "Annotate the screen", "data-key": "A", hidden: true, html: icon("note") + '<span class="toggle-label">Annotate</span>' });
const notesCopy = el("button", { class: "btn btn-sm btn-primary", type: "button", "data-tip": "Put every annotation on the clipboard as one prompt", hidden: true, html: icon("copy", "ic-sm") + "Copy all" });
const notesClear = el("button", { class: "tb-btn", type: "button", "aria-label": "Clear all annotations", "data-tip": "Clear all annotations", hidden: true, html: icon("trash") });
const notesListNode = el("div", { class: "list", role: "listbox", "aria-label": "Annotations", hidden: true });
axSpacer.before(notesToggle, notesCopy);
axView.ptool.append(notesClear);
axView.listWrap.append(notesListNode);

notesToggle.addEventListener("click", () => setAnnotating(!annotate.on));
$("annotateButton").addEventListener("click", () => setAnnotating(!annotate.on));
notesCopy.addEventListener("click", copyNotes);
notesClear.addEventListener("click", clearNotes);

const notesList = createList(notesListNode, {
  key: (item) => item.id,
  version: (item) => [annotate.items.indexOf(item), item.kind, item.text, noteTargetText(item), notesTreeFresh() && !annotate.onScreen.has(item.id)].join("|"),
  rowClass: () => "note-grid",
  render: renderNoteRow,
  empty: () => el("div", { class: "empty", html: "<b>No annotations yet</b>Press <kbd>A</kbd> or Annotate, then click an element on the screen — or drag a rectangle around something without accessibility — and write what the agent should change, or ask it a question. Copy all puts them on the clipboard as one prompt." }),
  onSelect: (key) => { annotate.selected = key; renderNoteDetail(); renderNotePins(); },
  onActivate: (key) => editNote(key, notesRow(key)),
  onMenu: (key, item, x, y, row) => openMenu(x, y, noteMenuItems(item, row), row)
});

function notesRow(id) {
  return notesListNode.querySelector('.row[data-key="' + CSS.escape(id) + '"]');
}

function renderNoteRow(item, row) {
  const number = annotate.items.indexOf(item) + 1;
  const gone = notesTreeFresh() && !annotate.onScreen.has(item.id);
  row.innerHTML =
    '<span class="note-pin note-pin-static' + (item.kind === "question" ? " question" : "") + '">' + number + "</span>" +
    '<span class="cell note-kind">' + ANNOTATION_KINDS[item.kind] + "</span>" +
    '<span class="cell note-target" translate="no">' + escapeHTML(noteTargetText(item)) + "</span>" +
    '<span class="cell note-words">' + escapeHTML(item.text.replace(/\s*\n\s*/g, " ⏎ ")) + "</span>" +
    '<span class="cell note-gone">' + (gone ? "Not on the screen" : "") + "</span>" +
    '<span class="note-acts">' +
      '<button class="tb-btn" type="button" tabindex="-1" data-act="edit" aria-label="Edit annotation ' + number + '" data-tip="Edit" data-key="↩">' + icon("edit") + "</button>" +
      '<button class="tb-btn" type="button" tabindex="-1" data-act="delete" aria-label="Delete annotation ' + number + '" data-tip="Delete" data-key="⌫">' + icon("trash") + "</button>" +
    "</span>";
  row.title = item.text;
}

function noteMenuItems(item, row) {
  return [
    { icon: "edit", label: "Edit", kbd: "↩", run: () => editNote(item.id, row) },
    { icon: "copy", label: "Copy this annotation as a prompt", run: () => copyText(annotationsPrompt([item], noteContext()), "Annotation copied") },
    { icon: "copy", label: "Copy all as one prompt", run: copyNotes },
    "-",
    { icon: "trash", label: "Delete", kbd: "⌫", tone: "danger", run: () => deleteNote(item.id) }
  ];
}

notesListNode.addEventListener("click", (event) => {
  const button = event.target.closest("[data-act]");
  if (!button) return;
  const row = button.closest(".row[data-key]");
  if (button.dataset.act === "edit") editNote(row.dataset.key, row);
  if (button.dataset.act === "delete") deleteNote(row.dataset.key);
});
notesListNode.addEventListener("keydown", (event) => {
  if ((event.key === "Delete" || event.key === "Backspace") && annotate.selected && !event.metaKey) { event.preventDefault(); deleteNote(annotate.selected); }
});
// A row under the pointer outlines its element on the screen.
notesListNode.addEventListener("mouseover", (event) => {
  const row = event.target.closest(".row[data-key]");
  const node = row ? annotate.onScreen.get(row.dataset.key) : null;
  const key = node ? node._key : null;
  if (key !== annotate.hover) { annotate.hover = key; drawRedlines(); }
});
notesListNode.addEventListener("mouseleave", () => { annotate.hover = null; drawRedlines(); });

function renderNotes() {
  const items = annotate.items;
  const count = items.length;
  setCount("notes", count);
  $("annotateCount").textContent = count ? formatCount(count) : "";
  const button = $("annotateButton");
  button.setAttribute("aria-pressed", String(annotate.on));
  button.setAttribute("aria-label", "Annotate" + (count ? ", " + plural(count, "annotation", "annotations") : ""));
  button.dataset.tip = annotate.on ? "Stop annotating — the screen takes touches again" : "Annotate the screen for the agent";
  notesToggle.setAttribute("aria-pressed", String(annotate.on));
  notesCopy.disabled = !count;
  notesClear.disabled = !count;
  notesList.update(items.slice());
  renderNotePins();
  if (ax.view !== "notes") return;
  const questions = items.filter((item) => item.kind === "question").length;
  const gone = notesTreeFresh() ? items.filter((item) => !annotate.onScreen.has(item.id)).length : 0;
  axView.guide.innerHTML = guideHTML([
    count ? plural(count - questions, "change", "changes") + " · " + plural(questions, "question", "questions") : "",
    gone ? formatCount(gone) + " not on the screen now" : "",
    annotateActive() ? "<b>Annotating</b> — click an element or drag a region; the arrows, Enter and R from the keyboard" : "Press A to annotate the screen"
  ], "");
  renderNoteDetail();
}

function renderNoteDetail() {
  if (ax.view !== "notes") return;
  const item = annotate.selected ? annotate.items.find((candidate) => candidate.id === annotate.selected) : null;
  showDetail(axView.panel, !!item);
  if (!item) return;
  const number = annotate.items.indexOf(item) + 1;
  const frame = item.region || item.element.frame;
  const where = "x " + Math.round(frame.x) + "  y " + Math.round(frame.y) + "  w " + Math.round(frame.width) + "  h " + Math.round(frame.height) + " pt";
  const fresh = notesTreeFresh();
  const facts = item.region
    ? { Frame: where, Inside: (item.inside || []).length ? (item.inside || []).map((element) => annotationElementText(element, false)).join("\n") : "No accessibility elements" }
    : { Role: item.element.role, Identifier: item.element.id || "—", Label: item.element.label || "—", Value: item.element.value || "—", Frame: where };
  patchPane(axView.detail, "note:" + item.id,
    '<div class="dhead"><span class="note-pin note-pin-static' + (item.kind === "question" ? " question" : "") + '">' + number + "</span>" +
      '<span class="dtitle" translate="no">' + escapeHTML(noteTargetText(item)) + "</span>" +
      '<div class="dactions"><button class="btn btn-sm" type="button" data-act="edit">' + icon("edit", "ic-sm") + "Edit</button>" +
      '<button class="btn btn-sm btn-danger" type="button" data-act="delete">' + icon("trash", "ic-sm") + "Delete</button>" +
      '<button class="tb-btn" type="button" data-act="close" aria-label="Close the details">' + icon("close") + "</button></div></div>" +
    '<div class="dmeta"><span>' + ANNOTATION_KINDS[item.kind] + "</span>" +
      (fresh ? "<span>" + (annotate.onScreen.has(item.id) ? "On the screen" : "Not on the screen now — the note keeps what it was made on") + "</span>" : "") + "</div>" +
    '<div class="dbody note-body"><p class="note-full">' + escapeHTML(item.text) + "</p>" +
      '<div class="sec">' + (item.region ? "Region" : "Element") + "</div>" + kvHTML(facts) +
      '<div class="sec">In the prompt</div><pre class="code" translate="no">' + escapeHTML(annotationPromptItem(item, number)) + "</pre>" +
    "</div>");
}

axView.detail.addEventListener("click", (event) => {
  const action = event.target.closest("[data-act]");
  const id = annotate.selected;
  if (!action || !id || ax.view !== "notes") return;
  if (action.dataset.act === "edit") editNote(id, action);
  if (action.dataset.act === "delete") deleteNote(id);
  if (action.dataset.act === "close") { notesList.select(null); notesList.focus(); }
});
