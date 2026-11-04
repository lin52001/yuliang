import Foundation

/// UI language is a presentation preference. Collector payloads stay in their original form.
public enum YuliangLanguage: String, CaseIterable, Codable, Sendable {
    case system, zhHans, en, ja

    public var label: String {
        switch self {
        case .system: return YuliangL10n.text("跟随系统")
        case .zhHans: return "简体中文"
        case .en: return "English"
        case .ja: return "日本語"
        }
    }

    public var resolved: Self {
        guard self == .system else { return self }
        return Self.resolve(preferredLanguages: Locale.preferredLanguages)
    }

    public static func resolve(preferredLanguages: [String]) -> Self {
        for identifier in preferredLanguages {
            let code = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
            if code == "zh" || code.hasPrefix("zh-") { return .zhHans }
            if code == "ja" || code.hasPrefix("ja-") { return .ja }
            if code == "en" || code.hasPrefix("en-") { return .en }
        }
        return .en
    }

    public var locale: Locale {
        switch resolved {
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .ja: return Locale(identifier: "ja-JP")
        case .en, .system: return Locale(identifier: "en-US")
        }
    }
}

/// A locked preference avoids actor constraints for pure presentation/core callers.
/// Locale changes never mutate stored observations or start a collector request.
public enum YuliangL10n {
    private final class LanguageStorage: @unchecked Sendable {
        let lock = NSLock()
        var value: YuliangLanguage = .system
        func read() -> YuliangLanguage { lock.lock(); defer { lock.unlock() }; return value }
        func write(_ newValue: YuliangLanguage) { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
    private static let storage = LanguageStorage()
    public static let languageDidChange = Notification.Name("YuliangInterfaceLanguageDidChange")
    public static var language: YuliangLanguage {
        get { storage.read() }
        set {
            guard newValue != storage.read() else { return }
            storage.write(newValue)
            NotificationCenter.default.post(name: languageDidChange, object: nil)
        }
    }

    public static func text(_ source: String, language override: YuliangLanguage? = nil) -> String {
        let selected = (override ?? language).resolved
        guard selected != .zhHans else { return source }
        if let translated = catalog[source] { return selected == .ja ? translated.ja : translated.en }
        return dynamic(source, language: selected) ?? source
    }

    /// Numbered placeholders keep values intact and allow word-order changes.
    public static func format(_ source: String, _ arguments: String...) -> String {
        format(source, arguments: arguments, language: language)
    }

    public static func format(_ source: String, arguments: [String], language: YuliangLanguage) -> String {
        var result = text(source, language: language)
        guard let pattern = try? NSRegularExpression(pattern: #"\{(\d+)\}"#) else { return result }
        let matches = pattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let numberRange = Range(match.range(at: 1), in: result),
                  let index = Int(result[numberRange]), arguments.indices.contains(index),
                  let tokenRange = Range(match.range, in: result) else { continue }
            result.replaceSubrange(tokenRange, with: arguments[index])
        }
        return result
    }

    private static func captures(_ pattern: String, in source: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: source).map { String(source[$0]) } }
    }

    private static func dynamic(_ source: String, language: YuliangLanguage) -> String? {
        let japanese = language == .ja
        if let value = captures(#"^(\d+(?:\.\d+)?)(天|小时|分钟)额度$"#, in: source), value.count == 2 {
            let unit = value[1] == "天" ? (japanese ? "日" : "d") : value[1] == "小时" ? (japanese ? "時間" : "h") : (japanese ? "分" : "min")
            return japanese ? "\(value[0])\(unit)枠" : "\(value[0])\(unit) quota"
        }
        if let value = captures(#"^(.+) · (\d+) 秒后重试$"#, in: source), value.count == 2 {
            let message = text(value[0], language: language)
            return japanese ? "\(message) · \(value[1])秒後に再試行" : "\(message) · Retry in \(value[1])s"
        }
        if let value = captures(#"^已读取 Codex · 目标每 (\d+) 秒刷新$"#, in: source)?.first {
            return japanese ? "Codex を取得済み · 約\(value)秒ごとに更新" : "Codex updated · Every ~\(value)s"
        }
        if let value = captures(#"^每 (\d+) 秒自动查询，复用本机 Codex CLI 登录。请求慢或限流时顺延；仅查询，不发起对话任务。$"#, in: source)?.first {
            return japanese ? "この Mac の Codex CLI ログインを使い、約\(value)秒ごとに照会します。遅延やレート制限時は間隔を延ばします。会話タスクは作成しません。" : "Checks about every \(value)s using this Mac’s Codex CLI sign-in. Slow requests and rate limits delay the next check. No conversation tasks are started."
        }
        if let value = captures(#"^额度用了 ([\d.]+)% · 吃一块小饼干$"#, in: source)?.first {
            return japanese ? "利用枠を\(value)%使用 · クッキーをひとくち" : "\(value)% quota used · A cookie break"
        }
        if let value = captures(#"^已用 ([\d.]+)%$"#, in: source)?.first {
            return japanese ? "使用済み \(value)%" : "\(value)% used"
        }
        if let value = captures(#"^剩余百分之(\d+)$"#, in: source)?.first {
            return japanese ? "残り\(value)パーセント" : "\(value) percent remaining"
        }
        if let value = captures(#"^余 (\d+)%$"#, in: source)?.first {
            return japanese ? "残り \(value)%" : "\(value)% left"
        }
        if let value = captures(#"^上次剩余 (.+) · (记录已陈旧|重置待核对)$"#, in: source), value.count == 2 {
            return "\(text("上次剩余", language: language)) \(value[0]) · \(text(value[1], language: language))"
        }
        if let value = captures(#"^(.+)格式无效。$"#, in: source)?.first {
            let field = text(value, language: language)
            return japanese ? "\(field)の形式が無効です。" : "Invalid \(field.lowercased()) format."
        }
        if let value = captures(#"^摸摸(.+)$"#, in: source)?.first {
            let name = text(value, language: language)
            return japanese ? "\(name)をなでる" : "Pet \(name)"
        }
        if let value = captures(#"^和(.+)互动$"#, in: source)?.first {
            let name = text(value, language: language)
            return japanese ? "\(name)と遊ぶ" : "Play with \(name)"
        }
        let prefixes = ["服务端日统计 · ", "余量 · ", "选择小伙伴 · ", "日用量 · ", "订阅额度 · ", "刚刚更新 · ", "额度更新 ", "用量更新 ", "上次成功读取 ", "最后读取 ", "读于 ", "重置 ", "剩余 ", "上次剩余 "]
        for prefix in prefixes where source.hasPrefix(prefix) {
            let value = String(source.dropFirst(prefix.count))
            let heading = text(prefix.trimmingCharacters(in: .whitespaces), language: language)
            return "\(heading) \(text(value, language: language))"
        }
        // Multi-line tooltips consist entirely of independently translated UI lines.
        if source.contains("\n") {
            return source.components(separatedBy: "\n").map { text($0, language: language) }.joined(separator: "\n")
        }
        return nil
    }

