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

        // overlay（更新下来的）优先，其次包内 www
        guard var data = MirrorStore.shared.data(for: rel) else { return nil }

        let mime = mimeType(for: (rel as NSString).pathExtension)
        // 只有 JS 里才可能出现 API 域名；CSS/JSON 不必解码，省掉每帧几百 KB 的字符串开销。
        // 更新到 overlay 的 JS 同样要替换 —— 否则换了新版本，API 还指着公网域名。
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

// MARK: - 可写镜像层
//
// 装进 ipa 的 www/ 是只读的，官网一发新版就会永远停在旧版本。
// 所以在 Application Support 里再放一层可写的 overlay，读取顺序：
//     overlay（更新下来的） → 包内 www（打包时带的） → 交回网络反代
//
// 换版流程和桌面版/安卓版一致：
//   取 version.json 比对 build → 先把数据表和 core 资源下到 overlay
//   → 最后才切 index.html（反了会白屏重载）→ 记历史并清掉 overlay 里的旧版文件

final class MirrorStore {

    static let shared = MirrorStore()

    private let bundled: URL
    let overlay: URL

    private var netFailStreak = 0

    /// 名字固定、必须跟着版本一起换的数据表（旧数据表配新代码会出错）
    private static let bootData = [
        "/data/types.json", "/data/items.json", "/data/abilities.json",
        "/data/pokemon.json", "/data/sprites.json", "/data/moves.json",
        "/data/learnsets.json", "/data/i18n/zh.json",
    ]

    /// 文件名跨版本不变的目录：命中就用，但换版后允许后台换新
    private static let stablePrefixes = [
        "/assets/models/", "/assets/pmd/", "/assets/portraits/", "/assets/items/",
        "/assets/icons/", "/assets/ui/", "/assets/env/", "/assets/cries/",
        "/assets/music/", "/data/",
    ]

    private static let maxFileBytes = 12 * 1024 * 1024
    private static let maxSyncBytes = 32 * 1024 * 1024
    /// 手机走代理比桌面慢得多，给足时间再去判定「下不动」，否则总是半途而废
    private static let maxSyncSeconds: TimeInterval = 150

    private init() {
        let root = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        bundled = root.appendingPathComponent("www", isDirectory: true)

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        overlay = support.appendingPathComponent("mirror", isDirectory: true)
        try? FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
    }

    static func isStable(_ path: String) -> Bool {
        for p in stablePrefixes where path.hasPrefix(p) { return true }
        return false
    }

    // MARK: 读

    func data(for rel: String) -> Data? {
        let clean = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
        let f = overlay.appendingPathComponent(clean)
        if let d = try? Data(contentsOf: f), !d.isEmpty { return d }
        let b = bundled.appendingPathComponent(clean)
        return try? Data(contentsOf: b)
    }

    private func existsInOverlay(_ rel: String) -> Bool {
        let clean = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
        return FileManager.default.fileExists(atPath: overlay.appendingPathComponent(clean).path)
    }

    func currentBuild() -> String? {
        guard let d = data(for: "/index.html"), let html = String(data: d, encoding: .utf8) else { return nil }
        return Self.buildTag(html)
    }

