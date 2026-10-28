// The process list: every SimTool process on this Mac — servers from any
// simtool binary with what runs for them, the reaper, commands, and the orphans
// whose server is gone. It opens from the server's address in the status bar
// or the palette, refreshes while it is open, and stops a process from its row.
// The server stops only what its own discovery calls SimTool's, and itself only
// when the request confirms it.

const procs = { open: false, data: null, error: "", pending: new Set(), opener: null };

function openProcesses() {
  if (procs.open) return;
  closeMenu();
  closePopover();
  procs.opener = document.activeElement;
  procs.open = true;
  $("procsScrim").hidden = false;
  $("sbServer").setAttribute("aria-expanded", "true");
  renderProcesses();
  $("procsClose").focus();
  poller.poke("processes");
}

function closeProcesses(restore) {
  if (!procs.open) return false;
  procs.open = false;
  $("procsScrim").hidden = true;
  $("sbServer").setAttribute("aria-expanded", "false");
  if (restore !== false && procs.opener && procs.opener.focus) procs.opener.focus();
  return true;
}

async function loadProcesses() {
  try {
    procs.data = await apiJSON("/api/v1/processes");
    procs.error = "";
  } catch (error) {
    procs.error = error && error.message ? error.message : String(error);
  }
  if (procs.open) renderProcesses();
}

function renderProcesses() {
  const data = procs.data;
  const body = $("procsBody");
  const killOrphans = $("procsKillOrphans");
  const orphans = data ? data.orphans : 0;
  killOrphans.disabled = !orphans || procs.pending.has("orphans");
  $("procsOrphanCount").textContent = orphans ? formatCount(orphans) : "";
  if (!data) {
    $("procsSummary").textContent = "";
    patchPane(body, "procs", procs.error
      ? '<div class="empty"><b>The processes could not be read</b>' + escapeHTML(procs.error) + "</div>"
      : '<div class="empty">Reading the processes…</div>');
    return;
  }
  const all = data.groups.flatMap((group) => group.processes);
  const servers = all.filter((process) => process.kind === "server").length;
  $("procsSummary").textContent = [plural(all.length, "process", "processes"), plural(servers, "server", "servers"), orphans ? formatCount(orphans) + " orphaned" : ""]
    .filter(Boolean).join(" · ") + (procs.error ? " — not refreshed: " + procs.error : "");
  if (!all.length) {
    patchPane(body, "procs", '<div class="empty"><b>No SimTool process is running</b>Not even this server — the list is from a moment ago.</div>');
    return;
  }
  const now = Date.now();
  let html = '<table class="procs-table"><thead><tr><th scope="col">PID</th><th scope="col">Process</th><th scope="col" class="procs-device">Simulator</th>' +
    '<th scope="col">Up</th><th scope="col"><span class="sr-only">Stop</span></th></tr></thead>';
  data.groups.forEach((group, index) => {
    const heading = processGroupHeading(group, data);
    html += '<tbody class="procs-group procs-' + group.kind + '" aria-labelledby="procs-g' + index + '">' +
      '<tr class="procs-caption"><th colspan="5" scope="rowgroup" id="procs-g' + index + '">' +
      "<span>" + escapeHTML(heading.title) + "</span>" +
      (heading.self ? '<span class="tag tag-hit">This viewer</span>' : "") +
      (heading.detail ? '<span class="procs-detail">' + escapeHTML(heading.detail) + "</span>" : "") +
      "</th></tr>";
    for (const process of group.processes) html += processRowHTML(process, group, data, now);
    html += "</tbody>";
  });
  html += "</table>";
  patchPane(body, "procs", html);
}

