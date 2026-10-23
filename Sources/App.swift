// PokeBonk iOS 客户端
//
// 为什么不能照搬桌面版/安卓版：
//   WKWebView 不允许拦截 https 请求（WKURLSchemeHandler 只能拦自定义 scheme，
//   NSURLProtocol 对 WKWebView 无效）。所以这里换一条路——
//   在进程内起一个只监听 127.0.0.1 的 HTTP 服务，WebView 加载 http://127.0.0.1:port，
//   静态资源从 App 包内读，其余请求反向代理到源站。
//
// API 域名的处理：
//   主 chunk 里是 fetch(this.base + path)，base 来自 `https://api.pokebonk.com`（全包只出现 1 次）。
//   返回 JS 时把它替换成 http://127.0.0.1:<port>/__api__，于是 API 也走本地服务，
//   与页面同源，绕开 CORS，也不需要改写打包资源（端口是运行时随机的，必须动态替换）。

import UIKit
import WebKit
import Network

// MARK: - 工具

private func mimeType(for ext: String) -> String {
    switch ext.lowercased() {
    case "html", "htm": return "text/html; charset=utf-8"
    case "js", "mjs": return "text/javascript; charset=utf-8"
    case "css": return "text/css; charset=utf-8"
    case "json": return "application/json; charset=utf-8"
    case "webmanifest": return "application/manifest+json"
    case "svg": return "image/svg+xml"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "webp": return "image/webp"
    case "gif": return "image/gif"
    case "ico": return "image/x-icon"
    case "woff2": return "font/woff2"
    case "woff": return "font/woff"
    case "ttf": return "font/ttf"
    case "mp3": return "audio/mpeg"
    case "ogg": return "audio/ogg"
    case "mp4": return "video/mp4"
    case "glb": return "model/gltf-binary"
    case "gltf": return "model/gltf+json"
    default: return "application/octet-stream"
    }
}

private func reasonPhrase(_ code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 204: return "No Content"
    case 301: return "Moved Permanently"
    case 304: return "Not Modified"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 500: return "Internal Server Error"
    case 502: return "Bad Gateway"
    case 503: return "Service Unavailable"
    case 504: return "Gateway Timeout"
    default: return "OK"
    }
}

// MARK: - 本地服务

final class LocalServer {