    static func buildTag(_ html: String) -> String? {
        guard let k = html.range(of: "pokebonk-build") else { return nil }
        guard let c = html.range(of: "content=\"", range: k.upperBound..<html.endIndex) else { return nil }
        let rest = html[c.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<end])
    }

    private static func jsonBuild(_ text: String) -> String? {
        guard let k = text.range(of: "\"build\"") else { return nil }
        guard let c = text.range(of: "\"", range: k.upperBound..<text.endIndex) else { return nil }
        let rest = text[c.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let v = String(rest[rest.startIndex..<end])
        return v.isEmpty ? nil : v
    }

    private static func refsFrom(_ text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()

        func add(_ s: String) {
            if seen.insert(s).inserted { out.append(s) }
        }

        if let rx = try? NSRegularExpression(
            pattern: "(?:\\./|/)?assets/([A-Za-z0-9._@%\\-]+\\.(?:js|css|json|webmanifest|woff2))") {
            let ns = text as NSString
            for m in rx.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
                if m.numberOfRanges > 1 { add("/assets/" + ns.substring(with: m.range(at: 1))) }
            }
        }
        if let rx2 = try? NSRegularExpression(
            pattern: "\"\\./([A-Za-z0-9._@%\\-]+\\.(?:js|css))\"") {
            let ns = text as NSString
            for m in rx2.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
                if m.numberOfRanges > 1 { add("/assets/" + ns.substring(with: m.range(at: 1))) }
            }
        }
        return out
    }

    // MARK: 写

    private func put(_ rel: String, _ data: Data) {
        let clean = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
        let f = overlay.appendingPathComponent(clean)
        let dir = f.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(f.lastPathComponent + ".part")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.removeItem(at: f)
            try FileManager.default.moveItem(at: tmp, to: f)
        } catch { }
    }

    // MARK: build 记录（overlay/_build.txt，内容 "build|历史,历史"）

    private var recordURL: URL { overlay.appendingPathComponent("_build.txt") }

    private func recorded() -> (build: String?, history: [String]) {
        guard let d = try? Data(contentsOf: recordURL),
              let t = String(data: d, encoding: .utf8) else { return (nil, []) }
        let parts = t.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let b = parts.isEmpty ? "" : String(parts[0]).trimmingCharacters(in: .whitespaces)
        var hist: [String] = []
        if parts.count > 1 {
            for p in String(parts[1]).split(separator: ",") {
                let s = p.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty && !hist.contains(s) { hist.append(s) }
            }
        }
        return (b.isEmpty ? nil : b, hist)
    }

    private func setRecord(_ build: String, history: [String]) {
        let keep = history.suffix(8).joined(separator: ",")
        put("/_build.txt", Data("\(build)|\(keep)".utf8))
    }

    // MARK: 网络

    /// 用引用类型接 URLSession 的结果，避免在并发闭包里改捕获的 var（Swift 6 会报错）
    private final class Cell { var data: Data? }

    private func fetch(_ urlString: String, timeout: TimeInterval, noCache: Bool = false) -> Data? {
        if netFailStreak >= 6 { return nil }
        guard let url = URL(string: urlString) else { return nil }

        var req = URLRequest(url: url,
                             cachePolicy: noCache ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy,
                             timeoutInterval: timeout)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                     + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")

        let cell = Cell()
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 { cell.data = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 8)

        if let d = cell.data {
            netFailStreak = 0
            return d.count > MirrorStore.maxFileBytes ? nil : d
        }
        netFailStreak += 1
        return nil
    }

    // MARK: 分段换版：下载 与 生效 分离
    //
    // 游戏中不能直接 reload —— 那会把玩家正在跑的一局当场打断。
    // 所以运行中的轮询只「备料」：新资源和新首页都下到 overlay，但不动 index.html；
    // 真正生效留到两个安全时机：
    //   1. App 冷启动（syncIfNeeded(commit: true)）
    //   2. 玩家自己点了站点上的「Recargar」（走 applyAndReload）

    private var pendingBuildURL: URL { overlay.appendingPathComponent("_pending.txt") }
    private var pendingIndexURL: URL { overlay.appendingPathComponent("index.pending.html") }

    private func stagedBuild() -> String? {
        guard let d = try? Data(contentsOf: pendingBuildURL),
              let t = String(data: d, encoding: .utf8) else { return nil }
        let b = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? nil : b
    }

    private func stage(_ home: Data, build: String) {
        put("/index.pending.html", home)
        put("/_pending.txt", Data(build.utf8))
    }

    private func dropPending() {
        try? FileManager.default.removeItem(at: pendingIndexURL)
        try? FileManager.default.removeItem(at: pendingBuildURL)
    }

    /// 冷启动时把上一轮备好的那一版切成正式版。返回切过去的 build（没备好就 nil）。
    /// 先切再查线上：这样即使这次没网，也能进到已经下好的新版。
    @discardableResult
    private func applyStaged() -> String? {
        guard let build = stagedBuild() else { return nil }
        if build == currentBuild() {
            dropPending()          // 已经是这一版了，备料没用了
            return nil
        }
        guard let home = try? Data(contentsOf: pendingIndexURL), home.count > 800 else {
            dropPending()
            return nil
        }

        let before = recorded().build
        put("/index.html", home)
        dropPending()

        var hist = recorded().history
        if let old = before, old != build, !hist.contains(old) { hist.append(old) }
        hist.removeAll { $0 == build }
        setRecord(build, history: hist)
        cleanupOldBuilds(current: build, olds: hist)

        NSLog("PokeBonk: 已切到备好的 \(build)")
        return build
    }

    /// 纯本地检查：当前 index 及其引用的 chunk 是不是都能读到。不联网，很快。
    /// 用来发现「index 换了但资源没跟上」的残缺状态 —— 旧逻辑会把它永久锁死在「已是最新」。
    private func coreComplete() -> Bool {
        guard let d = data(for: "/index.html"),
              let html = String(data: d, encoding: .utf8) else { return false }
        var queue = Self.refsFrom(html)
        var seen = Set<String>()
        var round = 0
        while round < 3 && !queue.isEmpty {
            var next: [String] = []
            for rel in queue {
                if !seen.insert(rel).inserted { continue }
                guard let f = data(for: rel) else {
                    NSLog("PokeBonk: core 缺 \(rel)")
                    return false
                }
                if rel.hasSuffix(".js"), let t = String(data: f, encoding: .utf8) {
                    next.append(contentsOf: Self.refsFrom(t))
                }
            }
            queue = next
            round += 1
        }
        return true
    }

    // MARK: 换版

    /// 对齐版本。
    /// - commit = true：下完就切 index.html（冷启动、玩家主动刷新时用）
    /// - commit = false：只把资源和新首页备好，不切、不重载（游戏中定时检查用）
    /// 返回「真的切换生效了」的新 build，否则 nil。
    /// 必须在后台线程调用 —— 里面是同步网络 IO。
    func syncIfNeeded(commit: Bool = true, progress: ((String) -> Void)? = nil) -> String? {
        netFailStreak = 0

        if commit { _ = applyStaged() }
        let local = currentBuild()

        guard let vj = fetch("https://pokebonk.com/version.json", timeout: 10, noCache: true),
              let text = String(data: vj, encoding: .utf8),
              let remote = Self.jsonBuild(text) else { return nil }

        var rec = recorded()
        if rec.build == nil {
            setRecord(remote, history: rec.history)
            rec = recorded()
        }

        // 这一版已经备好了就别再备一遍（数据表是强制重下的，白跑流量）
        if !commit, stagedBuild() == remote {
            NSLog("PokeBonk: \(remote) 已备好，等下次启动生效")
            return nil
        }

        if local == remote {
            if progress == nil || coreComplete() {
                return nil
            }
            NSLog("PokeBonk: build 记的一致但核心文件不全，重新补齐")
        }

        progress?("发现新版本 \(remote)，正在更新…")

        guard let home = fetch("https://pokebonk.com/", timeout: 30, noCache: true),
              home.count > 800 else { return nil }

        var queue = Self.bootData + Self.refsFrom(String(data: home, encoding: .utf8) ?? "")
        // 数据表名字固定，overlay 里可能留着上一版 —— 换版时必须无条件重下。
        let force = Set(Self.bootData)
        var wanted = Set<String>()
        var budget = MirrorStore.maxSyncBytes
        let deadline = Date().addingTimeInterval(MirrorStore.maxSyncSeconds)
        var failed: [String] = []
        var got = 0
        // 只有「build 一致但文件残缺」这条自愈路径才顺着本地已有 chunk 找漏；
        // 换版路径不能这么干，否则会把上一版的 chunk 又拖回来。
        let healing = (local == remote)

        var round = 0
        while round < 4 && !queue.isEmpty {
            var next: [String] = []
            for rel in queue {
                if !wanted.insert(rel).inserted { continue }
                if !force.contains(rel) && existsInOverlay(rel) {
                    if healing, rel.hasSuffix(".js"),
                       let d = data(for: rel), let t = String(data: d, encoding: .utf8) {
                        next.append(contentsOf: Self.refsFrom(t))
                    }
                    continue
                }
                if Date() > deadline { failed.append(rel); continue }
                if budget <= 0 { failed.append(rel); continue }

                guard let d = fetch("https://pokebonk.com" + rel, timeout: 25) else {
                    failed.append(rel)
                    continue
                }
                put(rel, d)
                budget -= d.count
                got += 1
                if rel.hasSuffix(".js"), let t = String(data: d, encoding: .utf8) {
                    next.append(contentsOf: Self.refsFrom(t))
                }
            }
            queue = next
            round += 1
        }

        NSLog("PokeBonk: 下到 \(got) 个文件，未拿到 \(failed.count) 个")

        // 资源不齐就不切：半套资源配新首页，站点自带的恢复逻辑会不停重载，
        // 表现成「一直被提示有新版本、刷新也没用」。老实留在旧版反而没事。
        guard failed.isEmpty else {
            NSLog("PokeBonk: 资源不齐，本次不动 index -> \(failed)")
            progress?("更新未完成，稍后自动重试")
            return nil
        }

        if !commit {
            // 运行中：只备料，绝不碰正在跑的页面
            stage(home, build: remote)
            NSLog("PokeBonk: \(remote) 已备好，等下次启动生效")
            return nil
        }

        // 资源就位了，最后才切首页
        put("/index.html", home)

        rec = recorded()
        var hist = rec.history
        if let old = rec.build, old != remote, !hist.contains(old) { hist.append(old) }
        hist.removeAll { $0 == remote }
        setRecord(remote, history: hist)
        cleanupOldBuilds(current: remote, olds: hist)

        return remote
    }

    private func cleanupOldBuilds(current: String, olds: [String]) {
        guard !olds.isEmpty else { return }
        let dir = overlay.appendingPathComponent("assets", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                     includingPropertiesForKeys: nil) else { return }
        guard let rx = try? NSRegularExpression(pattern: "-(?<tag>[a-z0-9]{8})\\.(?:js|css|woff2)$",
                                               options: [.caseInsensitive]) else { return }

        for f in files {
            let name = f.lastPathComponent
            let ns = name as NSString
            guard let m = rx.firstMatch(in: name, options: [], range: NSRange(location: 0, length: ns.length)),
                  let r = Range(m.range(withName: "tag"), in: name) else { continue }
            let tag = String(name[r])
            if tag.lowercased() == current.lowercased() { continue }
            // 只删历史里确实记录过的 build，别按「像 8 位 hash」乱删（three-xxxx.js 会被误伤）
            if olds.contains(where: { $0.lowercased() == tag.lowercased() }) {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }
}

// MARK: - 界面

final class GameViewController: UIViewController, WKNavigationDelegate {

    private var webView: WKWebView!
    private let hint = UILabel()
    private var pollTimer: Timer?
    /// 本地服务的首页地址（重新加载时要用干净 URL，不能带 ?v=）
    private var homeURL: URL?

    deinit {
        pollTimer?.invalidate()
    }

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
        wv.navigationDelegate = self

        // 检查版本 / 更新资源时的一句话提示（新版本首页配旧资源会白屏重载，所以先对齐再进）
        hint.text = "正在检查版本…"
        hint.textColor = UIColor(white: 0.78, alpha: 1)
        hint.font = UIFont.systemFont(ofSize: 13)
        hint.numberOfLines = 0
        hint.textAlignment = .center
        hint.backgroundColor = UIColor(white: 0.06, alpha: 0.9)
        hint.layer.cornerRadius = 8
        hint.clipsToBounds = true
        hint.sizeToFit()
        hint.frame = CGRect(x: 16, y: 40,
                            width: view.bounds.width - 32, height: 34)
        hint.autoresizingMask = [.flexibleWidth]
        view.addSubview(hint)

        if let port = LocalServer.shared.start(),
           let url = URL(string: "http://127.0.0.1:\(port)/") {
            homeURL = url
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let updated = MirrorStore.shared.syncIfNeeded { text in
                    DispatchQueue.main.async { self?.hint.text = text }
                }
                DispatchQueue.main.async {
                    self?.hint.isHidden = true
                    wv.load(URLRequest(url: url))
                    if let u = updated {
                        NSLog("PokeBonk: 已更新到 \(u)")
                    }
                    self?.startPolling()
                }
            }
        } else {
            // 本地服务起不来就直连官网：没有加速，但至少能玩
            hint.isHidden = true
            wv.load(URLRequest(url: URL(string: "https://pokebonk.com/")!))
        }
    }

    // MARK: 版本轮询

    /// 运行中每 3 分钟问一次线上版本，但**只备料**：把新资源下到 overlay 就停手。
    ///
    /// 不能在这里 reload。站点自己的更新条是避开游戏中的（它判断 e.run），
    /// 我们无条件重载等于绕过它的保护，玩家会被当场踢出这一局。
    /// 何时真正换版交给两个安全时机：下次冷启动，或玩家自己点「Recargar」。
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            self?.pollOnce()
        }
    }

    private func pollOnce() {
        DispatchQueue.global(qos: .utility).async {
            _ = MirrorStore.shared.syncIfNeeded(commit: false)
        }
    }

    /// 玩家主动点了刷新（或站点的恢复跳转）：下载 → 立刻切换 → 用干净 URL 重载一次。
    /// 这里是「人已经决定要更新了」，所以可以打断。
    private func applyAndReload() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let updated = MirrorStore.shared.syncIfNeeded(commit: true)
            DispatchQueue.main.async {
                if let u = updated { NSLog("PokeBonk: 已更新到 \(u)") }
                guard let self = self else { return }
                if let home = self.homeURL {
                    self.webView.load(URLRequest(url: home))
                } else {
                    self.webView.reload()
                }
            }
        }
    }

    /// 站点自带的「刷新」按钮会跳 ?v=&lt;新build&gt;，自带的恢复逻辑会跳 ?pb-reload=。
    /// 我们按路径查本地、忽略查询串，放它过去只会再拿到同一份旧 index.html，
    /// 提示会原地复活 —— 拦下来做一次真正的更新。
    private static func isVersionBust(_ url: URL) -> Bool {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return false
        }
        return items.contains { $0.name == "v" || $0.name == "pb-reload" }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url,
           GameViewController.isVersionBust(url) {
            decisionHandler(.cancel)
            applyAndReload()
            return
        }
        decisionHandler(.allow)
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