    struct Translation: Sendable { let en: String; let ja: String }
    static let catalog: [String: Translation] = {
        let rows = """
跟随系统|System|システム設定
浅色|Light|ライト
深色|Dark|ダーク
轻巧卡片|Card|カード
Duo 圆环|Duo ring|Duo リング
自动 · 后台淡为单色|Auto · Monochrome in background|自動 · 背景では単色
始终全彩|Always full color|常にフルカラー
始终单色|Always monochrome|常に単色
语言|Language|言語
界面语言|Interface language|表示言語
简体中文|简体中文|简体中文
余量|Yuliang|Yuliang
余量 ·|Yuliang ·|Yuliang ·
余量 · 桌面卡片|Yuliang · Desktop card|Yuliang · デスクトップカード
余量 · 用量与额度|Yuliang · Usage & quota|Yuliang · 使用量と残量
余量 · 连接 Claude|Yuliang · Connect Claude|Yuliang · Claude に接続
余量 · 设置|Yuliang · Settings|Yuliang · 設定
余量 · 互动|Yuliang · Play|Yuliang · ふれあい
余量额度小窗|Yuliang quota widget|Yuliang 残量ウィジェット
未知|Unknown|不明
未提供|Not provided|未提供
未提供日期|Date not provided|日付未提供
日期未知|Date unknown|日付不明
额度未提供|Quota not provided|残量未提供
等待读取额度|Waiting for quota|残量の取得待ち
尚未读取|Not read yet|未取得
未读取|Not read|未取得
待连接|Connect|未接続
待确认|Unconfirmed|未確認
等待读取|Waiting|取得待ち
已读取|Updated|取得済み
剩余|Remaining|残り
上次剩余|Last remaining|前回の残り
上次|Previous|前回
剩余额度未知|Remaining quota unknown|残量は不明です
额度未知|Quota unknown|残量不明
订阅剩余额度|Subscription quota remaining|サブスクリプションの残量
订阅额度|Subscription quota|サブスクリプション枠
网页订阅|Web subscription|Web サブスクリプション
额度窗口|Quota window|利用枠
主额度窗口|Primary window|主な利用枠
另一额度窗口|Other window|別の利用枠
会话|Session|セッション
每周|Weekly|週間
所有模型|All models|すべてのモデル
当前会话|Current session|現在のセッション
本周|This week|今週
读取失败，点此查看|Read failed · View details|取得に失敗 · 詳細を見る
额度读取失败，点此查看|Quota read failed · View details|残量取得に失敗 · 詳細を見る
请先登录 Codex|Sign in to Codex|Codex にログインしてください
请先连接 Claude|Connect Claude first|Claude に接続してください
等待读取 Codex 额度|Waiting for Codex quota|Codex の残量取得待ち
上次额度已陈旧，点此查看|Quota is out of date · View details|前回の残量は古い情報です · 詳細
额度重置待核对|Quota reset needs verification|利用枠のリセットを要確認
官方未提供额度比例|No quota percentage provided|公式の残量率は未提供です
记录已陈旧|Out of date|古い記録
重置待核对|Reset unverified|リセット要確認
上次记录 · 已陈旧|Previous record · Out of date|前回の記録 · 古い情報
上次记录 · 重置待核对|Previous record · Reset unverified|前回の記録 · リセット要確認
上次记录，已陈旧|Previous record is out of date|前回の記録は古い情報です
上次记录，重置待核对|Previous record · Reset unverified|前回の記録 · リセット要確認
Codex 未提供百分比|Codex did not provide a percentage|Codex の残量率は未提供です
官网未提供百分比|No percentage on the official page|公式ページの残量率は未提供です
设置|Settings|設定
额度来源|Quota source|データ取得元
小组件样式|Widget style|ウィジェットの形
显示内容|Content|表示内容
外观|Appearance|外観
选择小伙伴|Choose companion|キャラクターを選ぶ
互动|Play|ふれあい
返回|Back|戻る
关闭|Close|閉じる
锁定位置|Lock position|位置を固定
悬浮置顶|Keep on top|最前面に表示
显示／收起卡片|Show / hide card|カードを表示／非表示
移回当前屏幕|Move to this screen|この画面に移動
连接 Claude 官网|Connect to Claude|Claude 公式サイトに接続
查看当前额度详情|Quota details|現在の残量の詳細
日 Token 用量|Daily tokens|1 日のトークン数
累计 Token 用量|Total tokens|累計トークン数
紧凑模式|Compact mode|コンパクト表示
自主陪伴|Ambient companionship|自動のふれあい
等待首次读取|Waiting for first update|初回の取得待ち
随机互动|Surprise me|ランダムに遊ぶ
小组件设置|Widget settings|ウィジェット設定
右键或按住 Control 点击，打开设置|Right-click or Control-click for settings|右クリックまたは Control＋クリックで設定
互动动作|Companion actions|ふれあいの動作
位置已锁定|Position locked|位置を固定中
拖动小组件|Drag widget|ウィジェットをドラッグ
显示桌面卡片|Show desktop card|デスクトップカードを表示
找回桌面卡片|Find desktop card|デスクトップカードを戻す
用量与额度详情|Usage details|使用量と残量の詳細
用量与额度|Usage & quota|使用量と残量
立即刷新|Refresh now|今すぐ更新
退出余量|Quit Yuliang|Yuliang を終了
编辑|Edit|編集
撤销|Undo|取り消す
剪切|Cut|切り取る
复制|Copy|コピー
粘贴|Paste|貼り付け
全选|Select all|すべて選択
累计用量|Total usage|累計使用量
日用量|Daily usage|1 日の使用量
日用量 ·|Daily ·|1 日 ·
选择小伙伴 ·|Companion ·|キャラクター ·
订阅额度 ·|Quota ·|利用枠 ·
额度更新|Quota updated|残量の更新
额度尚未读取|Quota not read yet|残量は未取得です
点按查看用量与额度详情|Click for usage & quota details|クリックして使用量と残量の詳細を表示
日|Day|1 日
累计|Total|累計
重置|Resets|リセット
未提供重置时间|Reset time not provided|リセット時刻未提供
已选择|Selected|選択済み
未选择|Not selected|未選択
暂停|Pause|一時停止
开始刷新|Start refresh|自動更新を開始
刷新|Refresh|更新
等待官方接口返回额度窗口|Waiting for quota windows from the official service|公式サービスの利用枠を取得中
Token 使用量|Token usage|トークン使用量
用量更新|Usage updated|使用量の更新
用量尚未读取|Usage not read yet|使用量は未取得です
日用量使用官方返回的最新统计日，服务端未注明时区。累计使用量独立读取，不通过额度百分比换算；缺失项显示未知，读取失败时保留上次数据。|Daily usage uses the latest reporting day returned by the service; its time zone is unspecified. Total usage is read separately, never inferred from quota percentages. Missing values stay unknown; failures preserve the last data.|1 日の使用量は公式サービスが返す最新の集計日を使用します。タイムゾーンは未指定です。累計は個別に取得し、残量率から換算しません。未提供の値は不明のままにし、取得失敗時は前回の記録を保持します。
请先在官方 Codex 中登录；CLI 尚未登录时，可在终端运行 codex login，完成后重试。|Sign in through official Codex first. If the CLI is not signed in, run codex login in Terminal, then retry.|公式 Codex にログインしてください。CLI が未ログインの場合は、ターミナルで codex login を実行してから再試行してください。
仅读取额度和用量摘要，不读取密码、令牌或对话正文。|Reads quota and usage summaries only, without reading passwords, tokens, or conversation text.|残量と使用量の概要のみ取得し、パスワード、認証トークン、会話本文は読み取りません。
Claude 订阅额度|Claude subscription quota|Claude のサブスクリプション枠
在连接窗口登录官网后，开启每 60 秒自动读取。|Sign in on the official page in the connection window, then enable checks every 60 seconds.|接続ウィンドウで公式サイトにログインし、60 秒ごとの自動取得を有効にしてください。
官网未提供重置时间|No reset time on the official page|公式ページのリセット時刻は未提供です
上次成功读取|Last successful read|前回の取得成功
Claude 官网订阅额度独立保存，不与 Codex 合并。官网未显示 Token 使用量时不推算；外部浏览器的登录不会自动同步到应用的连接窗口。|Claude subscription quota is stored separately from Codex. Tokens are not estimated when the official page does not provide them. An external browser sign-in does not sync to the app’s connection window.|Claude の利用枠は Codex と分けて保存します。公式ページにトークン使用量がない場合は推算しません。外部ブラウザのログインはアプリの接続ウィンドウに同期されません。
Codex 账号用量 · 服务端日统计|Codex account usage · Service daily totals|Codex アカウント使用量 · サーバー日次集計
连接 Claude 额度|Connect Claude quota|Claude の残量に接続
在下方官网登录，再开启每分钟自动读取。|Sign in on the official page below, then enable automatic checks every minute.|下の公式サイトでログインし、毎分の自動取得を有効にしてください。
打开官网|Open official site|公式サイトを開く
在默认浏览器查看额度；浏览器登录不会自动同步到本窗口。|View quota in your default browser. Its sign-in does not sync to this window.|既定のブラウザで残量を確認します。ブラウザのログインはこのウィンドウに同期されません。
连接官网|Connect|公式サイトに接続
前往额度页|Go to usage page|使用量ページへ
暂停自动读取|Pause automatic checks|自動取得を一時停止
开始 60 秒刷新|Start 60s checks|60 秒ごとの更新を開始
正在读取|Reading|取得中
Google 等官网登录会在独立窗口完成。返回后点击「前往额度页」。若官网限制内嵌浏览器登录，可使用「打开官网」查看；外部浏览器登录不会自动同步。|Google and other sign-ins open in a separate official window. Return here and choose Go to usage page. If embedded sign-in is blocked, use Open official site to view usage. External browser sessions do not sync here.|Google などのログインは別の公式ウィンドウで行います。完了後に戻り「使用量ページへ」を選択してください。埋め込みログインが制限される場合は「公式サイトを開く」で確認できます。外部ブラウザのログインは同期されません。
Claude 官网登录与额度页面|Claude official sign-in and usage page|Claude 公式ログインと使用量ページ
仅保存官网显示的额度与重置时间。关闭此窗口后，已开启的自动读取仍会继续。|Only quota and reset times shown on the official page are saved. Enabled automatic checks continue after this window closes.|公式ページに表示される利用枠とリセット時刻のみ保存します。このウィンドウを閉じても、有効にした自動取得は継続します。
连接官网后开始自动读取|Connect to start automatic checks|公式サイトに接続して自動取得を開始
ChatGPT 自动额度暂未接入，不能推算百分比|Automatic ChatGPT quota is not connected; percentages cannot be inferred|ChatGPT の自動取得は未対応のため、残量率は推算できません
正在前往额度页；如需登录，请在官网完成后继续|Opening the usage page; complete any sign-in on the official site|使用量ページを開いています。必要なログインは公式サイトで完了してください
电脑休眠中，唤醒后继续读取|Mac asleep · Checks resume on wake|スリープ中 · 復帰後に取得を再開
官网限流，请等待退避结束|Official site rate-limited · Waiting to retry|公式サイトのレート制限中 · 再試行待ち
官网要求等待，退避结束后继续读取|Official site requested a pause · Checks resume after backoff|公式サイトの待機要求 · 待機後に取得を再開
已暂停，保留上次成功记录|Paused · Last successful record preserved|一時停止中 · 前回の取得成功記録を保持
电脑休眠中，暂不发起读取|Mac asleep · No checks started|スリープ中のため取得を行いません
官网正在限流，请等待退避结束|Official site rate-limited · Waiting to retry|公式サイトのレート制限中 · 再試行待ち
缺少额度解析资源，请重新安装应用|Usage parser missing · Reinstall the app|残量解析リソースがありません · アプリを再インストール
尚未连接本机额度存储|Local quota storage is not connected|ローカルの残量保存先が未接続です
尚未连接本机额度存储。|Local quota storage is not connected.|ローカルの残量保存先が未接続です。
请先完成独立官网窗口中的登录，再前往额度页|Complete sign-in in the separate official window, then open the usage page|別の公式ウィンドウでログインしてから使用量ページへ進んでください
请先完成官网登录，并打开额度页|Sign in on the official site and open the usage page first|公式サイトにログインし、使用量ページを開いてください
正在刷新合成测试页面|Refreshing synthetic test page|合成テストページを更新中
正在刷新官网额度页|Refreshing official usage page|公式の使用量ページを更新中
本次读取超时，保留上次记录|Read timed out · Previous record preserved|取得がタイムアウト · 前回の記録を保持
官网已转到套餐页，未提供可读取额度。请核对登录账号与套餐|The site redirected to a plan page without readable quota. Check your account and plan.|プランのページに移動し、取得可能な利用枠がありません。アカウントとプランを確認してください
已读取 · 目标每 60 秒刷新|Updated · Checks about every 60s|取得済み · 約 60 秒ごとに更新
已完成一次读取|Read completed|取得が完了しました
本机保存失败，保留上次成功记录|Local save failed · Last successful record preserved|ローカル保存に失敗 · 前回の取得成功記録を保持
官网当前未打开额度页，请完成登录或验证后再前往额度页|Usage page is not open. Finish sign-in or verification, then open it.|使用量ページが開かれていません。ログインや認証後にページを開いてください
额度页已打开，点击开始 60 秒自动读取|Usage page ready · Start 60s automatic checks|使用量ページを開きました · 60 秒ごとの自動取得を開始できます
请完成官网登录或验证，再前往额度页|Finish official sign-in or verification, then open the usage page|公式サイトのログインや認証後に使用量ページを開いてください
额度页已打开，等待官网字段；可稍后手动刷新|Usage page open · Waiting for fields; try refreshing later|使用量ページを開きました · データを待っています。後で手動更新できます
官网需要登录或验证，已暂停自动刷新|Official sign-in or verification required · Automatic checks paused|公式サイトのログインや認証が必要です · 自動更新を一時停止
官网字段无法验证，保留上次记录|Official fields could not be verified · Previous record preserved|公式ページのデータを検証できません · 前回の記録を保持
未读到可确认的额度字段，保留上次记录|No verifiable quota fields found · Previous record preserved|確認可能な残量データがありません · 前回の記録を保持
网络读取失败，保留上次记录|Network read failed · Previous record preserved|ネットワーク取得に失敗 · 前回の記録を保持
无法打开官网，请检查网络后重新连接|Cannot open official site · Check the network and reconnect|公式サイトを開けません · ネットワークを確認して再接続
官网页面进程已停止，保留上次记录|Official page stopped · Previous record preserved|公式ページのプロセスが停止 · 前回の記録を保持
官网页面已停止，下次刷新时重新打开|Official page stopped · Reopens on the next check|公式ページが停止 · 次回の更新で開き直します
官网页面已停止，请重新连接后继续|Official page stopped · Reconnect to continue|公式ページが停止 · 再接続してください
页面离开额度页，请完成登录或验证后重新开始|Left the usage page · Finish sign-in or verification and restart|使用量ページから移動しました · ログインや認証後に再開
官网限流，刷新间隔已延长|Official site rate-limited · Refresh interval extended|公式サイトのレート制限中 · 更新間隔を延長
官网要求登录或验证，已暂停自动刷新|Official sign-in or verification required · Automatic checks paused|公式サイトのログインや認証が必要です · 自動更新を一時停止
官网暂时无法读取，保留上次记录|Official site temporarily unavailable · Previous record preserved|公式ページを一時的に取得できません · 前回の記録を保持
Claude · 官网登录|Claude · Official sign-in|Claude · 公式ログイン
请在独立官网登录窗口完成登录，再返回额度页|Finish sign-in in the separate official window, then return to usage|別の公式ウィンドウでログインし、使用量ページに戻ってください
请在独立官网登录窗口完成登录，再点击前往额度页|Finish sign-in in the separate official window, then choose Go to usage page|別の公式ウィンドウでログインし「使用量ページへ」を選択してください
登录窗口已关闭；完成登录后点击前往额度页|Sign-in window closed · After signing in, choose Go to usage page|ログインウィンドウを閉じました · ログイン後に「使用量ページへ」を選択
等待读取 Token 用量|Waiting for token usage|トークン使用量の取得待ち
准备连接本机 Codex|Connecting to local Codex|この Mac の Codex に接続準備中
电脑休眠中，唤醒后继续读取 Codex|Mac asleep · Codex checks resume on wake|スリープ中 · 復帰後に Codex の取得を再開
Codex 要求等待，退避结束后继续读取|Codex requested a pause · Checks resume after backoff|Codex の待機要求 · 待機後に取得を再開
Codex 正在限流，请等待退避结束|Codex rate-limited · Waiting to retry|Codex のレート制限中 · 再試行待ち
未找到本机 Codex，请先安装并登录 Codex|Codex not found · Install and sign in first|Codex が見つかりません · インストールしてログインしてください
正在读取 Codex 合成测试记录|Reading synthetic Codex test data|Codex の合成テストデータを取得中
正在读取本机 Codex 额度|Reading local Codex quota|この Mac の Codex 残量を取得中
Codex 未返回对应额度，保留上次记录|Codex returned no matching quota · Previous record preserved|Codex に対応する利用枠がありません · 前回の記録を保持
Codex 额度字段无法验证，保留上次记录|Codex quota could not be verified · Previous record preserved|Codex の残量を検証できません · 前回の記録を保持
已完成一次 Codex 额度读取|Codex quota read completed|Codex の残量取得が完了しました
本机额度保存失败，保留上次成功记录|Local quota save failed · Last successful record preserved|残量のローカル保存に失敗 · 前回の取得成功記録を保持
请先在 Codex 中登录账户，再重新连接|Sign in to Codex, then reconnect|Codex にログインして再接続してください
本机 Codex 暂不支持额度读取，请检查版本|This Codex version cannot read quota · Check for an update|この Codex は残量取得に未対応です · バージョンを確認
Codex 暂时限流，刷新间隔已延长|Codex rate-limited · Refresh interval extended|Codex のレート制限中 · 更新間隔を延長
本机 Codex 未能启动，保留上次记录|Local Codex failed to start · Previous record preserved|この Mac の Codex を起動できません · 前回の記録を保持
Codex 返回记录无法验证，保留上次记录|Codex response could not be verified · Previous record preserved|Codex の応答を検証できません · 前回の記録を保持
Codex 暂时无法读取，保留上次记录|Codex temporarily unavailable · Previous record preserved|Codex を一時的に取得できません · 前回の記録を保持
服务端暂未返回 Token 数值|Service has not provided token counts|サーバーのトークン数は未提供です
已读取账号 Token 用量|Account token usage updated|アカウントのトークン使用量を取得済み
Token 字段无法验证，保留上次记录|Token counts could not be verified · Previous record preserved|トークン数を検証できません · 前回の記録を保持
本机 Codex 暂不支持 Token 用量读取|This Codex version cannot read token usage|この Codex はトークン使用量の取得に未対応です
Token 用量需要 Codex 账号登录|Sign in to Codex to read token usage|トークン使用量の取得には Codex ログインが必要です
Token 用量暂时限流，保留上次记录|Token usage rate-limited · Previous record preserved|トークン使用量のレート制限中 · 前回の記録を保持
Token 用量暂时不可读，保留上次记录|Token usage unavailable · Previous record preserved|トークン使用量を取得できません · 前回の記録を保持
合成 UI 测试数据|Synthetic UI test data|合成 UI テストデータ
来自 Codex 官方本机额度接口；未返回的数值保持未知。|From the official local Codex quota interface; missing values stay unknown.|Codex 公式のローカル利用枠インターフェースから取得し、未提供の値は不明のままにします。
本机额度文件无法验证，已保留原文件。|Local quota file could not be verified; the original was preserved.|ローカルの残量ファイルを検証できません。元のファイルを保持しました。
本机额度正在更新，请稍后重试。|Local quota is being updated. Try again shortly.|ローカルの残量を更新中です。しばらくして再試行してください。
共享容器尚未可用，请检查三个原生目标的 App Group 与签名。|Shared container unavailable. Check App Groups and signing for the native targets.|共有コンテナが利用できません。各ネイティブターゲットの App Group と署名を確認してください。
另一进程正在更新，请稍后重试。|Another process is updating. Try again shortly.|別のプロセスが更新中です。しばらくして再試行してください。
切换额度服务|Switch quota provider|利用枠のサービスを切り替える
切换当前显示的服务，不修改额度。|Switch the displayed provider without changing quota.|残量を変更せず、表示するサービスを切り替えます。
摸摸小伙伴|Pet companion|キャラクターをなでる
小伙伴回应你，饱腹度只跟随真实使用量。|Your companion responds; satiety follows actual usage only.|キャラクターが反応します。満腹度は実際の使用量のみに連動します。
切换小伙伴|Switch companion|キャラクターを切り替える
切换库洛米与美乐蒂，不修改额度、使用量和读取时间。|Switch Kuromi and My Melody without changing quota, usage, or observation time.|残量、使用量、取得時刻を変更せず、クロミとマイメロディを切り替えます。
等你一起开工|Ready when you are|一緒に始めよう
零食时间 · 这口不改变额度|Snack time · Quota stays unchanged|おやつの時間 · 利用枠は変わりません
摸摸头，心情变好了|A little pat lifts the mood|なでてもらって元気になったよ
在这里，陪你一起开工|Right here, keeping you company|ここで一緒に頑張るよ
眯一小会儿，马上回来|A tiny nap, then I’m back|少しだけお昼寝。すぐ戻るよ
给你一点小小的鼓励|A little encouragement for you|小さな応援を届けるよ
蹦一下，继续加油|A little hop to keep going|ぴょんと跳んで、もうひと頑張り
跟着节拍摇摇摆|Swaying to the beat|リズムに合わせてゆらゆら
转一圈，元气回来啦|A little spin brings the energy back|くるっと回って元気になったよ
伸个懒腰，肩膀放松一点|Stretch out and relax your shoulders|伸びをして肩の力を抜こう
靠近一点，陪着你就很好|Happy just to be near you|そばにいられるだけでうれしいよ
探个头，看看你有没有想我|Peeking in to say hello|ひょっこり、会いに来たよ
碰个杯，你也喝口水吧|Cheers · Have some water too|乾杯。あなたもお水を飲んでね
摸摸头，今天也一起加油呀。|A little pat · Let’s keep going together.|なでなで。今日も一緒に頑張ろうね。
等一口新消息|Waiting for a little news|新しいお知らせを待ってるよ
吃饱啦，歇一会儿|Full now · Time to rest|おなかいっぱい、ひと休み
很满足|Feeling content|大満足
再吃一小口|Just one more bite|もうひとくち
肚子还空空的|Still a little hungry|まだおなかがすいてるよ
等待 Codex 读取|Waiting for Codex|Codex の取得待ち
等待官网读取|Waiting for official page|公式ページの取得待ち
已用量未知|Used amount unknown|使用量不明
读于|Read at|取得時刻
最后读取|Last read|前回の取得
星光额度轨道|Starlight quota rail|星の残量バー
点按与小伙伴互动，额度不会改变|Click to play; quota stays unchanged|クリックして遊べます。利用枠は変わりません
点按回应|Click for a response|クリックで反応
点按随机回应，右键选择互动动作|Click for a surprise; right-click to choose an action|クリックでランダムな反応、右クリックで動作を選択
休息|Rest|ひと休み
喂一口饼干|Offer a cookie|クッキーをあげる
喂一块饼干|Offer a cookie|クッキーをあげる
摸摸头|Pet|なでる
招招手|Wave|手を振る
小睡一下|Take a nap|お昼寝
给点鼓励|Cheer on|応援する
跳一跳|Hop|ジャンプ
摇摇摆|Sway|ゆらゆら
转个圈|Spin|くるっと回る
伸伸懒腰|Stretch|伸びをする
蹭蹭你|Nuzzle|すりすり
探个头|Peek|ひょっこり
一起喝水|Water break|一緒に水分補給
额度已更新|Quota updated|残量を更新しました
刚刚更新 ·|Just updated ·|たった今更新 ·
慢慢来，每一步都算数|Take your time. Every step counts.|ゆっくりでいい。一歩ずつ進もう
先做好眼前这一小步|One small step at a time.|まずは目の前の小さな一歩から
认真投入的你，很棒|You’re doing great work.|一生懸命なあなたはすてきだよ
不用着急，按自己的节奏|No rush. Go at your own pace.|焦らず、自分のペースでね
累了就歇一会儿|Rest when you need to.|疲れたらひと休みしよう
今天也有一点点进步|A little progress today, too.|今日も少しずつ進んでいるよ
小小的坚持，也值得肯定|Your small efforts matter.|小さな積み重ねも大切だよ
照顾好自己，再继续|Look after yourself as you go.|自分を大切にして、また進もう
这一口，奖励认真开工|A bite for your hard work.|頑張ったあなたに、ひとくち
饼干收到，你也要照顾自己|Cookie received. Take care, too.|クッキーありがとう。あなたも大切にね
补点能量，再慢慢向前|Recharge, then keep going gently.|元気を補給して、またゆっくり進もう
摸摸头，你已经很努力了|A little pat. You’ve worked hard.|なでなで。もう十分頑張ってるよ
今天的你，也值得被肯定|You deserve kindness today, too.|今日のあなたも、ほめてあげよう
别着急，我陪你慢慢来|No rush. I’m here with you.|急がなくていいよ。一緒にゆっくりね
我在这里，陪你一起开工|I’m here to keep you company.|ここで一緒に頑張るよ
挥挥手，把压力放轻一点|A wave to ease the pressure.|手を振って、少し気を楽にしよう
新的一步，我们一起|Let’s take the next step together.|次の一歩も一緒に進もう
闭闭眼，休息也是向前|Close your eyes. Rest counts, too.|目を閉じて。休むのも大切な一歩
给自己一点喘息的时间|Give yourself room to breathe.|ひと息つく時間を大切にね
不用一直绷紧，歇一下吧|You can loosen up and rest.|気を張り続けず、少し休もう
你已经做得很棒了|You’re already doing so well.|もう、とてもよくできているよ
这一点点进步，也值得庆祝|Even a small step is worth celebrating.|小さな進歩もお祝いしよう
认真坚持的你，值得掌声|Your effort deserves applause.|頑張り続けるあなたに拍手
跳一下，给自己打打气|A little hop to lift your spirits.|ぴょんと跳んで、自分を応援しよう
向前一小步，也很了不起|A small step forward is wonderful.|小さな一歩だって、すごいこと
轻轻起跳，再稳稳落地|A gentle hop, a steady landing.|ふわっと跳んで、しっかり着地
摇一摇，把紧绷放松一点|Sway a little. Let the tension go.|ゆらゆら揺れて、力を抜こう
跟着自己的节奏慢慢来|Keep moving at your own rhythm.|自分のリズムでゆっくり進もう
让心情也松一口气|Let your mind take a breather.|気持ちもひと息つこう
转个圈，换个轻松的思路|A spin for a fresh perspective.|くるっと回って、気分を変えよう
暂时卡住，也没关系|It’s okay to feel stuck for a moment.|今つまずいても、大丈夫だよ
换个角度，再试一次|Try again from another angle.|見方を変えて、もう一度
伸伸懒腰，肩膀也放松一点|Stretch and relax those shoulders.|伸びをして、肩もほぐそう
舒展一下，再陪你继续|A stretch, then we’ll carry on.|伸びをして、また一緒に進もう
抬抬手，紧绷可以放下来|Reach up and let the tension go.|手を上げて、力を抜こう
蹭蹭你，谢谢你陪着我|A nuzzle. Thanks for being here.|すりすり。一緒にいてくれてありがとう
借你一点温柔，回你一点元气|A little kindness, a little energy back.|優しさをもらって、元気をお返し
靠近一点点，今天也陪着你|A little closer. Here with you today.|少しだけ近くで、今日も一緒だよ
探头看看，你已经很认真啦|Peeking in. You’re doing your best.|ひょっこり。とても頑張っているね
我在旁边，给你一点小鼓励|Here beside you, cheering you on.|そばから小さな応援を送るよ
偷偷看你一眼，继续一起加油|A tiny peek. Let’s keep going.|ちらっと見て、一緒にもうひと頑張り
干杯，你也记得喝口水|Cheers. Remember some water, too.|乾杯。あなたもお水を忘れずに
水杯举起来，照顾好自己|Raise your cup and take care.|カップを持って、自分を大切にね
慢慢喝一口，再继续向前|Take a sip, then carry on.|ひとくち飲んで、また進もう
星糖龙娘|Stardust Dragon|星砂ドラゴン
云朵精灵|Cloud Sprite|雲の妖精
橘光学姐|Amber Senpai|アンバー先輩
蓝鲸少女|Blue Whale Girl|青いクジラの少女
星喵少女|Starcat Girl|星ねこの少女
库洛米|Kuromi|クロミ
美乐蒂|My Melody|マイメロディ
奶龙|Nailong|ナイロン
持剑小猫|Kitten Knight|子ねこ剣士
小猫剑士|Kitten Knight|子ねこ剣士
团子猫|Mochi Cat|もちねこ
奶油兔|Butter Bunny|バターうさぎ
薄荷狐|Mint Fox|ミントきつね
芝麻熊|Sesame Bear|ごまくま
采集记录不能超过 100 KB。|A collected record cannot exceed 100 KB.|取得記録は 100 KB 以下にしてください。
时间必须包含完整日期、秒和时区。|Time must include a complete date, seconds, and time zone.|時刻には年月日、秒、タイムゾーンが必要です。
时间包含无效的日期或时刻。|Time contains an invalid date or clock time.|日付または時刻が無効です。
时间包含不存在的日期。|Time contains a nonexistent date.|存在しない日付です。
时间或时区无效。|Invalid time or time zone.|時刻またはタイムゾーンが無効です。
此服务不支持该额度窗口。|This quota window is not supported by this provider.|このサービスは指定の利用枠に対応していません。
已用百分比必须在 0 至 100 之间。|Used percentage must be between 0 and 100.|使用率は 0〜100 の範囲にしてください。
ChatGPT 限制提示不能推算统一百分比。|ChatGPT limit notices cannot imply a universal percentage.|ChatGPT の制限通知から共通の使用率を推算することはできません。
额度窗口的采样时间无效。|Invalid observation time for this quota window.|利用枠の取得時刻が無効です。
重置时间无效。|Invalid reset time.|リセット時刻が無効です。
重置说明|Reset details|リセットの説明
备注|Notes|メモ
记录版本、来源或页面类型不受支持。|Unsupported record version, source, or page type.|記録バージョン、取得元、ページ種別が未対応です。
采样时间不能来自未来。|Observation time cannot be in the future.|取得時刻を未来にすることはできません。
额度窗口为空、过多或重复。|Quota windows are empty, excessive, or duplicated.|利用枠が空、上限超過、または重複しています。
记录 ID 无效。|Invalid record ID.|記録 ID が無効です。
所选额度窗口不受支持。|The selected quota window is unsupported.|選択した利用枠は未対応です。
本机快照版本或服务列表无效。|Invalid local snapshot version or provider list.|ローカル記録のバージョンまたはサービス一覧が無効です。
等待开饭|Waiting for a snack|おやつ待ち
饿肚子|Hungry|おなかがすいたよ
吃几口|A few bites|ひとくち、ふたくち
吃饱啦|Full and happy|おなかいっぱい
陪你一阵子啦，喝口水吧|We’ve been at it a while. Have some water.|しばらく頑張ったね。お水を飲もう
伸伸懒腰，也看看远处吧|Stretch a little and look into the distance.|伸びをして、遠くも見てみよう
伸个懒腰，再陪你一会儿|A little stretch, then more time together.|伸びをして、もう少し一緒にいよう
肩膀放松一点点吧|Let those shoulders relax.|肩の力を少し抜こう
一起舒展一下，好不好|Shall we stretch together?|一緒に伸びをしようか
蹭蹭你，给我一点关注嘛|A nuzzle. A little attention, please?|すりすり。ちょっとこっちを見て
借一点点你的好心情|May I borrow a little of your good mood?|いい気分を少し分けてね
忙完这小步，摸摸我好不好|A little pat after this step?|このひと区切りの後、なでてくれる？
探个头，你还好吗|Peeking in. How are you?|ひょっこり。元気にしてる？
我有乖乖陪着你哦|I’m right here keeping you company.|ちゃんとそばにいるよ
偷偷看看你，继续加油|A little peek. You’ve got this.|ちらっと。もうひと頑張りだね
我先喝一口，你也来一点|I’ll take a sip. You too?|先にひとくち。あなたもどう？
喝口水，慢慢继续吧|Have some water, then go gently.|お水を飲んで、ゆっくり進もう
杯子碰一下，照顾好自己|Cheers. Take good care of yourself.|乾杯。自分を大切にね
挥挥手，我一直在这里|A little wave. I’m always here.|手を振るよ。ずっとそばにいるよ
抬头看我一眼就好|Just a little glance my way.|ちょっと顔を上げて見てね
今天也一起慢慢前进|Let’s move forward gently today, too.|今日も一緒に少しずつ進もう
靠在这里，陪你眯一会儿|Resting here with you for a moment.|ここで寄り添って、ひと休み
我打个小盹，醒来还陪你|A tiny nap. I’ll still be here.|少しお昼寝。起きてもそばにいるよ
不着急，歇一下也可以|No rush. A rest is fine.|急がず、ひと休みしてもいいよ
认真投入的你，很闪亮|You shine when you’re focused.|一生懸命なあなたは輝いているよ
送你一颗小小的星星|A tiny star for you.|小さなお星さまをどうぞ
已经走了一点点，很棒哦|You’ve made progress. Well done.|少し進んだね。よくできました
上次成功读取 {0}|Last successful read {0}|前回の取得成功 {0}
剩余 {0}%|{0}% remaining|残り {0}%
日用量 · {0}|Daily · {0}|1 日 · {0}
龙息星糖|Dragon spark|ドラゴンの星砂
暖光应援|Amber cheer|暖かな光の応援
泡泡跃浪|Bubble leap|泡と波のジャンプ
星轨巡游|Star trail|星めぐり
云朵轻飘|Cloud drift|ふわふわ雲
弹弹肚皮|Belly bounce|おなかポヨン
护你一剑|Knight’s guard|子ねこ剣士の守り
暖心贴贴|Cozy nuzzle|ほっこりすりすり
龙尾画个圈，送你一点勇气|A dragon-tail twirl for a little courage.|しっぽをくるり。小さな勇気を届けるよ
小小龙息，暖暖陪着你|A tiny dragon spark to keep you warm.|小さなドラゴンの息で、暖かく寄り添うよ
星糖闪一下，今天也加油|A stardust sparkle. You’ve got this.|星砂がきらり。今日も応援してるよ
暖光绕一圈，为你轻轻鼓掌|Warm light circles round to cheer you on.|暖かな光で、あなたに小さな拍手
把这束暖光，留给认真开工的你|A little warm light for your hard work.|頑張るあなたに、この暖かな光を
挥挥手，今天也有我应援|A little wave. I’m cheering for you today.|手を振って、今日もあなたを応援するよ
跃过小浪花，我们慢慢前进|Over the little waves, one step at a time.|小さな波を越えて、ゆっくり進もう
吹个泡泡，把紧张放轻一点|A little bubble to lighten the tension.|泡をふわり。緊張を少し軽くしよう
蓝鲸陪着你，深呼吸一下|Your blue whale is here. Take a breath.|青いクジラがそばにいるよ。深呼吸しよう
星轨转一圈，灵感来敲门|A starry orbit to welcome a new idea.|星をひとめぐり。ひらめきがやって来るよ
耳朵动一下，听见你的努力啦|An ear twitch. I hear all your hard work.|耳をぴくり。頑張りが聞こえているよ
送你一颗星，照亮眼前一小步|A star to light your next small step.|次の小さな一歩を照らす星をどうぞ
轻轻飘一下，肩膀也放松吧|Float a little and relax those shoulders.|ふわりと浮かんで、肩の力も抜こう
把烦恼放进云朵里歇一会儿|Leave your worries in a cloud for a moment.|心配事を雲に預けて、ひと休みしよう
云朵软软的，借你靠一下|A soft little cloud to lean on.|柔らかな雲に、少し寄りかかってね
肚皮弹一弹，烦恼抖掉一点点|A belly bounce to shake a little worry away.|おなかポヨン。心配を少し振り払おう
奶龙陪你，慢慢来也很棒|Nailong’s here. Your own pace is just fine.|ナイロンがそばにいるよ。ゆっくりでも大丈夫
吨吨一下，给今天补点元气|A happy little bounce for a fresh bit of energy.|ぽよんと弾んで、今日の元気を補給
小剑出鞘，替你挡住一点烦恼|A tiny sword to keep a little worry away.|小さな剣で、心配から少し守るよ
收剑站好，陪你稳稳往前走|Sword at rest. Steady steps together.|剣を収めて、一緒に着実に進もう
这一剑，斩掉一点点坏心情|A little sword swing to lift a gloomy mood.|小さなひと振りで、気分を軽くしよう
轻轻靠近，陪你慢慢来|Gently close by, at your own pace.|そっと寄り添って、あなたのペースで
你忙你的，我会乖乖陪着|Do your thing. I’ll be right here.|あなたは自分のことを。ここで待ってるよ
送你一点小小的元气|A tiny boost of energy for you.|小さな元気をあなたに
紧凑卡片 · 280 × 112|Compact card · 280 × 112|コンパクト · 280 × 112
点击查看用量与操作|Click for usage and actions|クリックして使用量と操作を表示
剩余百分之{0}|{0} percent remaining|残り{0}パーセント
每 {0} 秒自动查询，复用本机 Codex CLI 登录。请求慢或限流时顺延；仅查询，不发起对话任务。|Checks about every {0}s using this Mac’s Codex CLI sign-in. Slow requests and rate limits delay the next check. No conversation tasks are started.|この Mac の Codex CLI ログインを使い、約{0}秒ごとに照会します。遅延やレート制限時は間隔を延ばします。会話タスクは作成しません。
剩余 {0}|{0} remaining|残り {0}
上次剩余 {0} · 记录已陈旧|Last remaining {0} · Out of date|前回の残り {0} · 古い記録
上次剩余 {0} · 重置待核对|Last remaining {0} · Reset unverified|前回の残り {0} · リセット要確認
余 {0}%|{0}% left|残り {0}%
最后读取 {0}|Last read {0}|前回の取得 {0}
读于 {0}|Read at {0}|取得時刻 {0}
重置 {0}|Resets {0}|リセット {0}
摸摸{0}|Pet {0}|{0}をなでる
和{0}互动|Play with {0}|{0}と遊ぶ
{0} · {1}|{0} · {1}|{0} · {1}
{0}百分之{1}|{0}, {1} percent|{0} {1}パーセント
已用 {0}%|{0}% used|使用済み {0}%
读取 {0}前|Read {0} ago|{0}前に取得
额度用了 {0}% · 吃一块小饼干|{0}% quota used · A cookie break|利用枠を{0}%使用 · クッキーをひとくち
订阅额度 · {0}|Quota · {0}|利用枠 · {0}
服务端日统计 ·|Service daily total ·|サーバー日次集計 ·
账号累计统计|Account total|アカウント累計
服务端日统计，时区未注明|Service daily total; time zone unspecified|サーバー日次集計。タイムゾーン未指定
保留上次数据|Previous data retained|前回のデータを保持
更新 {0}|Updated {0}|更新 {0}
"""
        return Dictionary(uniqueKeysWithValues: rows.split(separator: "\n").compactMap { row in
            let fields = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { return nil }
            return (fields[0], Translation(en: fields[1], ja: fields[2]))
        })
    }()
}
