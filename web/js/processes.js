// The process list: every SimTool process on the server's Mac — servers from
// any simtool binary with what runs for them, the reaper, commands, and the
// orphans whose server is gone — and what the Mac's memory and CPU go to: its
// own figures, each simulator booted on it with everything running inside, and
// what each SimTool process costs. It opens from the server's address in the
// status bar or the palette and refreshes while it is open. On the Mac itself
// it stops a process from its row; the server stops only what its own
// discovery calls SimTool's, and itself only when the request confirms it. A
// viewer that came in over the network reads the list and stops nothing: the
// server refuses that from the network.

const procs = { open: false, data: null, error: "", pending: new Set(), opener: null };

// Stopping a process is the Mac's own: over the network the server refuses it.
function processesCanStop() {
  return !remote.overNetwork;
}

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
    procs.data = await apiJSON("api/v1/processes");
    procs.error = "";
  } catch (error) {
    procs.error = error && error.message ? error.message : String(error);
  }
  if (procs.open) renderProcesses();
}

function renderProcesses() {
  const data = procs.data;
  const body = $("procsBody");
  const canStop = processesCanStop();
  const killOrphans = $("procsKillOrphans");
  const orphans = data ? data.orphans : 0;
  killOrphans.hidden = !canStop;
  killOrphans.disabled = !canStop || !orphans || procs.pending.has("orphans");
  $("procsOrphanCount").textContent = orphans ? formatCount(orphans) : "";
  $("procsFoot").innerHTML = canStop
    ? "Every SimTool process running as you on this Mac, from any simtool binary — refreshed every 2 s. CPU as in Activity Monitor: 100% is one core. In a terminal: <code>simtool ps</code>, <code>simtool kill &lt;pid&gt;</code>."
    : "Every SimTool process running on the server's Mac — refreshed every 2 s. CPU as in Activity Monitor: 100% is one core. Over the network the list is read-only: processes are stopped on the Mac itself.";
  renderMachine(data && data.machine);
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
  const now = Date.now();
  let html = data.machine ? simulatorsTableHTML(data, now) : "";
  if (!all.length) {
    html += '<div class="empty"><b>No SimTool process is running</b>Not even this server — the list is from a moment ago.</div>';
    patchPane(body, "procs", html);
    return;
  }
  const columns = canStop ? 7 : 6;
  html += '<table class="procs-table"><thead><tr><th scope="col">PID</th><th scope="col">Process</th><th scope="col" class="procs-device">Simulator</th>' +
    '<th scope="col" class="procs-num">CPU</th><th scope="col" class="procs-num">Memory</th><th scope="col">Up</th>' +
    (canStop ? '<th scope="col"><span class="sr-only">Stop</span></th>' : "") + "</tr></thead>";
  data.groups.forEach((group, index) => {
    const heading = processGroupHeading(group, data);
    html += '<tbody class="procs-group procs-' + group.kind + '" aria-labelledby="procs-g' + index + '">' +
      '<tr class="procs-caption"><th colspan="' + columns + '" scope="rowgroup" id="procs-g' + index + '">' +
      "<span>" + escapeHTML(heading.title) + "</span>" +
      (heading.self ? '<span class="tag tag-hit">This viewer</span>' : "") +
      (heading.detail ? '<span class="procs-detail">' + escapeHTML(heading.detail) + "</span>" : "") +
      "</th></tr>";
    for (const process of group.processes) html += processRowHTML(process, group, data, now, canStop);
    html += "</tbody>";
  });
  html += "</table>";
  patchPane(body, "procs", html);
}

