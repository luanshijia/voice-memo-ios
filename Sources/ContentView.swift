import SwiftUI
import UIKit

/// 主界面。
/// 顶部一行**五个**按钮(等宽),颜色当指示灯用:
///   网络 = 能不能连上家里(蓝=通 / 灰=不通或没测)
///   宽谱 = 当前麦克风是否宽谱模式(蓝=是 / 灰=否或未授权);点它弹系统「麦克风模式」面板
///   开启 = 录音开关(红=录着)
///   扩展 = 系统直播三态(灰=确定没开播 / 蓝=已开播但没收到系统声 / 红=已收到系统声)
///   设置 = 连接参数、日志排错、黑匣子
/// 中间:三块固定高度 —— 上 1/10 第一遍(蓝,流式)、中 1/2 第二遍定稿(黑)、下 4/10 会中提要
///   (档位按钮 + 状态行 + 要点列表,见 `summaryPanel`)。
/// 最底:一整行状态(未连接 / 网络 断 / 麦克风 … / 录 收 句),贴屏幕底边(`bottomBar`)。
struct ContentView: View {
    @StateObject private var model = SessionModel()
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    // 顶部按钮状态
    @State private var followsLatestFinal = true
    /// 合并后的定稿行。以前是 computed property:status 每秒变两次 → 每 0.5 秒把整场字幕重合并一遍
    /// (两小时会议几千行,单人长文 O(n²) 拼接)。改成只在定稿条数变化时重算。
    @State private var rows: [DisplayRow] = []

