import JavaScriptCore
@testable import SimToolWeb
import XCTest

// web/js/logic.js holds everything the viewer decides without the browser:
// what a status means, what a filter keeps, what changed in a model, where a
// step sits in a recording, what to copy. It runs here on its own.
final class WebViewerLogicTests: XCTestCase {
    private func makeContext(file: StaticString = #filePath, line: UInt = #line) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in
            XCTFail("JS exception: \(exception?.toString() ?? "?")", file: file, line: line)
        }
        context.evaluateScript(WebViewer.asset("js/logic.js"))
        return context
    }

    private func value(_ context: JSContext, _ expression: String) -> String {
        context.evaluateScript(expression)?.toString() ?? ""
    }

    // MARK: - Network status

    // A dropped .app goes up as a tar the server's tar unpacks: ustar headers
    // with octal fields and a checksum, a pax record for a long path,
    // executable files, and two empty blocks at the end.
    func testADroppedAppIsATarTheServerCanUnpack() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var tar = tarArchive([{ path: "My.app", bytes: null }, { path: "My.app/Info.plist", bytes: new Uint8Array([60, 63]) },
                              { path: "My.app/" + "d/".repeat(60) + "f", bytes: new Uint8Array([1]) }], 0);
        function text(at, length) { var s = ""; for (var i = at; i < at + length && tar[i]; i++) s += String.fromCharCode(tar[i]); return s; }
        function sum(at) { var total = 0; for (var i = at; i < at + 512; i++) total += (i >= at + 148 && i < at + 156) ? 32 : tar[i]; return total; }
        """)
        XCTAssertEqual(value(context, "tar.length % 512"), "0")
        XCTAssertEqual(value(context, "text(0, 100)"), "My.app/")
        XCTAssertEqual(value(context, "String.fromCharCode(tar[156])"), "5")
        XCTAssertEqual(value(context, "text(257, 5)"), "ustar")
        XCTAssertEqual(value(context, "parseInt(text(148, 6), 8) === sum(0)"), "true")
        XCTAssertEqual(value(context, "text(512, 100)"), "My.app/Info.plist")
        XCTAssertEqual(value(context, "text(512 + 100, 7)"), "0000755")
        XCTAssertEqual(value(context, "parseInt(text(512 + 124, 11), 8)"), "2")
        XCTAssertEqual(value(context, "text(1024, 2)"), "<?")
        // The long path: a pax header ("x") whose record names it in full.
        XCTAssertEqual(value(context, "String.fromCharCode(tar[1536 + 156])"), "x")
        XCTAssertEqual(value(context, #"/^\d+ path=My\.app\/(d\/){60}f\n$/.test(text(2048, 512))"#), "true")
        XCTAssertEqual(value(context, "parseInt(text(2048, 4), 10) === text(2048, 512).length"), "true")
        XCTAssertEqual(value(context, "Array.prototype.slice.call(tar, tar.length - 1024).every(function (b) { return b === 0; })"), "true")
    }

    func testADropIsMediaABuildOrNothing() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "dropKind('Shot.PNG', '', false)"), "media")
        XCTAssertEqual(value(context, "dropKind('clip.mov', 'video/quicktime', false)"), "media")
        XCTAssertEqual(value(context, "dropKind('Build.ipa', '', false)"), "ipa")
        XCTAssertEqual(value(context, "dropKind('My.app', '', true)"), "app")
        XCTAssertEqual(value(context, "dropKind('Folder', '', true)"), "none")
        XCTAssertEqual(value(context, "dropKind('notes.txt', 'text/plain', false)"), "none")
    }

    func testHTTPStatusSeverityFollowsTheStatusClass() throws {
        let context = try makeContext()
        func severity(_ code: Int) -> String {
            value(context, "networkStatus({ protocol: 'http', response: { statusCode: \(code) } }).severity")
        }
        XCTAssertEqual(severity(200), "ok")
        XCTAssertEqual(severity(204), "ok")
        XCTAssertEqual(severity(304), "info", "not modified is not a warning")
        XCTAssertEqual(severity(404), "warn")
        XCTAssertEqual(severity(500), "err")
        XCTAssertEqual(value(context, "JSON.stringify(networkStatus({ protocol: 'http', error: { message: 'timed out' } }))"),
                       #"{"text":"Failed","severity":"err","title":"timed out"}"#)
        XCTAssertEqual(value(context, "networkStatus({ protocol: 'http' }).severity"), "pending")
    }

    func testGRPCCodesAreNamedAndSplitIntoClientAndServerFailures() throws {
        let context = try makeContext()
        func status(_ code: String) -> String {
            value(context, "(s => s.text + ' ' + s.severity)(networkStatus({ protocol: 'grpc', response: { grpcStatusCode: '\(code)' } }))")
        }
        XCTAssertEqual(status("0"), "OK ok")
        XCTAssertEqual(status("5"), "NOT_FOUND warn")
        XCTAssertEqual(status("16"), "UNAUTHENTICATED warn")
        XCTAssertEqual(status("13"), "INTERNAL err")
        XCTAssertEqual(status("14"), "UNAVAILABLE err")
        XCTAssertEqual(value(context, "networkStatus({ protocol: 'grpc', response: { grpcStatusCode: '13', grpcStatusMessage: 'upstream reset' } }).title"),
                       "INTERNAL — upstream reset")
    }

    func testFailuresAndClientProblemsAreCountedApartAsTheirRowsAreColoured() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var calls = [
          { protocol: 'http', response: { statusCode: 200 } },
          { protocol: 'http', response: { statusCode: 404 } },
          { protocol: 'grpc', response: { grpcStatusCode: '16' } },
          { protocol: 'grpc', response: { grpcStatusCode: '13' } },
          { protocol: 'http', error: { message: 'timed out' } }
        ];
        """)
        XCTAssertEqual(value(context, "networkMarks(calls).map(m => m.tone + ':' + m.count).join(' ')"), "err:2 warn:2")
        XCTAssertEqual(value(context, "calls.filter(isNetworkProblem).length"), "4", "the Problems filter keeps both")
    }

    func testCopyCommandsReproduceTheRequest() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var http = { protocol: 'http', request: { method: 'POST', url: 'https://api.example.com/v2/cart/items', headers: { accept: 'application/json' }, bodyPreview: '{"qty":1}' },
                     response: { statusCode: 201, bodyPreview: '{ "cartId": "k-1" }' } };
        var grpc = { protocol: 'grpc', request: { path: '/shop.v1.Promo/GetPromotions', grpcService: 'shop.v1.Promo', grpcMethod: 'GetPromotions', grpcAuthority: 'grpc.example.com:443', metadata: { 'x-client': '3.4' }, bodyPreview: '{}' },
                     response: { grpcStatusCode: '14' } };
        """)
        XCTAssertEqual(value(context, "curlCommand(http)"),
                       "curl \\\n  -X POST \\\n  'https://api.example.com/v2/cart/items' \\\n  -H 'accept: application/json' \\\n  --data-raw '{\"qty\":1}'")
        XCTAssertEqual(value(context, "grpcurlCommand(grpc)"),
                       "grpcurl \\\n  -H 'x-client: 3.4' \\\n  -d '{}' \\\n  grpc.example.com:443 \\\n  shop.v1.Promo/GetPromotions")
        // A mock entry a YAML test can paste: the answer it got, or the error.
        XCTAssertEqual(value(context, "mockYaml(grpc)"), "mocks:\n  - method: \"*/GetPromotions\"\n    error: unavailable")
        XCTAssertEqual(value(context, "mockYaml({ protocol: 'grpc', request: { grpcMethod: 'List' }, response: { grpcStatusCode: '0', bodyPreview: '{ \"items\": [] }' } })"),
                       "mocks:\n  - method: \"*/List\"\n    body: {\"items\":[]}")
    }

    // A call can arrive twice — pushed, then replayed after a reconnect — and
    // its id says it is the same call.
    func testPushedCallsReplaceTheirIdAndKeepOnlyTheNewest() throws {
        let context = try makeContext()
        context.evaluateScript("var held = [{ id: 'a', n: 1 }, { id: 'b', n: 1 }];")
        XCTAssertEqual(value(context, "mergeNetworkEvents(held, [{ id: 'b', n: 2 }, { id: 'c', n: 1 }], 10).map(e => e.id + e.n).join()"), "a1,b2,c1")
        XCTAssertEqual(value(context, "mergeNetworkEvents(held, [{ id: 'c' }, { id: 'd' }], 3).map(e => e.id).join()"), "b,c,d", "the oldest goes first")
        XCTAssertEqual(value(context, "mergeNetworkEvents(held, undefined, 10).length"), "2")
        XCTAssertEqual(value(context, "held.map(e => e.n).join()"), "1,1", "what the page held is not changed under it")
    }

    // MARK: - Any protocol, and streams as sessions

    // The filter offers HTTP and gRPC, then whatever else the app's logger reported.
    func testAnyProtocolIsNamedAndOffered() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "[protocolLabel('websocket'), protocolLabel('grpc'), protocolLabel('mqtt'), protocolLabel('tcp'), protocolLabel('graphql'), protocolLabel('custom-rpc')].join()"),
                       "WS,gRPC,MQTT,TCP,GraphQL,custom-rpc")
        XCTAssertEqual(value(context, "networkProtocols([{ protocol: 'websocket' }, { protocol: 'http' }, { protocol: 'amqp' }, { protocol: 'websocket' }]).join()"), "http,grpc,amqp,websocket")
    }

    // A call of a protocol SimTool knows nothing of reads by its operation and
    // the status the app gave it; finished without an error, it is fine.
    func testACallOfAnotherProtocolReadsAsTheAppReportedIt() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var gql = { protocol: 'graphql', request: { method: 'query Profile', url: 'https://api.example.test/graphql', host: 'api.example.test' }, response: { status: 'OK', headers: {}, metadata: {} } };
        var tcp = { protocol: 'tcp', request: { path: '10.0.0.1:9000' }, response: null, error: { message: 'Connection refused' } };
        """)
        XCTAssertEqual(value(context, "var s = networkStatus(gql); s.text + '|' + s.severity"), "OK|ok")
        XCTAssertEqual(value(context, "networkStatus(tcp).severity"), "err")
        XCTAssertEqual(value(context, "networkStatus({ protocol: 'mqtt', request: {} }).severity"), "pending")
        // JavaScriptCore has no URL: where a URL went reads whole here, as host and path in a browser.
        XCTAssertEqual(value(context, "requestName(gql) + '|' + requestWhere(gql).endsWith('api.example.test/graphql')"), "query Profile|true")
        XCTAssertEqual(value(context, "requestName(tcp) + '|' + requestWhere(tcp) + '|' + chipPathForEvent(tcp)"), "10.0.0.1:9000|10.0.0.1:9000|10.0.0.1:9000")
    }

    // A session's events become one row, in the order the logger numbered them;
    // the same events next time are the same row.
    func testAStreamSessionIsOneRowOfItsEventsInOrder() throws {
        let context = try makeContext()
        context.evaluateScript("""
        function frame(id, seq, at, stream, extra) {
          return Object.assign({ id: id, protocol: 'websocket', timestamp: '2026-01-01T00:00:0' + at + '.000Z', launchId: 3,
            request: { url: 'wss://chat.example.test/connection/websocket', host: 'chat.example.test', headers: {} },
            stream: Object.assign({ sessionId: 's1', sequence: seq, subprotocol: 'chat-v2', metadata: {} }, stream) }, extra || {});
        }
        var events = [
          { id: 'call', protocol: 'http', timestamp: '2026-01-01T00:00:00.500Z', request: {} },
          frame('b', 1, 2, { kind: 'connected' }),
          frame('a', 0, 1, { kind: 'connecting' }, { request: { url: 'wss://chat.example.test/connection/websocket', host: 'chat.example.test', headers: { Origin: 'app' } } }),
          frame('c', 2, 3, { kind: 'subscribed', channel: 'chat:1' }),
          frame('d', 3, 4, { kind: 'message', direction: 'in', channel: 'chat:1', payloadPreview: '{"text":"hi"}', payloadByteCount: 13 }),
          frame('e', 4, 5, { kind: 'publish', direction: 'out', channel: 'chat:1', payloadPreview: '{"text":"yo"}', payloadByteCount: 13 }),
          frame('f', 5, 6, { kind: 'message', direction: 'in', channel: 'chat:1', payloadPreview: 'AAEC', payloadEncoding: 'base64', payloadByteCount: 3 })
        ];
        var items = networkItems(events);
        var session = items[1];
        """)
        XCTAssertEqual(value(context, "items.map(i => i.id).join()"), "call,stream:s1")
        XCTAssertEqual(value(context, "session.frames.map(f => f.id).join()"), "a,b,c,d,e,f")
        XCTAssertEqual(value(context, "[session.protocol, session.subprotocol, session.launchId, session.durationMilliseconds, session.request.headers.Origin].join()"), "websocket,chat-v2,3,5000,app")
        XCTAssertEqual(value(context, "[requestName(session), requestWhere(session).endsWith('chat.example.test/connection/websocket · chat-v2'), messageByteCount(session, 'request'), networkSize(session)].join('|')"),
                       "websocket|true|13|16")
        XCTAssertEqual(value(context, "var s = networkStatus(session); s.text + '|' + s.severity"), "Open · 1 ch|ok")
        XCTAssertEqual(value(context, "frameSummary(session.frames[5]) + '|' + frameSummary(session.frames[3])"), "Binary · 3 B|{\"text\":\"hi\"}")
        XCTAssertEqual(value(context, "networkItems(events, new Map([['stream:s1', session]]))[1] === session"), "true")
        XCTAssertEqual(value(context, "networkItems(events.slice(0, 5), new Map([['stream:s1', session]]))[1] === session"), "false", "a new event makes a new row")
        XCTAssertEqual(value(context, "var fields = networkSearchFields(session); networkHits(fields, 'chat:1').join(',')"), "channel")
        XCTAssertEqual(value(context, "networkHits(fields, 'yo').join(',') + '|' + networkHits(fields, 'hi').join(',')"), "request body|response body")
    }

    // A session reads from its connection's last lifecycle event; how a close
    // reads depends on its protocol's codes.
    func testAStreamSessionsStateFollowsItsConnection() throws {
        let context = try makeContext()
        context.evaluateScript("""
        function session(protocol, kinds) {
          return { protocol: protocol, frames: kinds.map((stream, index) => ({ id: String(index), stream: Object.assign({ sequence: index, metadata: {} }, stream), error: stream.error })) };
        }
        function status(protocol, kinds) { var s = networkStatus(session(protocol, kinds)); return s.text + '|' + s.severity; }
        """)
        XCTAssertEqual(value(context, "status('websocket', [{ kind: 'connecting' }])"), "Connecting…|pending")
        XCTAssertEqual(value(context, "status('websocket', [{ kind: 'connected' }, { kind: 'disconnected', code: 1000 }])"), "Closed 1000|info")
        XCTAssertEqual(value(context, "status('websocket', [{ kind: 'connected' }, { kind: 'disconnected', code: 1006 }])"), "Closed 1006|err")
        XCTAssertEqual(value(context, "status('websocket', [{ kind: 'connected' }, { kind: 'disconnected', code: 4001 }])"), "Closed 4001|warn")
        XCTAssertEqual(value(context, "status('websocket', [{ kind: 'connected' }, { kind: 'error', reason: 'reset' }])"), "Failed|err")
        XCTAssertEqual(value(context, "status('websocket', [{ kind: 'disconnected' }, { kind: 'connecting' }, { kind: 'connected' }])"), "Open|ok", "a reconnect opens it again")
        XCTAssertEqual(value(context, "status('websocket', [{ kind: 'connected' }, { kind: 'subscriptionError', channel: 'chat:2', code: 103 }])"), "Open|warn")
        XCTAssertEqual(value(context, "status('websocket', [{ kind: 'message', direction: 'in' }])"), "Open|ok", "only messages: it is open")
        XCTAssertEqual(value(context, "status('grpc', [{ kind: 'disconnected', code: 0 }]) + ' ' + status('grpc', [{ kind: 'disconnected', code: 14 }]) + ' ' + status('grpc', [{ kind: 'disconnected', code: 7 }])"),
                       "Closed 0|info Closed 14|err Closed 7|warn")
        XCTAssertEqual(value(context, "status('mqtt', [{ kind: 'disconnected', code: 5 }])"), "Closed 5|info", "a code of another protocol says nothing")
        XCTAssertEqual(value(context, "isNetworkProblem(session('websocket', [{ kind: 'error' }]))"), "true")
    }

    // The page keeps as many calls and, apart from them, as many stream events as the server.
    func testStreamEventsAreCappedApartFromCalls() throws {
        let context = try makeContext()
        context.evaluateScript("var held = [{ id: 'c1' }, { id: 'f1', stream: {} }, { id: 'c2' }, { id: 'f2', stream: {} }];")
        XCTAssertEqual(value(context, "mergeNetworkEvents(held, [{ id: 'f3', stream: {} }, { id: 'c3' }], 2, 2).map(e => e.id).join()"), "c2,f2,f3,c3")
        XCTAssertEqual(value(context, "mergeNetworkEvents(held, [{ id: 'f3', stream: {} }], 5, 5).length"), "5")
    }

    // MARK: - A call's detail

    func testAJSONBodyIsATreeOfKeysAndItems() throws {
        let context = try makeContext()
        context.evaluateScript(#"var tree = parseBodyTree('{"user":{"id":42,"vip":true,"note":null},"tags":["a","b"]}');"#)
        XCTAssertEqual(value(context, "tree.format + ' ' + tree.complete"), "json true")
        XCTAssertEqual(value(context, "tree.root.children.map(c => c.key + ':' + c.kind).join(',')"), "user:object,tags:array")
        XCTAssertEqual(value(context, "tree.root.children[0].children.map(c => c.key + '=' + c.type + ' ' + c.text).join(',')"), "id=num 42,vip=lit true,note=null null")
        XCTAssertEqual(value(context, "tree.root.children[1].children.map(c => c.key + '=' + c.text).join(',')"), #"0="a",1="b""#)
        XCTAssertEqual(value(context, "treeSize(tree.root)"), "8")
    }

    // gRPC loggers print messages in the protobuf text format, cut at the preview's length.
    func testAProtobufTextMessageIsATreeAndACutOneReadsAsFarAsItGoes() throws {
        let context = try makeContext()
        context.evaluateScript(#"""
        var whole = parseBodyTree('ExampleAPI.PortfolioResponse:\nportfolio {\n  account_id: "acc \\"1\\""\n  total {\n    currency_code: "USD"\n    units: 5000\n  }\n  kind: KIND_CASH\n  open: true\n}\n');
        var cut = parseBodyTree('Payments.Response:\nresponse {\n  attributes {\n    key: "account"\n    value {\n      per_o');
        """#)
        XCTAssertEqual(value(context, "whole.format + ' ' + whole.complete + ' ' + whole.root.typeName"), "proto true ExampleAPI.PortfolioResponse")
        let portfolio = "whole.root.children[0]"
        XCTAssertEqual(value(context, "\(portfolio).key + ' ' + \(portfolio).kind"), "portfolio message")
        XCTAssertEqual(value(context, "\(portfolio).children.map(c => c.key + '=' + (c.type || c.kind)).join(',')"), "account_id=str,total=message,kind=enum,open=lit")
        XCTAssertEqual(value(context, "\(portfolio).children[0].value"), #"acc "1""#)
        XCTAssertEqual(value(context, "\(portfolio).children[1].children[1].type"), "num")
        XCTAssertEqual(value(context, "cut.format + ' ' + cut.complete"), "proto false", "a cut preview is still a tree, and says it is cut")
        XCTAssertEqual(value(context, "cut.root.children[0].children[0].children[0].value"), "account")
    }

    func testTextThatIsNeitherStaysText() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "parseBodyTree('hello world, nothing structured').format"), "text")
        XCTAssertEqual(value(context, "parseBodyTree('{\"cut\": [1, 2').format"), "text", "a cut JSON preview is shown as text")
        XCTAssertEqual(value(context, "parseBodyTree('').format"), "empty")
    }

    func testTheQueryIsDecodedAndTheStatusNamed() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "JSON.stringify(queryParams('https://x.test/a?limit=20&cursor=abc%20def&flag&q=a+b#frag'))"),
                       #"[["limit","20"],["cursor","abc def"],["flag",""],["q","a b"]]"#)
        XCTAssertEqual(value(context, "queryParams('/svc.Service/Method').length"), "0")
        XCTAssertEqual(value(context, "httpStatusText(404) + '|' + httpStatusText(503) + '|' + httpStatusText(299)"), "Not Found|Service Unavailable|")
    }

    // A search reads headers and bodies too, and says where it found the term.
    func testASearchFindsATermInHeadersAndBodiesAndSaysWhere() throws {
        let context = try makeContext()
        context.evaluateScript(#"""
        var call = { protocol: 'grpc',
          request: { grpcService: 'pkg.Svc', grpcMethod: 'GetThing', path: '/pkg.Svc/GetThing', metadata: { 'x-trace': 'T-77' }, bodyPreview: 'Req:\nid: "abc"\n' },
          response: { grpcStatusCode: '5', metadata: { server: 'envoy' }, bodyPreview: 'Resp:\nowner: "ABC Corp"\n' } };
        var fields = networkSearchFields(call);
        """#)
        XCTAssertEqual(value(context, "networkHits(fields, 'abc').join(',')"), "request body,response body")
        XCTAssertEqual(value(context, "networkHits(fields, 't-77').join(',')"), "request headers")
        XCTAssertEqual(value(context, "networkHits(fields, 'not_found').join(',')"), "status", "a gRPC code is found by its name")
        XCTAssertEqual(value(context, "networkHits(fields, 'abc', 'header').length"), "0", "header: searches the headers alone")
        XCTAssertEqual(value(context, "networkHits(fields, 'getthing').join(',')"), "url,method")
        XCTAssertEqual(value(context, "matchesFilters(fields.url + fields.body, [], 'corp', fields, 'body')"), "true")
    }

    func testMarksAreEscapedAndCaseInsensitive() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "markHTML('<b>Token</b> token', 'TOKEN')"), "&lt;b&gt;<mark>Token</mark>&lt;/b&gt; <mark>token</mark>")
        XCTAssertEqual(value(context, "markHTML('a&b', '')"), "a&amp;b")
    }

    // MARK: - Table columns (Logs, Network)

    func testASavedLayoutIsMadeWholeAndKeptInBounds() throws {
        let context = try makeContext()
        context.evaluateScript("var describe = (l) => l.map(c => c.key + (c.hidden ? '-' : '') + (c.width ? c.width : '')).join(',');")
        XCTAssertEqual(value(context, "describe(columnLayout(LOG_COLUMNS, null))"),
                       "time86,level62,subsystem160,category-120,process-110,message", "by default category and process are off")
        // Unknown and repeated columns go, widths are bounded, a missing column comes back after the one it follows.
        let saved = #"[{"key":"message"},{"key":"bogus","width":10},{"key":"time","width":5},{"key":"level","width":9999,"hidden":true},{"key":"time","width":300}]"#
        XCTAssertEqual(value(context, "describe(columnLayout(LOG_COLUMNS, \(saved)))"),
                       "message,time60,level-640,subsystem160,category-120,process-110")
        XCTAssertEqual(value(context, "columnLayout(LOG_COLUMNS, [{ key: 'message', hidden: true }])[0].hidden"), "false", "the flexible column is never hidden")
        XCTAssertEqual(value(context, "columnLayout(LOG_COLUMNS, 'not a list').length"), "6")
        // A column a later viewer adds lands after its neighbour in an older saved order.
        XCTAssertEqual(value(context, "describe(columnLayout(NETWORK_COLUMNS, ['name', 'time', 'status', 'method', 'size', 'duration'].map(key => ({ key }))))"),
                       "name,time86,status118,method46,size62,duration64,wf90")
    }

    func testAMovedColumnStandsBeforeTheOneItWasDroppedOn() throws {
        let context = try makeContext()
        context.evaluateScript("var layout = columnLayout(LOG_COLUMNS, null); var keys = (l) => l.map(c => c.key).join(',');")
        XCTAssertEqual(value(context, "keys(moveColumn(layout, 'message', 1))"), "time,message,level,subsystem,category,process")
        XCTAssertEqual(value(context, "keys(moveColumn(layout, 'time', 3))"), "level,subsystem,time,category,process,message", "moving right counts the gap it leaves")
        XCTAssertEqual(value(context, "keys(moveColumn(layout, 'level', layout.length))"), "time,subsystem,category,process,message,level")
        XCTAssertEqual(value(context, "keys(moveColumn(layout, 'nope', 0))"), "time,level,subsystem,category,process,message")
    }

    func testTheRowsGridFollowsTheShownColumnsAndEachNarrowerStepDropsItsColumns() throws {
        let context = try makeContext()
        context.evaluateScript("var logs = moveColumn(columnLayout(LOG_COLUMNS, [{ key: 'subsystem', width: 200 }, { key: 'process', hidden: false }]), 'message', 0);")
        XCTAssertEqual(value(context, "gridTemplate(LOG_COLUMNS, logs, 0)"), "minmax(120px, 1fr) 86px 62px 200px 110px")
        XCTAssertEqual(value(context, "gridTemplate(LOG_COLUMNS, logs, 1)"), "minmax(120px, 1fr) 86px 62px")
        XCTAssertEqual(value(context, "shownColumns(LOG_COLUMNS, logs, 1).map(c => c.key).join(',')"), "message,time,level")
        context.evaluateScript("var net = moveColumn(columnLayout(NETWORK_COLUMNS, null), 'duration', 0);")
        XCTAssertEqual(value(context, "gridTemplate(NETWORK_COLUMNS, net, 0)"), "64px 86px 46px minmax(140px, 1fr) 118px 62px 90px")
        XCTAssertEqual(value(context, "gridTemplate(NETWORK_COLUMNS, net, 1)"), "64px 86px 46px minmax(140px, 1fr) 118px", "≤ 760 px: no size, no waterfall")
        XCTAssertEqual(value(context, "gridTemplate(NETWORK_COLUMNS, net, 2)"), "64px 86px minmax(140px, 1fr) 118px", "≤ 560 px: no method either")
    }

    // MARK: - Filters

    func testChipsExcludeFirstThenIncludeAnyThenTheLiveText() throws {
        let context = try makeContext()
        context.evaluateScript("var chips = [{ kind: 'include', term: 'catalog' }, { kind: 'include', term: 'cart' }, { kind: 'exclude', term: 'analytics' }];")
        XCTAssertEqual(value(context, "matchesFilters('get /catalog/list', chips, '')"), "true")
        XCTAssertEqual(value(context, "matchesFilters('post /cart/analytics', chips, '')"), "false", "exclude wins")
        XCTAssertEqual(value(context, "matchesFilters('get /orders', chips, '')"), "false", "includes are OR'd")
        XCTAssertEqual(value(context, "matchesFilters('get /catalog/list', chips, 'orders')"), "false", "the live text narrows further")
    }

    func testAFieldTermMatchesOnlyThatField() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "JSON.stringify(parseFieldTerm('subsystem:com.app', ['subsystem', 'message']))"), #"{"field":"subsystem","term":"com.app"}"#)
        XCTAssertEqual(value(context, "parseFieldTerm('https://x', ['subsystem']).field"), "null", "an URL's scheme is not a field")
        XCTAssertEqual(value(context, "matchesFilters('', [{ kind: 'include', term: 'net', field: 'subsystem' }], '', { subsystem: 'com.app.net', message: '' })"), "true")
        XCTAssertEqual(value(context, "matchesFilters('net', [{ kind: 'include', term: 'net', field: 'subsystem' }], '', { subsystem: 'com.app.ui', message: 'net' })"), "false")
    }

    func testAnExcludeChipReplacesTheSameIncludeInsteadOfStacking() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "JSON.stringify(withChip([{ kind: 'include', term: 'Cart' }], 'exclude', 'cart'))"), #"[{"kind":"exclude","term":"cart"}]"#)
        XCTAssertEqual(value(context, "withChip([], 'include', '   ').length"), "0")
    }

    // MARK: - Logs

    func testAnErrorIsALevelNotAWordInTheMessage() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "isLogError({ level: 'Info', message: 'Did post notification. error:0' })"), "false")
        XCTAssertEqual(value(context, "isLogError({ level: 'Error', message: 'ok' })"), "true")
        XCTAssertEqual(value(context, "isLogError({ level: 'fault' })"), "true")
        XCTAssertEqual(value(context, "logLevel({})"), "Default", "a line without a level is Default")
    }

    func testALineAtOrBelowTheCursorIsNeverTakenAgain() throws {
        let context = try makeContext()
        context.evaluateScript("var lines = [{ sequence: 4 }, { sequence: 5 }, { sequence: 6 }];")
        XCTAssertEqual(value(context, "linesAfter(lines, 5).map(l => l.sequence).join()"), "6")
        XCTAssertEqual(value(context, "linesAfter(lines, null).length"), "3", "no cursor yet: every line")
        XCTAssertEqual(value(context, "linesAfter(lines, 9).length"), "0")
        XCTAssertEqual(value(context, "linesAfter(undefined, 1).length"), "0")
    }

    // MARK: - State

    func testStateDiffsNameTheChangedPaths() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "JSON.stringify(diffStateValues({ total: 1, items: ['a'], nested: { on: false } }, { total: 2, items: ['a'], nested: { on: true } }, '', []))"),
                       #"[{"path":"total","before":1,"after":2},{"path":"nested.on","before":false,"after":true}]"#)
        XCTAssertEqual(value(context, "diffStateValues({ $modelId: 'A' }, { $modelId: 'B' }, '', []).length"), "0", "the marker never diffs")
    }

    // A list of three hundred placeholders changed wholesale is one line, said
    // in runs; a few items changed are named one by one.
    func testAListThatChangedWholesaleIsOneShortLine() throws {
        let context = try makeContext()
        context.evaluateScript("var atms = Array.from({ length: 300 }, () => '<ATM>');")
        XCTAssertEqual(value(context, "JSON.stringify(diffStateValues({ atms: [] }, { atms: atms }, '', []).map(d => d.path))"), #"["atms"]"#)
        XCTAssertEqual(value(context, "stateValueText(atms)"), #"["<ATM>" ×300]"#)
        XCTAssertEqual(value(context, "stateValueText([])"), "[]")
        XCTAssertEqual(value(context, "stateValueText(Array.from({ length: 300 }, (_, i) => i)).length <= STATE_TEXT_LIMIT + 12"), "true", "a long list is cut")
        XCTAssertTrue(value(context, "stateValueText(Array.from({ length: 300 }, (_, i) => i))").hasSuffix(" 300 items]"))
        XCTAssertEqual(value(context, "JSON.stringify(diffStateValues({ tags: ['a', 'b'] }, { tags: ['a', 'b', 'c'] }, '', []))"),
                       #"[{"path":"tags[2]","after":"c"}]"#, "an added item is named")
        XCTAssertEqual(value(context, "JSON.stringify(diffStateValues({ rows: [{ n: 1 }, { n: 2 }] }, { rows: [{ n: 1 }, { n: 3 }] }, '', []).map(d => d.path))"), #"["rows[1].n"]"#)
        XCTAssertEqual(value(context, "diffStateValues({ atms: atms }, { atms: atms.slice() }, '', []).length"), "0", "placeholders that look the same are no change")
    }

    func testARunOfOneValueIsOneRowOfTheSnapshot() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "JSON.stringify(stateArrayRows(['a', '<ATM>', '<ATM>', '<ATM>', { n: 1 }, { n: 1 }]).map(r => r.label + ' ' + r.count))"),
                       #"["[0] 1","[1…3] 3","[4] 1","[5] 1"]"#, "objects keep a row each: they unfold")
    }

    // A report in which nothing changed is no entry in Changes; the app's own
    // observation fires on every write, equal or not.
    func testAReportThatChangedNothingIsNoChange() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var view = { latest: {}, changes: [], lastChange: {}, newestLaunch: null };
        foldStateEvent(view, { modelId: 'Map#0', seq: 0, launchId: 1, snapshot: { selected: null } }, true);
        foldStateEvent(view, { modelId: 'Map#0', seq: 1, launchId: 1, snapshot: { selected: 9 } }, true);
        foldStateEvent(view, { modelId: 'Map#0', seq: 2, launchId: 1, snapshot: { selected: 9 } }, true);
        """)
        XCTAssertEqual(value(context, "view.changes.map(c => c.event.seq).join()"), "1")
        XCTAssertEqual(value(context, "JSON.stringify(view.lastChange)"), #"{"Map#0":["selected"]}"#, "the last real change stays marked")
    }

    // The app started over: its models are named again from #0 by the new
    // process. That is a new instance — no diff against the old process — and
    // a model only the old process had is ended, not alive.
    func testAModelOfAnEarlierLaunchEndedWithItsProcess() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var view = { latest: {}, changes: [], lastChange: {}, newestLaunch: null };
        foldStateEvent(view, { modelId: 'Cart#0', seq: 0, launchId: 3, pid: 100, snapshot: { items: 2 } }, true);
        foldStateEvent(view, { modelId: 'OTP#0', seq: 0, launchId: 3, pid: 100, snapshot: { code: '12' } }, true);
        foldStateEvent(view, { modelId: 'Cart#0', seq: 0, launchId: 4, pid: 200, snapshot: { items: 0 } }, true);
        """)
        XCTAssertEqual(value(context, "view.changes.length"), "0", "a new process's first report is not a change")
        XCTAssertEqual(value(context, "view.latest['Cart#0'].snapshot.items"), "0")
        XCTAssertEqual(value(context, "stateModelStatus(view.latest['Cart#0'], view.newestLaunch)"), "alive")
        XCTAssertEqual(value(context, "stateModelStatus(view.latest['OTP#0'], view.newestLaunch)"), "ended")
        XCTAssertEqual(value(context, "stateModelStatus({ deallocated: true, launchId: 4 }, 4)"), "deallocated")
        XCTAssertEqual(value(context, "stateModelStatus({ launchId: null }, 4)"), "alive", "an event without a launch cannot be judged")
        XCTAssertEqual(value(context, "JSON.stringify(embeddedModelIds({ Old: { launchId: 3, snapshot: { child: { $modelId: 'Child' } } } }, 4))"), "{}",
                       "a child resurfaces once its parent's process ended")
    }

    func testAReviewedRunKnowsWhenTheAppStartedOver() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var events = [{ modelId: 'OTP#0', seq: 0, launchId: 1, timestamp: 10, snapshot: { code: '' } }];
        var before = foldStateEvents(events, { from: 0, to: 15000 }, [{ launchId: 2, at: 20000 }]);
        var after = foldStateEvents(events, { from: 0, to: 25000 }, [{ launchId: 2, at: 20000 }]);
        """)
        XCTAssertEqual(value(context, "stateModelStatus(before.latest['OTP#0'], before.newestLaunch)"), "alive")
        XCTAssertEqual(value(context, "stateModelStatus(after.latest['OTP#0'], after.newestLaunch)"), "ended", "the relaunch came before the end of the window")
    }

    func testAModelEmbeddedInALiveParentIsFoldedIntoIt() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "JSON.stringify(embeddedModelIds({ Parent: { snapshot: { child: { $modelId: 'Child', n: 1 } } }, Child: { snapshot: { n: 1 } } }))"), #"{"Child":"Parent"}"#)
        XCTAssertEqual(value(context, "JSON.stringify(embeddedModelIds({ Parent: { deallocated: true, snapshot: { child: { $modelId: 'Child' } } } }))"), "{}",
                       "a child resurfaces once its parent deallocates")
    }

    // MARK: - Tests and recordings

    func testOutcomesSayWhatTheVerdictMeansForTheKind() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "outcomeOf({ verdict: 'unsatisfied', kind: 'bug' }).text"), "Bug reproduced")
        XCTAssertEqual(value(context, "outcomeOf({ verdict: 'satisfied', kind: 'feature' }).text"), "Confirmed")
        XCTAssertEqual(value(context, "outcomeOf({ verdict: 'infra' }).text"), "Infra — cannot be trusted")
        XCTAssertEqual(value(context, "outcomeOf({ status: 'failed' }).text"), "Failed", "tests without a kind keep pass/fail")
    }

    func testStepTextSplitsIntoMarkPositionHeadAndReason() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "JSON.stringify(parseStepText('✗ 3/3 Wait for \"Done\" · AC-1 — no element appeared'))"),
                       #"{"mark":"failed","index":3,"total":3,"text":"Wait for \"Done\" · AC-1 — no element appeared"}"#)
        XCTAssertEqual(value(context, "JSON.stringify(splitStep('Wait for \"Done\" — no element appeared'))"), #"{"head":"Wait for \"Done\"","tail":"no element appeared"}"#)
        XCTAssertEqual(value(context, "parseStepText('Launched com.example').mark"), "note")
    }

    func testStepOffsetsScaleOntoAVideoShorterThanTheWallClock() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var session = { startedAt: '2026-01-01T00:00:00Z', recordingStartedAt: '2026-01-01T00:00:00Z', endedAt: '2026-01-01T00:00:20Z', videoDurationSeconds: 10 };
        """)
        XCTAssertEqual(value(context, "entryOffsetSeconds(session, { at: '2026-01-01T00:00:10Z' })"), "5")
        XCTAssertEqual(value(context, "entryOffsetSeconds(session, { at: '2026-01-01T00:00:30Z' })"), "10", "never past the end of the video")
        XCTAssertEqual(value(context, "entryOffsetSeconds({ startedAt: '2026-01-01T00:00:00Z' }, { at: '2026-01-01T00:00:04Z' })"), "4")
    }

    func testTheLastRunOfEachTestIsItsNewestFinishedSession() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, """
        (r => r['a.yml'].id + ',' + r['b.yml'].id)(lastRunByFile([
          { id: 'old', file: 'a.yml', status: 'failed', startedAt: '2026-01-01T00:00:00Z' },
          { id: 'new', file: 'a.yml', status: 'passed', startedAt: '2026-01-02T00:00:00Z' },
          { id: 'live', file: 'a.yml', status: 'running', startedAt: '2026-01-03T00:00:00Z' },
          { id: 'b', file: 'b.yml', status: 'passed', startedAt: '2026-01-01T00:00:00Z' }
        ]))
        """), "new,b")
    }

    // MARK: - Accessibility

    // Measured on an iPhone 17 Pro: a still Settings screen sends 169–215-byte
    // frames five times a second, the clock ticking over sends 612 bytes.
    func testOnlyAFrameThatChangesThePictureCountsAsAChange() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "frameChangesScreen('delta', 215, 169)"), "false", "the same picture again")
        XCTAssertEqual(value(context, "frameChangesScreen('delta', 612, 169)"), "true", "the clock ticked over")
        XCTAssertEqual(value(context, "frameChangesScreen('delta', 25519, 169)"), "true")
        XCTAssertEqual(value(context, "frameChangesScreen('keyframe', 30000, 169)"), "true")
        XCTAssertEqual(value(context, "frameChangesScreen('delta', 380, 120)"), "false", "never below 400 bytes")
        XCTAssertEqual(value(context, "frameChangesScreen('delta', 5637, 5637)"), "false", "the first frame after a keyframe is its own measure")
    }

    func testAStepNamesAnElementTheWayTheRunnerFindsIt() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "axYamlStep({ accessibilityIdentifier: 'About', label: 'About us' })"), #"- tap: { id: "About" }"#)
        XCTAssertEqual(value(context, "axYamlStep({ label: ' Settings ' })"), #"- tap: { label: "Settings" }"#)
        XCTAssertEqual(value(context, "axYamlStep({ frame: { x: 10, y: 20, width: 100, height: 40 } })"), "- tap: { x: 60, y: 40 }", "a nameless element is tapped at its centre")
        XCTAssertEqual(value(context, "axCliCommand({ label: \"Bob's\" })"), #"simtool input tap --label 'Bob'\''s'"#)
        XCTAssertEqual(value(context, "axSelectorCount([{ title: 'Done', children: [{ label: ' Done ' }, { accessibilityIdentifier: 'Done' }] }], { key: 'label', value: 'Done' })"), "2",
                       "a label matches a label or a title, never an id")
    }

    // A touch overlay shares its id with a dozen others; the runner taps the
    // first match, wherever it is. Pick names only what finds this element alone.
    func testAPickedElementIsNamedOnlyByWhatFindsItAlone() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var frame = (x, y, width, height) => ({ x, y, width, height });
        var avatar = { accessibilityIdentifier: 'TouchOverlayView', frame: frame(183, 70, 36, 36) };
        var overlay = { accessibilityIdentifier: 'TouchOverlayView', frame: frame(0, 122, 382, 56) };
        var widget = { accessibilityIdentifier: 'HomeScreen-ProfileWidget', frame: frame(0, 122, 382, 56), children: [
          { accessibilityIdentifier: 'AvatarView-AvatarIcon', label: 'ic_profile_default', frame: frame(40, 122, 56, 56) },
          { accessibilityIdentifier: 'HomeScreen-ProfileNameText', label: 'Alex', frame: frame(114, 129, 85, 20) }
        ] };
        var card = { accessibilityIdentifier: 'CardRow-CardView', frame: frame(122, 395, 70, 48) };
        var cardOverlay = { accessibilityIdentifier: 'TouchOverlayView', frame: frame(122, 395, 70, 48) };
        var row = { accessibilityIdentifier: 'probe.row0', frame: frame(16, 442, 370, 36), children: [{ accessibilityIdentifier: 'probe.row0', label: 'Row 0', frame: frame(177, 450, 47, 20) }] };
        var lone = { accessibilityIdentifier: 'TouchOverlayView', frame: frame(300, 600, 20, 20) };
        var roots = [{ label: 'App', frame: frame(0, 0, 402, 874), children: [avatar, widget, overlay, card, { accessibilityIdentifier: 'CardRow-CardView', frame: frame(40, 395, 70, 48) }, cardOverlay, row, lone] }];
        """)
        XCTAssertEqual(value(context, "axYamlStep(widget, roots)"), #"- tap: { id: "HomeScreen-ProfileWidget" }"#)
        XCTAssertEqual(value(context, "axYamlStep(overlay, roots)"), #"- tap: { id: "HomeScreen-ProfileWidget" }"#,
                       "the shared id gives way to the view it covers: the same centre, the same tap")
        XCTAssertEqual(value(context, "axSelector(overlay, roots).via === widget"), "true")
        XCTAssertEqual(value(context, "axYamlStep(row.children[0], roots)"), #"- tap: { label: "Row 0" }"#, "its id is shared with the row; its label is not")
        XCTAssertEqual(value(context, "axYamlStep(cardOverlay, roots)"), "- tap: { x: 157, y: 419 }",
                       "nothing at its centre is unique: the centre, never an ambiguous id")
        XCTAssertEqual(value(context, "axCliCommand(lone, roots)"), "simtool input tap --x 310 --y 610")
        XCTAssertEqual(value(context, "axYamlStep(overlay)"), #"- tap: { id: "TouchOverlayView" }"#, "without the tree, as before")
        XCTAssertEqual(value(context, "axIsAnonymous({ role: 'AXGroup', label: '  ' })"), "true")
        XCTAssertEqual(value(context, "axRoleName({ role: 'AXButton' })"), "Button")
    }

    // MARK: - Annotations

    // Every annotation in one prompt for an agent: a line naming the app and
    // the device, then each note — its kind, its element as the tree names it,
    // in whole points — and the person's words under it.
    func testAnnotationsCopyAsOnePromptForTheAgent() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var items = [
          { id: 'a', kind: 'change', text: 'Make it the secondary style.', element: { role: 'Button', id: 'home.transfer', label: 'Transfer', value: '', frame: { x: 16, y: 540.4, width: 361, height: 51.6 } } },
          { id: 'b', kind: 'question', text: 'Where does this text come from — a localization key?', element: { role: 'StaticText', id: '', label: 'Bienvenido', value: '', frame: { x: 24, y: 180, width: 200, height: 20 } } }
        ];
        var where = { app: 'com.example.shop', device: 'iPhone 17 Pro', os: 'iOS 26.4' };
        """)
        XCTAssertEqual(value(context, "annotationsPrompt(items, where)"), """
        SimTool annotations — 2 items · com.example.shop · iPhone 17 Pro (iOS 26.4)

        1. [Change] Button "Transfer" (id: home.transfer, frame 16,540 361×52)
           Make it the secondary style.
        2. [Question] StaticText "Bienvenido" (frame 24,180 200×20)
           Where does this text come from — a localization key?
        """)
        XCTAssertEqual(value(context, "annotationsPrompt(items.slice(1), { device: 'iPhone 17 Pro' }).split('\\n')[0]"), "SimTool annotations — 1 item · iPhone 17 Pro",
                       "no app attached, no runtime known: the header says what it knows")
        XCTAssertEqual(value(context, "annotationsPrompt([], where)"), "", "nothing to copy")
        XCTAssertEqual(value(context, "annotationsPrompt(null)"), "")
    }

    // An element is named by what it has: an id, a label, a value that says
    // more than the label — and its frame always, for the ones with neither.
    func testAnAnnotatedElementIsNamedByWhatItHas() throws {
        let context = try makeContext()
        context.evaluateScript("var at = { x: 0, y: 0, width: 40, height: 40 };")
        func text(_ element: String) -> String { value(context, "annotationElementText(\(element))") }
        XCTAssertEqual(text("{ role: 'Button', id: 'pay', label: '', value: '', frame: at }"), "Button (id: pay, frame 0,0 40×40)")
        XCTAssertEqual(text("{ role: 'Image', id: '', label: '', value: '', frame: at }"), "Image (frame 0,0 40×40)")
        XCTAssertEqual(text("{ role: 'TextField', id: 'amount', label: 'Amount', value: '100', frame: at }"), #"TextField "Amount" (id: amount, value: "100", frame 0,0 40×40)"#)
        XCTAssertEqual(text(#"{ role: 'StaticText', id: '', label: 'Say "hi"', value: 'Say "hi"', frame: at }"#), #"StaticText "Say \"hi\"" (frame 0,0 40×40)"#,
                       "a label's own quotes stay readable; a value that repeats it is not said twice")
        XCTAssertEqual(text("{ role: 'Switch', id: 'push', label: 'Push', value: '1' }, false"), #"Switch "Push" (id: push, value: "1")"#, "the popover's chip leaves the frame out")
        XCTAssertEqual(value(context, "JSON.stringify(axSnapshot({ role: 'AXButton', label: ' Pay ', frame: { x: 1, y: 2, width: 3, height: 4 } }))"),
                       #"{"role":"Button","id":"","label":"Pay","value":"","frame":{"x":1,"y":2,"width":3,"height":4}}"#)
        XCTAssertEqual(value(context, "axSnapshot({ role: 'AXButton', title: 'Close' }).label"), "Close", "a title stands in for a missing label")
    }

    // A region names the elements a test can name that lie mostly inside it,
    // in reading order — never the app, never a container that only overlaps.
    func testARegionPrintsTheElementsInsideIt() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var nodes = [
          { _depth: 0, role: 'AXApplication', label: 'Shop', frame: { x: 0, y: 0, width: 402, height: 874 } },
          { _depth: 2, role: 'AXButton', accessibilityIdentifier: 'pay', label: 'Pay', frame: { x: 16, y: 640, width: 370, height: 48 } },
          { _depth: 2, role: 'AXStaticText', label: 'Total', frame: { x: 16, y: 604, width: 60, height: 16 } },
          { _depth: 1, role: 'AXGroup', frame: { x: 0, y: 600, width: 402, height: 100 } },
          { _depth: 1, role: 'AXButton', label: 'Help', frame: { x: 300, y: 560, width: 80, height: 60 } }
        ];
        var region = { x: 0, y: 600, width: 402, height: 120 };
        var inside = axElementsInside(nodes, region).map(axSnapshot);
        """)
        XCTAssertEqual(value(context, "inside.map(e => e.label).join()"), "Total,Pay", "Help has only a third of itself inside; the group has no name")
        XCTAssertEqual(value(context, "annotationsPrompt([{ kind: 'change', text: 'Make this area scroll.', region: region, inside: inside }], {})"), """
        SimTool annotations — 1 item

        1. [Change] Region (frame 0,600 402×120) containing:
           - StaticText "Total" (frame 16,604 60×16)
           - Button "Pay" (id: pay, frame 16,640 370×48)
           Make this area scroll.
        """)
        XCTAssertEqual(value(context, "annotationPromptItem({ kind: 'question', text: 'What is drawn here?', region: region, inside: [] }, 12)"), """
        12. [Question] Region (frame 0,600 402×120), no accessibility elements inside
            What is drawn here?
        """, "the words line up under the number, however wide it is")
        XCTAssertEqual(value(context, "annotationPromptItem({ kind: 'change', text: 't', region: region, inside: Array.from({ length: 14 }, () => inside[0]) }, 1).split('\\n').slice(-2).join('|')"),
                       "   - … and 2 more|   t", "a crowded region names twelve and counts the rest")
    }

    // Words keep their lines, each indented under the note; blank lines stay
    // blank, and nothing trails at the ends.
    func testAnAnnotationsWordsKeepTheirLines() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, #"annotationPromptItem({ kind: 'change', text: '  First.\n\n  - keep this\nLast.  \n', element: { role: 'Cell', id: 'row', label: '', value: '', frame: { x: 0, y: 0, width: 1, height: 1 } } }, 3)"#), """
        3. [Change] Cell (id: row, frame 0,0 1×1)
           First.

             - keep this
           Last.
        """)
    }

    // A pin shows while its element is where it was: the same names within
    // 2 pt. Scrolled away, renamed or gone, the note keeps its snapshot and
    // its pin hides. A region shows while half of what it held still does.
    func testAnAnnotationsPinShowsOnlyWhileItsElementIsWhereItWas() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var pay = (dy, label, value) => ({ role: 'AXButton', accessibilityIdentifier: 'pay', label: label || 'Pay', value: value, frame: { x: 16, y: 620 + dy, width: 370, height: 48 } });
        var total = { role: 'AXStaticText', label: 'Total', frame: { x: 16, y: 604, width: 60, height: 16 } };
        var item = { kind: 'change', text: 'x', element: axSnapshot(pay(0)) };
        var region = { kind: 'change', text: 'x', region: { x: 0, y: 600, width: 402, height: 120 }, inside: [axSnapshot(pay(0)), axSnapshot(total)] };
        """)
        XCTAssertEqual(value(context, "annotationOnScreen(item, [total, pay(0)])"), "true")
        XCTAssertEqual(value(context, "annotationOnScreen(item, [pay(1.5)])"), "true", "a layout pass a point off is the same place")
        XCTAssertEqual(value(context, "annotationOnScreen(item, [pay(-40)])"), "false", "scrolled away")
        XCTAssertEqual(value(context, "annotationOnScreen(item, [pay(0, 'Pay now')])"), "false", "another element in its place")
        XCTAssertEqual(value(context, "annotationOnScreen(item, [pay(0, 'Pay', 'on')])"), "true", "a named element keeps its identity when its value changes")
        XCTAssertEqual(value(context, "annotationNode(item.element, [total, pay(0)]) !== null"), "true")
        XCTAssertEqual(value(context, "annotationOnScreen(region, [pay(0)])"), "true", "half of it is still there")
        XCTAssertEqual(value(context, "annotationOnScreen(region, [pay(-200)])"), "false")
        XCTAssertEqual(value(context, "annotationOnScreen({ region: region.region, inside: [] }, [])"), "true", "a region that held nothing cannot tell")
        XCTAssertEqual(value(context, "axReadingOrder([pay(0), total]).map(n => n.label).join()"), "Total,Pay")
    }

    // An app's logger may count an empty request message as nothing at all.
    // Protobuf sends a message with no fields as no bytes, so its size is 0 B,
    // not "—"; a size the preview cannot settle stays unknown.
    func testAnEmptyGRPCMessageTheLoggerDidNotCountIsZeroBytes() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var call = (request, response) => ({ protocol: 'grpc', request, response });
        """)
        XCTAssertEqual(value(context, "messageByteCount(call({ messageByteCount: 27 }, {}), 'request')"), "27")
        XCTAssertEqual(value(context, "messageByteCount(call({ bodyPreview: 'ExampleAPI.GetProfileRequest:\\n' }, {}), 'request')"), "0")
        XCTAssertEqual(value(context, "messageByteCount(call({ bodyPreview: 'Api.GetChatsRequest:\\nproduct: PRODUCT_TYPE_SUPPORT\\n' }, {}), 'request')"), "null",
                       "a message with fields has a size only the app knows")
        XCTAssertEqual(value(context, "messageByteCount(call({ bodyPreview: 'Api.Request:\\nnested {\\n  id: 1' }, {}), 'request')"), "null", "a cut preview settles nothing")
        XCTAssertEqual(value(context, "messageByteCount(call({}, { bodyPreview: 'Api.Empty:\\n' }), 'response')"), "0")
        XCTAssertEqual(value(context, "networkSize(call({}, { messageByteCount: 132 }))"), "132")
        XCTAssertEqual(value(context, "messageByteCount({ protocol: 'http', request: { method: 'GET' } }, 'request')"), "null")
        XCTAssertEqual(value(context, "messageByteCount({ protocol: 'http', request: { bodyByteCount: 12 } }, 'request')"), "12")
    }

    // MARK: - Formatting

    func testFormattingUsesOneClockAndReadableUnits() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "formatClock(new Date(2026, 0, 2, 3, 4, 5, 6), true)"), "03:04:05.006")
        XCTAssertEqual(value(context, "formatClock('not a date')"), "not a date", "a bad timestamp shows as it came")
        XCTAssertEqual(value(context, "formatDuration(84)"), "84 ms")
        XCTAssertEqual(value(context, "formatDuration(2310)"), "2.31 s")
        XCTAssertEqual(value(context, "formatBytes(2416)"), "2.4 kB")
        XCTAssertEqual(value(context, "formatOffset(83.4)"), "1:23")
        XCTAssertEqual(value(context, "plural(1, 'step', 'steps') + ' / ' + plural(2, 'step', 'steps')"), "1 step / 2 steps")
        XCTAssertEqual(value(context, "runtimeName('com.apple.CoreSimulator.SimRuntime.iOS-26-4')"), "iOS 26.4")
        // The iPhone Duo's device-specific runtime: the OS version, not the model.
        XCTAssertEqual(value(context, "runtimeName('com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4')"), "iOS 27.2")
        XCTAssertEqual(value(context, "runtimeName('com.apple.CoreSimulator.SimRuntime.watchOS-11-0')"), "watchOS 11.0")
    }

    // MARK: - A screen's picture

    // The open inner panel of an iPhone Duo streams a portrait framebuffer
    // under a landscape picture: its frames are turned once their shape is
    // the panel's, and a cover frame still in flight is not.
    func testAFrameTurnsWithTheScreenItShows() throws {
        let context = try makeContext()
        context.evaluateScript("var inner = { id: 'primary-1', width: 2007, height: 2853, rotation: 90 };")
        XCTAssertEqual(value(context, "frameRotation(900, 1280, inner)"), "90", "the encoder scales, the shape stays")
        XCTAssertEqual(value(context, "frameRotation(880, 1280, inner)"), "0", "a cover frame (1398×2034) is not the inner panel's")
        XCTAssertEqual(value(context, "frameRotation(900, 1280, null)"), "0")
        XCTAssertEqual(value(context, "frameRotation(900, 1280, { width: 2007, height: 2853, rotation: -90 })"), "270")
    }

    // The canvas transform must put the framebuffer's bottom-left corner at
    // the top-left of a picture turned 90° clockwise.
    func testTheCanvasTurnPutsEachCornerWhereThePictureHasIt() throws {
        let context = try makeContext()
        context.evaluateScript("""
        function place(rotation, x, y) {
          var t = canvasTurn(rotation, 300, 200);
          return Math.round(t.a * x + t.c * y + t.e) + "," + Math.round(t.b * x + t.d * y + t.f);
        }
        """)
        // Drawn at (turn.width × turn.height) = (200 × 300) in frame space.
        XCTAssertEqual(value(context, "place(90, 0, 300)"), "0,0", "the frame's bottom-left lands top-left")
        XCTAssertEqual(value(context, "place(90, 0, 0)"), "300,0", "the frame's top-left lands top-right")
        XCTAssertEqual(value(context, "[canvasTurn(90, 300, 200).width, canvasTurn(90, 300, 200).height].join('x')"), "200x300")
        XCTAssertEqual(value(context, "place(180, 0, 0)"), "300,200")
        XCTAssertEqual(value(context, "place(270, 0, 0)"), "0,200")
        XCTAssertEqual(value(context, "place(0, 10, 20)"), "10,20")
    }

    // A click on the 3D device lands on the panel's framebuffer through the
    // projected quad of the leaf it hit, and goes out as a picture fraction.
    func testA3DClickLandsOnThePanelUnderIt() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var flat = { pieces: [[[0.1, 0.2], [0.5, 0.2], [0.5, 0.8], [0.1, 0.8], [0, 0.5, 1, 0.5]],
                              [[0.5, 0.2], [0.9, 0.2], [0.9, 0.8], [0.5, 0.8], [0, 0, 1, 0.5]]] };
        function at(x, y) { var p = pointOnDuoScreen(flat, x, y); return p ? p.x.toFixed(3) + "," + p.y.toFixed(3) : "none"; }
        """)
        XCTAssertEqual(value(context, "at(0.1, 0.2)"), "0.000,0.500", "the first leaf's top-left is its region's top-left")
        XCTAssertEqual(value(context, "at(0.3, 0.5)"), "0.500,0.750")
        XCTAssertEqual(value(context, "at(0.7, 0.5)"), "0.500,0.250")
        XCTAssertEqual(value(context, "at(0.05, 0.5)"), "none", "beside the screen touches nothing")
        XCTAssertEqual(value(context, "pointOnDuoScreen(null, 0.5, 0.5)"), "null")
        // The inverse of the server's turn (SimulatorDisplayRotation.framebufferRatio).
        XCTAssertEqual(value(context, "JSON.stringify(pictureRatio({ x: 0.496, y: 0.832 }, 90))"), #"{"x":0.16800000000000004,"y":0.496}"#)
        XCTAssertEqual(value(context, "JSON.stringify(pictureRatio({ x: 0.9, y: 0.25 }, 270))"), #"{"x":0.25,"y":0.09999999999999998}"#)
        XCTAssertEqual(value(context, "JSON.stringify(pictureRatio({ x: 0.75, y: 0.9 }, 180))"), #"{"x":0.25,"y":0.09999999999999998}"#)
        XCTAssertEqual(value(context, "JSON.stringify(pictureRatio({ x: 0.3, y: 0.4 }, 0))"), #"{"x":0.3,"y":0.4}"#)
        XCTAssertEqual(value(context, "cssColorHex('rgb(27, 29, 32)')"), "1b1d20")
        // A stage that changed shape asks for frames of its new shape; a pixel's worth does not.
        XCTAssertEqual(value(context, "stageReframes(0.8, 0.81)"), "false")
        XCTAssertEqual(value(context, "stageReframes(0.8, 1.1)"), "true")
        XCTAssertEqual(value(context, "stageReframes(0.8, 0.7)"), "true")
        XCTAssertEqual(value(context, "stageReframes(0, 1.1)"), "false", "no 3D frames asked for yet")
        XCTAssertEqual(value(context, "cssColorHex('transparent')"), "000000")
    }

    func testTheToolbarSaysHowTheDeviceIsFolded() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "foldReadout({ hingeDegrees: 130, pose: 'book', panel: 'inner' })"), "book · 130° · inner")
        XCTAssertEqual(value(context, "foldReadout({ hingeDegrees: 92.64, panel: 'inner' })"), "92.6° · inner")
        XCTAssertEqual(value(context, "foldReadout({ panel: 'cover' })"), "cover")
        XCTAssertEqual(value(context, "foldReadout(null)"), "")
    }

    func testTheScreensCornersComeFromItsDeviceTypeInProportion() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "screenRadius({ cornerRadii: [8, 59, 59, 8], points: { width: 466, height: 678 } }, 233)"), "4px 30px 30px 4px")
        XCTAssertEqual(value(context, "screenRadius({ points: { width: 466, height: 678 } }, 233)"), "", "no radii: the page's own heuristic")
        XCTAssertEqual(value(context, "screenRadius(null, 233)"), "")
    }

    // MARK: - Theme

    // The theme button pins the other theme, and forgets the pin once the other
    // theme is the system's: two clicks always lead back to following the system.
    func testTheThemeButtonPinsTheOtherThemeUnlessTheSystemShowsIt() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "themeAfterToggle('dark', 'dark')"), "light")
        XCTAssertEqual(value(context, "themeAfterToggle('light', 'dark')"), "null", "back to the system's dark")
        XCTAssertEqual(value(context, "themeAfterToggle('light', 'light')"), "dark")
        XCTAssertEqual(value(context, "themeAfterToggle('dark', 'light')"), "null", "back to the system's light")
    }
}