// The Mac: its name, and two bars — memory used and CPU busy — whose darker
// part is the simulators'.
function renderMachine(machine) {
  const node = $("procsMac");
  node.hidden = !machine;
  if (!machine) return;
  const shares = machineShares(machine);
  const pressure = machine.pressure && machine.pressure !== "normal" ? machine.pressure : "";
  const percent = (fraction) => Math.round(fraction * 100);
  const bar = (label, used, simulators, state, text) =>
    '<span class="mac-bar' + (state ? " is-" + state : "") + '" role="meter" aria-label="' + label + '" aria-valuemin="0" aria-valuemax="100"' +
    (used == null ? "" : ' aria-valuenow="' + percent(used) + '"') + ' aria-valuetext="' + escapeHTML(text) + '">' +
    '<span class="mac-bar-used" style="width:' + (used == null ? 0 : used * 100).toFixed(1) + '%"></span>' +
    '<span class="mac-bar-sims" style="width:' + (simulators == null ? 0 : simulators * 100).toFixed(1) + '%"></span></span>';
  const memoryValue = formatMemory(machine.memoryUsed) + " of " + formatMemoryTotal(machine.memory);
  const memoryMeta = [
    '<span class="mac-swatch" aria-hidden="true"></span>simulators ' + formatMemory(shares.simulatorMemory),
    machine.swapUsed ? "swap " + formatMemory(machine.swapUsed) : "",
    pressure ? '<span class="mac-pressure is-' + pressure + '">pressure ' + pressure + "</span>" : "pressure normal"
  ].filter(Boolean).join(" · ");
  const cpuValue = shares.cpuBusy == null ? "—" : percent(shares.cpuBusy) + "% busy";
  const cpuMeta = [
    '<span class="mac-swatch" aria-hidden="true"></span>simulators ' + formatCpu(shares.simulatorCores),
    "load " + (machine.load || 0).toFixed(1)
  ].join(" · ");
  patchPane(node, "mac",
    '<div class="mac-head"><span class="mac-name">' + escapeHTML(machine.name || "This Mac") + "</span>" +
    '<span class="mac-spec">' + escapeHTML(plural(machine.cores, "core", "cores") + " · " + formatMemoryTotal(machine.memory)) + "</span></div>" +
    '<div class="mac-row"><span class="mac-label">Memory</span>' +
    bar("Memory used", shares.memoryUsed, shares.memorySimulators, pressure, memoryValue + ", simulators " + formatMemory(shares.simulatorMemory)) +
    '<span class="mac-value mono">' + escapeHTML(memoryValue) + '</span><span class="mac-meta">' + memoryMeta + "</span></div>" +
    '<div class="mac-row"><span class="mac-label">CPU</span>' +
    bar("CPU busy", shares.cpuBusy, shares.cpuSimulators, "", cpuValue + ", simulators " + formatCpu(shares.simulatorCores)) +
    '<span class="mac-value mono">' + escapeHTML(cpuValue) + '</span><span class="mac-meta">' + cpuMeta + "</span></div>");
}

// Every simulator booted on the Mac — all of it, the app under test included —
// and CoreSimulator's processes on the Mac, which every simulator shares.
function simulatorsTableHTML(data, now) {
  const machine = data.machine;
  const servers = simulatorServers(data);
  const own = (deviceInfo.udid || "").toUpperCase();
  let html = '<table class="procs-table procs-sims"><thead><tr><th scope="col">Simulator</th><th scope="col" class="procs-served">Served by</th>' +
    '<th scope="col" class="procs-num procs-count">Processes</th><th scope="col" class="procs-num">CPU</th><th scope="col" class="procs-num">Memory</th><th scope="col">Up</th></tr></thead>' +
    '<tbody aria-labelledby="procs-sims"><tr class="procs-caption"><th colspan="6" scope="rowgroup" id="procs-sims"><span>Simulators</span>' +
    '<span class="procs-detail">Everything running in each, its apps included</span></th></tr>';
  const simulators = orderedSimulators(machine.simulators, servers, own);
  if (!simulators.length) html += '<tr class="procs-row"><td colspan="6" class="procs-none">No simulator is booted on this Mac.</td></tr>';
  for (const simulator of simulators) {
    const udid = (simulator.udid || "").toUpperCase();
    const by = servers[udid] || [];
    const meta = [runtimeName(simulator.runtime), simulator.udid ? simulator.udid.slice(0, 8) + "…" : "launchd_sim " + simulator.pid].filter(Boolean).join(" · ");
    html += '<tr class="procs-row">' +
      '<td class="procs-name"' + (simulator.udid ? ' title="' + escapeHTML(simulator.udid) + '"' : "") + '><span class="procs-title">' + escapeHTML(simulator.name || simulator.udid || "Simulator") + "</span>" +
      (own && udid === own ? '<span class="tag tag-hit">This viewer</span>' : "") +
      '<span class="procs-path">' + escapeHTML(meta) + "</span></td>" +
      '<td class="procs-served mono">' + (by.length ? escapeHTML(by.map((server) => server.port ? ":" + server.port : "PID " + server.pid).join(" ")) : '<span class="procs-quiet" title="No SimTool server holds it">—</span>') + "</td>" +
      '<td class="procs-num procs-count mono">' + formatCount(simulator.processes) + "</td>" +
      '<td class="procs-num mono">' + formatCpu(simulator.usage.cpu) + "</td>" +
      '<td class="procs-num mono">' + formatMemory(simulator.usage.memory) + "</td>" +
      '<td class="procs-up mono">' + escapeHTML(formatUptime(simulator.bootedAt, now)) + "</td></tr>";
  }
  const services = machine.simulatorServices;
  if (services) {
    html += '<tr class="procs-row is-shared"><td class="procs-name"><span class="procs-title">CoreSimulator on the Mac</span>' +
      '<span class="procs-note">Draws every simulator\'s screen and runs them — shared by all of them</span></td>' +
      '<td class="procs-served"></td><td class="procs-num procs-count mono">' + formatCount(services.processes) + "</td>" +
      '<td class="procs-num mono">' + formatCpu(services.usage.cpu) + "</td>" +
      '<td class="procs-num mono">' + formatMemory(services.usage.memory) + '</td><td class="procs-up"></td></tr>';
  }
  return html + "</tbody></table>";
}