function processRowHTML(process, group, data, now) {
  const depth = Math.min(3, processDepth(process, group.processes));
  const pending = procs.pending.has(process.pid);
  const self = process.pid === data.pid;
  const command = [tildePath(process.executable, data.home)].concat(process.arguments || []).join(" ");
  const image = processImageLine(process, data.home);
  const device = process.deviceName || (process.deviceUDID ? process.deviceUDID.slice(0, 8) + "…" : "");
  return '<tr class="procs-row depth-' + depth + (process.orphan ? " is-orphan" : "") + '"' + (pending ? ' aria-busy="true"' : "") + ">" +
    '<td class="procs-pid mono">' + process.pid + "</td>" +
    '<td class="procs-name" title="' + escapeHTML(command) + '"><span class="procs-title">' + escapeHTML(process.name) + "</span>" +
    (process.orphan ? '<span class="tag tag-warn">Orphan</span>' : "") +
    (image ? '<span class="procs-path">' + escapeHTML(image) + "</span>" : "") +
    (process.note ? '<span class="procs-note">' + escapeHTML(process.note) + "</span>" : "") + "</td>" +
    '<td class="procs-device"><span' + (process.deviceUDID ? ' title="' + escapeHTML(process.deviceUDID) + '"' : "") + ">" + escapeHTML(device) + "</span></td>" +
    '<td class="procs-up mono">' + escapeHTML(formatUptime(process.startedAt, now)) + "</td>" +
    '<td class="procs-act"><button class="btn btn-sm btn-danger" type="button" data-act="kill:' + process.pid + '"' +
    ' aria-label="' + escapeHTML((self ? "Stop this viewer's server, " : "Stop " + process.name + ", ") + "PID " + process.pid) + '"' +
    (pending ? " disabled" : "") + ">" + (pending ? "Stopping…" : "Kill") + "</button></td></tr>";
}

async function killProcess(pid) {
  const data = procs.data;
  if (!data || procs.pending.has(pid)) return;
  const group = data.groups.find((candidate) => candidate.processes.some((process) => process.pid === pid));
  const process = group && group.processes.find((candidate) => candidate.pid === pid);
  if (!process) return;
  const question = processKillQuestion(process, data, group.kind === "server" ? processPort(group) : "");
  const confirmed = !question || (await confirmDestructive(question.title, question.text, question.confirm));
  // The list was drawn again under the question: back to the row's button.
  focusProcessRow(pid);
  if (!confirmed) return;
  procs.pending.add(pid);
  renderProcesses();
  try {
    const result = await apiJSON("/api/v1/processes/" + pid + "/kill", { method: "POST", body: JSON.stringify({ confirm: !!(question && question.self) }) });
    const outcome = result.outcomes[0];
    toast(processKillMessage(outcome), { duration: 4000 });
    // This server stops after it answers: the page says so as it goes.
    if (outcome.result === "stopping") closeProcesses();
  } catch (error) {
    fail("Could not stop PID " + pid, error);
  } finally {
    procs.pending.delete(pid);
  }
  if (procs.open) await loadProcesses();
  if (procs.open && !$("procsScrim").contains(document.activeElement)) $("procsBody").focus();
}

function focusProcessRow(pid) {
  if (!procs.open) return;
  const button = $("procsBody").querySelector('[data-act="kill:' + pid + '"]');
  (button && !button.disabled ? button : $("procsBody")).focus();
}

async function killAllOrphans() {
  if (!procs.data || !procs.data.orphans || procs.pending.has("orphans")) return;
  procs.pending.add("orphans");
  renderProcesses();
  try {
    const result = await apiJSON("/api/v1/processes/kill-orphans", { method: "POST" });
    const stopped = result.outcomes.reduce((count, outcome) => count + 1 + (outcome.alongside || []).length, 0);
    toast(stopped ? "Stopped " + plural(stopped, "orphaned process", "orphaned processes") : "No orphan was left to stop", { duration: 4000 });
  } catch (error) {
    fail("Could not stop the orphans", error);
  } finally {
    procs.pending.delete("orphans");
  }
  if (procs.open) await loadProcesses();
}

$("sbServer").addEventListener("click", openProcesses);
$("procsClose").addEventListener("click", () => closeProcesses());
$("procsKillOrphans").addEventListener("click", killAllOrphans);
$("procsBody").addEventListener("click", (event) => {
  const button = event.target.closest("button[data-act^='kill:']");
  if (button) killProcess(Number(button.dataset.act.slice(5)));
});
$("procsScrim").addEventListener("mousedown", (event) => { if (event.target === $("procsScrim")) closeProcesses(); });
$("procsScrim").addEventListener("keydown", (event) => {
  if (event.key === "Escape") { event.preventDefault(); closeProcesses(); return; }
  if (event.key !== "Tab") return;
  // Focus stays inside the list while it is open.
  const focusable = [...$("procsScrim").querySelectorAll("button:not([disabled]), [tabindex='0']")].filter((node) => node.getClientRects().length);
  if (!focusable.length) return;
  const index = focusable.indexOf(document.activeElement);
  const next = event.shiftKey ? (index <= 0 ? focusable.length - 1 : index - 1) : (index + 1) % focusable.length;
  event.preventDefault();
  focusable[next].focus();
});
