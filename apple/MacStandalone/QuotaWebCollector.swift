import Foundation
import Combine
import AppKit
import WebKit
import QuotaCore

/// A local, opt-in browser for the quota page. It never reads cookies,
/// passwords, chat content, private application state or internal APIs.
/// Each attempt starts a real page navigation; re-reading an old DOM is not a refresh.
@MainActor
final class QuotaWebCollector: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let service: QuotaProvider
    let webView: WKWebView
    /// A start-to-start target, not a promise that the provider publishes new
    /// quota every minute. Transient errors back off rather than overlap loads.
    let interval: TimeInterval = 60
    let isFixture: Bool
    var onSnapshot: ((SnapshotEnvelope) throws -> Void)?

    @Published private(set) var status = "连接官网后开始自动读取"
    @Published private(set) var lastAttemptAt: Date?
    @Published private(set) var lastSuccessAt: Date?
    @Published private(set) var nextRefreshAt: Date?
    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var needsLogin = false
    @Published private(set) var isSuspended = false
    @Published private(set) var hasUsagePage = false
    @Published private(set) var lastError: String?
    @Published private(set) var loginWindowCount = 0

    private let pageURL: URL
    private let fixtureURL: URL?
    private let parserSource: String?
    private var activeNavigation: WKNavigation?
    private var nextTask: Task<Void, Never>?
    private var parseTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var cycle: UInt64 = 0
    private var consecutiveFailures = 0
    private var throttleUntil: Date?
    private var resumeAfterSleep = false
    private var loginWindows: [ObjectIdentifier: NSWindow] = [:]

    convenience init(service: QuotaProvider = .claude, resourceBundle: Bundle = .main) {
        self.init(service: service, resourceBundle: resourceBundle, fixtureURL: nil)
    }

    #if QUOTA_COLLECTOR_TESTING
    /// Test-only initializer. Its session is ephemeral and must use an isolated test store.
    /// The shipping app is built without QUOTA_COLLECTOR_TESTING and has no fixture entry point.
    convenience init(service: QuotaProvider = .claude, fixtureURL: URL,
                     resourceBundle: Bundle = .main,
                     onSnapshot: ((SnapshotEnvelope) throws -> Void)? = nil) {
        precondition(fixtureURL.isFileURL || (["127.0.0.1", "localhost", "::1"].contains(fixtureURL.host ?? "") && fixtureURL.scheme == "http"))
        self.init(service: service, resourceBundle: resourceBundle, fixtureURL: fixtureURL)
        self.onSnapshot = onSnapshot
    }
    #endif

    private init(service: QuotaProvider, resourceBundle: Bundle, fixtureURL: URL?) {
        self.service = service
        self.fixtureURL = fixtureURL
        isFixture = fixtureURL != nil
        pageURL = URL(string: service == .claude ? "https://claude.ai/settings/usage" : "https://chatgpt.com")!
        parserSource = resourceBundle.url(forResource: "parser", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let configuration = WKWebViewConfiguration()
        #if QUOTA_SHELL_TESTING
        configuration.websiteDataStore = .nonPersistent()
        #else
        configuration.websiteDataStore = fixtureURL == nil ? .default() : .nonPersistent()
        #endif
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep(_:)),
                                                        name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake(_:)),
                                                        name: NSWorkspace.didWakeNotification, object: nil)
        if service == .chatgpt {
            status = "ChatGPT 自动额度暂未接入，不能推算百分比"
        }
    }

    /// Open the login/connection browser once. Never loops reloads while the user signs in.
    func connect() {
        stopWork()
        closeLoginWindows()
        resumeAfterSleep = false
        isRunning = false
        lastError = nil
        guard service == .claude else {
            status = "ChatGPT 自动额度暂未接入，不能推算百分比"
            return
        }
        status = "正在前往额度页；如需登录，请在官网完成后继续"
        loadPage()
    }

    /// Reuse this browser's own session. This neither imports an external
    /// browser session nor assumes that visiting a login page completed login.
    func openUsagePage() { connect() }

    func closeLoginWindows() {
        for window in Array(loginWindows.values) { window.close() }
    }

    #if QUOTA_COLLECTOR_TESTING
    var fixtureLoginWindows: [NSWindow] { Array(loginWindows.values) }
    var fixtureLoginWebViews: [WKWebView] { loginWindows.values.compactMap { $0.contentView as? WKWebView } }
    #endif

    func start() {
        // A second press must not skip the existing one-minute deadline.
        guard !isRunning else { return }
        guard canStart() else { return }
        isRunning = true
        needsLogin = false
        if isSuspended {
            resumeAfterSleep = true
            status = "电脑休眠中，唤醒后继续读取"
            return
        }
        if let throttleUntil, throttleUntil > Date() {
            lastError = "官网限流，请等待退避结束"
            schedule(after: throttleUntil.timeIntervalSinceNow,
                     message: "官网要求等待，退避结束后继续读取")
        } else {
            beginAttempt()
        }
    }

    func pause() {
        stopWork()
        resumeAfterSleep = false
        isRunning = false
        lastError = nil
        status = "已暂停，保留上次成功记录"
    }

    /// A manual refresh does one real navigation without enabling automatic collection.
    func refreshNow() {
        guard !isBusy else { return }
        guard !isSuspended else { status = "电脑休眠中，暂不发起读取"; return }
        guard canStart() else { return }
        if let throttleUntil, throttleUntil > Date() {
            status = "官网正在限流，请等待退避结束"
            lastError = status
            return
        }
        beginAttempt()
    }

    private func canStart() -> Bool {
        guard service == .claude else {
            status = "ChatGPT 自动额度暂未接入，不能推算百分比"
            lastError = status
            return false
        }
        guard parserSource != nil else {
            status = "缺少额度解析资源，请重新安装应用"
            lastError = status
            return false
        }
        guard onSnapshot != nil else {
            status = "尚未连接本机额度存储"
            lastError = status
            return false
        }
        guard loginWindowCount == 0 else {
            needsLogin = true
            status = "请先完成独立官网窗口中的登录，再前往额度页"
            return false
        }
        if let url = webView.url, isUpgradeURL(url) {
            quotaUnavailable()
            return false
        }
        guard let url = webView.url, isAllowedQuotaURL(url) else {
            needsLogin = true
            status = "请先完成官网登录，并打开额度页"
            lastError = status
            return false
        }
        return true
    }

    private func beginAttempt() {
        guard !isBusy, !isSuspended else { return }
        nextTask?.cancel()
        nextTask = nil
        nextRefreshAt = nil
        cycle &+= 1
        let expectedCycle = cycle
        isBusy = true
        needsLogin = false
        lastAttemptAt = Date()
        status = isFixture ? "正在刷新合成测试页面" : "正在刷新官网额度页"
        loadPage()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.cycle == expectedCycle, self.isBusy else { return }
            self.failAttempt("本次读取超时，保留上次记录")
        }
    }

    private func loadPage() {
        hasUsagePage = false
        let target = fixtureURL ?? pageURL
        if target.isFileURL {
            activeNavigation = webView.loadFileURL(target, allowingReadAccessTo: target.deletingLastPathComponent())
        } else {
            var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            activeNavigation = webView.load(request)
        }
    }

    private func isAllowedQuotaURL(_ url: URL) -> Bool {
        if let fixtureURL {
            return url.scheme == fixtureURL.scheme && url.host == fixtureURL.host
                && url.port == fixtureURL.port && url.path == fixtureURL.path
        }
        return url.scheme == "https" && url.host == "claude.ai"
            && (url.path == "/settings/usage" || url.path == "/settings/usage/")
    }

    private func isUpgradeURL(_ url: URL) -> Bool {
        guard service == .claude else { return false }
        let upgradePath: String
        if let fixtureURL {
            guard url.scheme == fixtureURL.scheme, url.host == fixtureURL.host,
                  url.port == fixtureURL.port else { return false }
            upgradePath = fixtureURL.deletingLastPathComponent().appendingPathComponent("upgrade").path
        } else {
            guard url.scheme == "https", url.host == "claude.ai" else { return false }
            upgradePath = "/upgrade"
        }
        return url.path == upgradePath || url.path.hasPrefix(upgradePath + "/")
    }

    private func stopWork(stopLoading: Bool = true) {
        cycle &+= 1
        nextTask?.cancel(); nextTask = nil
        parseTask?.cancel(); parseTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        activeNavigation = nil
        isBusy = false
        nextRefreshAt = nil
        if stopLoading { webView.stopLoading() }
    }

    private func needLogin(_ message: String, stopLoading: Bool = false) {
        stopWork(stopLoading: stopLoading)
        resumeAfterSleep = false
        isRunning = false
        needsLogin = true
        status = message
        lastError = message
    }

    /// A plan page is not a verified quota or a failed login. Keep the provider's
    /// page visible, stop attempts and retain every successful observation.
    private func quotaUnavailable() {
        stopWork(stopLoading: false)
        resumeAfterSleep = false
        isRunning = false
        hasUsagePage = false
        needsLogin = false
        status = "官网已转到套餐页，未提供可读取额度。请核对登录账号与套餐"
        lastError = status
    }

    @objc private func willSleep(_ notification: Notification) {
        resumeAfterSleep = isRunning
        isSuspended = true
        // Invalidate the generation so navigation, DOM and timeout callbacks
        // cannot become queued writes or multiple refreshes after wake.
        stopWork()
        if isRunning { status = "电脑休眠中，唤醒后继续读取" }
    }

    @objc private func didWake(_ notification: Notification) {
        guard isSuspended else { return }
        isSuspended = false
        let shouldResume = resumeAfterSleep && isRunning
        resumeAfterSleep = false
        guard shouldResume else { return }
        guard canStart() else { isRunning = false; return }
        if let throttleUntil, throttleUntil > Date() {
            schedule(after: throttleUntil.timeIntervalSinceNow, message: "官网要求等待，退避结束后继续读取")
        } else {
            // Exactly one immediate refresh, then the normal start-to-start cadence.
            beginAttempt()
        }
    }

    private func finishSuccess(_ snapshot: SnapshotEnvelope) {
        do {
            guard let onSnapshot else { throw QuotaError.invalid("尚未连接本机额度存储。") }
            try onSnapshot(snapshot)
            lastSuccessAt = snapshot.observedAt
            lastError = nil
            consecutiveFailures = 0
            throttleUntil = nil
            finishAttempt()
            if isRunning {
                let elapsed = Date().timeIntervalSince(lastAttemptAt ?? Date())
                schedule(after: max(0.2, interval - elapsed), message: "已读取 · 目标每 60 秒刷新")
            } else {
                status = "已完成一次读取"
            }
        } catch {
            failAttempt("本机保存失败，保留上次成功记录")
        }
    }

    private func finishAttempt() {
        parseTask?.cancel(); parseTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        activeNavigation = nil
        isBusy = false
    }

    private func failAttempt(_ message: String, retryAfter: TimeInterval? = nil) {
        lastError = message
        finishAttempt()
        webView.stopLoading()
        consecutiveFailures = min(7, consecutiveFailures + 1)
        let delay = retryAfter ?? min(300, interval * pow(2, Double(consecutiveFailures - 1)))
        if retryAfter != nil { throttleUntil = Date().addingTimeInterval(delay) }
        if isRunning {
            schedule(after: delay, message: "\(message) · \(Int(ceil(delay))) 秒后重试")
        } else {
            nextRefreshAt = nil
            status = message
        }
    }

    private func schedule(after delay: TimeInterval, message: String) {
        nextTask?.cancel()
        let safeDelay = max(0.2, delay)
        let expectedCycle = cycle
        nextRefreshAt = Date().addingTimeInterval(safeDelay)
        status = message
        nextTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(safeDelay))
            guard !Task.isCancelled, let self, self.isRunning, self.cycle == expectedCycle else { return }
            self.beginAttempt()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        guard let url = webView.url else { return }
        hasUsagePage = isAllowedQuotaURL(url)
        guard isAllowedQuotaURL(url) else {
            if isUpgradeURL(url) { quotaUnavailable() }
            else { needLogin("官网当前未打开额度页，请完成登录或验证后再前往额度页") }
            return
        }
        guard isBusy, navigation === activeNavigation else {
            guard !isRunning else { return }
            let expectedCycle = cycle
            parseTask?.cancel()
            parseTask = Task { @MainActor [weak self] in
                guard let self else { return }
                // Login completion may return to the usage SPA before its
                // fields arrive. Verify visible fields without storing a sample
                // or enabling collection; HTTP/auth errors remain explicit.
                for _ in 0..<24 {
                    guard !Task.isCancelled, self.cycle == expectedCycle, !self.isBusy else { return }
                    let result = await self.readVisibleSnapshot(requireRecentAttempt: false)
                    guard !Task.isCancelled, self.cycle == expectedCycle, !self.isBusy else { return }
                    switch result {
                    case .snapshot:
                        self.needsLogin = false
                        self.lastError = nil
                        self.status = "额度页已打开，点击开始 60 秒自动读取"
                        return
                    case .login:
                        self.needLogin("请完成官网登录或验证，再前往额度页")
                        return
                    case .quotaUnavailable:
                        self.quotaUnavailable()
                        return
                    case .invalid, .unavailable: break
                    }
                    try? await Task.sleep(for: .milliseconds(350))
                }
                guard !Task.isCancelled, self.cycle == expectedCycle else { return }
                self.status = "额度页已打开，等待官网字段；可稍后手动刷新"
            }
            return
        }
        let expectedCycle = cycle
        parseTask?.cancel()
        parseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // A SPA may finish document navigation before its visible usage fields arrive.
            for _ in 0..<24 {
                guard !Task.isCancelled, self.cycle == expectedCycle, self.isBusy else { return }
                let result = await self.readVisibleSnapshot()
                guard !Task.isCancelled, self.cycle == expectedCycle, self.isBusy else { return }
                switch result {
                case .snapshot(let snapshot): self.finishSuccess(snapshot); return
                case .login: self.needLogin("官网需要登录或验证，已暂停自动刷新"); return
                case .quotaUnavailable: self.quotaUnavailable(); return
                case .unavailable: break
                case .invalid: self.failAttempt("官网字段无法验证，保留上次记录"); return
                }
                try? await Task.sleep(for: .milliseconds(350))
            }
            guard !Task.isCancelled, self.cycle == expectedCycle, self.isBusy else { return }
            self.failAttempt("未读到可确认的额度字段，保留上次记录")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        navigationFailed(navigation, error: error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        navigationFailed(navigation, error: error)
    }
    private func navigationFailed(_ navigation: WKNavigation?, error: Error) {
        guard navigation === activeNavigation else { return }
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled else { return }
        hasUsagePage = false
        if isBusy {
            failAttempt("网络读取失败，保留上次记录")
        } else {
            activeNavigation = nil
            status = "无法打开官网，请检查网络后重新连接"
            lastError = status
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        hasUsagePage = false
        if isBusy { failAttempt("官网页面进程已停止，保留上次记录") }
        else {
            status = isRunning ? "官网页面已停止，下次刷新时重新打开" : "官网页面已停止，请重新连接后继续"
            lastError = status
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        guard isAllowedBrowserURL(url) else { decisionHandler(.cancel); return }
        // A popup is a separate browsing context. Its redirects must never
        // alter the quota page, sampling generation or main-page readiness.
        guard webView === self.webView else { decisionHandler(.allow); return }
        let isMain = navigationAction.targetFrame?.isMainFrame ?? false
        if isMain { hasUsagePage = isAllowedQuotaURL(url) }
        if isMain, isUpgradeURL(url) {
            quotaUnavailable()
        } else if isMain, (isRunning || isBusy), !isAllowedQuotaURL(url) {
            needLogin("页面离开额度页，请完成登录或验证后重新开始")
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        guard webView === self.webView, navigationResponse.isForMainFrame,
              let response = navigationResponse.response as? HTTPURLResponse else { decisionHandler(.allow); return }
        if let url = response.url, isUpgradeURL(url) {
            quotaUnavailable()
            decisionHandler(.allow)
            return
        }
        guard isBusy else { decisionHandler(.allow); return }
        // A response from the login navigation cannot be interpreted as a quota
        // result or rate-limit response, even if the old attempt was busy.
        guard let url = response.url, isAllowedQuotaURL(url) else {
            decisionHandler(.allow)
            return
        }
        if response.statusCode == 429 {
            let delay = Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After"))
            decisionHandler(.cancel)
            failAttempt("官网限流，刷新间隔已延长", retryAfter: delay)
        } else if response.statusCode == 401 || response.statusCode == 403 {
            decisionHandler(.allow)
            needLogin("官网要求登录或验证，已暂停自动刷新")
        } else if response.statusCode >= 400 {
            decisionHandler(.cancel)
            failAttempt("官网暂时无法读取，保留上次记录")
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, loginWindows.count < 4,
              let url = navigationAction.request.url, isAllowedBrowserURL(url),
              webView === self.webView || loginWindows[ObjectIdentifier(webView)] != nil else { return nil }
        // WebKit's supplied configuration contains the opener relationship.
        // Returning a genuine child without manually loading its request keeps
        // window.opener/postMessage and the provider's own login flow intact.
        let child = WKWebView(frame: NSRect(x: 0, y: 0, width: 680, height: 720), configuration: configuration)
        child.navigationDelegate = self
        child.uiDelegate = self
        child.allowsBackForwardNavigationGestures = true
        let window = NSWindow(contentRect: child.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Claude · 官网登录"
        window.minSize = NSSize(width: 460, height: 480)
        window.contentView = child
        window.delegate = self
        loginWindows[ObjectIdentifier(child)] = window
        loginWindowCount = loginWindows.count
        if isRunning || isBusy { needLogin("请在独立官网登录窗口完成登录，再返回额度页") }
        else {
            needsLogin = true
            lastError = nil
            status = "请在独立官网登录窗口完成登录，再点击前往额度页"
        }
        if !isFixture {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        loginWindows[ObjectIdentifier(webView)]?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let item = loginWindows.first(where: { $0.value === window }) else { return }
        if let child = window.contentView as? WKWebView {
            child.stopLoading()
            child.navigationDelegate = nil
            child.uiDelegate = nil
        }
        loginWindows.removeValue(forKey: item.key)
        loginWindowCount = loginWindows.count
        window.contentView = nil
        if loginWindows.isEmpty && !hasUsagePage {
            status = "登录窗口已关闭；完成登录后点击前往额度页"
        }
    }

    private func isAllowedBrowserURL(_ url: URL) -> Bool {
        if url.scheme == "https" || url.absoluteString == "about:blank" { return true }
        guard let fixtureURL else { return false }
        return url.isFileURL || (url.scheme == "http" && url.host == fixtureURL.host && url.port == fixtureURL.port)
    }

    private enum ReadResult {
        case snapshot(SnapshotEnvelope), login, quotaUnavailable, unavailable, invalid
    }

    private func readVisibleSnapshot(requireRecentAttempt: Bool = true) async -> ReadResult {
        guard let url = webView.url else { return .login }
        if isUpgradeURL(url) { return .quotaUnavailable }
        guard let parserSource, isAllowedQuotaURL(url) else { return .login }
        let canonicalURL = isFixture ? "https://claude.ai/settings/usage" : ""
        let script = parserSource + "\n" + Self.snapshotScript(canonicalURL: canonicalURL)
        do {
            guard let result = try await webView.evaluateJavaScript(script) as? String,
                  let data = result.data(using: .utf8), data.count <= 110_000,
                  let wrapper = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = wrapper["state"] as? String else { return .unavailable }
            // SPA routing may change the visible URL without another WebKit
            // navigation callback, including while JavaScript is returning.
            if let currentURL = webView.url, isUpgradeURL(currentURL) { return .quotaUnavailable }
            guard let currentURL = webView.url, isAllowedQuotaURL(currentURL) else { return .login }
            if state == "login" { return .login }
            guard state == "snapshot", let raw = wrapper["record"], JSONSerialization.isValidJSONObject(raw) else { return .unavailable }
            let snapshot = try SnapshotEnvelope.decode(JSONSerialization.data(withJSONObject: raw))
            guard snapshot.providerId == service,
                  // JavaScript Date.now has millisecond precision, unlike Date.
                  (!requireRecentAttempt || snapshot.observedAt >= (lastAttemptAt ?? .distantFuture).addingTimeInterval(-0.001)),
                  Date().timeIntervalSince(snapshot.observedAt) < 30 else { return .invalid }
            return .snapshot(snapshot)
        } catch {
            return .invalid
        }
    }

    private static func snapshotScript(canonicalURL: String) -> String {
        // canonicalURL is either empty (production) or a fixed literal (test-only fixture).
        """
        (() => {
          const canonical = '\(canonicalURL)';
          const url = canonical || location.href;
          const parsedURL = new URL(url);
          if (parsedURL.origin !== 'https://claude.ai' || !/^\\/settings\\/usage\\/?$/.test(parsedURL.pathname)) return JSON.stringify({state:'login'});
          function visible(element) {
            if (!element || element.closest('[hidden], [aria-hidden="true"]') || !element.getClientRects().length) return false;
            for (let parent = element; parent; parent = parent.parentElement) {
              const style = getComputedStyle(parent);
              if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' || style.opacity === '0') return false;
            }
            return true;
          }
          const title = document.title.toLowerCase();
          const auth = document.querySelector('input[type="password"], input[autocomplete="one-time-code"], #challenge-running, #challenge-stage, iframe[src*="challenges.cloudflare.com"]');
          if (visible(auth) || /just a moment|verify (?:you are|your)|security verification|安全验证|人机验证/.test(title)) return JSON.stringify({state:'login'});
          const main = document.querySelector('main, [role="main"]');
          if (!visible(main)) return JSON.stringify({state:'loading'});
          const raw = globalThis.YuliangVisibleParser.parseClaudeUsage(main.innerText, {url, now:Date.now()});
          if (!raw) return JSON.stringify({state:'loading'});
          const record = {
            schemaVersion:1, providerId:'claude', pageKind:'usage', observedAt:raw.observedAt,
            source:'browser', parserVersion:1,
            windows:raw.windows.map(w => ({id:w.id, label:w.label, usedPercent:w.usedPercent,
              resetAt:w.resetAt, resetLabel:w.resetLabel, note:w.note}))
          };
          return JSON.stringify({state:'snapshot', record});
        })();
        """
    }

    private static func retryDelay(_ header: String?) -> TimeInterval {
        if let header, let seconds = TimeInterval(header), seconds.isFinite, seconds >= 0 {
            return max(30, min(86_400, seconds))
        }
        if let header {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            if let date = formatter.date(from: header) { return max(30, min(86_400, date.timeIntervalSinceNow)) }
        }
        return 60
    }
}