function processRowHTML(process, group, data, now, canStop) {
  const depth = Math.min(3, processDepth(process, group.processes));
  const pending = procs.pending.has(process.pid);
  const self = process.pid === data.pid;
  const command = [tildePath(process.executable, data.home)].concat(process.arguments || []).join(" ");
  const image = processImageLine(process, data.home);
  const device = process.deviceName || (process.deviceUDID ? process.deviceUDID.slice(0, 8) + "…" : "");
  const usage = process.usage;
  return '<tr class="procs-row depth-' + depth + (process.orphan ? " is-orphan" : "") + '"' + (pending ? ' aria-busy="true"' : "") + ">" +
    '<td class="procs-pid mono">' + process.pid + "</td>" +
    '<td class="procs-name" title="' + escapeHTML(command) + '"><span class="procs-title">' + escapeHTML(process.name) + "</span>" +
    (process.orphan ? '<span class="tag tag-warn">Orphan</span>' : "") +
    (image ? '<span class="procs-path">' + escapeHTML(image) + "</span>" : "") +
    (process.note ? '<span class="procs-note">' + escapeHTML(process.note) + "</span>" : "") + "</td>" +
    '<td class="procs-device"><span' + (process.deviceUDID ? ' title="' + escapeHTML(process.deviceUDID) + '"' : "") + ">" + escapeHTML(device) + "</span></td>" +
    '<td class="procs-num mono">' + formatCpu(usage && usage.cpu) + "</td>" +
    '<td class="procs-num mono">' + (usage ? formatMemory(usage.memory) : "—") + "</td>" +
    '<td class="procs-up mono">' + escapeHTML(formatUptime(process.startedAt, now)) + "</td>" +
    (canStop
      ? '<td class="procs-act"><button class="btn btn-sm btn-danger" type="button" data-act="kill:' + process.pid + '"' +
        ' aria-label="' + escapeHTML((self ? "Stop this viewer's server, " : "Stop " + process.name + ", ") + "PID " + process.pid) + '"' +
        (pending ? " disabled" : "") + ">" + (pending ? "Stopping…" : "Kill") + "</button></td>"
      : "") + "</tr>";
}

async function killProcess(pid) {
  const data = procs.data;
  if (!processesCanStop() || !data || procs.pending.has(pid)) return;
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
    const result = await apiJSON("api/v1/processes/" + pid + "/kill", { method: "POST", body: JSON.stringify({ confirm: !!(question && question.self) }) });
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
  if (!processesCanStop() || !procs.data || !procs.data.orphans || procs.pending.has("orphans")) return;
  procs.pending.add("orphans");
  renderProcesses();
  try {
    const result = await apiJSON("api/v1/processes/kill-orphans", { method: "POST" });
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
