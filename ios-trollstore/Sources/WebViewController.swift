import UIKit
import WebKit
import AVFoundation
import Speech
import Darwin

/// Vỏ ứng dụng GrandSpeak Độc lập 100% trên iOS (TrollStore):
/// - Nhúng sẵn toàn bộ học liệu + Resort 3D ngay trong Bundle (phục vụ qua loopback cố định 127.0.0.1:34560, không cần bất kỳ máy chủ ngoài nào).
/// - Nhận diện giọng nói tiếng Anh trực tiếp qua phần cứng Micro iPhone bằng Apple Speech (`SFSpeechRecognizer` + `AVAudioEngine`).
/// - Đọc giọng chuẩn Anh – Mỹ / Anh – Anh / Tiếng Việt qua `AVSpeechSynthesizer` (phát rõ cả khi gạt nút Im lặng bên sườn máy).
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

private final class EmbeddedLoopbackServer {
    private let webRoot: URL
    private var listenFd: Int32 = -1
    private(set) var port: UInt16 = 0
    private var running = false

    init(webRoot: URL) {
        self.webRoot = webRoot.standardizedFileURL
    }

    func start() -> UInt16 {
        if running && port > 0 { return port }
        for candidate in [UInt16(34560), UInt16(34561), UInt16(34562), UInt16(0)] {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            if fd < 0 { continue }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = candidate.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindRes == 0 && Darwin.listen(fd, 64) == 0 {
                var actual = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                _ = withUnsafeMutablePointer(to: &actual) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.getsockname(fd, $0, &len)
                    }
                }
                self.listenFd = fd
                self.port = UInt16(bigEndian: actual.sin_port)
                self.running = true
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.acceptLoop()
                }
                return self.port
            }
            Darwin.close(fd)
        }
        return 0
    }

    private func acceptLoop() {
        while running && listenFd >= 0 {
            var clientAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFd, $0, &len)
                }
            }
            if clientFd < 0 { continue }
            var noSigPipe: Int32 = 1
            setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFd)
            }
        }
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    private func resolveFile(for rawPath: String) -> URL? {
        let clean = (rawPath.removingPercentEncoding ?? rawPath).components(separatedBy: "?")[0]
        let trimmed = clean.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let mapped: String
        switch "/" + trimmed {
        case "/", "/app", "/app/":
            mapped = "app.html"
        case "/landing":
            mapped = "index.html"
        case "/resort", "/city", "/flashcard/city", "/flashcard/resort":
            mapped = "resort/resort.html"
        case "/places", "/flashcard/places":
            mapped = "places/places.html"
        case "/room", "/flashcard/room":
            mapped = "room/room.html"
        default:
            mapped = trimmed.isEmpty ? "app.html" : trimmed
        }
        let target = webRoot.appendingPathComponent(mapped).standardizedFileURL
        guard target.path.hasPrefix(webRoot.path + "/") || target.path == webRoot.path else { return nil }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) {
            if isDir.boolValue {
                let idx = target.appendingPathComponent("index.html")
                if FileManager.default.fileExists(atPath: idx.path) { return idx }
                return nil
            }
            return target
        }
        return nil
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = Darwin.recv(fd, &buf, buf.count - 1, 0)
        guard n > 0 else { return }
        let reqStr = String(decoding: buf[0..<n], as: UTF8.self)
        guard let firstLine = reqStr.components(separatedBy: "\r\n").first else { return }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])

        guard let fileURL = resolveFile(for: path), let body = try? Data(contentsOf: fileURL) else {
            let notFound = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            writeAll(fd, notFound)
            return
        }
        let mime = mimeType(for: fileURL.pathExtension)
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: \(mime)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-cache",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        writeAll(fd, Data(header.utf8))
        if method != "HEAD" {
            writeAll(fd, body)
        }
    }
}

