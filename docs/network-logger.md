# The network logger SDK

`SimToolNetworkLogger` is the library an app embeds — in its Debug build, or
behind whatever keeps it out of a release — to show its traffic in the
**Network** tab. It reports any network, in two shapes:

- a **call**: one request, one answer — an HTTP request, a unary gRPC call, a
  GraphQL operation, a request over the app's own socket protocol;
- a **stream session**: one long-lived connection and what happens on it — a
  WebSocket, server-sent events, a streaming gRPC call, MQTT, a raw socket.

A protocol is a name. `http`, `grpc` and `websocket` are SimTool's own; any
other — `sse`, `mqtt`, `graphql` — is listed, filtered and searched as the app
named it.

```swift
import SimToolNetworkLogger

// Once, at startup: nil unless SimTool armed the app (see How SimTool arms it).
let logger = SimToolNetworkLogger.resolved()

// URLSession: every call made through the configuration is captured.
logger?.instrument(configuration)

// A call of any protocol, from the app's own network layer.
let call = logger?.startCall("graphql", method: "query Feed", url: endpoint, body: .data(requestBody))
call?.finish(status: "OK", body: .data(responseBody))         // or finish(error: error)

// An HTTP layer of the app's own.
let http = logger?.startHTTPCall(request)
http?.finish(response: response, body: data, error: error)

// gRPC, from a client interceptor.
let grpc = logger?.startGRPCCall(service: "pkg.Service", method: "Get", requestMessagePreview: requestText)
await grpc?.finish(statusCode: "0", responseMessagePreview: responseText)

// One stream session per connection object, kept across its reconnects.
let chat = logger?.startStream(.websocket, url: socketURL, subprotocol: "chat-v2", headers: handshakeHeaders)
chat?.connecting()
chat?.connected()
chat?.subscribed("chat:123")
chat?.received(.text(json), channel: "chat:123", kind: "publication")
chat?.sent(.text(json), channel: "chat:123")
chat?.disconnected(code: 1000, reason: "bye")                 // or failed(error)
```

- **`URLSessionWebSocketTask`**: `startStream(webSocket: task)` takes the task's
  URL, subprotocol and headers; `sent(webSocket:)`, `received(webSocket:)` and
  `disconnected(closeCode:reason:)` take what the task and its delegate hand
  back.
- **A streaming gRPC call**: `startGRPCStream(service:method:authority:)`, each
  message with `sent` or `received`, the end with `disconnected(code:reason:)`
  and its status code, or `failed`.
- **Anything else on a stream** — a ping, a protocol's own lifecycle — goes
  through `record(_:direction:channel:payload:code:reason:metadata:error:)`.
  An event with a `direction` is a message; one without belongs to the
  connection's or a channel's lifecycle.
- **A payload** is `.data(bytes)` — read as text when it is UTF-8, kept as
  base64 when not — `.text(string)`, or `.rendered(text, byteCount:)`: a
  readable rendering of a binary message, such as protobuf's text format, with
  its size on the wire.

Every call returns at once and never throws, so it is safe from any thread and
from synchronous delegate callbacks. Events reach SimTool in the order they
happened, on the logger's own task, and never affect the app's networking;
`await logger.flush()` waits for them. Headers, metadata and URL query
parameters whose names look secret (`authorization`, `cookie`, `…token…`,
`…secret…`, `api-key`, `password`) are redacted on the device. Bodies and
payloads are kept as a bounded preview (2 KB by default) when
`captureBodyPreviews` is on, as it is for a logger SimTool armed. Mock rules
answer the calls an app's interceptor asks `MockStore` about — gRPC today;
other protocols and streams are reported, not mocked.

## How SimTool arms it

`simtool run` and `simtool serve --app <bundle-id>` arm the logger for the app
they launch, pointed at their server ([Project config, `run` and
`open`](project-config.md)).

`SimToolNetworkLogger.makeFromEnvironment()` reads `SIMTOOL_NETWORK_LOGGER` and
`SIMTOOL_SERVER_URL` for you, returning `nil` (no capture) unless the logger is
enabled. For simulator development prefer `SimToolNetworkLogger.resolved()`: it
behaves like `makeFromEnvironment()` but, **only in the iOS Simulator**, also
self-activates from an on-device marker it persists the first time SimTool arms
it. That keeps network events flowing after you fully kill and relaunch the app
outside SimTool — by tapping its icon or running from Xcode — where the
`SIMTOOL_*` environment is gone. It is hard-gated to the simulator, so device,
TestFlight, and App Store builds never auto-enable, and an explicit
`SIMTOOL_NETWORK_LOGGER=0` opts a run out. To arm it by hand, launch the app with
`--env SIMTOOL_NETWORK_LOGGER=1 --env SIMTOOL_SERVER_URL=…` (see
[Building and launching apps](app-build.md)).

## One release for the CLI and the app

An app that links `SimToolNetworkLogger` or `SimToolStateLogger` talks to the
CLI's server, so pin the package to the release the CLI is — with a mise pin,
the same number in both places:

```swift
.package(url: "https://github.com/platacard/SimTool.git", exact: "1.0.0"),
```

The network logger reports its release to the server with every event batch
and mock poll. When its major or minor differs from the CLI's, `simtool doctor`
(the `network logger` row, while a server for the project runs) and the
viewer's **Network** tab say so — "The app links SimToolNetworkLogger 1.0, the
CLI is 1.1" — and `GET /api/v1/mocks/ack` carries the report as `logger`.
Loggers before 1.0 report nothing and read as older.

## In the viewer

The viewer's **Network** tab shows what the app reports — calls as rows, each
stream session as one row with its messages — see
[The Network and Logs tabs](usage.md#the-network-and-logs-tabs).
