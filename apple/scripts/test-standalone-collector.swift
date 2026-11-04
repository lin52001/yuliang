// Compile with -D QUOTA_COLLECTOR_TESTING and QuotaWebCollector.swift.
// Arguments: <usage.html fixture> <bundle containing parser.js>
// Uses only an ephemeral WKWebView, loopback HTTP and in-memory records.
import AppKit
import Foundation
import WebKit
import QuotaCore

private struct VerificationFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private func verify(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw VerificationFailure(description: message) }
}

@MainActor
private func eventually(_ message: String, timeout: TimeInterval = 5,
                        _ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    } while Date() < deadline
    throw VerificationFailure(description: "等待超时：\(message)")
}

private struct FixtureStats: Decodable {
    let requests: Int
    let active: Int
    let maxActive: Int
    let requestTimes: [Double]
}

@MainActor
private final class LoopbackFixture {
    let process: Process
    let baseURL: URL
    var usageURL: URL { baseURL.appendingPathComponent("usage") }

    init(html: URL) throws {
        let javascript = #"""
        const http = require('node:http');
        const fs = require('node:fs');
        const template = fs.readFileSync(process.argv[1], 'utf8');
        const oauthTemplate = fs.readFileSync(process.argv[2], 'utf8');
        let state = { mode: 'valid', used: 35, delay: 0 };
        let requests = 0, active = 0, maxActive = 0;
        const requestTimes = [];
        const server = http.createServer((req, res) => {
          const url = new URL(req.url, 'http://127.0.0.1');
          res.setHeader('Cache-Control', 'no-store');
          if (url.pathname === '/control') {
            state = { mode: url.searchParams.get('mode') || 'valid', used: Number(url.searchParams.get('used') || 0), delay: Number(url.searchParams.get('delay') || 0) };
            res.end('ok'); return;
          }
          if (url.pathname === '/stats') {
            res.setHeader('Content-Type', 'application/json');
            res.end(JSON.stringify({ requests, active, maxActive, requestTimes })); return;
          }
          if (url.pathname === '/oauth/start' || url.pathname === '/oauth/popup') {
            res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
            res.end(oauthTemplate); return;
          }
          if (url.pathname === '/upgrade' || url.pathname.startsWith('/upgrade/') || url.pathname === '/settings') {
            res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
            res.end('<main><h1>Synthetic plan or settings page</h1><p>No quota fields, account or purchase.</p></main>'); return;
          }
          if (url.pathname !== '/usage') { res.writeHead(404); res.end(); return; }
          requests++; active++; maxActive = Math.max(maxActive, active); requestTimes.push(Date.now());
          let settled = false;
          let timer;
          const finish = () => { if (!settled) { settled = true; active--; } if (timer) clearTimeout(timer); };
          res.on('finish', finish); res.on('close', finish);
          const sample = { ...state };
          const deliver = () => {
            if (res.destroyed) return;
            if (sample.mode === 'spa-upgrade') {
              res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
              res.end('<main>Loading synthetic account state</main><script>setTimeout(() => history.replaceState(null, "", "/upgrade?from=wren"), 150)</script>'); return;
            }
            if (['upgrade', 'upgrade-nested', 'nonusage'].includes(sample.mode)) {
              const destination = sample.mode === 'upgrade' ? '/upgrade?from=wren'
                : sample.mode === 'upgrade-nested' ? '/upgrade/plans?from=wren' : '/settings';
              res.writeHead(302, { Location: destination }); res.end(); return;
            }
            if (sample.mode === 'http429') {
              res.writeHead(429, { 'Retry-After': '45', 'Content-Type': 'text/html' }); res.end('<main>Rate limited synthetic fixture</main>'); return;
            }
            let mode = sample.mode === 'slow' ? 'valid' : sample.mode;
            const status = sample.mode === 'http401' ? 401 : sample.mode === 'http403' ? 403 : 200;
            if (status !== 200) mode = 'login';
            const body = template.replace('const query = new URLSearchParams(location.search);',
              'const query = new URLSearchParams(location.search); query.set("mode", ' + JSON.stringify(mode) + '); query.set("used", ' + JSON.stringify(String(sample.used)) + ');');
            res.writeHead(status, { 'Content-Type': 'text/html; charset=utf-8' }); res.end(body);
          };
          if (sample.delay > 0) timer = setTimeout(deliver, sample.delay); else deliver();
        });
        server.listen(0, '127.0.0.1', () => process.stdout.write(String(server.address().port) + '\n'));
        process.on('SIGTERM', () => { server.closeAllConnections(); server.close(() => process.exit(0)); });
        """#
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", javascript, html.path,
                             html.deletingLastPathComponent().appendingPathComponent("oauth-login.html").path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        var line = Data()
        while true {
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty || byte == Data([10]) { break }
            line.append(byte)
        }
        guard let value = String(data: line, encoding: .utf8), let port = Int(value),
              let url = URL(string: "http://127.0.0.1:\(port)") else {
            process.terminate()
            throw VerificationFailure(description: "本机合成HTTP测试服务未能启动")
        }
        baseURL = url
    }

    func control(_ mode: String, used: Double = 35, delay: Int = 0) async throws {
        var components = URLComponents(url: baseURL.appendingPathComponent("control"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "mode", value: mode), .init(name: "used", value: String(used)), .init(name: "delay", value: String(delay))]
        let (_, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw VerificationFailure(description: "合成服务模式切换失败")
        }
    }

    func stats() async throws -> FixtureStats {
        let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("stats"))
        return try JSONDecoder().decode(FixtureStats.self, from: data)
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }
}

@main
struct StandaloneCollectorVerification {
    @MainActor static func main() {
        guard (3...4).contains(CommandLine.arguments.count),
              let resources = Bundle(path: CommandLine.arguments[2]) else {
            fputs("参数：<usage.html fixture> <含 parser.js 的资源 Bundle>\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let html = URL(fileURLWithPath: CommandLine.arguments[1])
                if CommandLine.arguments.last == "--upgrade-only" {
                    try await runUpgrade(html: html, resources: resources)
                    print("真实WKWebView套餐页状态隔离验证通过：3组。仅合成重定向、恢复与子窗口，无真实账户。")
                } else {
                    try await runOAuth(html: html, resources: resources)
                    if CommandLine.arguments.last == "--oauth-only" {
                        print("真实WKWebView OAuth弹窗隔离验证通过。仅合成opener/postMessage和手动关闭，无真实账户。")
                    } else {
                        try await runUpgrade(html: html, resources: resources)
                        try await run(html: html, resources: resources)
                        print("真实WKWebView采集隔离验证通过：15组。全部使用合成HTTP响应，无真实账户或本机额度写入。")
                    }
                }
                exit(0)
            } catch {
                fputs("采集隔离验证失败：\(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor static func runUpgrade(html: URL, resources: Bundle) async throws {
        let server = try LoopbackFixture(html: html)
        defer { server.stop() }
        var records: [SnapshotEnvelope] = []
        let collector = QuotaWebCollector(service: .claude, fixtureURL: server.usageURL,
                                          resourceBundle: resources) { records.append(try $0.validated()) }
        defer { collector.pause(); collector.closeLoginWindows() }
        collector.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 640)
        let window = NSWindow(contentRect: collector.webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = collector.webView
        defer { window.close() }

        // Initial redirects are not collection attempts and cannot imply a
        // missing login, a free plan, a zero quota, or a successful observation.
        try await server.control("upgrade")
        collector.connect()
        try await eventually("首次连接转到套餐页") {
            collector.webView.url?.path == "/upgrade" && !collector.webView.isLoading
                && collector.lastError?.contains("套餐") == true
        }
        try verify(!collector.hasUsagePage && !collector.needsLogin && !collector.isRunning && !collector.isBusy,
                   "套餐页应明确未提供额度，不得误称仍在导航或需要再次登录")
        try verify(collector.status.contains("未提供可读取额度") && collector.status.contains("账号")
                   && !collector.status.contains("正在前往") && !collector.status.contains("免费"),
                   "套餐页只应说明可验证的官网状态，不猜测免费套餐或继续显示导航中")
        try verify(records.isEmpty && collector.lastAttemptAt == nil && collector.lastSuccessAt == nil
                   && collector.nextRefreshAt == nil, "首次套餐页不能写入零额度、成功时间或自动重试")
        try await server.control("nonusage")
        collector.openUsagePage()
        try await eventually("普通非额度初始导航结束") {
            collector.webView.url?.path == "/settings" && !collector.webView.isLoading
                && collector.status.contains("未打开额度页")
        }
        try verify(!collector.hasUsagePage && !collector.status.contains("正在前往"),
                   "普通初始非额度页导航结束后也必须结束等待提示")
        collector.webView.load(URLRequest(url: server.baseURL.appendingPathComponent("upgrade/plans")))
        try await eventually("套餐子路径也被明确识别") {
            collector.webView.url?.path == "/upgrade/plans" && !collector.webView.isLoading
                && collector.lastError?.contains("套餐") == true && !collector.needsLogin
        }
        try await server.control("spa-upgrade")
        collector.openUsagePage()
        try await eventually("SPA在导航结束后转套餐页") {
            collector.webView.url?.path == "/upgrade" && !collector.webView.isLoading
                && !collector.hasUsagePage && !collector.needsLogin && collector.lastError?.contains("套餐") == true
        }
        try verify(records.isEmpty && collector.lastAttemptAt == nil && collector.lastSuccessAt == nil,
                   "SPA套餐路由也不能被当作登录失败或成功额度")
        print("✓ 初始upgrade、子路径与延后SPA路由明确提示未提供额度，普通非额度导航也不再无限等待")

        // A redirect during an active refresh invalidates every scheduled or
        // in-flight write. Repeated starts cannot bypass the unavailable page.
        try await server.control("valid", used: 41)
        collector.openUsagePage()
        try await eventually("建立有效额度基线") {
            collector.webView.url == server.usageURL && !collector.webView.isLoading
                && collector.hasUsagePage && !collector.needsLogin && collector.lastError == nil
        }
        collector.refreshNow()
        try await eventually("保存套餐重定向前的有效额度") { records.count == 1 }
        let baseline = records
        let success = collector.lastSuccessAt
        try await server.control("upgrade-nested")
        collector.start()
        try await eventually("自动读取跳到套餐页后停止") {
            collector.webView.url?.path == "/upgrade/plans" && !collector.webView.isLoading
                && !collector.isRunning && !collector.isBusy && collector.lastError?.contains("套餐") == true
        }
        let attemptedAt = collector.lastAttemptAt
        let requests = try await server.stats().requests
        for _ in 0..<6 { collector.start(); collector.refreshNow() }
        try await Task.sleep(for: .milliseconds(400))
        let afterRepeatedStarts = try await server.stats().requests
        try verify(records == baseline && collector.lastSuccessAt == success,
                   "读取中跳套餐页必须保留上次额度和成功时间，不得写零或刷新旧值")
        try verify(!collector.hasUsagePage && !collector.needsLogin && !collector.isRunning && !collector.isBusy
                   && collector.nextRefreshAt == nil && afterRepeatedStarts == requests
                   && collector.lastAttemptAt == attemptedAt,
                   "套餐页必须停止整个读取循环，连续点击不能触发无穷刷新")
        print("✓ 活跃采集转套餐页立即停止，旧额度/成功时间保留，连续开始和刷新不发请求")

        // Explicitly reopening usage can recover after the provider changes.
        // A child plan page remains an independent OAuth browsing context.
        try await server.control("valid", used: 44)
        collector.openUsagePage()
        try await eventually("从套餐页明确前往额度页后恢复就绪") {
            collector.webView.url == server.usageURL && !collector.webView.isLoading
                && collector.hasUsagePage && !collector.needsLogin && collector.lastError == nil
        }
        try verify(records == baseline && collector.lastSuccessAt == success && !collector.isRunning,
                   "恢复额度页只确认就绪，不应隐式采样或启用自动刷新")
        _ = try await collector.webView.evaluateJavaScript("window.open('/oauth/popup', 'fixture-upgrade-child'); true")
        try await eventually("打开独立合成登录子窗口") {
            collector.loginWindowCount == 1 && collector.fixtureLoginWebViews.first?.isLoading == false
        }
        guard let child = collector.fixtureLoginWebViews.first else {
            throw VerificationFailure(description: "套餐隔离检查未创建真实child WKWebView")
        }
        let parentStatus = collector.status
        let parentError = collector.lastError
        let parentLogin = collector.needsLogin
        child.load(URLRequest(url: server.baseURL.appendingPathComponent("upgrade/plans")))
        try await eventually("仅子窗口进入套餐页") { child.url?.path == "/upgrade/plans" && !child.isLoading }
        try verify(collector.hasUsagePage && collector.status == parentStatus && collector.lastError == parentError
                   && collector.needsLogin == parentLogin && records == baseline && collector.lastSuccessAt == success,
                   "子窗口套餐导航不能修改主额度页状态、采样或成功时间")
        collector.fixtureLoginWindows.first?.close()
        collector.refreshNow()
        try await eventually("恢复后显式读取新额度") { records.count == baseline.count + 1 }
        try verify(records.last?.windows.first(where: { $0.id == "session" })?.usedPercent == 44
                   && collector.lastSuccessAt != success && collector.lastError == nil,
                   "用户明确恢复后应能读取新额度并清除套餐页提示")
        print("✓ 用户前往额度页可恢复，子窗口upgrade不影响主状态，显式刷新才记录新额度")
    }

    @MainActor static func runOAuth(html: URL, resources: Bundle) async throws {
        let server = try LoopbackFixture(html: html)
        defer { server.stop() }
        try await server.control("valid", used: 57)
        var records: [SnapshotEnvelope] = []
        let collector = QuotaWebCollector(service: .claude, fixtureURL: server.usageURL,
                                          resourceBundle: resources) { records.append(try $0.validated()) }
        defer { collector.pause(); collector.closeLoginWindows() }
        collector.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 640)
        let window = NSWindow(contentRect: collector.webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = collector.webView
        defer { window.close() }
        let loginURL = server.baseURL.appendingPathComponent("oauth/start")
        let popupURL = server.baseURL.appendingPathComponent("oauth/popup")

        collector.webView.load(URLRequest(url: loginURL))
        try await eventually("合成OAuth父页面") { collector.webView.url == loginURL && !collector.webView.isLoading }
        _ = try await collector.webView.evaluateJavaScript("document.querySelector('#fixture-open').click(); true")
        try await eventually("独立child WK登录窗口") {
            collector.loginWindowCount == 1 && collector.fixtureLoginWebViews.first?.url == popupURL
                && collector.fixtureLoginWebViews.first?.isLoading == false
        }
        guard let child = collector.fixtureLoginWebViews.first else {
            throw VerificationFailure(description: "OAuth没有创建真正的child WKWebView")
        }
        let hasOpener = try await child.evaluateJavaScript("Boolean(window.opener && window.opener !== window)") as? Bool
        try verify(hasOpener == true && collector.webView.url == loginURL,
                   "登录弹窗必须保留window.opener，不能把子页面载入父WK")
        try verify(!child.configuration.websiteDataStore.isPersistent && !collector.hasUsagePage,
                   "合成登录使用临时会话，且不能把父登录页面当作额度页")
        collector.start()
        try verify(!collector.isRunning && !collector.isBusy && collector.lastAttemptAt == nil && records.isEmpty,
                   "独立登录窗口存在时不能启动额度读取")

        // Even a valid usage document in the child must not update the main
        // browser's readiness or enter its sampling pipeline.
        child.load(URLRequest(url: server.usageURL))
        try await eventually("子窗口自己的合成额度页") { child.url == server.usageURL && !child.isLoading }
        try verify(!collector.hasUsagePage && records.isEmpty && collector.lastAttemptAt == nil,
                   "子WK导航完成不得改变主额度就绪状态、生成读取尝试或采样")
        child.load(URLRequest(url: popupURL))
        try await eventually("回到合成OAuth子页面") { child.url == popupURL && !child.isLoading }
        _ = try await child.evaluateJavaScript("document.querySelector('#fixture-complete').click(); true")
        try await eventually("opener收到postMessage并返回usage，子窗口自行关闭") {
            collector.loginWindowCount == 0 && collector.fixtureLoginWindows.isEmpty
                && collector.webView.url == server.usageURL && !collector.webView.isLoading
                && collector.hasUsagePage && !collector.needsLogin
        }
        try verify(records.isEmpty && collector.lastSuccessAt == nil && collector.lastError == nil,
                   "OAuth返回只确认就绪，不能自行采集、写入或伪造成功时间")
        collector.refreshNow()
        try await eventually("登录回传后的显式额度读取") { records.count == 1 }
        try verify(records[0].windows.first(where: { $0.id == "session" })?.usedPercent == 57,
                   "登录后必须仅读取父额度页的真实合成字段")
        collector.pause()

        collector.webView.load(URLRequest(url: loginURL))
        try await eventually("再次进入合成OAuth父页面") { collector.webView.url == loginURL && !collector.webView.isLoading }
        _ = try await collector.webView.evaluateJavaScript("document.querySelector('#fixture-open').click(); true")
        try await eventually("再次打开独立登录窗口") { collector.loginWindowCount == 1 }
        collector.fixtureLoginWindows.first?.close()
        try verify(collector.loginWindowCount == 0 && collector.fixtureLoginWindows.isEmpty,
                   "原生手动关闭必须清理child窗口、视图与代理")
        collector.openUsagePage()
        try await eventually("明确前往额度页后恢复开始入口") {
            collector.webView.url == server.usageURL && !collector.webView.isLoading && collector.hasUsagePage && !collector.needsLogin
        }
        try verify(records.count == 1 && !collector.isRunning && !collector.isBusy,
                   "前往额度页不能隐式恢复自动读取或导入其他浏览器会话")
        print("✓ 真正OAuth child保留opener/postMessage，父页回usage；子页隔离采样，自动/手动关闭清理")
    }

    @MainActor static func run(html: URL, resources: Bundle) async throws {
        let server = try LoopbackFixture(html: html)
        defer { server.stop() }
        var records: [SnapshotEnvelope] = []
        let collector = QuotaWebCollector(service: .claude, fixtureURL: server.usageURL,
                                          resourceBundle: resources) { snapshot in
            records.append(try snapshot.validated())
        }
        defer { collector.pause() }
        collector.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 640)
        let window = NSWindow(contentRect: collector.webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = collector.webView
        defer { window.close() }

        collector.connect()
        try await eventually("初次连接合成页面") { collector.webView.url != nil && !collector.webView.isLoading }
        try verify(collector.hasUsagePage, "额度页导航完成后应允许用户显式开始")
        try verify(records.isEmpty && !collector.isRunning, "连接动作不得自行采集或开始循环")
        try verify(collector.lastError == nil, "首次连接属于普通状态，不应显示读取错误")
        collector.start()
        try await eventually("第一轮真实刷新") { records.count == 1 }
        let firstDate = records[0].observedAt
        let firstNonce = try await collector.webView.evaluateJavaScript("document.documentElement.dataset.fixtureDocumentNonce") as? String
        let firstStats = try await server.stats()
        for _ in 0..<20 { collector.start() }
        try await Task.sleep(for: .milliseconds(250))
        let afterRepeatedStarts = try await server.stats()
        try verify(afterRepeatedStarts.requests == firstStats.requests, "重复开始不得跳过60秒截止时间或重入")
        try await eventually("第二轮60秒刷新", timeout: 65) { records.count == 2 }
        let secondNonce = try await collector.webView.evaluateJavaScript("document.documentElement.dataset.fixtureDocumentNonce") as? String
        let initialStats = try await server.stats()
        try verify(initialStats.requests >= 3, "连接与两轮采集应产生不同HTTP请求")
        let intervals = zip(initialStats.requestTimes.dropFirst(2), initialStats.requestTimes.dropFirst()).map { ($0.0 - $0.1) / 1000 }
        try verify(intervals.contains { $0 >= 59.5 && $0 <= 64 }, "自动刷新目标应约60秒一次")
        try verify(firstNonce != nil && secondNonce != nil && firstNonce != secondNonce, "两轮必须真的重新加载文档，不能只重读旧DOM")
        try verify(records[1].observedAt > firstDate, "新成功响应应更新成功读取时间")
        try verify(collector.lastError == nil, "成功读取应清空以前的读取错误")
        print("✓ 连接不自动循环，连续开始不重入，两轮真实HTTP reload约60秒且文档nonce变化")

        window.close()
        let beforeCloseCount = records.count
        try await eventually("关闭连接窗口后的后台读取", timeout: 65) { records.count == beforeCloseCount + 1 }
        try verify(!window.isVisible, "合成连接窗口应处于关闭状态")
        print("✓ 关闭连接窗口后仍可完成真实页面刷新")

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        let sleepingRequests = try await server.stats().requests
        let sleepingCount = records.count
        try await Task.sleep(for: .seconds(6))
        let afterSleepRequests = try await server.stats().requests
        try verify(afterSleepRequests == sleepingRequests && records.count == sleepingCount, "休眠通知后不得继续读取或写入")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await eventually("唤醒后单次恢复") { records.count == sleepingCount + 1 }
        try await Task.sleep(for: .milliseconds(250))
        let afterWakeRequests = try await server.stats().requests
        try verify(afterWakeRequests == sleepingRequests + 1, "重复唤醒通知不能补发积压请求")
        collector.pause()
        try verify(collector.lastError == nil, "主动暂停属于普通状态")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(250))
        let pausedWakeRequests = try await server.stats().requests
        try verify(pausedWakeRequests == afterWakeRequests, "已暂停的采集器不能被唤醒通知自行启动")
        print("✓ 模拟休眠停止读取，重复唤醒只恢复一次，暂停不被唤醒撤销")

        for used in [0.0, 100.0] {
            try await server.control("valid", used: used)
            let count = records.count
            collector.refreshNow()
            try await eventually("边界已用\(used)") { records.count == count + 1 }
            try verify(records.last?.windows.first(where: { $0.id == "session" })?.usedPercent == used, "0/100边界必须真实保留")
        }
        try await server.control("unknown")
        let knownCount = records.count
        collector.refreshNow()
        try await eventually("未知额度") { records.count == knownCount + 1 }
        try verify(records.last?.windows.allSatisfy { $0.usedPercent == nil } == true, "未知额度不能生成0%")
        print("✓ 0%、100%和unknown分别保存，不混淆")

        try await server.control("remaining", used: 26)
        let remainingCount = records.count
        collector.refreshNow()
        try await eventually("读取明确的剩余百分比") { records.count == remainingCount + 1 }
        try verify(records.last?.windows.first(where: { $0.id == "session" })?.usedPercent == 26,
                   "74% remaining应记录为已用26%，不能把剩余字段当成已用")
        print("✓ 官网明确的remaining字段正确转换为used，三种额度窗口互不混淆")

        let stableCount = records.count
        let stableDate = collector.lastSuccessAt
        try await server.control("empty")
        collector.refreshNow()
        try await eventually("空页有界重试结束", timeout: 12) { !collector.isBusy }
        try verify(records.count == stableCount && collector.lastSuccessAt == stableDate, "空页不得freshen上次记录")
        try verify(collector.lastError != nil, "未能验证字段时应向小组件暴露读取错误")
        try verify((collector.lastAttemptAt ?? .distantPast) > (stableDate ?? .distantFuture), "尝试时间和成功时间必须区分")
        print("✓ 空页失败保留数据和成功时间，尝试时间独立")

        for mode in ["login", "challenge", "http401", "http403"] {
            try await server.control(mode)
            collector.refreshNow()
            try await eventually("登录/验证暂停：\(mode)") { !collector.isBusy && collector.needsLogin }
            try await Task.sleep(for: .milliseconds(200))
            try verify(!collector.isRunning && collector.needsLogin, "登录或验证状态不得被didFinish抹去")
            try verify(collector.lastError != nil, "登录或验证拦截必须有可展示的错误状态")
            try verify(records.count == stableCount && collector.lastSuccessAt == stableDate, "登录/验证不得更新时间")
        }
        print("✓ 登录、验证码、HTTP401/403自动暂停且不改成功时间")

        try await server.control("slow", delay: 1000)
        let requestsBeforePause = try await server.stats().requests
        collector.refreshNow()
        for _ in 0..<20 { collector.refreshNow() }
        try await eventually("迟到测试请求发出") { try await server.stats().requests == requestsBeforePause + 1 }
        collector.pause()
        try verify(collector.lastError == nil, "暂停应清除读取错误，保留成功记录")
        try await Task.sleep(for: .milliseconds(1400))
        try verify(records.count == stableCount && collector.lastSuccessAt == stableDate, "暂停后的迟到响应不得写入")
        print("✓ 连续手动刷新不重入，暂停隔离迟到响应")

        try await server.control("slow", delay: 20_000)
        let requestsBeforeTimeout = try await server.stats().requests
        collector.refreshNow()
        for _ in 0..<20 { collector.refreshNow() }
        try await eventually("15秒超时", timeout: 18) { !collector.isBusy }
        try verify(records.count == stableCount && collector.lastSuccessAt == stableDate, "超时不得freshen上次记录")
        let timeoutStats = try await server.stats()
        try verify(timeoutStats.requests == requestsBeforeTimeout + 1 && timeoutStats.maxActive <= 1, "超时期间不能重入并发请求")
        print("✓ 超时保留旧值，等待期间无重入")

        try await server.control("http429")
        collector.start()
        try await eventually("429退避") { !collector.isBusy && collector.nextRefreshAt != nil }
        try verify((collector.nextRefreshAt?.timeIntervalSinceNow ?? 0) > 30, "429应尊重Retry-After而非立即重试")
        let limitedRequests = try await server.stats().requests
        collector.refreshNow()
        try await Task.sleep(for: .seconds(6))
        let afterBackoffRequests = try await server.stats().requests
        try verify(afterBackoffRequests == limitedRequests, "429退避期间不得重发请求")
        try verify(records.count == stableCount && collector.lastSuccessAt == stableDate, "429不得更新时间")
        collector.pause()
        print("✓ HTTP429尊重退避，手动刷新也不能绕过")

        let noSecretText = String(data: try JSONEncoder().encode(records), encoding: .utf8) ?? ""
        try verify(!noSecretText.contains("TEST_CHAT_SENTINEL") && !noSecretText.contains("fixtureDocumentNonce"), "记录只能含白名单额度字段")
        try verify(collector.isFixture && collector.interval == 60, "测试必须是隔离fixture且保留真实60秒周期")
        print("✓ 白名单摘要与隔离fixture标记正确")
    }
}
