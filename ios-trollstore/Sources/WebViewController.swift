import UIKit
import WebKit

/// Vỏ ứng dụng native (WKWebView) mở Học viện từ máy chủ Node.js của bạn.
/// - Giữ đăng nhập tuyệt đối sau khi tắt hẳn app (UserDefaults native + cookie HttpOnly + localStorage).
/// - Hỗ trợ alert/confirm/prompt, tải file (chứng nhận PNG, mã HEAP2), micro, âm thanh khi bật nút Im lặng.
/// - Nút "Đổi máy chủ" trực tiếp trên giao diện hoặc chạm giữ 3 ngón tay 1,2 giây để đổi địa chỉ máy chủ.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

final class WebViewController: UIViewController,
    WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate, UIGestureRecognizerDelegate {

    private let defaults = UserDefaults.standard
    private let serverKey = "academy.serverURL"
    private let nativeTokenKey = "academy.sessionToken"
    private let nativeUserKey = "academy.cachedUserJSON"
    private let background = UIColor(red: 0.094, green: 0.110, blue: 0.133, alpha: 1.0)

    private var webView: WKWebView!
    private var didStart = false
    private var lastDownload: URL?

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    // MARK: - Vòng đời

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = background

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = WKWebsiteDataStore.default()

        let controller = WKUserContentController()
        controller.addUserScript(makeBootstrapScript())
        controller.add(WeakScriptMessageHandler(self), name: "native")
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

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleSecretPress(_:)))
        press.numberOfTouchesRequired = 3
        press.minimumPressDuration = 1.2
        press.cancelsTouchesInView = false
        press.delegate = self
        webView.addGestureRecognizer(press)
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "native")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didStart {
            didStart = true
            loadServer()
        }
    }

    // MARK: - Đồng bộ phiên đăng nhập Native <-> WebView

    private func jsStringLiteral(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value), let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        return "\"\""
    }

    private func makeBootstrapScript() -> WKUserScript {
        let savedToken = defaults.string(forKey: nativeTokenKey) ?? ""
        let savedUser = defaults.string(forKey: nativeUserKey) ?? ""
        let savedServer = defaults.string(forKey: serverKey) ?? ""
        let source = """
        (function() {
            window.ACADEMY_NATIVE_SHELL = true;
            window.ACADEMY_NATIVE_SERVER = \(jsStringLiteral(savedServer));
            try {
                var nt = \(jsStringLiteral(savedToken));
                var nu = \(jsStringLiteral(savedUser));
                if (nt && /^[a-f0-9]{64}$/i.test(nt) && !localStorage.getItem('academy_mobile_token_v1')) {
                    localStorage.setItem('academy_mobile_token_v1', nt);
                }
                if (nu && !localStorage.getItem('academy_auth_user_v2')) {
                    localStorage.setItem('academy_auth_user_v2', nu);
                }
            } catch (e) {}
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    private func refreshUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(makeBootstrapScript())
    }

    // MARK: - Máy chủ

    private func serverBase() -> String? {
        guard let raw = defaults.string(forKey: serverKey), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private func isPrivateOrLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h == "127.0.0.1" || h == "::1" || h.hasSuffix(".local") {
            return true
        }
        if h.hasPrefix("192.168.") || h.hasPrefix("10.") {
            return true
        }
        if h.hasPrefix("172.") {
            let parts = h.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), second >= 16 && second <= 31 {
                return true
            }
        }
        return false
    }

    private func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return nil
        }
        let lower = text.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            let hostPart = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
            let hostOnly = hostPart.split(separator: ":", maxSplits: 1).first.map(String.init) ?? hostPart
            text = (isPrivateOrLocalHost(hostOnly) ? "http://" : "https://") + text
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        if text.lowercased().hasSuffix("/app") {
            text = String(text.dropLast(4))
        }
        guard let url = URL(string: text), url.host != nil else {
            return nil
        }
        return text
    }

    private func loadServer() {
        refreshUserScripts()
        guard let base = serverBase(), let url = URL(string: base + "/app") else {
            promptForServer(message: "Nhập địa chỉ máy chủ GrandSpeak (khuyên dùng https://grandspeak.ten-mien.vn để bật Micro trên iPhone, hoặc http://192.168.1.x:3456 trong LAN).")
            return
        }
        let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20)
        webView.load(request)
    }

    private func promptForServer(message: String) {
        if presentedViewController != nil {
            return
        }
        let alert = UIAlertController(title: "Máy chủ GrandSpeak", message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "http://192.168.1.10:3456"
            field.text = self.defaults.string(forKey: self.serverKey)
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Kết nối", style: .default) { _ in
            let text = alert.textFields?.first?.text ?? ""
            if let normalized = self.normalize(text) {
                let oldServer = self.defaults.string(forKey: self.serverKey)
                if oldServer != nil && oldServer != normalized {
                    self.defaults.removeObject(forKey: self.nativeTokenKey)
                    self.defaults.removeObject(forKey: self.nativeUserKey)
                }
                self.defaults.set(normalized, forKey: self.serverKey)
                self.defaults.synchronize()
                self.loadServer()
            } else {
                DispatchQueue.main.async {
                    self.promptForServer(message: "Địa chỉ chưa hợp lệ. Ví dụ đúng: http://192.168.1.10:3456")
                }
            }
        })
        if serverBase() != nil {
            alert.addAction(UIAlertAction(title: "Hủy", style: .cancel, handler: nil))
        }
        present(alert, animated: true, completion: nil)
    }

    @objc private func handleSecretPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            promptForServer(message: "Nhập địa chỉ máy chủ GrandSpeak mới.")
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return true
    }

    // MARK: - Trang lỗi khi mất mạng

    private func htmlEscape(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func bundledIconDataURI() -> String? {
        if let path = Bundle.main.path(forResource: "AppIcon60x60@3x", ofType: "png"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            return "data:image/png;base64," + data.base64EncodedString()
        }
        return nil
    }

    private func showOfflinePage(detail: String) {
        let server = htmlEscape(serverBase() ?? "chưa cấu hình")
        let reason = htmlEscape(detail)
        let crestMarkup: String
        if let uri = bundledIconDataURI() {
            crestMarkup = "<img class=\"crest-img\" src=\"\(uri)\" alt=\"GrandSpeak\">"
        } else {
            crestMarkup = "<div class=\"crest\">G</div>"
        }
        let html = """
        <!doctype html>
        <html lang="vi"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>
        html,body{margin:0;height:100%;background:#181c22;color:#f7f3e8;font-family:-apple-system,Helvetica,Arial,sans-serif}
        .wrap{min-height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:28px;box-sizing:border-box;text-align:center}
        .crest{width:84px;height:84px;border-radius:22px;background:linear-gradient(135deg,#f3d282,#b98728);display:flex;align-items:center;justify-content:center;font-size:36px;font-weight:800;color:#181c22;margin-bottom:18px;box-shadow:0 12px 30px rgba(0,0,0,.45)}
        .crest-img{width:88px;height:88px;border-radius:22px;object-fit:cover;margin-bottom:18px;border:1px solid rgba(243,210,130,.45);box-shadow:0 12px 30px rgba(0,0,0,.5)}
        h1{font-size:21px;margin:0 0 8px}
        p{font-size:14px;line-height:1.55;margin:0 0 6px;color:#d5dce6}
        code{background:rgba(255,255,255,.12);padding:3px 8px;border-radius:6px;word-break:break-all}
        button{margin:12px 6px 0;padding:13px 22px;border-radius:12px;border:0;font-size:15px;font-weight:700}
        .gold{background:linear-gradient(135deg,#f3d282,#c99a3b);color:#181c22}
        .ghost{background:rgba(255,255,255,.12);color:#fff}
        small{display:block;margin-top:18px;color:#9aa6b8;font-size:12px;max-width:320px}
        </style></head><body><div class="wrap">
        \(crestMarkup)
        <h1>Không kết nối được GrandSpeak</h1>
        <p>Hãy kiểm tra iPhone và máy chủ đang cùng mạng Wi-Fi (hoặc 4G nếu dùng tên miền online), đồng thời <code>node server.mjs</code> đang chạy.</p>
        <p>Máy chủ hiện tại: <code>\(server)</code></p>
        <small>\(reason)</small>
        <div>
        <button class="gold" onclick="window.webkit.messageHandlers.native.postMessage('retry')">Thử kết nối lại</button>
        <button class="ghost" onclick="window.webkit.messageHandlers.native.postMessage('change')">Đổi địa chỉ máy chủ</button>
        </div>
        </div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func handleLoadError(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
            return
        }
        showOfflinePage(detail: nsError.localizedDescription)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadServer()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "http" || scheme == "https" {
            if navigationAction.navigationType == .linkActivated,
               let base = serverBase(),
               let baseHost = URL(string: base)?.host,
               let host = url.host,
               host != baseHost {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
            return
        }
        if scheme == "tel" || scheme == "mailto" || scheme == "sms" {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: - WKDownloadDelegate (chứng nhận PNG, mã sao lưu, báo cáo)

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        let name = suggestedFilename.isEmpty ? "academy-file" : suggestedFilename
        let destination = folder.appendingPathComponent(name)
        lastDownload = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = lastDownload else {
            return
        }
        DispatchQueue.main.async {
            let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = self.view
                popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
            self.present(sheet, animated: true, completion: nil)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        // Người dùng có thể thử lại; không cần xử lý thêm.
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            if let base = serverBase(), let baseHost = URL(string: base)?.host, url.host == baseHost {
                webView.load(URLRequest(url: url))
            } else {
                UIApplication.shared.open(url)
            }
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completionHandler()
        })
        present(alert, animated: true, completion: nil)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel) { _ in
            completionHandler(false)
        })
        alert.addAction(UIAlertAction(title: "Đồng ý", style: .default) { _ in
            completionHandler(true)
        })
        present(alert, animated: true, completion: nil)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = defaultText
        }
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel) { _ in
            completionHandler(nil)
        })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        present(alert, animated: true, completion: nil)
    }

    @available(iOS 15.0, *)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        AudioRouter.activateRecording()
        decisionHandler(.grant)
    }

    // MARK: - Cầu nối JavaScript → native

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let dict = message.body as? [String: Any], let cmd = dict["cmd"] as? String {
            switch cmd {
            case "saveSession":
                if let token = dict["token"] as? String, !token.isEmpty {
                    defaults.set(token, forKey: nativeTokenKey)
                }
                if let userJson = dict["userJson"] as? String, !userJson.isEmpty {
                    defaults.set(userJson, forKey: nativeUserKey)
                }
                defaults.synchronize()
                refreshUserScripts()
            case "clearSession":
                defaults.removeObject(forKey: nativeTokenKey)
                defaults.removeObject(forKey: nativeUserKey)
                defaults.synchronize()
                refreshUserScripts()
            default:
                break
            }
            return
        }

        guard let command = message.body as? String else {
            return
        }
        switch command {
        case "retry":
            loadServer()
        case "change":
            promptForServer(message: "Nhập địa chỉ máy chủ GrandSpeak mới.")
        case "clearSession":
            defaults.removeObject(forKey: nativeTokenKey)
            defaults.removeObject(forKey: nativeUserKey)
            defaults.synchronize()
            refreshUserScripts()
        case "recording":
            AudioRouter.activateRecording()
        case "playback":
            AudioRouter.activatePlayback()
        default:
            break
        }
    }
}
