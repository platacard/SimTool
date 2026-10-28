// Pure viewer logic: no DOM, no network, no timers. Everything here is
// exercised on its own in JavaScriptCore (WebViewerLogicTests), so the page
// can only disagree with the tests where it touches the browser.

// ---- Time, sizes, counts ----

function pad2(value) { return String(value).padStart(2, "0"); }

// One clock for the whole viewer: local time, HH:MM:SS, milliseconds when asked.
// Anything unparseable shows as it came, so a bad timestamp is visible rather than hidden.
function formatClock(value, withMilliseconds) {
  if (value == null || value === "") return "";
  const date = value instanceof Date ? value : new Date(typeof value === "number" ? value * 1000 : value);
  if (isNaN(date.getTime())) return String(value);
  const clock = pad2(date.getHours()) + ":" + pad2(date.getMinutes()) + ":" + pad2(date.getSeconds());
  return withMilliseconds ? clock + "." + String(date.getMilliseconds()).padStart(3, "0") : clock;
}

// "20 Oct 12:31" — a day no reader can take for a month.
function formatDayTime(value) {
  const date = value instanceof Date ? value : new Date(value);
  if (isNaN(date.getTime())) return "";
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  return date.getDate() + " " + months[date.getMonth()] + " " + pad2(date.getHours()) + ":" + pad2(date.getMinutes());
}

function formatAgo(value, now) {
  const date = value instanceof Date ? value : new Date(value);
  if (isNaN(date.getTime())) return "";
  const seconds = Math.max(0, Math.round(((now == null ? Date.now() : now) - date.getTime()) / 1000));
  if (seconds < 45) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return minutes + " min ago";
  const hours = Math.round(minutes / 60);
  if (hours < 24) return hours + " h ago";
  return formatDayTime(date);
}

function formatDuration(milliseconds) {
  if (milliseconds == null || !isFinite(milliseconds)) return "—";
  if (milliseconds < 1000) return Math.round(milliseconds) + " ms";
  const seconds = milliseconds / 1000;
  return (seconds < 10 ? seconds.toFixed(2) : seconds < 100 ? seconds.toFixed(1) : Math.round(seconds)) + " s";
}

function formatBytes(bytes) {
  if (bytes == null || !isFinite(bytes)) return "—";
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " kB";
  return (bytes / 1024 / 1024).toFixed(1) + " MB";
}

// Seconds as m:ss for recordings.
function formatOffset(seconds) {
  if (!isFinite(seconds) || seconds < 0) seconds = 0;
  return Math.floor(seconds / 60) + ":" + pad2(Math.floor(seconds % 60));
}

function formatCount(value) {
  return Number(value || 0).toLocaleString("en-US");
}

function plural(count, one, many) {
  return formatCount(count) + " " + (count === 1 ? one : many);
}

// "com.apple.CoreSimulator.SimRuntime.iOS-26-4" → "iOS 26.4"
// A device-specific runtime (iOS-27-2-iPhone19-4, the iPhone Duo's) names the
// OS version first and the model after it; the model is the device's, not the OS's.
function runtimeName(identifier) {
  if (!identifier) return "";
  const match = /SimRuntime\.([A-Za-z]+)-(\d+(?:-\d+)*?)(?:-[A-Za-z]+\d+-\d+)?$/.exec(identifier);
  if (!match) return identifier;
  return match[1] + " " + match[2].replace(/-/g, ".");
}

// ---- Network ----

const GRPC_CODES = ["OK", "CANCELLED", "UNKNOWN", "INVALID_ARGUMENT", "DEADLINE_EXCEEDED", "NOT_FOUND", "ALREADY_EXISTS",
  "PERMISSION_DENIED", "RESOURCE_EXHAUSTED", "FAILED_PRECONDITION", "ABORTED", "OUT_OF_RANGE", "UNIMPLEMENTED",
  "INTERNAL", "UNAVAILABLE", "DATA_LOSS", "UNAUTHENTICATED"];
// Codes that say the caller asked for something the server would not do — the
// app's own problem, not the server's.
const GRPC_CLIENT_CODES = [1, 3, 5, 6, 7, 9, 10, 11, 16];

function grpcCodeName(code) {
  const number = Number(code);
  return Number.isInteger(number) && GRPC_CODES[number] ? GRPC_CODES[number] : String(code);
}

// ---- Any protocol: calls, and each stream as one session ----

const PROTOCOL_LABELS = { http: "HTTP", grpc: "gRPC", websocket: "WS", sse: "SSE", mqtt: "MQTT", graphql: "GraphQL" };

// A protocol as a row and the filter name it: its known name, else as the app's logger did.
function protocolLabel(name) {
  const key = String(name || "").toLowerCase();
  return PROTOCOL_LABELS[key] || (key.length <= 4 ? key.toUpperCase() : key);
}

// The protocols the filter offers: HTTP and gRPC always, then every other one heard, by name.
function networkProtocols(events) {
  const heard = new Set();
  for (const event of events || []) if (event.protocol && event.protocol !== "http" && event.protocol !== "grpc") heard.add(event.protocol);
  return ["http", "grpc"].concat([...heard].sort());
}

const STREAM_CONNECTION_KINDS = ["connecting", "connected", "disconnected", "error"];

// A session's events in the order they happened: the logger's sequence, then time.
function frameOrder(a, b) {
  const left = a.stream.sequence, right = b.stream.sequence;
  if (left != null && right != null && left !== right) return left - right;
  return (Date.parse(a.timestamp) || 0) - (Date.parse(b.timestamp) || 0);
}

// The list's rows: calls as they are, and each stream session as one row that
// holds its events. A session whose events are the ones `previous` held for it
// is that same object, so what is worked out once for a row stays worked out.
function networkItems(events, previous) {
  const items = [];
  const grouped = new Map();
  for (const event of events || []) {
    if (!event.stream) { items.push(event); continue; }
    let frames = grouped.get(event.stream.sessionId);
    if (!frames) { frames = []; grouped.set(event.stream.sessionId, frames); items.push(event.stream.sessionId); }
    frames.push(event);
  }
  return items.map((item) => typeof item === "string" ? streamSession(item, grouped.get(item), previous) : item);
}

function streamSession(id, frames, previous) {
  const key = "stream:" + id;
  const signature = frames.length + "|" + frames[0].id + "|" + frames[frames.length - 1].id;
  const held = previous && previous.get(key);
  if (held && held.signature === signature) return held;
  frames.sort(frameOrder);
  const times = frames.map((frame) => Date.parse(frame.timestamp)).filter(Number.isFinite);
  const start = times.length ? Math.min(...times) : NaN, end = times.length ? Math.max(...times) : NaN;
  const described = frames.find((frame) => frame.request && (frame.request.url || frame.request.path)) || frames[0];
  const handshake = frames.find((frame) => frame.request && Object.keys(frame.request.headers || {}).length);
  const subprotocol = (frames.find((frame) => frame.stream.subprotocol) || { stream: {} }).stream.subprotocol || "";
  return {
    id: key,
    session: id,
    signature,
    protocol: frames[0].protocol,
    subprotocol,
    frames,
    launchId: frames[0].launchId,
    appBundleID: frames[0].appBundleID,
    mocked: false,
    timestamp: Number.isFinite(end) ? new Date(end).toISOString() : frames[frames.length - 1].timestamp,
    startedAt: Number.isFinite(start) ? new Date(start).toISOString() : frames[0].timestamp,
    durationMilliseconds: Number.isFinite(start) ? end - start : 0,
    request: Object.assign({}, described.request, { headers: handshake ? handshake.request.headers : {} })
  };
}

// How a close reads. A WebSocket's normal codes are plain; one that says the
// connection or the server broke is red, any other amber. A gRPC stream's
// status by its class, as a call's. Other protocols' codes say nothing about it.
function closeSeverity(protocol, code) {
  if (code == null) return "info";
  if (protocol === "websocket") return [1000, 1001, 1005].includes(code) ? "info" : [1006, 1011, 1012, 1013, 1014, 1015].includes(code) ? "err" : "warn";
  if (protocol === "grpc") return code === 0 ? "info" : GRPC_CLIENT_CODES.includes(code) ? "warn" : "err";
  return "info";
}

// A session's state, from its connection's last lifecycle event: connecting,
// open, closed with its code, failed. A refused subscription turns an open one amber.
function streamStatus(session) {
  let state = null, refused = null;
  const channels = new Set();
  for (const frame of session.frames) {
    const stream = frame.stream;
    if (!stream.direction && STREAM_CONNECTION_KINDS.includes(stream.kind)) state = frame;
    if (stream.kind === "subscribed" && stream.channel) channels.add(stream.channel);
    if ((stream.kind === "unsubscribed" || stream.kind === "subscriptionError") && stream.channel) channels.delete(stream.channel);
    if (stream.kind === "subscriptionError") refused = frame;
  }
  const kind = state ? state.stream.kind : null;
  if (kind === "error") {
    return { text: "Failed", severity: "err", title: (state.error && state.error.message) || state.stream.reason || "The connection failed", code: state.stream.code };
  }
  if (kind === "disconnected") {
    const code = state.stream.code;
    const title = ["Closed", code != null ? "code " + code : "", state.stream.reason || ""].filter(Boolean).join(" · ");
    return { text: "Closed" + (code != null ? " " + code : ""), severity: closeSeverity(session.protocol, code), title, code };
  }
  if (kind === "connecting") return { text: "Connecting…", severity: "pending", title: "Not open yet" };
  const text = "Open" + (channels.size ? " · " + channels.size + " ch" : "");
  if (refused) {
    return { text, severity: "warn", title: "Refused " + (refused.stream.channel || "a channel") + (refused.stream.reason ? ": " + refused.stream.reason : ""), code: refused.stream.code };
  }
  return { text, severity: "ok", title: channels.size ? "Open · " + plural(channels.size, "channel", "channels") + " subscribed" : "Open" };
}

