import AppKit
import SwiftUI
import WebKit
import QuotaCore

private typealias LanguageState = SwiftUI.State<YuliangLanguage>

/// The collector owns this browser, so closing/reopening the connection window
/// does not destroy its session or silently pause a refresh the user started.
private struct ClaudeUsageBrowser: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct ClaudeConnectionView: View {
    @ObservedObject var collector: QuotaWebCollector
    @LanguageState private var language: YuliangLanguage = YuliangL10n.language

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(YuliangL10n.text("连接 Claude 额度")).font(.title3.weight(.semibold))
                        Text(YuliangL10n.text("在下方官网登录，再开启每分钟自动读取。"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(YuliangL10n.text("打开官网"), systemImage: "arrow.up.right.square") {
                        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
                    }
                    .help(YuliangL10n.text("在默认浏览器查看额度；浏览器登录不会自动同步到本窗口。"))
                }

                HStack(spacing: 8) {
                    Button(YuliangL10n.text(collector.webView.url == nil ? "连接官网" : "前往额度页")) { collector.openUsagePage() }
                        .disabled(collector.isBusy)
                    if collector.isRunning {
                        Button(YuliangL10n.text("暂停自动读取"), systemImage: "pause.fill") { collector.pause() }
                    } else {
                        Button(YuliangL10n.text("开始 60 秒刷新"), systemImage: "play.fill") { collector.start() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!collector.hasUsagePage || collector.loginWindowCount > 0 || collector.isBusy || collector.isSuspended)
                    }
                    Button(YuliangL10n.text("立即刷新"), systemImage: "arrow.clockwise") { collector.refreshNow() }
                        .disabled(!collector.hasUsagePage || collector.loginWindowCount > 0 || collector.isBusy || collector.isSuspended)
                    Spacer()
                    if collector.isBusy {
                        ProgressView().controlSize(.small)
                        Text(YuliangL10n.text("正在读取")).font(.caption).foregroundStyle(.secondary)
                    }
                }

                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: collector.needsLogin ? "person.crop.circle.badge.exclamationmark" : "checkmark.shield")
                        .foregroundStyle(collector.needsLogin ? Color.orange : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(YuliangL10n.text(collector.status)).font(.callout).textSelection(.enabled)
                        if let date = collector.lastSuccessAt {
                            Text(YuliangL10n.format("上次成功读取 {0}", date.formatted(.dateTime.hour().minute().second().locale(YuliangL10n.language.locale))))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if collector.needsLogin {
                            Text(YuliangL10n.text("Google 等官网登录会在独立窗口完成。返回后点击「前往额度页」。若官网限制内嵌浏览器登录，可使用「打开官网」查看；外部浏览器登录不会自动同步。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
            .background(.bar)

            Divider()
            ClaudeUsageBrowser(webView: collector.webView)
                .accessibilityLabel(YuliangL10n.text("Claude 官网登录与额度页面"))
            Divider()

            Text(YuliangL10n.text("仅保存官网显示的额度与重置时间。关闭此窗口后，已开启的自动读取仍会继续。"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .environment(\.locale, language.locale)
        .onReceive(NotificationCenter.default.publisher(for: YuliangL10n.languageDidChange)) { _ in
            language = YuliangL10n.language
        }
        .frame(minWidth: 740, minHeight: 600)
        .onAppear {
            if collector.webView.url == nil { collector.connect() }
        }
        .onDisappear { collector.closeLoginWindows() }
    }
}