    var body: some View {
        // 底部那一行(未连接 / 网络 断 / 麦克风 … / 录 收 句)改成**真正贴屏幕底边**:
        // 以前挂在 safeAreaInset(edge: .bottom) 里,内容被顶在 34 点安全区之上,底边空出一条;
        // 现在整块允许下沉(home 指示条所在那条带),只留 12 点内边距避开指示条本身。
        ZStack(alignment: .bottom) {
            VStack(spacing: 6) {
                buttonRow                   // 顶部五个按钮(状态行搬到屏幕最下方)
                transcript                  // 提要面板已删 → 字幕铺满整屏
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 12)
            .padding(.top, -6)       // 顶排按钮比之前下移 4 点,留出少量呼吸空间
            .padding(.bottom, 26)           // 给贴底的底栏让出高度,别盖住字幕

            bottomBar
        }
        .ignoresSafeArea(edges: .bottom)
        .sheet(isPresented: $showSettings) { SettingsSheet(model: model) }
        .task { await refreshLoop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await model.refreshExt()
                    if !model.broadcastAlive { _ = model.prepareBroadcast() }
                    await model.refreshNet()
                }
            }
        }
        .onChange(of: model.isRecording) { _, active in
            if active { followsLatestFinal = true }
        }
    }

    // MARK: - 顶部五个按钮(一行)

    private var buttonRow: some View {
        HStack(spacing: 6) {
            netButton
            micModeButton
            recordButton
            extButton
            settingsButton
        }
    }

    /// 网络:只有显示功能。点了当场测一次;启动和回到前台也会自动测。
    /// 配色(用户口径 2026-10-15 晚):通 = 实心深蓝(与「宽谱」「开启」同一档);不通/没测 = 灰(与其它按钮关闭态同一档)。
    private var netButton: some View {
        flatButton(icon: model.netOK == true ? "wifi" : "wifi.slash", title: "网络",
                   fill: model.netOK == true ? Color.blue : Color.secondary.opacity(0.25),
                   fg: model.netOK == true ? .white : .primary) {
            Task { await model.refreshNet() }
        }
    }

    /// 宽谱:点它请系统把「麦克风模式」面板弹出来(App 不能替你设,只能叫面板)。
    /// 底色当状态灯:当前是宽谱 = 实心蓝;其它模式 / 未授权 = 灰(用户口径 2026-10-15)。
    private var micModeButton: some View {
        flatButton(icon: "waveform", title: "宽谱",
                   fill: model.micIsWide ? Color.blue : Color.secondary.opacity(0.25),
                   fg: model.micIsWide ? .white : .primary) {
            model.presentMicModePicker()
        }
    }

    /// 开启 / 停止:切换状态
    private var recordButton: some View {
        flatButton(icon: model.isRecording ? "stop.circle.fill" : "record.circle",
                   title: model.isRecording ? "停止" : "开启",
                   fill: model.isRecording ? Color.red : Color.accentColor,
                   fg: .white) {
            model.toggle()
        }
    }

    /// 直播槽:与其余四个按钮**同样的圆角长方形**(高 24、圆角 6、五等分),
    /// 里面放 iOS 原生直播选择器;不再画状态圆 —— 那颗球是 ReplayKit 状态的第二份副本,
    /// 底栏 `RepK` 已有唯一显示位(用户口径 2026-10-19:一个事实一个显示位)。
    /// 也不再需要 offset 硬挪:选择器在 24 高的块里居中即可。
    private var extButton: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.blue)
            BroadcastPickerView()
                .frame(width: 24, height: 24)
                .accessibilityLabel("开始或停止系统声音直播")
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
    }

    /// 设置:配色统一成「宽谱」「开启」那档实心深蓝(用户口径 2026-10-15 晚;以前是浅蓝 0.18)。
    private var settingsButton: some View {
        flatButton(icon: "gearshape", title: "设置",
                   fill: Color.blue, fg: .white) {
            showSettings = true
        }
    }

    /// 第一排五个按钮共用的标签几何。2026-10-16 用户要求:去掉图标、只留文字,
    /// 宽度仍是 5 等分;块高与「自动/手动」统一成 24(比原来的 20 高一点点)。
    /// icon 参数保留但不再使用 —— 为了不改动十几个调用点;要恢复图标只改这一处。
    private func buttonLabel(icon: String, title: String, fg: Color = .primary) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
    }

    /// 自绘的五等分按钮:整块圆角底色、块高统一(与底部档位按钮同高)。
    /// 为什么不用系统 .bordered/.borderedProminent:系统会在内容上下各加一圈内边距,
    /// 「网络/开启/设置」比「扩展」高出一截 —— 一行按钮高低不齐还白占屏幕(用户实测反馈)。
    private func flatButton(icon: String, title: String, fill: Color, fg: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            buttonLabel(icon: icon, title: title, fg: fg)
                .background(RoundedRectangle(cornerRadius: 6).fill(fill))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 屏幕最下方一行(状态 + 三个数)

    /// 一行放完全部:左边状态文字、右边「录 12 收 12 句 3」。
    /// 两处细节(用户口径):① 数字不再压成上下两行;② 底色一路铺到屏幕底边(绕开安全区),
    /// 视觉上就是贴着屏幕圆角底边的一道,而不是浮在中间的一条。
    /// 2026-10-16:整栏已下沉到屏幕底边(ZStack + ignoresSafeArea);左右各留 24 点(避开屏幕圆角吃字)、下方 12 点(避开 home 指示条)。
    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text(model.lastSummary.isEmpty ? model.status : model.lastSummary)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            // 用户定稿(2026-10-18):撤掉「网络/麦克风」—— 它们与两路链接状态重复(颜色太多是信息混杂);
            // 底栏只留两路链路 + 三个数,且两路一律用文字表述、不上色。
            inlineText("LivK", model.livekWord, .secondary)
            inlineText("RepK", model.repkWord, .secondary)
            inlineMetric("录", model.recordedSeconds, .primary)
            inlineMetric("收", model.serverSeconds, .primary)     // 差值判据有缺陷(见待办),先不再用红绿
            inlineMetric("句", Double(model.lines.count), .primary)
        }
        .padding(.horizontal, 24)     // iPhone 屏幕四角是圆角:左右各留 24 点,免得最外侧的字被吃掉
        .padding(.top, 3)
        .padding(.bottom, 12)
        .background(
            Rectangle().fill(.bar).ignoresSafeArea(edges: .bottom)
        )
    }

    /// 「标签 + 短文本」横向排(网络/麦克风这类状态用)
    private func inlineText(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
        }
        .fixedSize()
    }

    /// 「标签 + 数字」横向排(以前是标签一行、数字一行,占两行高度)
    private func inlineMetric(_ label: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value > 0 ? String(format: "%.0f", value) : "—")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .fixedSize()
    }

    /// 转写区。渲染规则(用户口径 2026-10-15):
    ///   ① **同一人接着写** —— 收到 final 不再另起一段,直接接在上一段文字后面;换人才分段
    ///      (这时才断行 + 显示说话人;屏幕上看不到机器身份,自己那一路显示「我」);
    ///   ② 同一人两段之间静音 ≥2.4 秒 → 在文字**中间夹一个 ~**(单个半角,不换行、不空行;超 30 秒带时长);
    ///   ③ 长行**不做任何干预** —— 不提前换行、也不阻止换行,交给手机自己排版。
    /// 本机(agent)的断句/定稿/第二遍逻辑完全不变,这里只是不再把它的内部分段显示成段落。
    /// 转写区(用户口径 2026-10-15 深夜,第二版):**三块固定高度,互不挤压** ——
    ///   上 1/10 = 第一遍(蓝,流式滚动,只露一两行);中 1/2 = 第二遍(黑,定稿带 ~);
    ///   下 4/10 = 实时总结区(占位,目前留空)。
    /// 调整理由:第一遍只是"正在说的"提示,读的是第二遍;把大头留给定稿。
    /// 为什么改:以前整屏一个滚动区,第一遍的字一长就占满全屏,第二遍只剩最后一行。
    private var transcript: some View {
        GeometryReader { geo in
            let usable = max(geo.size.height - 6, 0)      // 扣掉两条分隔线 + 间距
            VStack(spacing: 3) {
                partialPanel.frame(height: usable * 0.1)
                Divider().opacity(0.25)
                finalPanel.frame(height: usable * 0.5)
                Divider().opacity(0.25)
                summaryPanel(width: geo.size.width).frame(height: usable * 0.4)
            }
        }
    }

    /// 第一遍:流式部分自己的滚动区,跟着最新文字滚到底
    private var partialPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.partials) { item in
                        paragraph(who: displayWho(item.who, source: item.source), text: item.text, color: .blue)
                            .id(item.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.partials.map(\.text)) { _, _ in
                guard let last = model.partials.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    /// 第二遍:定稿(带 ~ 停顿记号)自己的滚动区
    private var finalPanel: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(rows) { row in
                            paragraph(who: row.who, text: row.text, color: .primary)
                                .id(row.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { _ in
                    followsLatestFinal = false
                })
                .onChange(of: model.lines.last?.id) { _, _ in
                    rows = buildRows()          // 定稿变多才重算;用最后一条的 id 而不是 count ——
                                                // 到达 4000 条上限后 count 恒定,用 count 会永久冻结(2026-10-18 审计)
                    guard followsLatestFinal, let last = rows.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                .onAppear { if rows.isEmpty { rows = buildRows() } }
                if !followsLatestFinal, let last = rows.last {
                    Button {
                        followsLatestFinal = true
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("回到最新字幕")
                    .padding(6)
                }
            }
        }
    }

    /// 会中滚动提要(方案 v3;界面按用户 2026-10-16 两条反馈改):
    ///   **整排只占一行**:[自动] [手动] + 提示内容(2026-10-19 去掉「状态」二字);
    ///   两个档位按钮 = 纯文字、单行、宽度与第一排按钮严格一致(第一排是 5 等分,这里用同一算法算宽度),
    ///   靠左排;未选中灰、选中同第一排的实心蓝;高度 34 与第一排一致;
    ///   提示过长就地截断(够看出意思即可),不再换行、不再多占一行;
    ///   下面是提要要点列表(空的时候什么都不显示 —— 空态提示与状态行重复,已去掉)。
    /// 语义:没有"到点必出",新增不足 200 字 / 转写质量不足 / 机器忙 → 状态行直接给原因。
    private func summaryPanel(width: CGFloat) -> some View {
        let gap: CGFloat = 6
        let btnW = max(52, (width - gap * 4) / 5)     // 与第一排同算法:5 等分
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: gap) {
                modeButton("自动", on: model.sumMode == "auto", width: btnW) { model.setSumMode("auto") }
                modeButton("手动", on: model.sumMode == "manual", width: btnW) { model.setSumMode("manual") }
                HStack(spacing: 4) {
                    // 用户口径 2026-10-19:去掉「状态」两个字 —— 这行本身就只讲提要状态,标签无意义。
                    Text(model.sumState)
                        .font(.system(size: 10))
                        .foregroundStyle(sumStateColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)   // 显式左对齐:整行不被居中,也不会被挤出边界

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.summaries) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Text(item.clock)
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .leading)
                                Text(item.text)
                                    .font(.system(size: 15))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(item.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .onChange(of: model.summaries.last?.id) { _, _ in
                    guard let last = model.summaries.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// 档位按钮:纯文字单行、**矮块**(用户 2026-10-16 要求:高度压到第一排按钮的 50~60%,
    /// 与第一排按钮**同高**),块高 24、圆角 6;宽度仍与第一排同算法(5 等分)。
    private func modeButton(_ title: String, on: Bool, width: CGFloat,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(on ? .white : .primary)
                .frame(width: width, height: 24)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(on ? Color.blue : Color.secondary.opacity(0.25)))
        }
        .buttonStyle(.plain)
    }

    /// 状态行配色:灰 = 等(周期未到/内容不足)、橙 = 机器忙或转写质量不足、蓝 = 正在生成。
    private var sumStateColor: Color {
        switch model.sumCode {
        case "go": return .blue
        case "quality", "busy_prev", "busy_refine", "busy_vram", "busy_cpu": return .orange
        default: return .secondary
        }
    }

    // MARK: - 转写渲染(分人 / 停顿 / 超长换行)

    /// 界面上的一段转写。**同一个说话人的连续定稿会长在同一段里**(text 会一直往后追加),
    /// 只有换人才起新的一段。停顿记号 ~ 直接夹在 text 中间。
    private struct DisplayRow: Identifiable {
        let id: String
        let who: String        // 空 = 同一人接着说,不重复显示说话人
        var text: String       // 随这个人的后续定稿继续往后长
    }

    /// 静音超过这么久,才在同一人的两段之间夹一个 ~(沿用家里断句阈值 2.4 秒)
    private static let gapThreshold: Double = 2.4

    private func buildRows() -> [DisplayRow] {
        var out: [DisplayRow] = []
        var prevWho = ""
        for (idx, line) in model.lines.enumerated() {
            let speakerKey = "\(line.source)|\(line.who)"
            let sameSpeaker = (speakerKey == prevWho)
            if sameSpeaker, !out.isEmpty {
                // 同一人:接着上一段往后写;中间停顿 ≥2.4 秒就夹一个 ~(不换行)
                if let gap = line.gap, gap >= Self.gapThreshold {
                    out[out.count - 1].text += " " + Self.gapLabel(gap)
                }
                out[out.count - 1].text += line.text
            } else {
                // 换人:起新的一段,并显示说话人
                out.append(DisplayRow(id: "line-\(idx)",
                                      who: displayWho(line.who, source: line.source), text: line.text))
            }
            prevWho = speakerKey
        }
        return out
    }

    /// 身份标签(用户口径 2026-10-15 晚:**自己那一路不再显示任何标签** ——
    /// 以前显示「我」或机器身份,没有实际用途和意义,已去掉)。
    /// 「对方」保留:线上会议时它是唯一能区分两个人的东西,去掉就分不清谁说的。
    private func displayWho(_ who: String, source: String) -> String {
        if source == model.identity { return "本地1" }
        if source.hasSuffix("-livekit") { return "现场·\(who)" }
        if source.hasSuffix("-replaykit") { return "在线1" }
        return source.isEmpty ? who : "\(source)·\(who)"
    }

    /// 停顿记号(用户口径 2026-10-15:三个 ~~~ 改成**一个半角 ~**):超过 30 秒带上时长。
    private static func gapLabel(_ seconds: Double) -> String {
        guard seconds >= 30 else { return "~" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return s == 0 ? "~ \(m)分钟" : "~ \(m)分\(s)秒"
    }

    private func paragraph(who: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !who.isEmpty {
                Text(who).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            // 字号 15(用户口径 2026-10-15:调小 2 号);长行不干预,交给手机自己排版
            Text(text)
                .font(.system(size: 15))
                .lineSpacing(6)
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 刷新

    private func refreshLoop() async {
        await model.refreshExt()
        if !model.broadcastAlive { _ = model.prepareBroadcast() }
        await model.refreshNet()
        model.refreshMicMode()
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)   // 每 3 秒看一次扩展状态 + 麦克风模式
            await model.refreshExt()
            // 扩展到点就把 token 文件读走并删掉:一发现"没在播"必须立刻补写。
            // 以前只在 tick % 100(300 秒)补,于是"按停→从系统选择器重开"这段窗口里必哑(配置缺失)。
            if !model.broadcastAlive { _ = model.prepareBroadcast() }
            if tick % 100 == 0 { _ = model.prepareBroadcast() }  // 长直播:保持随时有一份未过期的 token
            model.refreshMicMode()
            tick += 1
            if tick % 5 == 0 { await model.refreshNet() }        // 每 15 秒顺手探一次网络
        }
    }
}

/// 设置页:连接参数、黑匣子信息都收在这里,平时主界面干净
struct SettingsSheet: View {
    @ObservedObject var model: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var copiedAt = ""

    var body: some View {
        NavigationStack {
            Form {
                stateSection          // 固定信息(环境 / 身份 / 版本)—— 按用户口径放最上面
                connectionSection     // 固定(可编辑)
                copySection           // 固定(一个按钮)
                ExtLogSection()       // 会长/要滚的全部集中在下面
                stepsSection
                crashSection          // 有才显示
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private var connectionSection: some View {
        Section {
            TextField("wss://100.64.0.2:7443", text: $model.serverURL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .font(.system(size: 14, design: .monospaced))
            Button("恢复默认连接参数") { model.resetToDefaults() }
        } header: {
            Text("连接参数")
        } footer: {
            Text("地址填家里的 TLS 代理 wss://100.64.0.2:7443。App 不再保存 key/secret:每次连接前向家里要一张 15 分钟的门禁卡(取不到会在状态栏报错)。")
        }
    }

    /// 排错:一个按钮把「连接参数 + 状态 + 环境 + 扩展日志」一次复制走。
    /// (以前是两个按钮——「复制探针日志」与「复制全套排错信息」,信息还重叠,已并成一个。)
    private var copySection: some View {
        Section {
            Button {
                UIPasteboard.general.string = debugBundle
                copiedAt = "已复制 \(debugBundle.count) 字符(连接参数 + 状态 + 环境 + 扩展日志)"
            } label: {
                Label("复制排错信息", systemImage: "square.and.arrow.up")
            }
            if !copiedAt.isEmpty {
                Text(copiedAt).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } header: {
            Text("排错")
        } footer: {
            Text("顺序:①「网络」按钮看路通不通;②「扩展」按钮启动系统声音采集(灰/蓝/红三态);③点这里复制,贴回来给我。")
        }
    }

    /// 复制走的内容:一眼能看全「这台手机现在是什么状态」
    private var debugBundle: String {
        """
        server=\(model.serverURL)
        identity=\(model.identity)
        status=\(model.status)
        录=\(Int(model.recordedSeconds)) 收=\(Int(model.serverSeconds)) 句=\(model.lines.count)
        麦克风模式=\(model.micModeText)(宽谱=\(model.micIsWide))
        App Group=\(BroadcastProbe.groupName())
        扩展=\(BroadcastProbe.extensionBundleID)
        version=\(appVersion)

        \(BroadcastProbe.fullLogText())
        """
    }

    @ViewBuilder private var crashSection: some View {
        if let crash = CrashLog.previousCrashFile {
            Section("上次异常(黑匣子文件)") {
                Text(crash).font(.system(size: 11, design: .monospaced))
                Button("清空黑匣子") { CrashLog.clear() }
            }
        } else if let failed = CrashLog.lastFailure {
            Section("上次异常") {
                Text(failed).font(.system(size: 11, design: .monospaced))
                Button("清空黑匣子") { CrashLog.clear() }
            }
        }
    }

    @ViewBuilder private var stepsSection: some View {
        if !model.notes.isEmpty {
            Section("最近步骤") {
                Text(model.notesText).font(.system(size: 10, design: .monospaced))
            }
        }
    }

    // MARK: - 状态段(全固定 → 放设置页最上面)

    private var stateSection: some View {
        Section {
            AppGroupRow()
            ExtensionRow()
            valueRow("身份", model.identity)
            valueRow("版本", appVersion)
        } header: {
            Text("状态")
        }
    }

    /// 值那一列统一款式:等宽小字 + 绿色,与 App Group / 扩展 两行完全一致
    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.green)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.middle)
        }
    }

    /// 版本从包里读真值(以前写死 "build 12",排查时会误导)
    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(v) · build \(b)"
    }
}

#Preview {
    ContentView()
}