    static let shared = LocalServer()

    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "pokebonk.local.server", qos: .userInitiated)
    private let www: URL
    private let apiOrigin = "https://api.pokebonk.com"
    private let siteOrigin = "https://pokebonk.com"

    private var patchedCache: [String: Data] = [:]
    private let cacheLock = NSLock()

    private var readyFlag = false
    private let readyLock = NSLock()

    private init() {
        let root = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        www = root.appendingPathComponent("www", isDirectory: true)
    }

    /// 启动；返回可用端口，失败返回 nil（调用方降级为直连官网）。
    func start() -> UInt16? {
        for useLoopback in [true, false] {
            if let p = tryStart(loopbackOnly: useLoopback) {
                port = p
                return p
            }
        }
        return nil
    }

    private func tryStart(loopbackOnly: Bool) -> UInt16? {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if loopbackOnly {
            // 只监听回环，别把游戏资源暴露到局域网
            params.requiredInterfaceType = .loopback
        }

        guard let l = try? NWListener(using: params, on: .any) else { return nil }

        let sem = DispatchSemaphore(value: 0)
        readyLock.lock()
        readyFlag = false
        readyLock.unlock()

        l.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            var signal = false
            self.readyLock.lock()
            switch state {
            case .ready:
                if !self.readyFlag { self.readyFlag = true; signal = true }
            case .failed, .cancelled:
                if !self.readyFlag { self.readyFlag = true; signal = true }
            default:
                break
            }
            self.readyLock.unlock()
            if signal { sem.signal() }
        }

        l.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }

        l.start(queue: queue)
        _ = sem.wait(timeout: .now() + 6)

        guard let p = l.port?.rawValue, p > 0 else {
            l.cancel()
            return nil
        }
        listener = l
        return p
    }

    // MARK: 连接与解析

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, Data())
    }

    private func readRequest(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isDone, error in
            guard let self = self else { conn.cancel(); return }

            var acc = buffer
            if let d = data, !d.isEmpty { acc.append(d) }
            if acc.count > 8 * 1024 * 1024 { conn.cancel(); return }

            guard let sep = acc.range(of: Data("\r\n\r\n".utf8)) else {
                if isDone || error != nil { conn.cancel() } else { self.readRequest(conn, acc) }
                return
            }

            let headData = acc.subdata(in: acc.startIndex ..< sep.lowerBound)
            let body = acc.subdata(in: sep.upperBound ..< acc.endIndex)
            guard let head = String(data: headData, encoding: .utf8) else { conn.cancel(); return }

            var lines = head.components(separatedBy: "\r\n")
            guard !lines.isEmpty else { conn.cancel(); return }

            let parts = lines.removeFirst().split(separator: " ")
            guard parts.count >= 2 else { conn.cancel(); return }
            let method = String(parts[0]).uppercased()
            let path = String(parts[1])

            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[line.startIndex ..< colon].lowercased()
                // 显式包一层 String：Substring 上不保证有 trimmingCharacters
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }

            let need = Int(headers["content-length"] ?? "0") ?? 0
            if body.count < need {
                self.readRequest(conn, acc)
                return
            }

            self.route(conn, method: method, path: path, headers: headers, body: body.prefix(need))
        }
    }

    // MARK: 路由

    private func route(_ conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        // 用闭包而不是 String.init：map(String.init) 在 Substring 上会撞到重载歧义
        let withoutQuery: String? = path
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { String($0) }
        let clean = withoutQuery ?? "/"

        // 1) API 转发
        if clean.hasPrefix("/__api__") {
            let rest = String(clean.dropFirst("/__api__".count))
            let target = apiOrigin + (rest.isEmpty ? "/" : rest)
            var full = target
            if let q = path.firstIndex(of: "?") { full += String(path[q...]) }
            proxy(conn, method: method, urlString: full, headers: headers, body: body)
            return
        }

        // 2) 本地静态资源
        if method == "GET" || method == "HEAD" {
            if let file = staticFile(clean) {
                respond(conn, 200, ["Content-Type": file.mime,
                                    "Cache-Control": "no-cache",
                                    "Accept-Ranges": "none"],
                        method == "HEAD" ? Data() : file.data)
                return
            }
        }

        // 3) 其它（favicon、version.json、cdn-cgi 等）→ 回源
        proxy(conn, method: method, urlString: siteOrigin + path, headers: headers, body: body)
    }

    private struct StaticFile {
        let data: Data
        let mime: String
    }

    private func staticFile(_ path: String) -> StaticFile? {
        var rel = path
        if rel.isEmpty || rel == "/" { rel = "/index.html" }
        if rel.contains("..") { return nil }

        let fileURL = www.appendingPathComponent(String(rel.dropFirst()))
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard var data = try? Data(contentsOf: fileURL) else { return nil }

        let mime = mimeType(for: fileURL.pathExtension)
        // 只有 JS 里才可能出现 API 域名；CSS/JSON 不必解码，省掉每帧几百 KB 的字符串开销
        if mime.contains("javascript") {
            data = patchAPI(data, key: rel)
        }
        return StaticFile(data: data, mime: mime)
    }

    /// 把主 chunk 里的 API 域名换成「本机 + /__api__」，端口在运行时才知道，所以只能在这里改。
    private func patchAPI(_ data: Data, key: String) -> Data {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        let cacheKey = "\(port)|\(key)"
        if let hit = patchedCache[cacheKey] { return hit }

        guard port > 0,
              let text = String(data: data, encoding: .utf8),
              text.contains(apiOrigin) else {
            return data
        }

        let replacement = "http://127.0.0.1:\(port)/__api__"
        let out = Data(text.replacingOccurrences(of: apiOrigin, with: replacement).utf8)
        patchedCache[cacheKey] = out
        return out
    }

    // MARK: 回源

    private func proxy(_ conn: NWConnection, method: String, urlString: String, headers: [String: String], body: Data) {
        guard let url = URL(string: urlString) else {
            respond(conn, 400, ["Content-Type": "text/plain"], Data("bad url".utf8))
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 40

        // 只透传「向后端说明我是谁」的头；origin/referer 故意不带——
        // 带上去会暴露 127.0.0.1，服务端做来源校验时会直接拒。
        let passthrough = ["authorization", "content-type", "accept", "accept-language",
                           "cookie", "user-agent", "x-device", "x-client", "x-admin-token"]
        for (k, v) in headers where passthrough.contains(k) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if !body.isEmpty {
            req.httpBody = body
        }

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { conn.cancel(); return }

            if let error = error {
                let msg = "上游请求失败：\(error.localizedDescription)"
                self.respond(conn, 502, ["Content-Type": "text/plain; charset=utf-8"], Data(msg.utf8))
                return
            }

            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 502

            var outHeaders: [String: String] = [:]
            let ct = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json; charset=utf-8"
            outHeaders["Content-Type"] = ct
            outHeaders["Cache-Control"] = "no-store"
            if let sc = http?.value(forHTTPHeaderField: "Set-Cookie") {
                outHeaders["Set-Cookie"] = sc
            }

            self.respond(conn, code, outHeaders, data ?? Data())
        }.resume()
    }

    // MARK: 响应

    private func respond(_ conn: NWConnection, _ code: Int, _ headers: [String: String], _ body: Data) {
        var head = "HTTP/1.1 \(code) \(reasonPhrase(code))\r\n"
        for (k, v) in headers {
            head += "\(k): \(v)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(body)

        sendAll(conn, payload)
    }

    /// 分块发送，最后用 finalMessage 收尾。一次性 send 几 MB 再立刻 cancel 容易把尾部截掉。
    private func sendAll(_ conn: NWConnection, _ data: Data) {
        let chunkSize = 64 * 1024
        var offset = 0

        func sendNext() {
            if offset >= data.count {
                conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                          completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            let end = min(offset + chunkSize, data.count)
            let piece = data.subdata(in: offset ..< end)
            offset = end
            conn.send(content: piece, completion: .contentProcessed { error in
                if error != nil { conn.cancel(); return }
                sendNext()
            })
        }

        sendNext()
    }
}

// MARK: - 界面

final class GameViewController: UIViewController {

    private var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.suppressesIncrementalRendering = false

        let wv = WKWebView(frame: view.bounds, configuration: config)
        wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wv.backgroundColor = .black
        wv.isOpaque = false
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.allowsBackForwardNavigationGestures = false
        if #available(iOS 16.4, *) {
            wv.isInspectable = true
        }
        view.addSubview(wv)
        webView = wv

        if let port = LocalServer.shared.start(),
           let url = URL(string: "http://127.0.0.1:\(port)/") {
            wv.load(URLRequest(url: url))
        } else {
            // 本地服务起不来就直连官网：没有加速，但至少能玩
            wv.load(URLRequest(url: URL(string: "https://pokebonk.com/")!))
        }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .allButUpsideDown
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        webView.frame = view.bounds
    }
}

// MARK: - 入口

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    static func main() {
        _ = UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil,
                              NSStringFromClass(AppDelegate.self))
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let win = UIWindow(frame: UIScreen.main.bounds)
        win.rootViewController = GameViewController()
        win.makeKeyAndVisible()
        window = win
        return true
    }
}