final class WebViewController: UIViewController,
    WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, AVSpeechSynthesizerDelegate {

    private let defaults = UserDefaults.standard
    private let dbStorageKey = "grandspeak.standaloneDB.v1"
    private let nativeTokenKey = "academy.sessionToken"
    private let nativeUserKey = "academy.cachedUserJSON"
    private let background = UIColor(red: 0.094, green: 0.110, blue: 0.133, alpha: 1.0)

    private var webView: WKWebView!
    private var localServer: EmbeddedLoopbackServer?
    private var didStart = false

    // Native TTS & Native Speech Recognition
    private let synthesizer = AVSpeechSynthesizer()
    private var activeSpeakId: Int = 0
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var activeSpeechReqId: Int = 0
    private var silenceTimer: Timer?
    private var speechIsContinuous = false

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = background
        synthesizer.delegate = self

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = WKWebsiteDataStore.default()

        let controller = WKUserContentController()
        controller.addUserScript(makeStandaloneBootstrapScript())
        controller.add(WeakScriptHandler(self), name: "native")
        config.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = background
        webView.scrollView.backgroundColor = background
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "native")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didStart {
            didStart = true
            startEmbeddedApp()
        }
    }

    private func jsStringLiteral(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value), let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        return "\"\""
    }

    private func makeStandaloneBootstrapScript() -> WKUserScript {
        let savedDb = defaults.string(forKey: dbStorageKey) ?? ""
        let savedToken = defaults.string(forKey: nativeTokenKey) ?? ""
        let savedUser = defaults.string(forKey: nativeUserKey) ?? ""

        let source = """
        (function() {
            window.ACADEMY_NATIVE_SHELL = true;
            window.ACADEMY_STANDALONE = true;
            window.ACADEMY_NATIVE_SPEECH = true;
            try {
                var savedDb = \(jsStringLiteral(savedDb));
                if (savedDb && !localStorage.getItem('grandspeak_standalone_db_v1')) {
                    localStorage.setItem('grandspeak_standalone_db_v1', savedDb);
                }
                var nt = \(jsStringLiteral(savedToken));
                var nu = \(jsStringLiteral(savedUser));
                if (nt && !localStorage.getItem('academy_mobile_token_v1')) {
                    localStorage.setItem('academy_mobile_token_v1', nt);
                }
                if (nu && !localStorage.getItem('academy_auth_user_v2')) {
                    localStorage.setItem('academy_auth_user_v2', nu);
                }
            } catch (e) {}

            function postNative(payload) {
                try {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.native) {
                        window.webkit.messageHandlers.native.postMessage(payload);
                    } else if (window.top && window.top !== window) {
                        window.top.postMessage({ __gsForwardNative: payload }, '*');
                    }
                } catch (e) {}
            }

            if (window.top === window) {
                window.addEventListener('message', function(ev) {
                    if (ev.data && ev.data.__gsForwardNative) {
                        postNative(ev.data.__gsForwardNative);
                    }
                });
            }

            // Native TTS Bridge (plays through Media channel, ignores iPhone hardware silent switch!)
            var ttsSeq = 0;
            var ttsCallbacks = {};
            window.academyNativeSpeak = function(text, lang, rate, onStart, onEnd) {
                var id = ++ttsSeq;
                ttsCallbacks[id] = { onStart: onStart, onEnd: onEnd };
                if (typeof onStart === 'function') { try { onStart(); } catch(e) {} }
                postNative({ cmd: 'speak', id: id, text: String(text || ''), lang: String(lang || 'en-US'), rate: Number(rate || 1.0) });
            };
            window.academyNativeStopSpeak = function() {
                postNative({ cmd: 'stopSpeak' });
            };

            // Also route window.speechSynthesis through Native AVSpeechSynthesizer so 3D Resort/Places/Room play clearly even on Silent switch
            if (window.speechSynthesis) {
                window.speechSynthesis.speak = function(utt) {
                    if (!utt || !utt.text) return;
                    window.academyNativeSpeak(utt.text, utt.lang || 'en-US', utt.rate || 1.0,
                        function() { if (typeof utt.onstart === 'function') utt.onstart({}); },
                        function() { if (typeof utt.onend === 'function') utt.onend({}); }
                    );
                };
                window.speechSynthesis.cancel = function() {
                    window.academyNativeStopSpeak();
                };
            }

            // Native Apple SpeechRecognition Polyfill (works in main frame & all 3D iframes!)
            var srSeq = 100;
            var srMap = {};
            function NativeSpeechRecognition() {
                this.lang = 'en-US';
                this.interimResults = false;
                this.continuous = false;
                this.maxAlternatives = 1;
                this.onstart = null;
                this.onresult = null;
                this.onerror = null;
                this.onend = null;
                this._listeners = {};
                this._id = ++srSeq;
            }
            NativeSpeechRecognition.prototype.addEventListener = function(type, fn) {
                if (!this._listeners[type]) this._listeners[type] = [];
                this._listeners[type].push(fn);
            };
            NativeSpeechRecognition.prototype.removeEventListener = function(type, fn) {
                if (!this._listeners[type]) return;
                this._listeners[type] = this._listeners[type].filter(function(f) { return f !== fn; });
            };
            NativeSpeechRecognition.prototype._emit = function(type, ev) {
                var prop = this['on' + type];
                if (typeof prop === 'function') { try { prop.call(this, ev); } catch(e) {} }
                var arr = this._listeners[type] || [];
                for (var i = 0; i < arr.length; i++) { try { arr[i].call(this, ev); } catch(e) {} }
            };
            NativeSpeechRecognition.prototype.start = function() {
                srMap[this._id] = this;
                postNative({
                    cmd: 'startSpeech',
                    reqId: this._id,
                    lang: this.lang || 'en-US',
                    interim: Boolean(this.interimResults),
                    continuous: Boolean(this.continuous)
                });
                var self = this;
                setTimeout(function() { self._emit('start', { type: 'start' }); }, 30);
            };
            NativeSpeechRecognition.prototype.stop = function() {
                postNative({ cmd: 'stopSpeech', reqId: this._id });
            };
            NativeSpeechRecognition.prototype.abort = function() {
                postNative({ cmd: 'stopSpeech', reqId: this._id });
            };

            window.SpeechRecognition = NativeSpeechRecognition;
            window.webkitSpeechRecognition = NativeSpeechRecognition;

            window.addEventListener('message', function(ev) {
                var d = ev.data;
                if (!d || !d.__gsNativeEvent) return;
                // Relay to child iframes as well
                var frames = document.querySelectorAll ? document.querySelectorAll('iframe') : [];
                for (var i = 0; i < frames.length; i++) {
                    try { frames[i].contentWindow.postMessage(d, '*'); } catch(e) {}
                }
                if (d.kind === 'ttsEnd') {
                    var cb = ttsCallbacks[d.id];
                    delete ttsCallbacks[d.id];
                    if (cb && typeof cb.onEnd === 'function') { try { cb.onEnd(); } catch(e) {} }
                } else if (d.kind === 'srResult') {
                    var inst = srMap[d.reqId];
                    if (!inst) return;
                    if (!d.isFinal && !inst.interimResults) return;
                    var item = [{ transcript: d.transcript || '', confidence: 0.95 }];
                    item.isFinal = Boolean(d.isFinal);
                    var results = [item];
                    results.resultIndex = 0;
                    window.__lastLiveSpeechTranscript = d.transcript || '';
                    inst._emit('result', { type: 'result', resultIndex: 0, results: results });
                } else if (d.kind === 'srError') {
                    var instE = srMap[d.reqId];
                    if (!instE) return;
                    delete srMap[d.reqId];
                    instE._emit('error', { type: 'error', error: d.error || 'no-speech' });
                    instE._emit('end', { type: 'end' });
                } else if (d.kind === 'srEnd') {
                    var instD = srMap[d.reqId];
                    if (!instD) return;
                    delete srMap[d.reqId];
                    instD._emit('end', { type: 'end' });
                }
            });
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private func startEmbeddedApp() {
        guard let webDir = Bundle.main.resourceURL?.appendingPathComponent("Web", isDirectory: true) else {
            webView.loadHTMLString("<h2 style='color:#fff;font-family:sans-serif;padding:32px'>Thiếu gói Web trong ứng dụng.</h2>", baseURL: nil)
            return
        }
        let srv = EmbeddedLoopbackServer(webRoot: webDir)
        let port = srv.start()
        self.localServer = srv
        if let url = URL(string: "http://127.0.0.1:\(port)/app") {
            webView.load(URLRequest(url: url))
        }
    }

    private func emitToJs(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("window.postMessage(\(json), '*');", completionHandler: nil)
        }
    }

    // MARK: - Native TTS (AVSpeechSynthesizer)
    private func handleSpeak(id: Int, text: String, lang: String, rate: Double) {
        if audioEngine.isRunning { return }
        synthesizer.stopSpeaking(at: .immediate)
        activeSpeakId = id
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: lang) ?? AVSpeechSynthesisVoice(language: "en-US")
        let scaled = Float(rate) * AVSpeechUtteranceDefaultSpeechRate
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, scaled))
        synthesizer.speak(u)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        emitToJs(["__gsNativeEvent": true, "kind": "ttsEnd", "id": activeSpeakId])
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        emitToJs(["__gsNativeEvent": true, "kind": "ttsEnd", "id": activeSpeakId])
    }

    // MARK: - Native Speech Recognition (SFSpeechRecognizer + AVAudioEngine)
    private func startNativeSpeech(reqId: Int, lang: String, continuous: Bool) {
        stopNativeSpeech(notifyEnd: false)
        synthesizer.stopSpeaking(at: .immediate)
        activeSpeechReqId = reqId
        speechIsContinuous = continuous

        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            guard let self = self else { return }
            guard authStatus == .authorized else {
                self.emitToJs(["__gsNativeEvent": true, "kind": "srError", "reqId": reqId, "error": "not-allowed"])
                return
            }
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard granted else {
                        self.emitToJs(["__gsNativeEvent": true, "kind": "srError", "reqId": reqId, "error": "not-allowed"])
                        return
                    }
                    self.beginAudioEngineRecognition(reqId: reqId, lang: lang)
                }
            }
        }
    }

    private func beginAudioEngineRecognition(reqId: Int, lang: String) {
        let locale = Locale(identifier: lang.isEmpty ? "en-US" : lang)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            emitToJs(["__gsNativeEvent": true, "kind": "srError", "reqId": reqId, "error": "service-not-allowed"])
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            self.recognitionRequest = req

            let inputNode = audioEngine.inputNode
            inputNode.removeTap(onBus: 0)
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            resetSilenceTimer(reqId: reqId, seconds: speechIsContinuous ? 8.0 : 4.5)

            recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
                guard let self = self, self.activeSpeechReqId == reqId else { return }
                if let res = result {
                    let text = res.bestTranscription.formattedString
                    self.emitToJs([
                        "__gsNativeEvent": true,
                        "kind": "srResult",
                        "reqId": reqId,
                        "transcript": text,
                        "isFinal": res.isFinal
                    ])
                    if res.isFinal {
                        self.stopNativeSpeech(notifyEnd: true)
                        return
                    } else {
                        self.resetSilenceTimer(reqId: reqId, seconds: self.speechIsContinuous ? 3.5 : 1.7)
                    }
                }
                if error != nil {
                    self.stopNativeSpeech(notifyEnd: true)
                }
            }
        } catch {
            emitToJs(["__gsNativeEvent": true, "kind": "srError", "reqId": reqId, "error": "audio-capture"])
        }
    }

    private func resetSilenceTimer(reqId: Int, seconds: TimeInterval) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self = self, self.activeSpeechReqId == reqId else { return }
            self.stopNativeSpeech(notifyEnd: true)
        }
    }

    private func stopNativeSpeech(notifyEnd: Bool) {
        silenceTimer?.invalidate()
        silenceTimer = nil
        let endedId = activeSpeechReqId
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        if notifyEnd && endedId > 0 {
            activeSpeechReqId = 0
            emitToJs(["__gsNativeEvent": true, "kind": "srEnd", "reqId": endedId])
        }
    }

    // MARK: - WKScriptMessageHandler
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let dict = message.body as? [String: Any], let cmd = dict["cmd"] as? String {
            switch cmd {
            case "saveStandaloneDB":
                if let dbJson = dict["dbJson"] as? String {
                    defaults.set(dbJson, forKey: dbStorageKey)
                }
            case "saveSession":
                if let token = dict["token"] as? String, !token.isEmpty {
                    defaults.set(token, forKey: nativeTokenKey)
                }
                if let userJson = dict["userJson"] as? String, !userJson.isEmpty {
                    defaults.set(userJson, forKey: nativeUserKey)
                }
            case "clearSession":
                defaults.removeObject(forKey: nativeTokenKey)
                defaults.removeObject(forKey: nativeUserKey)
            case "speak":
                let id = dict["id"] as? Int ?? 1
                let text = dict["text"] as? String ?? ""
                let lang = dict["lang"] as? String ?? "en-US"
                let rate = dict["rate"] as? Double ?? 1.0
                handleSpeak(id: id, text: text, lang: lang, rate: rate)
            case "stopSpeak":
                synthesizer.stopSpeaking(at: .immediate)
            case "startSpeech":
                let reqId = dict["reqId"] as? Int ?? 1
                let lang = dict["lang"] as? String ?? "en-US"
                let cont = dict["continuous"] as? Bool ?? false
                startNativeSpeech(reqId: reqId, lang: lang, continuous: cont)
            case "stopSpeech":
                stopNativeSpeech(notifyEnd: true)
            default:
                break
            }
        } else if let text = message.body as? String, text == "clearSession" {
            defaults.removeObject(forKey: nativeTokenKey)
            defaults.removeObject(forKey: nativeUserKey)
        }
    }

    // MARK: - WKUIDelegate (Auto-allow Microphone & Alerts)
    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "Đồng ý", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let host = url.host?.lowercased() ?? ""
        if host == "127.0.0.1" || host == "localhost" || url.scheme == "blob" || url.scheme == "data" || url.scheme == "about" {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