// What drives the device, and what the activity feed draws and copies.
final class WebViewerActivityLogicTests: XCTestCase {
    private func makeContext(file: StaticString = #filePath, line: UInt = #line) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in
            XCTFail("JS exception: \(exception?.toString() ?? "?")", file: file, line: line)
        }
        context.evaluateScript(WebViewer.asset("js/logic.js"))
        return context
    }

    private func value(_ context: JSContext, _ expression: String) -> String {
        context.evaluateScript(expression)?.toString() ?? ""
    }

    func testARunningTestDrivesTheDeviceAndSaysWhichStepIsNext() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var steps = [{ id: 1, actor: 'test', kind: 'step', title: '✓ 2/5 tap “General”', at: '2026-10-20T12:00:00.000Z', status: 'done' }];
        var cli = { active: true, sessionId: 's-1', name: 'Settings flow', completedSteps: 0, totalSteps: 0 };
        """)
        XCTAssertEqual(value(context, "(d => d.actor + ' ' + d.key + ' ' + d.step.index + '/' + d.step.total)(deviceDriver(steps, cli, 0))"), "test test:s-1 3/5",
                       "a run started from the CLI has no counts: the last step says where it is")
        XCTAssertEqual(value(context, "deviceDriver(steps, { active: true, file: 'a.yml', completedSteps: 1, totalSteps: 4 }, 0).step.index"), "2")
    }

    func testAnAgentDrivesUntilItHasBeenQuietForHalfAMinute() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var t = Date.parse('2026-10-20T12:00:00.000Z');
        var at = (s) => new Date(t + s * 1000).toISOString();
        var feed = [
          { id: 1, actor: 'agent', kind: 'tap', title: 'Tap “Wi-Fi”', at: at(0), endedAt: at(0.1), status: 'done' },
          { id: 2, actor: 'agent', kind: 'tap', title: 'Tap “General”', at: at(60), endedAt: at(60.1), status: 'done' },
          { id: 3, actor: 'viewer', kind: 'button', title: 'Press Home', at: at(65), endedAt: at(65.2), status: 'done' },
          { id: 4, actor: 'agent', kind: 'scroll', title: 'Scroll up 300 pt', at: at(80), endedAt: at(80.8), status: 'done' }
        ];
        """)
        XCTAssertEqual(value(context, "(d => d.actor + ' ' + d.key + ' ' + d.title)(deviceDriver(feed, null, t + 90000))"), "agent agent:2 Scroll up 300 pt",
                       "one stretch starts after a quiet half minute; the viewer's own press does not count")
        XCTAssertEqual(value(context, "deviceDriver(feed, null, t + 111000)"), "null", "quiet for 30 s: nobody drives")
        XCTAssertEqual(value(context, "deviceDriver(feed.concat([{ id: 5, actor: 'agent', kind: 'launch', title: 'Launch', at: at(200), status: 'running' }]), null, t + 300000).key"), "agent:5",
                       "a running action drives however long it takes")
    }

    func testAGesturePlacesItselfOnTheScreenItWasPlayedOn() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "JSON.stringify(gestureRatios({ from: { x: 201, y: 437 }, to: { x: 201, y: 437 }, screen: { width: 402, height: 874 } }))"),
                       #"{"from":{"x":0.5,"y":0.5},"to":{"x":0.5,"y":0.5},"moved":false}"#)
        XCTAssertEqual(value(context, "gestureRatios({ from: { x: 0, y: 874 }, to: { x: 0, y: 0 } }, { width: 402, height: 874 }).moved"), "true",
                       "without the server's size the page's own is used")
        XCTAssertEqual(value(context, "gestureRatios({ from: { x: 1, y: 1 }, to: { x: 1, y: 1 } }, null)"), "null")
    }

    func testATouchCopiesAsTheCommandThatRepeatsIt() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "activityCommand({ kind: 'tap', gesture: { from: { x: 201.4, y: 339.6 }, to: { x: 201.4, y: 339.6 }, press: 0.06 } })"),
                       "simtool input tap --x 201 --y 340")
        XCTAssertEqual(value(context, "activityCommand({ kind: 'scroll', gesture: { from: { x: 201, y: 655 }, to: { x: 201, y: 345 }, press: 0 } })"),
                       "simtool input swipe --start-x 201 --start-y 655 --end-x 201 --end-y 345")
        XCTAssertEqual(value(context, "activityCommand({ kind: 'type', title: 'Type “a”' })"), "")
    }

    func testAgesReadInSecondsThenMinutes() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "[formatSince(400), formatSince(3200), formatSince(61000), formatSince(7300000)].join(' | ')"), "now | 3 s ago | 1 min ago | 2 h ago")
    }
}