// A stream event in one line: its payload, or what happened to the connection or the channel.
function frameSummary(frame) {
  const stream = frame.stream;
  if (stream.payloadPreview) {
    if (stream.payloadEncoding === "base64") return "Binary · " + formatBytes(stream.payloadByteCount != null ? stream.payloadByteCount : Math.floor(stream.payloadPreview.length * 3 / 4));
    return stream.payloadPreview.replace(/\s+/g, " ").slice(0, 300);
  }
  return [stream.code != null ? String(stream.code) : "", stream.reason || "", frame.error && frame.error.message || ""].filter(Boolean).join(" · ");
}

// Severity is "ok", "info" (neither good nor bad: redirects, not-modified),
// "warn" (the client's request was refused), "err" (the server or transport
// failed), or "pending" (no answer yet).
function networkStatus(event) {
  if (event.frames) return streamStatus(event);
  if (event.error) {
    return { text: "Failed", severity: "err", title: event.error.message || "The request failed" };
  }
  const response = event.response;
  if (event.protocol !== "http" && event.protocol !== "grpc") {
    // A protocol SimTool knows nothing of: its status as the app gave it; finished without an error is fine.
    if (!response) return { text: "Pending", severity: "pending", title: "No answer yet" };
    const text = response.status || (response.statusCode != null ? String(response.statusCode) : "Done");
    return { text, severity: "ok", title: protocolLabel(event.protocol) + " " + text, code: response.statusCode };
  }
  if (event.protocol === "grpc") {
    if (!response || response.grpcStatusCode == null || response.grpcStatusCode === "") {
      return { text: "Pending", severity: "pending", title: "No status yet" };
    }
    const code = Number(response.grpcStatusCode);
    const name = grpcCodeName(response.grpcStatusCode);
    const severity = code === 0 ? "ok" : GRPC_CLIENT_CODES.indexOf(code) >= 0 ? "warn" : "err";
    const title = response.grpcStatusMessage ? name + " — " + response.grpcStatusMessage : name;
    return { text: code === 0 ? "OK" : name, severity, title, code };
  }
  if (!response || response.statusCode == null) {
    return { text: "Pending", severity: "pending", title: "No response yet" };
  }
  const status = response.statusCode;
  const severity = status >= 500 ? "err" : status >= 400 ? "warn" : status >= 300 ? "info" : "ok";
  return { text: String(status), severity, title: "HTTP " + status, code: status };
}

// 4xx, client gRPC codes and failed calls: what the Problems filter keeps.
function isNetworkProblem(event) {
  return ["err", "warn"].includes(networkStatus(event).severity);
}

// The marks a list of calls carries: failures in red, client-side problems
// (4xx, UNAUTHENTICATED…) in amber — the colours their rows use.
function networkMarks(events) {
  let failed = 0, problems = 0;
  for (const event of events) {
    const severity = networkStatus(event).severity;
    if (severity === "err") failed++;
    else if (severity === "warn") problems++;
  }
  return [{ count: failed, tone: "err", one: "failed", many: "failed" }, { count: problems, tone: "warn", one: "client error", many: "client errors" }];
}

function requestPath(event) {
  const request = event.request || {};
  if (event.protocol === "grpc") {
    return request.path || "/" + [request.grpcService, request.grpcMethod].filter(Boolean).join("/");
  }
  return request.url || request.path || "";
}

