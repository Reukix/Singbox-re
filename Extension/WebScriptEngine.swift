#if os(iOS)
    import Foundation
    import Libbox
    import os
    import WebKit

    /// Runs Surge scripts in a WebKit page instead of the in-process goja
    /// runtime. The JavaScript executes in WebKit's WebContent process, so a
    /// script that needs 20 MiB to rewrite a 1 MiB body costs the Network
    /// Extension only the copies of the body that cross the process boundary.
    ///
    /// The Go side falls back to goja while this engine reports itself
    /// unavailable, and fails open (forwards the message unchanged) on script
    /// errors and timeouts.
    final class WebScriptEngine: NSObject, LibboxScriptEngineProtocol {
        static let shared = WebScriptEngine()

        /// How long past the script timeout the page may take to report back.
        /// The Go side waits one second longer before failing open itself.
        private static let resultGrace: Int64 = 2000

        private let page = ScriptPage()

        func execute(_ scriptID: String?, timeout: Int64, invocation: String?, body: String?, host: (any LibboxScriptHostProtocol)?) -> String {
            guard let scriptID, let invocation, let host else {
                return ScriptOutcome.error("invalid script invocation")
            }
            if Thread.isMainThread {
                // WebKit completes the run on the main thread; waiting here
                // would deadlock.
                return ScriptOutcome.unavailable("script engine called on the main thread")
            }
            let run = ScriptRun(scriptID: scriptID, timeout: timeout, invocation: invocation, body: body ?? "", host: host)
            DispatchQueue.main.async {
                self.page.start(run)
            }
            let waitMilliseconds = Int(clamping: max(timeout, 0) + Self.resultGrace)
            if run.wait(until: .now() + .milliseconds(waitMilliseconds)) {
                return run.outcome
            }
            DispatchQueue.main.async {
                self.page.abandon(run)
            }
            return ScriptOutcome.timeout
        }
    }

    private enum ScriptOutcome {
        static let timeout = #"{"status":"timeout"}"#

        static func error(_ message: String) -> String {
            encode(["status": "error", "error": message])
        }

        /// The engine cannot run scripts at all; Go falls back to goja.
        static func unavailable(_ message: String) -> String {
            encode(["status": "unavailable", "error": message])
        }

        /// No memory to spare right now; the run fails open without falling
        /// back to goja, which would need even more.
        static func skipped(_ message: String) -> String {
            encode(["status": "skipped", "error": message])
        }

        /// Arguments for a host "log" call.
        static func logArguments(_ message: String) -> String {
            encode(["level": "info", "message": message])
        }

        /// A host reply that makes the script's API call throw.
        static func hostError(_ message: String) -> String {
            encode(["error": message])
        }

        private static func encode(_ object: [String: String]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let text = String(data: data, encoding: .utf8)
            else {
                return #"{"status":"error","error":"encode outcome"}"#
            }
            return text
        }
    }

    /// One Execute call. Created on a Go thread, then owned by the main
    /// thread until finish(_:) wakes the waiting Go thread.
    private final class ScriptRun {
        let scriptID: String
        let timeout: Int64
        let invocation: String
        /// The message body, kept out of the invocation JSON.
        let body: String
        let host: any LibboxScriptHostProtocol
        let started = DispatchTime.now()
        var token = ""
        var sourceRetried = false
        private(set) var isFinished = false
        private(set) var outcome = ScriptOutcome.error("script did not finish")
        private let semaphore = DispatchSemaphore(value: 0)

        init(scriptID: String, timeout: Int64, invocation: String, body: String, host: any LibboxScriptHostProtocol) {
            self.scriptID = scriptID
            self.timeout = timeout
            self.invocation = invocation
            self.body = body
            self.host = host
        }

        func finish(_ outcome: String) {
            guard !isFinished else {
                return
            }
            isFinished = true
            self.outcome = outcome
            semaphore.signal()
        }

        func wait(until deadline: DispatchTime) -> Bool {
            semaphore.wait(timeout: deadline) == .success
        }

        /// The script timeout left after waiting for the page, so the page's
        /// own timeout fires before the Go thread stops waiting.
        func remainingMilliseconds() -> Int64 {
            let elapsed = Int64((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            return max(timeout - elapsed, 1)
        }
    }

    /// Breaks the retain cycle between the user content controller and the
    /// page that owns it.
    private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
        weak var target: (any WKScriptMessageHandlerWithReply)?

        init(_ target: any WKScriptMessageHandlerWithReply) {
            self.target = target
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
            guard let target else {
                replyHandler(ScriptOutcome.hostError("script engine closed"), nil)
                return
            }
            target.userContentController(userContentController, didReceive: message, replyHandler: replyHandler)
        }
    }

    /// The page all scripts run in. Every member is used on the main thread.
    private final class ScriptPage: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
        private static let logger = Logger(subsystem: "io.nekohasekai.sfavt.extension", category: "WebScriptEngine")
        private static let handlerName = "sgbox"
        private static let promptPrefix = "sgbox:"
        private static let missingScript = #"{"status":"missing"}"#
        private static let loadTimeout: TimeInterval = 6
        private static let idleTimeout: TimeInterval = 90
        private static let probeTimeout: TimeInterval = 2
        /// Creating the page loads WebKit's client side into the extension.
        /// Go reserves that cost before the first run; this is only a floor
        /// for when the headroom changed in between.
        private static let minimumHeadroom = 12 * 1024 * 1024
        private static let failureLimit = 3
        private static let disableInterval: TimeInterval = 300

        private let hostQueue = DispatchQueue(label: "io.nekohasekai.sfavt.script-host", qos: .userInitiated, attributes: .concurrent)
        private var webView: WKWebView?
        private var generation = 0
        private var isReady = false
        private var queued: [ScriptRun] = []
        private var runs: [String: ScriptRun] = [:]
        private var sentSources = Set<String>()
        private var nextToken: UInt64 = 0
        private var loadTimer: DispatchWorkItem?
        private var idleTimer: DispatchWorkItem?
        private var loadFailures = 0
        private var disabledUntil: Date?
        private var pageStartHeadroom = 0
        private var pageStartTime = DispatchTime.now()
        private var pageStartReporter: (any LibboxScriptHostProtocol)?

        // MARK: Runs

        func start(_ run: ScriptRun) {
            if let disabledUntil, disabledUntil > Date() {
                run.finish(ScriptOutcome.unavailable("WebKit script engine paused after repeated load failures"))
                return
            }
            if webView == nil {
                let headroom = os_proc_available_memory()
                if headroom > 0, headroom < Self.minimumHeadroom {
                    run.finish(ScriptOutcome.skipped("not enough memory to start WebKit"))
                    return
                }
                pageStartHeadroom = headroom
                pageStartTime = .now()
                pageStartReporter = run.host
                createPage()
            }
            nextToken &+= 1
            run.token = String(nextToken)
            runs[run.token] = run
            idleTimer?.cancel()
            idleTimer = nil
            if isReady {
                dispatch(run)
            } else {
                queued.append(run)
            }
        }

        /// Called when the Go thread stopped waiting for run.
        func abandon(_ run: ScriptRun) {
            guard runs.removeValue(forKey: run.token) != nil else {
                return
            }
            run.finish(ScriptOutcome.timeout)
            queued.removeAll { $0 === run }
            // The script timeout inside the page should have fired first, so
            // the page is stuck in a loop or starved; replace it if it does
            // not answer.
            probe()
            scheduleIdleTeardown()
        }

        private func dispatch(_ run: ScriptRun) {
            guard let webView, !run.isFinished else {
                return
            }
            if sentSources.contains(run.scriptID) {
                evaluate(run, source: nil, in: webView)
                return
            }
            let generation = generation
            let host = run.host
            // Go may hold locks while compiling, so never block the main
            // thread on it.
            hostQueue.async {
                let source = host.source()
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.generation, let webView = self.webView, !run.isFinished else {
                        return
                    }
                    self.evaluate(run, source: source, in: webView)
                }
            }
        }

        private func evaluate(_ run: ScriptRun, source: String?, in webView: WKWebView) {
            let generation = generation
            let arguments: [String: Any] = [
                "token": run.token,
                "scriptID": run.scriptID,
                "invocation": run.invocation,
                "body": run.body,
                "remaining": run.remainingMilliseconds(),
                "source": source.map { $0 as Any } ?? NSNull(),
            ]
            webView.callAsyncJavaScript(
                "return await window.__sgbox.run(token, scriptID, invocation, body, source, remaining);",
                arguments: arguments,
                in: nil,
                in: .page
            ) { [weak self] result in
                guard let self, generation == self.generation, !run.isFinished else {
                    return
                }
                switch result {
                case let .success(value):
                    guard let outcome = value as? String else {
                        self.finish(run, ScriptOutcome.error("script engine returned no outcome"))
                        return
                    }
                    if outcome == Self.missingScript {
                        // The page dropped the source; send it again.
                        self.sentSources.remove(run.scriptID)
                        if source == nil, !run.sourceRetried {
                            run.sourceRetried = true
                            self.dispatch(run)
                        } else {
                            self.finish(run, ScriptOutcome.error("script source rejected by the page"))
                        }
                        return
                    }
                    if source != nil {
                        self.sentSources.insert(run.scriptID)
                    }
                    self.finish(run, outcome)
                case let .failure(error):
                    self.finish(run, ScriptOutcome.error("WebKit: \(error.localizedDescription)"))
                }
            }
        }

        private func finish(_ run: ScriptRun, _ outcome: String) {
            runs.removeValue(forKey: run.token)
            run.finish(outcome)
            scheduleIdleTeardown()
        }

        // MARK: Page lifecycle

        private func createPage() {
            let userContentController = WKUserContentController()
            userContentController.addUserScript(WKUserScript(source: scriptPrelude, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            userContentController.addScriptMessageHandler(WeakScriptMessageHandler(self), contentWorld: .page, name: Self.handlerName)
            let configuration = WKWebViewConfiguration()
            configuration.userContentController = userContentController
            configuration.websiteDataStore = .nonPersistent()
            configuration.suppressesIncrementalRendering = true
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            configuration.dataDetectorTypes = []
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = self
            webView.uiDelegate = self
            generation += 1
            self.webView = webView
            isReady = false
            sentSources.removeAll()
            webView.loadHTMLString("<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body></body></html>", baseURL: nil)
            let generation = generation
            let loadTimer = DispatchWorkItem { [weak self] in
                guard let self, generation == self.generation, !self.isReady else {
                    return
                }
                self.pageFailed("WebKit page load timed out")
            }
            self.loadTimer = loadTimer
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadTimeout, execute: loadTimer)
        }

        private func destroyPage() {
            loadTimer?.cancel()
            loadTimer = nil
            idleTimer?.cancel()
            idleTimer = nil
            guard let webView else {
                return
            }
            generation += 1
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.configuration.userContentController.removeAllUserScripts()
            self.webView = nil
            isReady = false
            sentSources.removeAll()
            pageStartReporter = nil
        }

        /// Drops the page and ends its runs. Before the page ever loaded the
        /// runs fall back to goja; once scripts ran in it they fail open,
        /// since a script that crashed WebKit must not be retried inside the
        /// extension.
        private func pageFailed(_ reason: String) {
            let loaded = isReady
            Self.logger.error("\(reason, privacy: .public)")
            destroyPage()
            let failedRuns = Array(runs.values)
            runs.removeAll()
            queued.removeAll()
            for run in failedRuns {
                run.finish(loaded ? ScriptOutcome.error(reason) : ScriptOutcome.unavailable(reason))
            }
            if !loaded {
                loadFailures += 1
                if loadFailures >= Self.failureLimit {
                    loadFailures = 0
                    disabledUntil = Date().addingTimeInterval(Self.disableInterval)
                }
            }
        }

        /// Logs what starting WebKit cost the extension, through the host of
        /// the run that started it (still waiting for the page).
        private func reportPageStart() {
            guard let reporter = pageStartReporter else {
                return
            }
            pageStartReporter = nil
            let elapsed = (DispatchTime.now().uptimeNanoseconds - pageStartTime.uptimeNanoseconds) / 1_000_000
            var message = "WebKit script engine started in \(elapsed) ms"
            let headroom = os_proc_available_memory()
            if pageStartHeadroom > 0, headroom > 0 {
                let mebibyte = 1024.0 * 1024.0
                message += String(format: ", extension memory %+.1f MiB, %.1f MiB left", Double(pageStartHeadroom - headroom) / mebibyte, Double(headroom) / mebibyte)
            }
            let arguments = ScriptOutcome.logArguments(message)
            hostQueue.async {
                _ = reporter.call("log", arguments: arguments)
            }
        }

        private func probe() {
            guard let webView, isReady else {
                return
            }
            let generation = generation
            var answered = false
            webView.evaluateJavaScript("0") { _, _ in
                answered = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.probeTimeout) { [weak self] in
                guard let self, generation == self.generation, !answered else {
                    return
                }
                self.pageFailed("WebKit page stopped responding")
            }
        }

        private func scheduleIdleTeardown() {
            guard runs.isEmpty, webView != nil else {
                return
            }
            idleTimer?.cancel()
            let generation = generation
            let idleTimer = DispatchWorkItem { [weak self] in
                guard let self, generation == self.generation, self.runs.isEmpty else {
                    return
                }
                // Idle pages are released so the WebContent process and the
                // client-side objects in the extension go away.
                self.destroyPage()
            }
            self.idleTimer = idleTimer
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleTimeout, execute: idleTimer)
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            guard webView === self.webView, !isReady else {
                return
            }
            isReady = true
            loadFailures = 0
            loadTimer?.cancel()
            loadTimer = nil
            reportPageStart()
            let pending = queued
            queued.removeAll()
            for run in pending {
                dispatch(run)
            }
        }

        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
            guard webView === self.webView else {
                return
            }
            pageFailed("WebKit page load failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: any Error) {
            guard webView === self.webView else {
                return
            }
            pageFailed("WebKit page load failed: \(error.localizedDescription)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard webView === self.webView else {
                return
            }
            pageFailed("WebKit content process terminated")
        }

        func webView(_: WKWebView, decidePolicyFor _: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only the initial blank document; a script must not navigate the
            // page away from under the other runs.
            decisionHandler(isReady ? .cancel : .allow)
        }

        // MARK: Host calls

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
            guard let body = message.body as? [String: Any],
                  let token = body["run"] as? String,
                  let method = body["method"] as? String,
                  let arguments = body["arguments"] as? String
            else {
                replyHandler(ScriptOutcome.hostError("invalid host call"), nil)
                return
            }
            callHost(token: token, method: method, arguments: arguments) { reply in
                replyHandler(reply, nil)
            }
        }

        /// Serves the synchronous API calls ($persistentStore, $utils.ungzip):
        /// the page blocks in prompt() until the completion handler runs.
        func webView(_: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText _: String?, initiatedByFrame _: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            guard prompt.hasPrefix(Self.promptPrefix) else {
                completionHandler(nil)
                return
            }
            let fields = prompt.dropFirst(Self.promptPrefix.count).split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else {
                completionHandler(ScriptOutcome.hostError("invalid host call"))
                return
            }
            callHost(token: String(fields[0]), method: String(fields[1]), arguments: String(fields[2]), completion: completionHandler)
        }

        func webView(_: WKWebView, runJavaScriptAlertPanelWithMessage _: String, initiatedByFrame _: WKFrameInfo, completionHandler: @escaping () -> Void) {
            completionHandler()
        }

        func webView(_: WKWebView, runJavaScriptConfirmPanelWithMessage _: String, initiatedByFrame _: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            completionHandler(false)
        }

        private func callHost(token: String, method: String, arguments: String, completion: @escaping (String) -> Void) {
            guard let run = runs[token] else {
                completion(ScriptOutcome.hostError("script run already finished"))
                return
            }
            let host = run.host
            // $httpClient may take seconds; the page keeps running meanwhile.
            hostQueue.async {
                let reply = host.call(method, arguments: arguments)
                DispatchQueue.main.async {
                    completion(reply)
                }
            }
        }
    }

    /// Installed at document start. The page itself only dispatches: every
    /// concurrently running script gets a slot, an iframe with its own global
    /// object and its own copy of the Surge API runtime, so scripts neither
    /// share implicit globals nor see values from a foreign realm.
    private let scriptPrelude = #"""
    (() => {
      "use strict";
      if (window.__sgbox) {
        return;
      }

      // Evaluated from its source text inside every slot frame.
      function installRuntime() {
        "use strict";
        const nativePrompt = window.prompt.bind(window);
        const hostPort = (window.webkit || window.parent.webkit).messageHandlers.sgbox;
        const indirectEval = window.eval;
        const nativeSetTimeout = window.setTimeout.bind(window);
        const nativeClearTimeout = window.clearTimeout.bind(window);
        const nativeSetInterval = window.setInterval.bind(window);
        const nativeClearInterval = window.clearInterval.bind(window);
        // Scripts run at global scope, like in goja: the API is a set of
        // global properties for the duration of the run. The slot runs one
        // script at a time, and afterwards every global the run added is
        // removed and every overridden native restored.
        const API_GLOBALS = [
          "$request", "request", "$response", "response", "$done", "done",
          "$argument", "$arguments", "$script", "$environment", "$persistentStore",
          "$httpClient", "$http", "$httpAPI", "$utils", "$notification", "$network",
          "$cronexp",
        ];
        const OVERRIDDEN_GLOBALS = [
          "console", "setTimeout", "clearTimeout", "setInterval", "clearInterval",
          "setImmediate", "clearImmediate",
        ];
        const nativeGlobals = new Map(OVERRIDDEN_GLOBALS.map((name) => [name, Object.getOwnPropertyDescriptor(window, name)]));
        const HTTP_METHODS = ["get", "post", "put", "delete", "head", "options", "patch", "trace"];
        const MAX_LOG_LENGTH = 8 * 1024;
        const MAX_HOST_PAYLOAD = 4 * 1024 * 1024;
        // goja runs scripts with a top-level return inside a function; so do
        // we. This message is only ever produced by the parser, before any
        // of the script ran.
        const RETURN_OUTSIDE_FUNCTION = /Return statements are only valid inside functions/;
        const wrappedScripts = new Set();
        const encoder = new TextEncoder();
        const decoder = new TextDecoder();
        let baselineGlobals = null;

        function resetGlobals() {
          for (const name of Object.getOwnPropertyNames(window)) {
            if (!baselineGlobals.has(name)) {
              Reflect.deleteProperty(window, name);
            }
          }
          for (const [name, descriptor] of nativeGlobals) {
            if (descriptor) {
              Object.defineProperty(window, name, descriptor);
            } else {
              Reflect.deleteProperty(window, name);
            }
          }
        }

        function evaluateScript(scriptID, source) {
          if (!wrappedScripts.has(scriptID)) {
            try {
              indirectEval(source);
              return 0;
            } catch (error) {
              if (!(error instanceof SyntaxError) || !RETURN_OUTSIDE_FUNCTION.test(error.message)) {
                throw error;
              }
              wrappedScripts.add(scriptID);
            }
          }
          indirectEval("(function () {\n" + source + "\n})();");
          return 1;
        }

        function base64ToBytes(data) {
          const binary = atob(data);
          const bytes = new Uint8Array(binary.length);
          for (let index = 0; index < binary.length; index++) {
            bytes[index] = binary.charCodeAt(index);
          }
          return bytes;
        }

        function bytesToBase64(bytes) {
          let binary = "";
          for (let index = 0; index < bytes.length; index += 0x8000) {
            binary += String.fromCharCode.apply(null, bytes.subarray(index, index + 0x8000));
          }
          return btoa(binary);
        }

        function asBytes(value) {
          if (ArrayBuffer.isView(value)) {
            return value instanceof Uint8Array ? value : new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
          }
          if (Object.prototype.toString.call(value) === "[object ArrayBuffer]") {
            return new Uint8Array(value);
          }
          return null;
        }

        // Bodies from the host are {encoding: "utf8" | "base64", data}.
        function wireText(body) {
          if (body.text === undefined) {
            body.text = body.encoding === "base64" ? decoder.decode(base64ToBytes(body.data)) : body.data;
          }
          return body.text;
        }

        function wireBytes(body) {
          return body.encoding === "base64" ? base64ToBytes(body.data) : encoder.encode(body.data);
        }

        function sameBytes(left, right) {
          if (left.length !== right.length) {
            return false;
          }
          for (let index = 0; index < left.length; index++) {
            if (left[index] !== right[index]) {
              return false;
            }
          }
          return true;
        }

        function defineBody(target, body, binaryMode) {
          if (!body) {
            return;
          }
          target.body = binaryMode ? wireBytes(body) : wireText(body);
          let bytes;
          Object.defineProperty(target, "bodyBytes", {
            get() {
              if (bytes === undefined) {
                bytes = wireBytes(body);
              }
              return bytes;
            },
            set(value) {
              bytes = value;
            },
            enumerable: true,
            configurable: true,
          });
        }

        function encodeBody(value, name) {
          if (typeof value === "string") {
            return { encoding: "utf8", data: value };
          }
          const bytes = asBytes(value);
          if (bytes) {
            return { encoding: "base64", data: bytesToBase64(bytes) };
          }
          throw new TypeError("invalid value: " + name + ": expected string or binary");
        }

        // An unchanged body is reported as "same" so it is not copied back.
        function resultBody(object, input) {
          let value = object.body;
          let name = "body";
          if (value === undefined || value === null) {
            value = object.bodyBytes;
            name = "bodyBytes";
          }
          if (value === undefined || value === null) {
            return undefined;
          }
          if (input) {
            if (typeof value === "string" && value === wireText(input)) {
              return { encoding: "same", data: "" };
            }
            const bytes = asBytes(value);
            if (bytes) {
              if (input.bytes === undefined) {
                input.bytes = wireBytes(input);
              }
              if (sameBytes(bytes, input.bytes)) {
                return { encoding: "same", data: "" };
              }
            }
          }
          return encodeBody(value, name);
        }

        function headersToValue(list, fullHeaderMode) {
          if (fullHeaderMode) {
            return list.map(([field, value]) => ({ field, value }));
          }
          const headers = {};
          for (const [field, value] of list) {
            const existing = headers[field];
            if (existing === undefined) {
              headers[field] = value;
            } else if (Array.isArray(existing)) {
              existing.push(value);
            } else {
              headers[field] = [existing, value];
            }
          }
          return headers;
        }

        const HEADER_TOKEN = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;

        // Mirrors Go's textproto.CanonicalMIMEHeaderKey.
        function canonicalHeaderKey(key) {
          if (!HEADER_TOKEN.test(key)) {
            return key;
          }
          let result = "";
          let upper = true;
          for (const character of key) {
            result += upper ? character.toUpperCase() : character.toLowerCase();
            upper = character === "-";
          }
          return result;
        }

        // The {field, value} array form keeps every entry, like goja. In the
        // object form a key replaces earlier keys that differ only in case,
        // so setting headers["user-agent"] overrides "User-Agent".
        function headersToList(value, name) {
          if (value === undefined || value === null) {
            return undefined;
          }
          if (typeof value !== "object") {
            throw new TypeError("invalid value: " + name + ": expected object");
          }
          const list = [];
          if (Array.isArray(value)) {
            value.forEach((entry, index) => {
              if (!entry || typeof entry !== "object") {
                throw new TypeError("invalid value: " + name + "[" + index + "]: expected object");
              }
              list.push([String(entry.field), String(entry.value)]);
            });
            return list;
          }
          const fields = new Map();
          for (const field of Object.keys(value)) {
            const fieldValue = value[field];
            if (fieldValue === undefined || fieldValue === null) {
              continue;
            }
            const key = canonicalHeaderKey(field);
            fields.delete(key);
            fields.set(key, Array.isArray(fieldValue) ? fieldValue.map(String) : [String(fieldValue)]);
          }
          for (const [key, values] of fields) {
            for (const item of values) {
              list.push([key, item]);
            }
          }
          return list;
        }

        function toStatus(value) {
          const status = Number(value);
          return Number.isFinite(status) ? Math.trunc(status) : 0;
        }

        function describe(error, lineOffset = 0) {
          if (error instanceof Error) {
            const line = typeof error.line === "number" && error.line > lineOffset ? " (line " + (error.line - lineOffset) + ")" : "";
            return error.name + ": " + error.message + line;
          }
          return String(error);
        }

        function inspect(value) {
          if (typeof value === "string") {
            return value;
          }
          if (value instanceof Error) {
            return describe(value);
          }
          if (value !== null && typeof value === "object") {
            try {
              return JSON.stringify(value);
            } catch (error) {
              return String(value);
            }
          }
          return String(value);
        }

        function formatLog(args) {
          if (args.length === 0) {
            return "";
          }
          const rest = Array.prototype.slice.call(args, 1);
          let message = inspect(args[0]);
          if (typeof args[0] === "string") {
            message = args[0].replace(/%[sdij%]/g, (directive) => {
              if (directive === "%%") {
                return "%";
              }
              if (rest.length === 0) {
                return directive;
              }
              const value = rest.shift();
              switch (directive) {
                case "%s":
                  return inspect(value);
                case "%j":
                  return JSON.stringify(value);
                default:
                  return String(Number(value));
              }
            });
          }
          for (const value of rest) {
            message += " " + inspect(value);
          }
          if (message.length > MAX_LOG_LENGTH) {
            message = message.slice(0, MAX_LOG_LENGTH) + " ... (" + (message.length - MAX_LOG_LENGTH) + " characters truncated)";
          }
          return message;
        }

        class Run {
          constructor(token, invocation, bodyText, remaining, resolve) {
            this.token = token;
            this.invocation = invocation;
            this.remaining = remaining;
            this.resolve = resolve;
            this.finished = false;
            this.lineOffset = 0;
            this.timers = new Set();
            this.intervals = new Set();
            this.timeout = undefined;
            this.counts = new Map();
            this.startTimes = new Map();
            const message = invocation.type === "http-request" ? invocation.request : invocation.response;
            this.input = (message && message.body) || null;
            if (this.input) {
              // The body data travels next to the invocation, not inside it.
              this.input.data = bodyText;
            }
          }

          start(scriptID, source) {
            // The time the run already spent waiting in the engine counts.
            this.timeout = nativeSetTimeout(() => this.finish("timeout", {}), Math.max(this.remaining, 1));
            const bindings = this.bindings();
            resetGlobals();
            for (const name of API_GLOBALS.concat(OVERRIDDEN_GLOBALS)) {
              Object.defineProperty(window, name, { value: bindings[name], writable: true, enumerable: true, configurable: true });
            }
            try {
              this.lineOffset = evaluateScript(scriptID, source);
            } catch (error) {
              this.fail(error);
            }
          }

          finish(status, fields) {
            if (this.finished) {
              return;
            }
            this.finished = true;
            nativeClearTimeout(this.timeout);
            for (const timer of this.timers) {
              nativeClearTimeout(timer);
            }
            for (const timer of this.intervals) {
              nativeClearInterval(timer);
            }
            resetGlobals();
            // The result body follows the JSON after a newline, so it is not
            // escaped into the JSON and the extension need not copy it out.
            let frame = null;
            const body = fields.value && fields.value.body;
            if (body && body.encoding !== "same") {
              frame = body.data;
              fields.value.body = { encoding: body.encoding };
              fields.framed = true;
            }
            let outcome;
            try {
              outcome = JSON.stringify(Object.assign({ status }, fields));
              if (frame !== null) {
                outcome += "\n" + frame;
              }
            } catch (error) {
              outcome = JSON.stringify({ status: "error", error: describe(error) });
            }
            if (outcome.length > this.invocation.resultLimit) {
              outcome = JSON.stringify({ status: "error", error: "script result exceeds " + this.invocation.resultLimit + " bytes" });
            }
            this.resolve(outcome);
          }

          fail(error) {
            this.finish("error", { error: describe(error, this.lineOffset) });
          }

          done(value) {
            if (this.finished) {
              return;
            }
            let serialized;
            try {
              serialized = this.serializeDone(value);
            } catch (error) {
              this.fail(error);
              return;
            }
            this.finish("done", serialized === undefined ? {} : { value: serialized });
          }

          serializeDone(value) {
            if (value === undefined || value === null) {
              return undefined;
            }
            if (typeof value !== "object") {
              throw new TypeError("invalid value: done() argument: expected object");
            }
            const result = {};
            if (value.abort === true) {
              result.abort = true;
            }
            const type = this.invocation.type;
            if (type !== "http-request" && type !== "http-response") {
              return result;
            }
            if (type === "http-request") {
              if (value.url !== undefined && value.url !== null) {
                result.url = String(value.url);
              }
            } else {
              const status = toStatus(value.status) || toStatus(value.statusCode);
              if (status) {
                result.status = status;
              }
            }
            const headers = headersToList(value.headers, "headers");
            if (headers) {
              result.headers = headers;
            }
            const body = resultBody(value, this.input);
            if (body) {
              result.body = body;
            }
            if (type === "http-request" && value.response !== undefined && value.response !== null) {
              if (typeof value.response !== "object") {
                throw new TypeError("invalid value: response: expected object");
              }
              const response = {};
              const status = toStatus(value.response.status) || toStatus(value.response.statusCode);
              if (status) {
                response.status = status;
              }
              const responseHeaders = headersToList(value.response.headers, "response.headers");
              if (responseHeaders) {
                response.headers = responseHeaders;
              }
              const responseBody = resultBody(value.response, null);
              if (responseBody) {
                response.body = responseBody;
              }
              result.response = response;
            }
            return result;
          }

          guard(callback) {
            return (...args) => {
              if (this.finished) {
                return undefined;
              }
              try {
                return callback(...args);
              } catch (error) {
                this.fail(error);
                return undefined;
              }
            };
          }

          callSync(method, args) {
            if (this.finished) {
              throw new Error("script run already finished");
            }
            const payload = JSON.stringify(args);
            if (payload.length > MAX_HOST_PAYLOAD) {
              throw new RangeError(method + ": arguments exceed " + MAX_HOST_PAYLOAD + " bytes");
            }
            const reply = nativePrompt("sgbox:" + this.token + "\n" + method + "\n" + payload);
            if (reply === null || reply === undefined) {
              throw new Error(method + ": script host unavailable");
            }
            const result = JSON.parse(reply);
            if (result.error !== undefined) {
              throw new Error(result.error);
            }
            return result;
          }

          callAsync(method, args) {
            if (this.finished) {
              return Promise.reject(new Error("script run already finished"));
            }
            const payload = JSON.stringify(args);
            if (payload.length > MAX_HOST_PAYLOAD) {
              return Promise.reject(new RangeError(method + ": arguments exceed " + MAX_HOST_PAYLOAD + " bytes"));
            }
            return hostPort.postMessage({ run: this.token, method, arguments: payload }).then((reply) => JSON.parse(reply));
          }

          post(method, args) {
            this.callAsync(method, args).catch(() => {});
          }

          log(level, args) {
            if (!this.finished) {
              this.post("log", { level, message: formatLog(args) });
            }
          }

          httpRequest(method, options, callback) {
            const request = {
              method: method.toUpperCase(),
              headers: [],
              autoCookie: true,
              autoRedirect: true,
            };
            let binaryMode = false;
            let fullHeaderMode = false;
            if (typeof options === "string") {
              request.url = options;
            } else if (options !== null && typeof options === "object") {
              if (typeof options.url !== "string") {
                throw new TypeError("invalid value: options.url: expected string");
              }
              request.url = options.url;
              request.headers = headersToList(options.headers, "options.headers") || [];
              const body = options.body;
              if (body !== undefined && body !== null) {
                if (typeof body === "object" && !asBytes(body)) {
                  request.body = { encoding: "utf8", data: JSON.stringify(body) };
                  if (!request.headers.some(([field]) => field.toLowerCase() === "content-type")) {
                    request.headers.push(["Content-Type", "application/json"]);
                  }
                } else {
                  request.body = encodeBody(body, "options.body");
                }
              }
              const timeout = Number(options.timeout);
              if (Number.isFinite(timeout) && timeout > 0) {
                request.timeout = Math.trunc(timeout);
              }
              request.insecure = options.insecure === true;
              if (options["auto-cookie"] !== undefined && options["auto-cookie"] !== null) {
                request.autoCookie = options["auto-cookie"] === true;
              }
              if (options["auto-redirect"] !== undefined && options["auto-redirect"] !== null) {
                request.autoRedirect = options["auto-redirect"] === true;
              }
              binaryMode = options["binary-mode"] === true;
              fullHeaderMode = options["full-header-mode"] === true;
            } else {
              throw new TypeError("invalid argument: options: expected string or object");
            }
            if (typeof callback !== "function") {
              throw new TypeError("invalid argument: callback: expected function");
            }
            const deliver = this.guard(callback);
            this.callAsync("http", request).then((reply) => {
              if (reply.error !== undefined) {
                deliver(reply.error, undefined, undefined);
                return;
              }
              const response = {
                status: reply.status,
                statusCode: reply.status,
                headers: headersToValue(reply.headers || [], fullHeaderMode),
              };
              defineBody(response, reply.body || { encoding: "utf8", data: "" }, binaryMode);
              deliver(null, response, response.body);
            }, (error) => {
              deliver(describe(error), undefined, undefined);
            });
          }

          bindings() {
            const invocation = this.invocation;
            const binaryMode = invocation.binaryBodyMode;
            const fullHeaderMode = invocation.fullHeaderMode;
            const bindings = {};
            if (invocation.request) {
              const request = {
                url: invocation.request.url,
                method: invocation.request.method,
                headers: headersToValue(invocation.request.headers || [], fullHeaderMode),
              };
              if (invocation.type === "http-request") {
                defineBody(request, invocation.request.body, binaryMode);
              }
              request.id = invocation.request.id;
              bindings.$request = request;
              bindings.request = request;
            }
            if (invocation.response) {
              const response = {
                status: invocation.response.status,
                statusCode: invocation.response.status,
                headers: headersToValue(invocation.response.headers || [], fullHeaderMode),
              };
              defineBody(response, invocation.response.body, binaryMode);
              bindings.$response = response;
              bindings.response = response;
            }
            const done = (value) => this.done(value);
            bindings.$done = done;
            bindings.done = done;
            bindings.$argument = invocation.argument;
            bindings.$arguments = invocation.arguments.slice();
            bindings.$script = {
              name: invocation.tag,
              type: invocation.type,
              startTime: new Date(invocation.startedAt),
              sessionID: invocation.sessionID,
              binaryBodyMode: binaryMode,
            };
            bindings.$environment = Object.assign({}, invocation.environment, {
              toString: () => "[sing-box Surge environment",
            });
            bindings.$persistentStore = {
              get: (key) => this.readStore(key),
              read: (key) => this.readStore(key),
              set: (value, key) => {
                this.writeStore(value, key);
              },
              write: (value, key) => {
                this.writeStore(value, key);
                return true;
              },
              toString: () => "[sing-box Surge persistentStore]",
            };
            const httpClient = { toString: () => "[sing-box Surge HTTP]" };
            for (const method of HTTP_METHODS) {
              httpClient[method] = (options, callback) => this.httpRequest(method, options, callback);
            }
            bindings.$httpClient = httpClient;
            bindings.$http = httpClient;
            bindings.$httpAPI = (method, path, body, callback) => {
              if (typeof callback !== "function") {
                throw new TypeError("$httpAPI requires method, path, body and callback");
              }
              callback({ success: false, error: "Surge HTTP API is not supported by sing-box" });
            };
            bindings.$utils = {
              geoip: () => null,
              ipasn: () => null,
              ipaso: () => null,
              ungzip: (data) => {
                const bytes = asBytes(data);
                if (!bytes) {
                  throw new TypeError("invalid argument: binary: expected binary");
                }
                const reply = this.callSync("utils.ungzip", { data: bytesToBase64(bytes) });
                return base64ToBytes(reply.data);
              },
              toString: () => "[sing-box Surge utils]",
            };
            bindings.$notification = {
              post: (title, subtitle, body, options) => {
                const notification = {
                  title: title === undefined || title === null ? "" : String(title),
                  subtitle: subtitle === undefined || subtitle === null ? "" : String(subtitle),
                  body: body === undefined || body === null ? "" : String(body),
                };
                if (options !== null && typeof options === "object") {
                  notification.options = {
                    action: String(options.action || ""),
                    url: String(options.url || ""),
                    text: String(options.text || ""),
                    "media-url": String(options["media-url"] || ""),
                    "media-base64": String(options["media-base64"] || ""),
                    "media-base64-mime": String(options["media-base64-mime"] || ""),
                    "auto-dismiss": Math.trunc(Number(options["auto-dismiss"]) || 0),
                  };
                }
                this.post("notification", notification);
              },
              toString: () => "[sing-box Surge notification]",
            };
            bindings.$network = { wifi: { ssid: null, bssid: null }, dns: [], v4: {}, v6: {} };
            if (invocation.type === "cron" && invocation.cronExpression) {
              bindings.$cronexp = invocation.cronExpression;
            }
            bindings.console = this.console();
            bindings.setTimeout = (callback, delay, ...args) => {
              if (this.finished) {
                return 0;
              }
              const timer = nativeSetTimeout(() => {
                this.timers.delete(timer);
                this.guard(callback)(...args);
              }, delay);
              this.timers.add(timer);
              return timer;
            };
            bindings.clearTimeout = (timer) => {
              this.timers.delete(timer);
              nativeClearTimeout(timer);
            };
            bindings.setInterval = (callback, delay, ...args) => {
              if (this.finished) {
                return 0;
              }
              const timer = nativeSetInterval(this.guard(() => callback(...args)), delay);
              this.intervals.add(timer);
              return timer;
            };
            bindings.clearInterval = (timer) => {
              this.intervals.delete(timer);
              nativeClearInterval(timer);
            };
            bindings.setImmediate = (callback, ...args) => bindings.setTimeout(callback, 0, ...args);
            bindings.clearImmediate = bindings.clearTimeout;
            return bindings;
          }

          readStore(key) {
            const reply = this.callSync("persistentStore.read", { key: key === undefined || key === null ? "" : String(key) });
            return reply.value === undefined ? null : reply.value;
          }

          writeStore(value, key) {
            this.callSync("persistentStore.write", {
              key: key === undefined || key === null ? "" : String(key),
              value: value === undefined || value === null ? "" : String(value),
            });
          }

          console() {
            const log = (level) => (...args) => this.log(level, args);
            return {
              log: log("info"),
              info: log("info"),
              debug: log("debug"),
              trace: log("debug"),
              warn: log("warn"),
              error: log("error"),
              assert: (assertion, ...args) => {
                if (!assertion) {
                  this.log("error", args);
                }
              },
              dir: (value) => this.log("info", [value]),
              dirxml: (value) => this.log("info", [value]),
              table: (value) => this.log("info", [value]),
              count: (label = "default") => {
                const count = (this.counts.get(label) || 0) + 1;
                this.counts.set(label, count);
                this.log("info", [label + ": " + count]);
              },
              countReset: (label = "default") => {
                this.counts.delete(label);
              },
              time: (label = "default") => {
                this.startTimes.set(label, Date.now());
              },
              timeLog: (label = "default") => {
                if (!this.startTimes.has(label)) {
                  this.log("error", ["Timer \"" + label + "\" doesn't exist."]);
                  return;
                }
                this.log("info", [label + ": " + (Date.now() - this.startTimes.get(label)) + "ms"]);
              },
              timeEnd: (label = "default") => {
                if (!this.startTimes.has(label)) {
                  return;
                }
                this.log("info", [label + ": " + (Date.now() - this.startTimes.get(label)) + "ms - - timer ended"]);
                this.startTimes.delete(label);
              },
              group: () => {},
              groupCollapsed: () => {},
              groupEnd: () => {},
              clear: () => {},
              profile: () => {},
              profileEnd: () => {},
              timeStamp: () => {},
            };
          }
        }

        window.__sgboxRuntime = {
          run(token, scriptID, invocationText, bodyText, source, remaining) {
            let invocation;
            try {
              invocation = JSON.parse(invocationText);
            } catch (error) {
              return Promise.resolve(JSON.stringify({ status: "error", error: describe(error) }));
            }
            return new Promise((resolve) => {
              new Run(token, invocation, bodyText, remaining, resolve).start(scriptID, source);
            });
          },
        };
        baselineGlobals = new Set(Object.getOwnPropertyNames(window));
      }

      const MISSING = JSON.stringify({ status: "missing" });
      const MAX_SOURCES = 32;
      const MAX_SLOTS = 6;
      // A slot's realm is replaced after this many runs, so state scripts
      // leave behind in implicit globals does not accumulate forever.
      const RUNS_PER_SLOT = 200;
      const runtimeSource = "(" + installRuntime.toString() + ")();";
      const sources = new Map();
      const idleSlots = [];
      let slotCount = 0;

      function createSlot() {
        const frame = document.createElement("iframe");
        frame.style.display = "none";
        document.body.appendChild(frame);
        frame.contentWindow.eval(runtimeSource);
        return { frame, runtime: frame.contentWindow.__sgboxRuntime, runs: 0 };
      }

      function releaseSlot(slot) {
        slot.runs++;
        if (slot.runs >= RUNS_PER_SLOT) {
          slot.frame.remove();
          slotCount--;
          return;
        }
        idleSlots.push(slot);
      }

      window.__sgbox = {
        run(token, scriptID, invocationText, bodyText, source, remaining) {
          if (typeof source === "string") {
            sources.delete(scriptID);
            sources.set(scriptID, source);
            while (sources.size > MAX_SOURCES) {
              sources.delete(sources.keys().next().value);
            }
          } else {
            source = sources.get(scriptID);
            if (source === undefined) {
              return Promise.resolve(MISSING);
            }
            sources.delete(scriptID);
            sources.set(scriptID, source);
          }
          let slot = idleSlots.pop();
          try {
            if (!slot) {
              if (slotCount >= MAX_SLOTS) {
                return Promise.resolve(JSON.stringify({ status: "error", error: "too many scripts running at once" }));
              }
              slot = createSlot();
              slotCount++;
            }
            return slot.runtime.run(token, scriptID, invocationText, bodyText, source, remaining).then((outcome) => {
              releaseSlot(slot);
              return outcome;
            });
          } catch (error) {
            if (slot) {
              slot.frame.remove();
              slotCount--;
            }
            return Promise.resolve(JSON.stringify({ status: "error", error: String(error) }));
          }
        },
      };
    })();
    """#
#endif