// A recorded run reviewed step by step: which part of it a step covers.
final class WebViewerReviewLogicTests: XCTestCase {
    private func makeContext(file: StaticString = #filePath, line: UInt = #line) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in
            XCTFail("JS exception: \(exception?.toString() ?? "?")", file: file, line: line)
        }
        context.evaluateScript(WebViewer.asset("js/logic.js"))
        context.evaluateScript("""
        var session = { startedAt: '2026-10-20T21:40:30Z', endedAt: '2026-10-20T21:40:50.500Z', entries: [
          { kind: 'step', at: '2026-10-20T21:40:31.300Z', text: 'Launched com.example.app' },
          { kind: 'step', at: '2026-10-20T21:40:38.775Z', text: '✓ 1/3 Wait for label "General"' },
          { kind: 'log', at: '2026-10-20T21:40:39.000Z', logs: ['On screen:'] },
          { kind: 'step', at: '2026-10-20T21:40:39.743Z', text: '✓ 2/3 Tap label "General"' },
          { kind: 'step', at: '2026-10-20T21:40:44.459Z', text: '✓ 3/3 Wait for label "About"' }
        ] };
        """)
        return context
    }

    private func value(_ context: JSContext, _ expression: String) -> String {
        context.evaluateScript(expression)?.toString() ?? ""
    }

    func testEveryTimeTheEvidenceCarriesIsRead() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "Math.round(parseInstant('2026-10-20 18:40:11.226211-0300')) === Date.parse('2026-10-20T21:40:11.226Z')"), "true", "OSLog's local time with an offset")
        XCTAssertEqual(value(context, "parseInstant(1792532411.5) === 1792532411500"), "true", "state's epoch seconds")
        XCTAssertEqual(value(context, "parseInstant('2026-10-20T21:40:39.743Z') === Date.parse('2026-10-20T21:40:39.743Z')"), "true")
        XCTAssertEqual(value(context, "isNaN(parseInstant('later'))"), "true")
    }

    func testAStepCoversFromItsActionToTheNextStepsAction() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "stepWindows(session).map(w => w.index + ':' + (w.to - w.from)).join(' ')"), "0:7475 1:968 3:4716 4:6041",
                       "a log entry is not a step; the last step runs to the end of the run")
        XCTAssertEqual(value(context, "(w => w.step + ' ' + w.text)(reviewWindow(session, 3, 'step'))"), #"3 ✓ 2/3 Tap label "General""#)
        XCTAssertEqual(value(context, "(w => w.step + ' ' + (w.to - w.from))(reviewWindow(session, -1, 'step'))"), "0 1300", "before the first step")
        XCTAssertEqual(value(context, "(w => (w.to - w.from) + ' ' + w.step)(reviewWindow(session, 3, 'run'))"), "20500 null")
    }

    func testARequestBelongsToTheStepItStartedIn() throws {
        let context = try makeContext()
        context.evaluateScript("var tap = reviewWindow(session, 3, 'step');")
        // Finished during the next step, started during the tap's.
        XCTAssertEqual(value(context, "inWindow('network', { timestamp: '2026-10-20T21:40:44.600Z', durationMilliseconds: 4000 }, tap)"), "true")
        XCTAssertEqual(value(context, "inWindow('network', { timestamp: '2026-10-20T21:40:39.800Z', durationMilliseconds: 900 }, tap)"), "false", "it started before the tap")
        XCTAssertEqual(value(context, "inWindow('logs', { timestamp: '2026-10-20 18:40:40.000000-0300' }, tap)"), "true")
        XCTAssertEqual(value(context, "inWindow('state', { timestamp: Date.parse('2026-10-20T21:40:44.600Z') / 1000 }, tap)"), "false", "the window ends where the next step begins")
    }

    func testStateIsWhatTheModelsHeldAtTheEndOfTheStep() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var t = (s) => Date.parse('2026-10-20T21:40:00Z') / 1000 + s;
        var events = [
          { modelId: 'Cart#1', seq: 1, timestamp: t(32), snapshot: { items: 0 } },
          { modelId: 'Cart#1', seq: 2, timestamp: t(40), snapshot: { items: 1 } },
          { modelId: 'Cart#1', seq: 3, timestamp: t(46), snapshot: { items: 2 } }
        ];
        var folded = foldStateEvents(events, reviewWindow(session, 3, 'step'));
        """)
        XCTAssertEqual(value(context, "folded.latest['Cart#1'].snapshot.items"), "1", "the change after the step is not yet there")
        XCTAssertEqual(value(context, "folded.changes.map(c => c.diffs.map(d => d.path + ' ' + d.before + '→' + d.after).join()).join('|')"), "items 0→1")
        XCTAssertEqual(value(context, "JSON.stringify(folded.lastChange)"), #"{"Cart#1":["items"]}"#)
    }
}