function lastPathSegment(rawPath) {
  if (!rawPath) return "";
  let path = String(rawPath);
  const cut = path.search(/[?#]/);
  if (cut >= 0) path = path.slice(0, cut);
  const segments = path.replace(/\/+$/, "").split("/").filter(Boolean);
  return segments.length ? segments[segments.length - 1] : path;
}

// What a row calls a request: the method name for gRPC, the last path segment
// for HTTP, the operation for another protocol; a session, where it connects.
function requestName(event) {
  const request = event.request || {};
  if (event.protocol === "grpc") return request.grpcMethod || lastPathSegment(requestPath(event)) || "call";
  if (event.frames) return lastPathSegment(requestPath(event)) || event.subprotocol || protocolLabel(event.protocol);
  if (event.protocol !== "http") return request.method || lastPathSegment(requestPath(event)) || request.host || protocolLabel(event.protocol);
  return lastPathSegment(requestPath(event)) || request.host || "request";
}

// Where it went: the service for gRPC, host + path for a URL, the target as
// the app gave it otherwise; a session adds what runs over it.
function requestWhere(event) {
  const where = requestPlace(event);
  return event.subprotocol ? [where, event.subprotocol].filter(Boolean).join(" · ") : where;
}

function requestPlace(event) {
  const request = event.request || {};
  if (event.protocol === "grpc") return request.grpcService || request.grpcAuthority || "";
  const raw = requestPath(event);
  if (!request.url && raw && raw[0] !== "/") return raw;
  try {
    const url = new URL(raw, "http://localhost");
    return (request.host || url.host) + url.pathname + url.search;
  } catch (_) {
    return raw;
  }
}

// The path a filter chip keeps: no host, no query; gRPC keeps service/method,
// and a target that is not a URL stays whole.
function chipPathForEvent(event) {
  const raw = requestPath(event);
  if (!raw || event.protocol === "grpc" || (!(event.request || {}).url && raw[0] !== "/")) return raw;
  try { return new URL(raw, "http://localhost").pathname; } catch (_) { return raw; }
}

function networkSize(event) {
  return messageByteCount(event, "response");
}

// What one side of a call carried, in bytes, as the app's logger reported it;
// for a session, what its messages carried that way. A gRPC message it left
// uncounted is 0 when its preview is a complete message with no fields:
// protobuf puts such a message on the wire as no bytes at all, and loggers
// tend to count an empty message as nothing. Null when unknown.
function messageByteCount(event, side) {
  if (event.frames) {
    const direction = side === "request" ? "out" : "in";
    let total = null;
    for (const frame of event.frames) {
      if (frame.stream.direction === direction && frame.stream.payloadByteCount != null) total = (total || 0) + frame.stream.payloadByteCount;
    }
    return total;
  }
  const part = (side === "request" ? event.request : event.response) || {};
  const reported = event.protocol === "grpc" ? part.messageByteCount : part.bodyByteCount;
  if (reported != null) return reported;
  if (event.protocol !== "grpc" || !part.bodyPreview) return null;
  const parsed = parseBodyTree(part.bodyPreview);
  return parsed.format === "proto" && parsed.complete && !parsed.root.children.length ? 0 : null;
}

function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'";
}

function curlCommand(event) {
  const request = event.request || {};
  const parts = ["curl"];
  const method = (request.method || "GET").toUpperCase();
  if (method !== "GET") parts.push("-X " + method);
  parts.push(shellQuote(request.url || ("https://" + (request.host || "") + (request.path || ""))));
  for (const [name, value] of Object.entries(request.headers || {})) parts.push("-H " + shellQuote(name + ": " + value));
  if (request.bodyPreview) parts.push("--data-raw " + shellQuote(request.bodyPreview));
  return parts.join(" \\\n  ");
}

function grpcurlCommand(event) {
  const request = event.request || {};
  const parts = ["grpcurl"];
  for (const [name, value] of Object.entries(request.metadata || {})) parts.push("-H " + shellQuote(name + ": " + value));
  if (request.bodyPreview) parts.push("-d " + shellQuote(request.bodyPreview));
  parts.push(request.grpcAuthority || request.host || "<host:port>");
  parts.push((request.grpcService || "") + "/" + (request.grpcMethod || lastPathSegment(requestPath(event))));
  return parts.join(" \\\n  ");
}

// A `mocks:` entry for a YAML test that answers this request the way it was
// answered now — the fastest way from "this call misbehaved" to a test that stages it.
function mockYaml(event) {
  const target = event.protocol === "grpc"
    ? "*/" + (event.request && event.request.grpcMethod ? event.request.grpcMethod : lastPathSegment(requestPath(event)))
    : chipPathForEvent(event);
  const lines = ["mocks:", "  - method: " + JSON.stringify(target)];
  const status = networkStatus(event);
  const body = event.response && event.response.bodyPreview;
  if (event.protocol === "grpc" && status.severity !== "ok" && status.severity !== "pending") {
    lines.push("    error: " + grpcCodeName(event.response.grpcStatusCode).toLowerCase());
  } else if (body) {
    let compact = body;
    try { compact = JSON.stringify(JSON.parse(body)); } catch (_) { compact = JSON.stringify(body); }
    lines.push("    body: " + compact);
  } else {
    lines.push("    body: {}");
  }
  return lines.join("\n");
}

// Events pushed by the server joined to the ones held: a known id is replaced
// where it stands, a new one goes last, and only the newest `max` calls and,
// apart from them, the newest `streamMax` stream events are kept — as many as
// the server keeps.
function mergeNetworkEvents(held, incoming, max, streamMax) {
  const merged = held.slice();
  const index = new Map(merged.map((event, position) => [event.id, position]));
  for (const event of incoming || []) {
    if (index.has(event.id)) merged[index.get(event.id)] = event;
    else { index.set(event.id, merged.length); merged.push(event); }
  }
  if (streamMax == null) return merged.length > max ? merged.slice(merged.length - max) : merged;
  let calls = 0, frames = 0;
  for (const event of merged) if (event.stream) frames++; else calls++;
  let dropCalls = Math.max(0, calls - max), dropFrames = Math.max(0, frames - streamMax);
  if (!dropCalls && !dropFrames) return merged;
  return merged.filter((event) => {
    if (event.stream) return dropFrames > 0 ? (dropFrames--, false) : true;
    return dropCalls > 0 ? (dropCalls--, false) : true;
  });
}

// ---- Filters: live text + include/exclude chips ----

// ---- A call's detail: bodies as trees, search hits, what its status says ----

const HTTP_STATUS_TEXT = {
  100: "Continue", 101: "Switching Protocols", 200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 206: "Partial Content",
  301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect",
  400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable",
  408: "Request Timeout", 409: "Conflict", 410: "Gone", 412: "Precondition Failed", 413: "Content Too Large", 415: "Unsupported Media Type",
  422: "Unprocessable Content", 429: "Too Many Requests", 500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway",
  503: "Service Unavailable", 504: "Gateway Timeout"
};

function httpStatusText(code) {
  return HTTP_STATUS_TEXT[Number(code)] || "";
}

// An URL's query as [name, value] pairs, decoded, in order; none for gRPC paths.
function queryParams(url) {
  const raw = String(url || "");
  const start = raw.indexOf("?");
  if (start < 0) return [];
  const query = raw.slice(start + 1).split("#")[0];
  const decode = (part) => { try { return decodeURIComponent(part.replace(/\+/g, " ")); } catch (_) { return part; } };
  return query.split("&").filter(Boolean).map((pair) => {
    const equals = pair.indexOf("=");
    return equals < 0 ? [decode(pair), ""] : [decode(pair.slice(0, equals)), decode(pair.slice(equals + 1))];
  });
}

// A body as a tree a person can fold: JSON, or the protobuf text format gRPC
// loggers print (`Type:\nfield: value\nnested {\n…\n}`). A logger keeps only
// a preview, so a body cut short still reads as far as it goes: `complete`
// says whether it ended where it should.
// A node: { key, kind: "object" | "array" | "message" | "value", type: "str" | "num" | "lit" | "null" | "enum", text, children }.
function parseBodyTree(text) {
  const body = String(text == null ? "" : text);
  if (!body.trim()) return { format: "empty", root: null, complete: true };
  const trimmed = body.trim();
  if (trimmed[0] === "{" || trimmed[0] === "[") {
    try { return { format: "json", root: jsonNode(null, JSON.parse(trimmed)), complete: true }; } catch (_) { /* a cut preview or not JSON */ }
  }
  const proto = parseProtoText(body);
  if (proto) return proto;
  return { format: "text", root: null, complete: true };
}

function jsonNode(key, value) {
  if (Array.isArray(value)) return { key, kind: "array", children: value.map((item, index) => jsonNode(String(index), item)) };
  if (value && typeof value === "object") return { key, kind: "object", children: Object.keys(value).map((name) => jsonNode(name, value[name])) };
  if (typeof value === "string") return { key, kind: "value", type: "str", text: JSON.stringify(value), value };
  if (typeof value === "number") return { key, kind: "value", type: "num", text: String(value), value: String(value) };
  if (value === null) return { key, kind: "value", type: "null", text: "null", value: "null" };
  return { key, kind: "value", type: "lit", text: String(value), value: String(value) };
}

// Protobuf text format, line by line. Null when the text does not read as it.
function parseProtoText(body) {
  const lines = body.split("\n");
  let index = 0;
  let typeName = null;
  const first = lines[0].trim();
  if (/^[A-Za-z_][\w.]*:$/.test(first)) { typeName = first.slice(0, -1); index = 1; }
  const root = { key: null, kind: "message", typeName, children: [] };
  const stack = [root];
  let fields = 0;
  let complete = true;
  for (; index < lines.length; index++) {
    const line = lines[index].trim();
    if (!line) continue;
    if (line === "}") {
      if (stack.length === 1) return null;
      stack.pop();
      continue;
    }
    let match = /^([A-Za-z_][\w.\[\]/]*)\s*:?\s*\{$/.exec(line);
    if (match) {
      const node = { key: match[1], kind: "message", children: [] };
      stack[stack.length - 1].children.push(node);
      stack.push(node);
      fields++;
      continue;
    }
    match = /^([A-Za-z_][\w.\[\]/]*)\s*:\s*(.*)$/.exec(line);
    if (match) {
      const raw = match[2];
      let type = "enum";
      let value = raw;
      if (/^".*"$/.test(raw) && raw.length > 1) { type = "str"; value = unquoteProto(raw.slice(1, -1)); }
      else if (raw[0] === '"') { type = "str"; value = unquoteProto(raw.slice(1)); complete = false; }
      else if (/^-?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?f?$/.test(raw) || /^-?(inf|nan)$/i.test(raw)) type = "num";
      else if (raw === "true" || raw === "false") type = "lit";
      else if (!/^[A-Za-z_][\w]*$/.test(raw)) type = "raw";
      stack[stack.length - 1].children.push({ key: match[1], kind: "value", type, text: raw, value });
      fields++;
      continue;
    }
    // The last line of a cut preview may stop anywhere.
    if (index === lines.length - 1 || lines.slice(index + 1).every((rest) => !rest.trim())) { complete = false; continue; }
    return null;
  }
  if (!fields && !typeName) return null;
  if (stack.length > 1) complete = false;
  return { format: "proto", root, complete };
}

function unquoteProto(text) {
  return text.replace(/\\(["'\\])/g, "$1").replace(/\\n/g, "\n").replace(/\\t/g, "\t");
}

// How many nodes a tree holds, itself included.
function treeSize(node) {
  if (!node) return 0;
  return 1 + (node.children || []).reduce((sum, child) => sum + treeSize(child), 0);
}

// What a search runs over in a call, field by field (lowercased): its URL or
// method path, method, status, host, both sides' headers or metadata, both bodies.
function networkSearchFields(event) {
  const request = event.request || {};
  const response = event.response || {};
  const status = networkStatus(event);
  const headerLines = (entries) => Object.entries(entries || {}).map(([name, value]) => name + ": " + value).join("\n");
  const custom = event.protocol !== "http" && event.protocol !== "grpc";
  const fields = event.frames ? streamSearchFields(event, status, headerLines) : {
    url: requestPath(event),
    method: event.protocol === "grpc" ? "grpc " + (request.grpcMethod || "") : custom ? event.protocol + " " + (request.method || "") : request.method || "",
    status: [status.text, status.title, response.statusCode, response.status, response.grpcStatusCode, response.grpcStatusMessage, event.error && event.error.message].filter((part) => part != null && part !== "").join(" "),
    host: request.host || request.grpcAuthority || "",
    reqheader: headerLines(event.protocol === "grpc" ? request.metadata : custom ? Object.assign({}, request.headers, request.metadata) : request.headers),
    resheader: headerLines(event.protocol === "grpc" ? response.metadata : custom ? Object.assign({}, response.headers, response.metadata) : response.headers),
    reqbody: request.bodyPreview || "",
    resbody: response.bodyPreview || "",
    channel: "",
    mock: event.mocked ? "mocked " + (event.mockRuleId || "") : ""
  };
  for (const name of Object.keys(fields)) fields[name] = String(fields[name]).toLowerCase();
  fields.header = fields.reqheader + "\n" + fields.resheader;
  fields.body = fields.reqbody + "\n" + fields.resbody;
  return fields;
}

// A session's fields: its messages' payloads are its bodies — what the app
// sent, what it received — and their metadata its response headers.
function streamSearchFields(session, status, headerLines) {
  const request = session.request || {};
  const sent = [], received = [], codes = [], metadata = [], channels = new Set();
  for (const frame of session.frames) {
    const stream = frame.stream;
    if (stream.payloadPreview) (stream.direction === "out" ? sent : received).push(stream.payloadPreview);
    if (stream.code != null || stream.reason) codes.push([stream.code, stream.reason].filter((part) => part != null && part !== "").join(" "));
    if (frame.error && frame.error.message) codes.push(frame.error.message);
    if (Object.keys(stream.metadata || {}).length) metadata.push(headerLines(stream.metadata));
    if (stream.channel) channels.add(stream.channel);
  }
  return {
    url: requestPath(session),
    method: [session.protocol, protocolLabel(session.protocol), session.subprotocol].filter(Boolean).join(" "),
    status: [status.text, status.title].concat(codes).join(" "),
    host: request.host || request.grpcAuthority || "",
    reqheader: headerLines(Object.assign({}, request.headers, request.metadata)),
    resheader: metadata.join("\n"),
    reqbody: sent.join("\n"),
    resbody: received.join("\n"),
    channel: [...channels].join("\n"),
    mock: ""
  };
}

const NETWORK_FILTER_FIELDS = ["url", "method", "status", "host", "header", "body", "channel"];

// Where a term is found in a call, in the order the detail shows them: the
// first is where the detail opens. Empty when it is not there.
function networkHits(fields, term, field) {
  const needle = String(term || "").toLowerCase();
  if (!needle) return [];
  const places = [["url", "url"], ["method", "method"], ["status", "status"], ["host", "host"], ["channel", "channel"], ["reqheader", "request headers"],
    ["reqbody", "request body"], ["resheader", "response headers"], ["resbody", "response body"], ["mock", "mock"]];
  const scope = field === "header" ? ["reqheader", "resheader"] : field === "body" ? ["reqbody", "resbody"] : field ? [field] : null;
  return places.filter(([name]) => (!scope || scope.includes(name)) && fields[name].indexOf(needle) >= 0).map(([, label]) => label);
}

// Text with every case-insensitive occurrence of `needle` marked, escaped for HTML.
function markHTML(text, needle) {
  const escape = (value) => String(value).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const source = String(text == null ? "" : text);
  if (!needle) return escape(source);
  const lower = source.toLowerCase(), find = String(needle).toLowerCase();
  let out = "", at = 0, hit;
  while (find && (hit = lower.indexOf(find, at)) >= 0) {
    out += escape(source.slice(at, hit)) + "<mark>" + escape(source.slice(hit, hit + find.length)) + "</mark>";
    at = hit + find.length;
  }
  return out + escape(source.slice(at));
}

// "field:text" scopes a term to one field instead of the whole haystack.
// Only fields from the allowed list count; anything else (say, an URL's
// "https:") stays a plain substring term.
function parseFieldTerm(text, allowedFields) {
  const colon = text.indexOf(":");
  if (colon > 0 && allowedFields) {
    const field = text.slice(0, colon).trim().toLowerCase();
    const term = text.slice(colon + 1).trim();
    if (term && allowedFields.indexOf(field) >= 0) return { field, term };
  }
  return { field: null, term: text };
}

function termMatches(term, field, hay, fields) {
  const needle = String(term).toLowerCase();
  if (field) return !!fields && (fields[field] || "").indexOf(needle) >= 0;
  return hay.indexOf(needle) >= 0;
}

// Exclude chips win over include chips; include chips are OR'd ("show only
// these"); the live input text is an extra substring filter on top.
function matchesFilters(hay, chips, query, fields, queryField) {
  for (const chip of chips) {
    if (chip.kind === "exclude" && termMatches(chip.term, chip.field, hay, fields)) return false;
  }
  const includes = chips.filter((chip) => chip.kind === "include");
  if (includes.length && !includes.some((chip) => termMatches(chip.term, chip.field, hay, fields))) return false;
  return !query || termMatches(query, queryField, hay, fields);
}

// Adding a chip replaces any chip with the same field+term (either kind),
// so an exclude flips an identical include instead of stacking next to it.
function chipKey(field, term) {
  return (field || "") + ":" + String(term).toLowerCase();
}

function withChip(chips, kind, term, field) {
  const trimmed = String(term).trim();
  if (!trimmed) return chips;
  const key = chipKey(field, trimmed);
  const next = chips.filter((chip) => chipKey(chip.field, chip.term) !== key);
  next.push(field ? { kind, term: trimmed, field } : { kind, term: trimmed });
  return next;
}

// ---- Logs ----

const LOG_LEVELS = ["Debug", "Info", "Default", "Error", "Fault"];

// Severity comes from the level the log carries — never from words in the
// message: "error:0" in an Info line is not an error.
function logLevel(entry) {
  const level = String(entry.level || "").toLowerCase();
  for (const known of LOG_LEVELS) if (known.toLowerCase() === level) return known;
  return "Default";
}

function isLogError(entry) {
  const level = logLevel(entry);
  return level === "Error" || level === "Fault";
}

function logFields(entry) {
  return {
    message: String(entry.message || "").toLowerCase(),
    subsystem: String(entry.subsystem || "").toLowerCase(),
    category: String(entry.category || "").toLowerCase(),
    process: String(entry.process || "").toLowerCase(),
    level: logLevel(entry).toLowerCase()
  };
}

function logLine(entry) {
  const head = [formatClock(entry.timestamp, true), logLevel(entry), entry.subsystem].filter(Boolean).join(" ");
  return head + ": " + (entry.message || "");
}

// ---- Table columns: their order, widths and which are shown, as a person left them ----
// A table's spec: its column keys in their default order, their names and
// default widths, the one flexible column that takes what is left (and is
// never hidden), the columns off until a person shows them, and the columns
// each narrower step of the pane drops.

const LOG_COLUMNS = {
  keys: ["time", "level", "subsystem", "category", "process", "message"],
  labels: { time: "Time", level: "Level", subsystem: "Subsystem", category: "Category", process: "Process", message: "Message" },
  widths: { time: 86, level: 62, subsystem: 160, category: 120, process: 110 },
  min: { time: 60, level: 48, subsystem: 60, category: 60, process: 60 },
  flex: "message", flexMin: 120,
  off: ["category", "process"],
  narrow: [["subsystem", "category", "process"]]          // ≤ 640 px
};

const NETWORK_COLUMNS = {
  keys: ["time", "method", "name", "status", "size", "duration", "wf"],
  labels: { time: "Finished", method: "Method", name: "Name", status: "Status", size: "Size", duration: "Duration", wf: "Waterfall" },
  widths: { time: 86, method: 46, status: 118, size: 62, duration: 64, wf: 90 },
  min: { time: 60, method: 40, status: 48, size: 44, duration: 48, wf: 40 },
  flex: "name", flexMin: 140,
  off: [],
  narrow: [["size", "wf"], ["size", "wf", "method"]]       // ≤ 760 px, ≤ 560 px
};

function clampColumnWidth(spec, key, width) {
  return Math.round(Math.max(spec.min[key] || 40, Math.min(640, Number(width) || spec.widths[key] || 100)));
}

// A saved layout made whole: every known column once, unknown ones dropped,
// widths in bounds; a column the saved one lacks goes after the one it
// follows by default, else first.
function columnLayout(spec, saved) {
  const list = Array.isArray(saved) ? saved.filter((column) => column && spec.keys.indexOf(column.key) >= 0) : [];
  const byKey = {};
  const order = [];
  for (const column of list) if (!byKey[column.key]) { byKey[column.key] = column; order.push(column.key); }
  spec.keys.forEach((key, index) => {
    if (order.indexOf(key) >= 0) return;
    const after = spec.keys.slice(0, index).reverse().find((previous) => order.indexOf(previous) >= 0);
    order.splice(after ? order.indexOf(after) + 1 : 0, 0, key);
  });
  return order.map((key) => {
    const column = byKey[key];
    if (key === spec.flex) return { key, width: null, hidden: false };
    return { key, width: clampColumnWidth(spec, key, column && column.width), hidden: column ? !!column.hidden : spec.off.indexOf(key) >= 0 };
  });
}

// The layout with `key` moved to stand before the column now at `before`
// (the length of the layout: last).
function moveColumn(layout, key, before) {
  const from = layout.findIndex((column) => column.key === key);
  if (from < 0) return layout;
  const next = layout.slice();
  const [column] = next.splice(from, 1);
  const to = Math.max(0, Math.min(next.length, before > from ? before - 1 : before));
  next.splice(to, 0, column);
  return next;
}

// The columns a row draws, in order: at full width (step 0), or at a narrower step of the pane.
function shownColumns(spec, layout, step) {
  const off = step ? spec.narrow[step - 1] || [] : [];
  return layout.filter((column) => !column.hidden && off.indexOf(column.key) < 0);
}

function gridTemplate(spec, layout, step) {
  return shownColumns(spec, layout, step).map((column) => column.key === spec.flex ? "minmax(" + spec.flexMin + "px, 1fr)" : column.width + "px").join(" ");
}

// The lines after the cursor: a line the page already has is never added twice,
// whichever way — stream, replay or poll — it arrives again.
function linesAfter(entries, cursor) {
  return cursor == null ? (entries || []).slice() : (entries || []).filter((entry) => entry.sequence > cursor);
}

// ---- State ----

// Nested models that are themselves tracked carry this marker in their
// snapshot object; the viewer folds their standalone history into the
// parent's diff and never renders the key itself.
const MODEL_ID_KEY = "$modelId";

// How many items of a list a diff names one by one; past that the list
// changed wholesale and is one line.
const STATE_ARRAY_DIFF_LIMIT = 5;
// A value longer than this is cut in a diff line or a tree row.
const STATE_TEXT_LIMIT = 160;

function diffStateValues(prev, next, path, out) {
  if (JSON.stringify(prev) === JSON.stringify(next)) return out;
  const isPlainObject = (value) => value && typeof value === "object" && !Array.isArray(value);
  if (isPlainObject(prev) && isPlainObject(next)) {
    const keys = Object.keys(prev).concat(Object.keys(next).filter((key) => !(key in prev)));
    for (const key of keys) {
      if (key === MODEL_ID_KEY) continue;
      diffStateValues(prev[key], next[key], path ? path + "." + key : key, out);
    }
    return out;
  }
  // A few items changed, added or dropped are named one by one — `items[3].name`;
  // a list that changed wholesale is one line, not a line per item.
  if (Array.isArray(prev) && Array.isArray(next)) {
    const changed = [];
    for (let index = 0; index < Math.max(prev.length, next.length) && changed.length <= STATE_ARRAY_DIFF_LIMIT; index++) {
      if (JSON.stringify(prev[index]) !== JSON.stringify(next[index])) changed.push(index);
    }
    if (changed.length <= STATE_ARRAY_DIFF_LIMIT) {
      for (const index of changed) diffStateValues(prev[index], next[index], path + "[" + index + "]", out);
      return out;
    }
  }
  out.push({ path, before: prev, after: next });
  return out;
}

// A model reported again by a newer launch of the app is a new instance, not a
// change: the process started over, and its own counter named the model again.
function stateSameInstance(previous, event) {
  return !!previous && (previous.launchId == null || event.launchId == null || previous.launchId === event.launchId);
}

// alive, deallocated, or ended — its process gave way to a newer launch of the
// app, which never says so for the models it took with it.
function stateModelStatus(event, newestLaunch) {
  if (event.deallocated) return "deallocated";
  if (event.launchId != null && newestLaunch != null && event.launchId < newestLaunch) return "ended";
  return "alive";
}

// One event into a State view { latest, changes, lastChange, newestLaunch }.
// `record` keeps what it changed. A model's first report, a new process's first
// report of it and a report in which nothing changed are not changes.
function foldStateEvent(view, event, record) {
  const known = view.latest[event.modelId];
  const previous = stateSameInstance(known, event) ? known : undefined;
  const diffs = event.deallocated ? [] : diffStateValues(previous ? previous.snapshot : undefined, event.snapshot, "", []);
  if (record) {
    if (event.deallocated || (previous && diffs.length)) view.changes.push({ event, diffs });
    if (!previous || event.deallocated) view.lastChange[event.modelId] = [];
    else if (diffs.length) view.lastChange[event.modelId] = diffs.map((diff) => diff.path);
  }
  // A deallocation carries no snapshot; the last known one shows what it held.
  view.latest[event.modelId] = event.deallocated && previous ? { ...event, snapshot: previous.snapshot } : event;
  if (event.launchId != null && !(view.newestLaunch >= event.launchId)) view.newestLaunch = event.launchId;
}

// A value as one short line. A list says what it holds in runs — `["<ATM>" ×300]` —
// and anything long is cut, so no diff runs to hundreds of lines.
function stateValueText(value) {
  if (value === undefined) return "—";
  const cut = (text) => text.length > STATE_TEXT_LIMIT ? text.slice(0, STATE_TEXT_LIMIT - 1) + "…" : text;
  if (!Array.isArray(value)) return cut(JSON.stringify(value));
  const runs = stateRuns(value).map((run) => run.text + (run.count > 1 ? " ×" + run.count : ""));
  const text = "[" + runs.join(", ") + "]";
  return text.length > STATE_TEXT_LIMIT ? cut(text.slice(0, -1)) + " " + value.length + " items]" : text;
}

// Consecutive equal items of a list: { start, count, text }.
function stateRuns(items) {
  const runs = [];
  items.forEach((item, index) => {
    const text = JSON.stringify(item);
    const last = runs[runs.length - 1];
    if (last && last.text === text) last.count++;
    else runs.push({ start: index, count: 1, text });
  });
  return runs;
}

// A list's rows in the snapshot tree: a run of the same plain value is one row,
// `[0…299]: "<ATM>" ×300`, not three hundred.
function stateArrayRows(items) {
  return stateRuns(items).flatMap((run) => {
    const item = items[run.start];
    if (run.count === 1 || (item && typeof item === "object")) {
      return Array.from({ length: run.count }, (_, offset) => ({ key: run.start + offset, label: "[" + (run.start + offset) + "]", count: 1 }));
    }
    return [{ key: run.start, label: "[" + run.start + "…" + (run.start + run.count - 1) + "]", count: run.count }];
  });
}

function collectEmbedded(value, ownerId, out) {
  if (!value || typeof value !== "object") return;
  if (Array.isArray(value)) { for (const item of value) collectEmbedded(item, ownerId, out); return; }
  const marker = value[MODEL_ID_KEY];
  if (typeof marker === "string" && marker !== ownerId) out[marker] = ownerId;
  for (const key of Object.keys(value)) if (key !== MODEL_ID_KEY) collectEmbedded(value[key], ownerId, out);
}

// childId → parentId for models embedded (expanded) inside another live
// tracked model's snapshot, from { modelId: latestEvent }. A child resurfaces
// on its own once its parent deallocates, or its process ends.
function embeddedModelIds(latestByModel, newestLaunch) {
  const embedded = {};
  for (const id of Object.keys(latestByModel)) {
    const event = latestByModel[id];
    if (stateModelStatus(event, newestLaunch) !== "alive") continue;
    collectEmbedded(event.snapshot, id, embedded);
  }
  return embedded;
}

// ---- Tests ----

const VERDICT_WORDS = {
  satisfied: { bug: "Bug not reproduced", feature: "Confirmed", none: "Claim holds" },
  unsatisfied: { bug: "Bug reproduced", feature: "Not confirmed", none: "Claim does not hold" },
  inconclusive: { bug: "Inconclusive", feature: "Inconclusive", none: "Inconclusive" },
  infra: { bug: "Infra — cannot be trusted", feature: "Infra — cannot be trusted", none: "Infra — cannot be trusted" }
};
const STATUS_WORDS = { running: "Running", passed: "Passed", failed: "Failed", interrupted: "Interrupted", stopped: "Stopped" };

// What a run means, in words: the verdict for kind-aware tests, the bare status otherwise.
function outcomeOf(session) {
  if (session.verdict && VERDICT_WORDS[session.verdict]) {
    const words = VERDICT_WORDS[session.verdict];
    return { tone: session.verdict, text: words[session.kind] || words.none };
  }
  return { tone: session.status, text: STATUS_WORDS[session.status] || String(session.status || "") };
}

// "✓ 2/5 Wait for label …" → { mark: "passed", index: 2, total: 5, text: "Wait for label …" }
function parseStepText(text) {
  const match = /^([✓✗◼●])\s*(\d+)\/(\d+)\s+(.*)$/.exec(String(text || ""));
  if (!match) return { mark: "note", text: String(text || "") };
  const marks = { "✓": "passed", "✗": "failed", "◼": "stopped", "●": "running" };
  return { mark: marks[match[1]], index: Number(match[2]), total: Number(match[3]), text: match[4] };
}

// Split a step's text into its short heading and the detail after " — ".
function splitStep(text) {
  const t = String(text || "").trim();
  const dash = t.indexOf(" — ");
  if (dash < 0) return { head: t, tail: "" };
  return { head: t.slice(0, dash).trim(), tail: t.slice(dash + 3).trim() };
}

// Video offset of an entry. The raw offset is the wall-clock span since the
// recorder started (at − recordingStartedAt, falling back to startedAt), but
// simctl's footage runs shorter than wall-clock — recorder startup/stop
// latency plus frame-rate drift under load — so a fixed anchor drifts ahead
// of the video and late steps can land past its end. When the real video
// length is known, scale the wall-clock span onto it; a no-op when the
// clocks agree.
function entryOffsetSeconds(session, entry) {
  const base = Date.parse(session.recordingStartedAt || session.startedAt);
  const at = Date.parse(entry.at);
  if (!isFinite(base) || !isFinite(at)) return 0;
  const raw = Math.max(0, (at - base) / 1000);
  const duration = session.videoDurationSeconds;
  const end = Date.parse(session.endedAt || "");
  if (isFinite(duration) && duration > 0 && isFinite(end)) {
    const span = (end - base) / 1000;
    if (span > 0) return Math.min(duration, (raw / span) * duration);
  }
  return raw;
}

function sessionDurationSeconds(session) {
  const duration = session.videoDurationSeconds;
  if (isFinite(duration) && duration > 0) return duration;
  const base = Date.parse(session.recordingStartedAt || session.startedAt);
  const end = Date.parse(session.endedAt || "");
  return isFinite(base) && isFinite(end) ? Math.max(0, (end - base) / 1000) : 0;
}

// The newest finished session of each test file.
function lastRunByFile(sessions) {
  const runs = {};
  for (const session of sessions) {
    if (!session.file || session.status === "running") continue;
    const known = runs[session.file];
    if (!known || Date.parse(session.startedAt) > Date.parse(known.startedAt)) runs[session.file] = session;
  }
  return runs;
}

// ---- Accessibility ----

// Whether a frame of the stream shows the screen changing. A still screen keeps
// sending small frames — the same picture encoded again, about 200 bytes on a
// phone — so the smallest frame seen is the measure of nothing happening, and a
// change costs several times that: a clock tick 600 bytes, a push tens of KB.
function frameChangesScreen(type, bytes, stillBytes) {
  if (type === "keyframe") return true;
  return bytes > Math.max(400, stillBytes * 2.5);
}

function axHasFrame(node) {
  const frame = node.frame;
  return !!(frame && frame.width > 0 && frame.height > 0);
}

// An element with nothing to say: no identifier, label, value or title — the
// anonymous containers that make AX trees deep without making them informative.
function axIsAnonymous(node) {
  return !node.accessibilityIdentifier && !(node.label && node.label.trim()) && !node.value && !node.title;
}

function axRoleName(node) {
  const role = String(node.role || node.type || "Element");
  return role.indexOf("AX") === 0 ? role.slice(2) : role;
}

function axTitle(node) {
  return node.accessibilityIdentifier || (node.label && node.label.trim()) || node.title || node.value || axRoleName(node);
}

// The selectors an element carries, in the order the YAML runner prefers them.
function axOwnSelectors(node) {
  const selectors = [];
  if (node.accessibilityIdentifier) selectors.push({ key: "id", value: node.accessibilityIdentifier });
  if (node.label && node.label.trim()) selectors.push({ key: "label", value: node.label.trim() });
  return selectors;
}

// How many elements of the tree a selector finds, matched as the runner and
// `simtool input` match: an id exactly, a label against the label or the title.
function axSelectorCount(roots, selector) {
  let count = 0;
  const walk = (node) => {
    if (selector.key === "id" ? node.accessibilityIdentifier === selector.value
      : (node.label || "").trim() === selector.value || (node.title || "").trim() === selector.value) count++;
    (node.children || []).forEach(walk);
  };
  (roots || []).forEach(walk);
  return count;
}

function axCentre(node) {
  const frame = node.frame;
  return frame && frame.width > 0 && frame.height > 0 ? { x: frame.x + frame.width / 2, y: frame.y + frame.height / 2 } : null;
}

// A selector that finds this element and nothing else, so a test step taps
// what was picked — the runner takes the first match, which for a shared id
// may be anywhere on the screen. Its own id or label when no other element has
// it; else the unique id or label of an element with the same centre: the
// runner taps centres, so that step lands on the very same point (a touch
// overlay and the view it covers, a cell and its content). `via` is that
// element. Null when nothing is unique: the step taps the centre. Without the
// tree (`roots`), the element's own selector, as it was before.
function axSelector(node, roots) {
  const own = axOwnSelectors(node);
  if (!roots) return own[0] || null;
  for (const selector of own) if (axSelectorCount(roots, selector) === 1) return selector;
  const centre = axCentre(node);
  if (!centre) return null;
  const twins = [];
  const walk = (other) => {
    const at = other !== node && axCentre(other);
    if (at && Math.abs(at.x - centre.x) <= 1 && Math.abs(at.y - centre.y) <= 1) twins.push(other);
    (other.children || []).forEach(walk);
  };
  roots.forEach(walk);
  // The nearest in size first: most often the very same frame.
  const gap = (other) => Math.abs(other.frame.width - node.frame.width) + Math.abs(other.frame.height - node.frame.height);
  twins.sort((a, b) => gap(a) - gap(b));
  for (const twin of twins) {
    for (const selector of axOwnSelectors(twin)) if (axSelectorCount(roots, selector) === 1) return { ...selector, via: twin };
  }
  return null;
}

function axYamlStep(node, roots, action) {
  const selector = axSelector(node, roots);
  const verb = action || "tap";
  if (!selector) {
    const frame = node.frame || {};
    return "- " + verb + ": { x: " + Math.round(frame.x + frame.width / 2) + ", y: " + Math.round(frame.y + frame.height / 2) + " }";
  }
  return "- " + verb + ": { " + selector.key + ": " + JSON.stringify(selector.value) + " }";
}

function axCliCommand(node, roots) {
  const selector = axSelector(node, roots);
  if (!selector) {
    const frame = node.frame || {};
    return "simtool input tap --x " + Math.round(frame.x + frame.width / 2) + " --y " + Math.round(frame.y + frame.height / 2);
  }
  return "simtool input tap --" + selector.key + " " + shellQuote(selector.value);
}

// Screen reference = the largest-area ROOT frame (the AXApplication, in points).
// Only roots are considered: some deep container groups report their frame in
// device pixels (e.g. 1206x2622 = 3x), which would otherwise hijack the reference.
function axScreenFrame(tree) {
  let best = null, bestArea = 0;
  for (const root of (tree && tree.roots) || []) {
    const frame = root.frame;
    if (!frame || !frame.width || !frame.height) continue;
    const area = frame.width * frame.height;
    if (area > bestArea) { bestArea = area; best = frame; }
  }
  return best;
}

// ---- Annotations: notes for an agent on what the screen shows ----

// An element as an annotation keeps it — what it is, what names it, where it
// was — so the note means the same after the screen has moved on.
function axSnapshot(node) {
  const frame = node.frame || {};
  return {
    role: axRoleName(node),
    id: node.accessibilityIdentifier || "",
    label: (node.label && node.label.trim()) || node.title || "",
    value: node.value == null ? "" : String(node.value),
    frame: { x: frame.x || 0, y: frame.y || 0, width: frame.width || 0, height: frame.height || 0 }
  };
}

// The elements in reading order: top to bottom, then left to right.
function axReadingOrder(nodes) {
  return nodes.slice().sort((a, b) => a.frame.y - b.frame.y || a.frame.x - b.frame.x);
}

// What a region holds: the elements a test can name that lie mostly inside it
// (half their area or more), in reading order. Roots — the app itself — never.
function axElementsInside(nodes, region) {
  const inside = [];
  for (const node of nodes) {
    if (!axHasFrame(node) || axIsAnonymous(node) || node._depth === 0) continue;
    const f = node.frame;
    const width = Math.min(f.x + f.width, region.x + region.width) - Math.max(f.x, region.x);
    const height = Math.min(f.y + f.height, region.y + region.height) - Math.max(f.y, region.y);
    if (width > 0 && height > 0 && width * height * 2 >= f.width * f.height) inside.push(node);
  }
  return axReadingOrder(inside);
}

// The element an annotation was made on, if the screen still shows it: the
// same role and names — its id and label, or its value when it has neither —
// within 2 pt of where it was. A screen that scrolled, turned or moved on has none.
function annotationNode(element, nodes) {
  const near = (a, b) => Math.abs(a - b) <= 2;
  for (const node of nodes) {
    if (!axHasFrame(node)) continue;
    const other = axSnapshot(node);
    if (other.role !== element.role || other.id !== element.id || other.label !== element.label) continue;
    if (!element.id && !element.label && other.value !== element.value) continue;
    const a = element.frame, b = other.frame;
    if (near(a.x, b.x) && near(a.y, b.y) && near(a.width, b.width) && near(a.height, b.height)) return node;
  }
  return null;
}

// Whether an annotation's target is on the screen now. A region is while at
// least half the elements it held still are; one that held none cannot tell,
// and stays.
function annotationOnScreen(item, nodes) {
  if (!item.region) return !!annotationNode(item.element || {}, nodes);
  const inside = item.inside || [];
  if (!inside.length) return true;
  return inside.filter((element) => annotationNode(element, nodes)).length * 2 >= inside.length;
}

const ANNOTATION_KINDS = { change: "Change", question: "Question" };
const ANNOTATION_INSIDE_MAX = 12;   // a region names this many of its elements, then counts the rest

// "16,540 361×52": a frame in whole points.
function annotationFrameText(frame) {
  return Math.round(frame.x) + "," + Math.round(frame.y) + " " + Math.round(frame.width) + "×" + Math.round(frame.height);
}

// Button "Transfer" (id: home.transfer, frame 16,540 361×52) — its value when
// it says more than the label; quotes as JSON, so a label's own quotes read.
function annotationElementText(element, withFrame) {
  const facts = [];
  if (element.id) facts.push("id: " + element.id);
  if (element.value && element.value !== element.label) facts.push("value: " + JSON.stringify(element.value));
  if (withFrame !== false && element.frame) facts.push("frame " + annotationFrameText(element.frame));
  return (element.role || "Element") + (element.label ? " " + JSON.stringify(element.label) : "") + (facts.length ? " (" + facts.join(", ") + ")" : "");
}

// One annotation in the prompt: its number, kind and target — a region with
// the elements it holds — then the person's words, indented under it.
function annotationPromptItem(item, number) {
  const indent = " ".repeat(String(number).length + 2);
  const head = number + ". [" + (ANNOTATION_KINDS[item.kind] || ANNOTATION_KINDS.change) + "] ";
  const lines = [];
  if (item.region) {
    const inside = item.inside || [];
    lines.push(head + "Region (frame " + annotationFrameText(item.region) + ")" + (inside.length ? " containing:" : ", no accessibility elements inside"));
    for (const element of inside.slice(0, ANNOTATION_INSIDE_MAX)) lines.push(indent + "- " + annotationElementText(element));
    if (inside.length > ANNOTATION_INSIDE_MAX) lines.push(indent + "- … and " + (inside.length - ANNOTATION_INSIDE_MAX) + " more");
  } else {
    lines.push(head + annotationElementText(item.element || {}));
  }
  for (const line of String(item.text || "").trim().split(/\r?\n/)) lines.push(line.trim() ? indent + line.trimEnd() : "");
  return lines.join("\n");
}

// Every annotation as one prompt for an agent, under a line naming the app and
// the device they were made on. Nothing to say, nothing to copy.
function annotationsPrompt(items, context) {
  if (!items || !items.length) return "";
  const where = context || {};
  const device = where.device ? where.device + (where.os ? " (" + where.os + ")" : "") : where.os || "";
  const head = ["SimTool annotations — " + plural(items.length, "item", "items"), where.app, device].filter(Boolean).join(" · ");
  return head + "\n\n" + items.map((item, index) => annotationPromptItem(item, index + 1)).join("\n");
}

// ---- A screen's picture on its framebuffer ----

// How far to turn a decoded frame for the screen it shows: the screen's
// rotation once the frame's shape is that screen's (a frame of the panel
// before a fold, still in flight, is not turned).
function frameRotation(frameWidth, frameHeight, display) {
  if (!display || !display.rotation || !display.width || !display.height || !frameWidth || !frameHeight) return 0;
  // The cover (0.687) and the inner panel (0.703) differ by little; the encoder rounds by less.
  const sameShape = Math.abs(frameWidth / frameHeight - display.width / display.height) < 0.006;
  return sameShape ? ((display.rotation % 360) + 360) % 360 : 0;
}

// The canvas transform that draws a frame turned clockwise by `rotation` into
// a canvas of width × height, and the size to draw the untransformed frame at.
function canvasTurn(rotation, width, height) {
  switch (rotation) {
    case 90: return { a: 0, b: 1, c: -1, d: 0, e: width, f: 0, width: height, height: width };
    case 180: return { a: -1, b: 0, c: 0, d: -1, e: width, f: height, width, height };
    case 270: return { a: 0, b: -1, c: 1, d: 0, e: 0, f: height, width: height, height: width };
    default: return { a: 1, b: 0, c: 0, d: 1, e: 0, f: 0, width, height };
  }
}

// The screen's corner radii as CSS for a picture `cssWidth` wide: its points,
// clockwise from the top-left as the picture reads.
function screenRadius(display, cssWidth) {
  const radii = display && display.cornerRadii, points = display && display.points;
  if (!Array.isArray(radii) || radii.length !== 4 || !points || !points.width || !cssWidth) return "";
  const scale = cssWidth / points.width;
  return radii.map((radius) => Math.round(radius * scale) + "px").join(" ");
}

// What the toolbar says about a fold: "130° · inner", "open · 180° · inner".
function foldReadout(fold) {
  if (!fold || fold.hingeDegrees == null) return fold && fold.panel ? fold.panel : "";
  const degrees = Math.round(fold.hingeDegrees * 10) / 10 + "°";
  return [fold.pose, degrees, fold.panel].filter(Boolean).join(" · ");
}

// ---- The 3D preview ----

// A point of a 3D frame (fractions, top-left origin) on the lit panel's
// framebuffer, or null off its screen: each projected leaf of the panel is
// inverted as a square-to-quad homography and its framebuffer region applied.
// Follows serve-sim's pointOnDuoScreen (Apache-2.0); see THIRD_PARTY_NOTICES.md.
function pointOnDuoScreen(projection, x, y) {
  if (!projection || !Array.isArray(projection.pieces)) return null;
  for (const piece of projection.pieces) {
    if (!Array.isArray(piece) || piece.length !== 5) continue;
    const [p0, p1, p2, p3, region] = piece;
    if ([...p0, ...p1, ...p2, ...p3, ...region].some((n) => !Number.isFinite(n))) continue;
    const dx1 = p1[0] - p2[0], dx2 = p3[0] - p2[0], dy1 = p1[1] - p2[1], dy2 = p3[1] - p2[1];
    const sx = p0[0] - p1[0] + p2[0] - p3[0], sy = p0[1] - p1[1] + p2[1] - p3[1];
    const denominator = dx1 * dy2 - dx2 * dy1;
    if (Math.abs(denominator) < 1e-10) continue;
    const g = (sx * dy2 - dx2 * sy) / denominator, h = (dx1 * sy - sx * dy1) / denominator;
    const a = p1[0] - p0[0] + g * p1[0], b = p3[0] - p0[0] + h * p3[0];
    const d = p1[1] - p0[1] + g * p1[1], e = p3[1] - p0[1] + h * p3[1];
    const aa = a - x * g, bb = b - x * h, dd = d - y * g, ee = e - y * h;
    const determinant = aa * ee - bb * dd;
    if (Math.abs(determinant) < 1e-10) continue;
    const u = ((x - p0[0]) * ee - bb * (y - p0[1])) / determinant;
    const v = (aa * (y - p0[1]) - (x - p0[0]) * dd) / determinant;
    if (u < -0.001 || v < -0.001 || u > 1.001 || v > 1.001) continue;
    return { x: region[0] + Math.max(0, Math.min(1, u)) * region[2], y: region[1] + Math.max(0, Math.min(1, v)) * region[3] };
  }
  return null;
}

// A framebuffer point as the screen's picture reads it, the picture turned
// `rotation` degrees clockwise — the inverse of the server's turn, so a touch
// sent as a picture fraction lands on the framebuffer point.
function pictureRatio(raw, rotation) {
  switch (((rotation % 360) + 360) % 360) {
    case 90: return { x: 1 - raw.y, y: raw.x };
    case 180: return { x: 1 - raw.x, y: 1 - raw.y };
    case 270: return { x: raw.y, y: 1 - raw.x };
    default: return { x: raw.x, y: raw.y };
  }
}

// Whether 3D frames asked for a stage `requested` wide per unit of height
// would sit in one `current` wide with more than a sliver of it left empty.
function stageReframes(requested, current) {
  if (!(requested > 0) || !(current > 0)) return false;
  return Math.abs(current / requested - 1) >= 0.04;
}

// `rgb(27, 29, 32)` → `1b1d20`, the stage's colour for the 3D frame's backdrop.
function cssColorHex(color) {
  const parts = /rgba?\((\d+),\s*(\d+),\s*(\d+)/.exec(color || "");
  if (!parts) return "000000";
  return parts.slice(1, 4).map((part) => Number(part).toString(16).padStart(2, "0")).join("");
}

// ---- Theme ----

// The theme a click on the theme button pins: the other one — or none, so the page
// follows the system again, when the other one is what the system shows anyway.
function themeAfterToggle(shown, system) {
  const next = shown === "dark" ? "light" : "dark";
  return next === system ? null : next;
}

// ---- Activity: what agents, test runs and viewers did to the device ----

// "3 s ago" — the feed's age, finer than formatAgo's "just now".
function formatSince(milliseconds) {
  if (!isFinite(milliseconds)) return "";
  const seconds = Math.max(0, Math.floor(milliseconds / 1000));
  if (seconds < 1) return "now";
  if (seconds < 60) return seconds + " s ago";
  const minutes = Math.floor(seconds / 60);
  return minutes < 60 ? minutes + " min ago" : Math.floor(minutes / 60) + " h ago";
}

const ACTOR_NAMES = { agent: "Agent", test: "Test", viewer: "Viewer" };

// How long an agent counts as driving after its last action: long enough to
// cover it reading the screen between two taps.
const AGENT_DRIVING_MS = 30000;

// Who drives the device now: the test run the server reports, or an agent that
// acted within AGENT_DRIVING_MS, or nobody (null). `key` names one stretch of
// driving, so a person who took over is asked again only when a new one starts.
function deviceDriver(entries, run, now) {
  if (run && run.active) {
    let step = run.totalSteps ? { index: Math.min(run.completedSteps + 1, run.totalSteps), total: run.totalSteps } : null;
    for (let i = entries.length - 1; i >= 0 && !step; i--) {
      const parsed = entries[i].kind === "step" ? parseStepText(entries[i].title) : null;
      if (parsed && parsed.index) step = { index: Math.min(parsed.index + 1, parsed.total), total: parsed.total };
    }
    return { actor: "test", key: "test:" + (run.sessionId || run.file || run.name || ""), title: run.name || run.file || "a test", step };
  }
  let newest = null, first = null;
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i];
    if (entry.actor !== "agent") continue;
    const end = Date.parse(entry.endedAt || entry.at);
    if (!newest) {
      if (entry.status !== "running" && !(now - end < AGENT_DRIVING_MS)) return null;
      newest = entry;
    } else if (Date.parse(first.at) - end >= AGENT_DRIVING_MS) {
      break;
    }
    first = entry;
  }
  return newest ? { actor: "agent", key: "agent:" + first.id, title: newest.title, lastAt: Date.parse(newest.endedAt || newest.at), entry: newest } : null;
}

// A gesture's ends as fractions of the screen, from the points it was played
// in; the server's screen size wins, the page's own (AX) size is the fallback.
function gestureRatios(gesture, screenPoints) {
  const screen = gesture && (gesture.screen || screenPoints);
  if (!screen || !screen.width || !screen.height) return null;
  const ratio = (point) => ({ x: Math.min(1, Math.max(0, point.x / screen.width)), y: Math.min(1, Math.max(0, point.y / screen.height)) });
  const from = ratio(gesture.from), to = ratio(gesture.to);
  const moved = Math.hypot(gesture.to.x - gesture.from.x, gesture.to.y - gesture.from.y) >= 1;
  return { from, to, moved };
}

// The CLI command that does what an entry did, for touches with a known path.
function activityCommand(entry) {
  const gesture = entry && entry.gesture;
  if (!gesture) return "";
  const round = (value) => Math.round(value);
  const at = "--x " + round(gesture.from.x) + " --y " + round(gesture.from.y);
  const path = "--start-x " + round(gesture.from.x) + " --start-y " + round(gesture.from.y) + " --end-x " + round(gesture.to.x) + " --end-y " + round(gesture.to.y);
  switch (entry.kind) {
    case "tap": return "simtool input tap " + at;
    case "long-press": return "simtool input long-press " + at + " --duration " + Math.round(gesture.press * 100) / 100;
    case "drag": return "simtool input drag " + path;
    case "swipe": case "scroll": case "fling": return "simtool input swipe " + path + (entry.kind === "fling" ? " --hold 0" : "");
    default: return "";
  }
}

// ---- Session review: the part of a run one step covers ----

// Milliseconds since the epoch from the times evidence carries: epoch seconds
// (state), ISO 8601 (network, steps) and OSLog's "2026-10-20 18:40:11.226211-0300"
// (logs), which not every browser parses. NaN when unreadable.
function parseInstant(value) {
  if (typeof value === "number") return value * 1000;
  if (value == null || value === "") return NaN;
  const text = String(value);
  const oslog = /^(\d{4}-\d\d-\d\d)[ T](\d\d:\d\d:\d\d)(?:\.(\d+))?([+-]\d\d):?(\d\d)$/.exec(text);
  if (oslog) return Date.parse(oslog[1] + "T" + oslog[2] + oslog[4] + ":" + oslog[5]) + (oslog[3] ? Number("0." + oslog[3]) * 1000 : 0);
  return Date.parse(text);
}

// What each step of a session covers: from the moment it began acting (its
// first input, or its end for a step that only waited) to the moment the next
// step did; the last one to the end of the run. A tap's window therefore holds
// the requests and lines it caused while the next step waited for them.
// `index` is the step's position in session.entries.
function stepWindows(session) {
  const end = parseInstant(session.endedAt);
  const steps = (session.entries || []).map((entry, index) => ({ entry, index })).filter(({ entry }) => entry.kind === "step");
  return steps.map(({ entry, index }, position) => ({
    index,
    text: entry.text || "",
    from: parseInstant(entry.at),
    to: position + 1 < steps.length ? parseInstant(steps[position + 1].entry.at) : (isFinite(end) ? end : Infinity)
  }));
}

// The window the playhead is in — the step at `entryIndex`, or what came
// before the first step — or the whole run.
function reviewWindow(session, entryIndex, scope) {
  const start = parseInstant(session.startedAt), end = parseInstant(session.endedAt);
  const run = { from: start, to: isFinite(end) ? end : Infinity, step: null, text: "" };
  if (scope === "run") return run;
  const windows = stepWindows(session);
  const position = windows.findIndex((window) => window.index === entryIndex);
  if (position < 0) return { from: start, to: windows.length ? windows[0].from : run.to, step: 0, text: "" };
  return { from: windows[position].from, to: windows[position].to, step: position + 1, text: windows[position].text };
}

// When an item of evidence happened: a request when it started (the logger
// stamps it when it finishes), a log line and a state change when they were written.
function evidenceInstant(kind, item) {
  if (kind === "network") return parseInstant(item.timestamp) - (item.durationMilliseconds || 0);
  return parseInstant(item.timestamp);
}

function inWindow(kind, item, window) {
  const at = evidenceInstant(kind, item);
  return at >= window.from && at < window.to;
}

// The tracked models as they stood at the end of a window, and what changed
// inside it — the State tab's latest/changes/lastChange for a moment of a run.
// `launches` ({ launchId, at } in ms, from the run's requests and log lines)
// tell when the app started over, so a model of an earlier process reads as
// ended even when the new one has not reported any state yet.
function foldStateEvents(events, window, launches) {
  const view = { latest: {}, changes: [], lastChange: {}, newestLaunch: null };
  const ordered = events.slice().sort((a, b) => (a.timestamp - b.timestamp) || ((a.cursor || 0) - (b.cursor || 0)));
  for (const event of ordered) {
    const at = event.timestamp * 1000;
    if (at >= window.to) break;
    foldStateEvent(view, event, at >= window.from);
  }
  for (const launch of launches || []) {
    if (launch.at < window.to && !(view.newestLaunch >= launch.launchId)) view.newestLaunch = launch.launchId;
  }
  return view;
}

// ---- An .app dropped on the screen ----

// A tar of entries { path, bytes } (bytes null for a folder) — how the viewer
// uploads an .app bundle, which a browser hands over as files, not as a
// folder. ustar, with a pax record for a path longer than its 100 bytes; every
// file is executable, since the browser does not say which ones were.
function tarArchive(entries, mtime) {
  const blocks = [];
  let size = 0;
  const push = (bytes) => { blocks.push(bytes); size += bytes.length; };
  const pad = (length) => { if (length % 512) push(new Uint8Array(512 - (length % 512))); };
  const header = (name, length, type, mode) => {
    const block = new Uint8Array(512);
    const ascii = (offset, text) => block.set(utf8Bytes(text), offset);
    block.set(name.subarray(0, 100), 0);
    ascii(100, mode.toString(8).padStart(7, "0"));
    ascii(108, "0000000");
    ascii(116, "0000000");
    ascii(124, length.toString(8).padStart(11, "0"));
    ascii(136, Math.floor(mtime || 0).toString(8).padStart(11, "0"));
    block[156] = type.charCodeAt(0);
    ascii(257, "ustar");
    ascii(263, "00");
    block.fill(32, 148, 156);
    let sum = 0;
    for (const byte of block) sum += byte;
    ascii(148, sum.toString(8).padStart(6, "0"));
    block[154] = 0;
    return block;
  };
  for (const entry of entries) {
    const folder = !entry.bytes;
    const path = entry.path + (folder && !entry.path.endsWith("/") ? "/" : "");
    const name = utf8Bytes(path);
    if (name.length > 100) {
      // "<length> path=<path>\n", the length counting its own digits.
      const rest = " path=" + path + "\n";
      let length = utf8Bytes(rest).length;
      while (String(length).length + utf8Bytes(rest).length !== length) length = String(length).length + utf8Bytes(rest).length;
      const record = utf8Bytes(length + rest);
      push(header(utf8Bytes("PaxHeader"), record.length, "x", 0o644));
      push(record);
      pad(record.length);
    }
    const data = entry.bytes || new Uint8Array(0);
    push(header(name, data.length, folder ? "5" : "0", 0o755));
    if (data.length) { push(data); pad(data.length); }
  }
  push(new Uint8Array(1024));
  const out = new Uint8Array(size);
  let at = 0;
  for (const block of blocks) { out.set(block, at); at += block.length; }
  return out;
}

function utf8Bytes(text) {
  const raw = unescape(encodeURIComponent(text));
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

// What a file dropped on the screen is for: Photos, an install, or nothing SimTool takes.
function dropKind(name, type, folder) {
  const lower = String(name || "").toLowerCase();
  if (folder) return lower.endsWith(".app") ? "app" : "none";
  if (lower.endsWith(".ipa")) return "ipa";
  if (/^(image|video)\//.test(type || "") || /\.(png|jpe?g|heic|heif|gif|webp|tiff?|mov|mp4|m4v)$/.test(lower)) return "media";
  return "none";
}

// ---- Processes: every SimTool process on this Mac ----

// How long a process has run: "42 s", "12 min", "3 h 5 min", "2 d 4 h".
function formatUptime(startedAt, now) {
  const start = startedAt ? new Date(startedAt).getTime() : NaN;
  if (isNaN(start)) return "";
  const seconds = Math.max(0, Math.floor(((now == null ? Date.now() : now) - start) / 1000));
  if (seconds < 60) return seconds + " s";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return minutes + " min";
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return hours + " h" + (minutes % 60 ? " " + (minutes % 60) + " min" : "");
  return Math.floor(hours / 24) + " d" + (hours % 24 ? " " + (hours % 24) + " h" : "");
}

// A path under the home directory, as a shell writes it.
function tildePath(path, home) {
  if (!path) return "";
  return home && (path === home || path.startsWith(home + "/")) ? "~" + path.slice(home.length) : path;
}

// A server group's port: its session's URL, else the --port it was started with.
function processPort(group) {
  const url = group.session && group.session.url;
  const match = url && /^[a-z]+:\/\/[^/]*:(\d+)/i.exec(url);
  if (match) return match[1];
  const args = (group.processes[0] && group.processes[0].arguments) || [];
  const index = args.indexOf("--port");
  return index >= 0 && args[index + 1] ? args[index + 1] : "";
}

// How deep under its group's first process a process runs.
function processDepth(process, members) {
  let depth = 0;
  let owner = process.owner;
  while (owner != null && depth < 8) {
    const above = members.find((candidate) => candidate.pid === owner);
    if (!above) break;
    depth += 1;
    owner = above.owner;
  }
  return depth;
}

// The line under a process's name: where a server, a command or the reaper runs
// from — a Homebrew install, a checkout's build — and a helper's image, whose
// name carries its version. A child's path says nothing its name does not.
function processImageLine(process, home) {
  if (process.kind === "child") return "";
  if (process.kind !== "helper") return tildePath(process.executable, home);
  const image = /\/SimulatorHelpers\/[^/]+$/.test(process.executable || "")
    ? process.executable
    : (process.arguments || []).find((argument) => /\/SimulatorHelpers\/[^/]+$/.test(argument)) || process.executable || "";
  return image.split("/").pop();
}

// A group's heading: what it is and, for a server, its port, simulator and project.
function processGroupHeading(group, list) {
  if (group.kind === "orphans") return { title: "Orphans", detail: "Their server or command is gone, and nothing will stop them", self: false };
  if (group.kind === "other") return { title: "Not under a server", detail: "The reaper and SimTool commands", self: false };
  const server = group.processes[0] || {};
  const port = processPort(group);
  const device = group.session ? group.session.device.name : server.deviceName || server.deviceUDID || "";
  const project = group.session && group.session.projectRoot ? group.session.projectRoot : server.directory;
  return {
    title: port ? "Server :" + port : "Server",
    detail: [device, tildePath(project, list.home)].filter(Boolean).join(" · "),
    self: server.pid === list.pid
  };
}

// What a stop asks first: about this page's own server, another server, a
// command or the reaper — someone may be using those. A helper, a child or an
// orphan stops without a question (null).
function processKillQuestion(process, list, port) {
  if (process.pid === list.pid) {
    return {
      title: "Stop this viewer's server?",
      text: "This page loses its device: the server shuts down the simulator it holds unless another server is on it. Start it again with simtool serve.",
      confirm: "Stop server",
      self: true
    };
  }
  if (process.kind === "server") {
    return {
      title: "Stop the server" + (port ? " on :" + port : "") + "?",
      text: "Its viewers lose the device, and the simulator it holds shuts down unless another server is on it.",
      confirm: "Stop server",
      self: false
    };
  }
  if (process.kind === "command") {
    return { title: "Stop " + process.name + "?", text: "Whoever runs it — an agent, a terminal — sees it fail.", confirm: "Stop", self: false };
  }
  if (process.kind === "reaper") {
    return {
      title: "Stop the reaper?",
      text: "It shuts down the simulators only it was watching as it goes. SimTool starts it again when it next holds a simulator.",
      confirm: "Stop",
      self: false
    };
  }
  return null;
}

// What a stop did, in a sentence.
function processKillMessage(outcome) {
  const what = outcome.name + " (PID " + outcome.pid + ")";
  const count = (outcome.alongside || []).length;
  const along = count ? " and " + plural(count, "process", "processes") + " running for it" : "";
  if (outcome.result === "stopped") return "Stopped " + what + along;
  if (outcome.result === "killed") return "Killed " + what + along + ": it did not stop on SIGTERM";
  if (outcome.result === "gone") return what + " had exited already";
  return what + " is stopping";
}
