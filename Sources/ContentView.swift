import SwiftUI

/// 主界面。
/// 顶部一行**五个**按钮(等宽),颜色当指示灯用:
///   代理 = XEdge 点到点链路能否到达家里 TLS 入口(蓝=通 / 灰=不通或没测)
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

    var body: some View {
        // 底部那一行(未连接 / 网络 断 / 麦克风 … / 录 收 句)改成**真正贴屏幕底边**:
        // 以前挂在 safeAreaInset(edge: .bottom) 里,内容被顶在 34 点安全区之上,底边空出一条;
        // 现在整块允许下沉(home 指示条所在那条带),只留 12 点内边距避开指示条本身。
        ZStack(alignment: .bottom) {
            VStack(spacing: 6) {
                buttonRow                   // 顶部五个按钮(状态行搬到屏幕最下方)
                transcript // 字幕与会中提要区域
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 12)
            .padding(.top, -6)       // 顶排按钮比之前下移 4 点,留出少量呼吸空间
            .padding(.bottom, 26)           // 给贴底的底栏让出高度,别盖住字幕

            bottomBar
        }
        .ignoresSafeArea(edges: .bottom)
        .sheet(isPresented: $showSettings) { SettingsView(model: model) }
        .task { await model.refreshForegroundStateLoop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await model.refreshExt()
                    await model.refreshNet()
                    // 回前台立刻补一次:后台期间漏掉的定稿在这一步补齐(seq 去重,不会重复上屏)
                    await model.catchUpNow()
                }
            }
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

    /// 代理:检测 XEdge 提供的点到点链路是否能到达家里的 TLS 入口。
    /// 点了当场重测;启动和回到前台也会自动测。
    /// 配色(用户口径 2026-10-15 晚):通 = 实心深蓝(与「宽谱」「开启」同一档);不通/没测 = 灰(与其它按钮关闭态同一档)。
    private var netButton: some View {
        flatButton(icon: model.netOK == true ? "wifi" : "wifi.slash", title: "代理",
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

    /// 开启 / 重连 / 停止:同一颗按钮,四态。
    ///   · 正在采 → 红「停止」
    ///   · 断联岔路 + 网络可用 → 蓝「重连」(点它带原号接回)
    ///   · 断联岔路 + 网络不可用 → **灰「重连」且不可点**(发不出去就别亮着)
    ///   · 其余 → 蓝「开启」,不带号;总管按自己的裁决并回旧会或新建一场
    /// 判断全部来自管家助手,这里只做文案与可点性。
    private var recordButton: some View {
        let state = model.presentation.primaryAction
        return flatButton(icon: state.icon,
                          title: state.title,
                          fill: color(for: state.tone),
                          fg: state.tone == .muted ? .primary : .white,
                          enabled: state.enabled,
                          hint: state.hint) {
            model.toggle()
        }
    }

    private func color(for tone: SessionPresentation.Tone) -> Color {
        switch tone {
        case .accent: return .accentColor
        case .stop: return .red
        case .muted: return Color.secondary.opacity(0.25)
        }
    }

    /// 直播槽:与其余四个按钮**同样的圆角长方形**(高 24、圆角 6、五等分),
    /// 里面放 iOS 原生直播选择器;不再画状态圆 —— 那颗球是 ReplayKit 状态的第二份副本,
    /// 底栏 `RepK` 已有唯一显示位(用户口径 2026-10-19:一个事实一个显示位)。
    /// 也不再需要 offset 硬挪:选择器在 24 高的块里居中即可。
    private var extButton: some View {
        ZStack {
            // 按历史 build 23 的结构：系统 picker 放底层，仅作程序触发器。
            BroadcastPickerView()
                .frame(width: 44, height: 44)
                .opacity(0.01)
                .accessibilityHidden(true)
            Button {
                BroadcastPickerTrigger.open()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(extFill)
                    Text("录屏")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(extFg)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("开始或停止系统声音直播")
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
    }

    /// 录屏按钮的底色 = ReplayKit 那一路的状态灯(沿用旧 extStatusColor 的四色口径)。
    /// 数据源是 `board.replaykit.observed`(站 5 已删掉重复的 broadcastPhase),视图里不另算状态。
    private var extFill: Color {
        switch model.board.replaykit.observed {
        case .notStarted, .unknown:      return Color.secondary.opacity(0.25)   // 没开 / 看不出来
        case .connecting, .reconnecting: return Color.blue                       // 已启动,等系统声
        case .connected:                 return Color.red                        // 正在收到系统声
        case .disconnected:              return Color.orange                     // 异常/中断
        }
    }

    /// 灰底上用主色文字,其它底色用白字(与「代理」「宽谱」两个按钮的规律一致)。
    private var extFg: Color {
        switch model.board.replaykit.observed {
        case .notStarted, .unknown: return Color.primary
        default:                    return Color.white
        }
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
                            enabled: Bool = true, hint: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            buttonLabel(icon: icon, title: title, fg: fg)
                .background(RoundedRectangle(cornerRadius: 6).fill(fill))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityHint(Text(hint ?? ""))
    }

    // MARK: - 屏幕最下方一行(会议状态 · 连接状态 · 主动终止)

    /// 底栏只放「必需显示」那一层(判据:看不到它会不会做错动作)。
    ///   · 会议状态 = 电脑端总管 meeting.status 的别名,六个词;
    ///   · 连接状态 = 两路 channel.status 的别名,五个词;看不到就不知道哪一路还活着;
    ///   · 主动终止 = 用户主动结束这场会。它的含义固定:**不想要这个 room 号了、
    ///     会议清盘结束,但录音和后续纪要照常要**。所以它做三件事:把两路在电脑端
    ///     停干净(会议照常收尾出纪要)、清本机会议号、让下一次「开启」从新 UUID 开始。
    ///     接回原会议**不在这里**:顶部「开启」带缓存会议号,断线后点它就是重连。
    /// 原来的「录 收 句」三个数按用户口径撤掉:它们不影响任何动作。
    /// 左右各留 24 点(避开屏幕圆角)、下方 12 点(避开 home 指示条),几何与上一版一致。
    private var bottomBar: some View {
        HStack(spacing: 6) {
            inlineText(AppSharedContract.meetingLabel, model.meetingContext.meetingAlias, .secondary)
            Text("·").font(.system(size: 10)).foregroundStyle(.secondary)
            inlineText(AppSharedContract.channelLabel, micWord, .secondary)
            inlineText("", sysWord, .secondary)
            Spacer(minLength: 6)
            // 断联岔路(B 岔路):想继续、但本机没在采、总管还记着这场会。
            // 发不出去时它仍是半透明蓝(这条路只剩它),但点不动;网络回来才实心可点。
            let state = model.presentation.terminateAction
            connectButton("主动终止",
                          enabled: state.enabled,
                          pending: state.pending,
                          hint: state.hint) {
                model.terminateMeeting()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 3)
        .padding(.bottom, 12)
        .background(
            Rectangle().fill(.bar).ignoresSafeArea(edges: .bottom)
        )
    }

    /// 麦 / 声 两路的当前状态词。左=麦克风,右=系统声音,与总管 channel 枚举一一对应。
    private var micWord: String {
        let short = AppSharedContract.channelShort[SessionControlContract.mic] ?? "麦"
        return "\(short) \(model.meetingContext.channelAlias(model.meetingContext.mic))"
    }

    private var sysWord: String {
        let short = AppSharedContract.channelShort[SessionControlContract.systemAudio] ?? "声"
        return "\(short) \(model.meetingContext.channelAlias(model.meetingContext.systemAudio))"
    }

    /// 底栏小按钮:与顶部按钮同一套圆角与高度,不可点时变灰且不响应点击。
    /// 宽度 56 = 四个 10pt 字 + 两侧余量(原来的 44 只够两个字,四个字会被挤掉)。
    private func connectButton(_ title: String, enabled: Bool, pending: Bool = false,
                               hint: String? = nil,
                               action: @escaping () -> Void) -> some View {
        // 三种底色：可点 = 实心蓝；在路上但发不出去 = 半透明蓝(用户口径:这个动作此刻属于这条路,
        // 但网络没回来前点不动)；与这条路无关 = 灰。
        let fill: Color = enabled ? Color.accentColor
            : (pending ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.25))
        let fg: Color = (enabled || pending) ? Color.white : Color.primary
        return Button(action: { if enabled { action() } }) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(fg)
                .frame(width: 56, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(fill))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        // 电脑端只做事后拒绝(409 + 错误码),没有事前原因;不可点的理由由
        // 管家助手翻成人话挂在这里,不占底栏位置。
        .accessibilityHint(Text(hint ?? ""))
    }

    /// 「标签 + 短文本」横向排(网络/麦克风这类状态用)
    private func inlineText(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
        }
        .fixedSize()
    }

    private var transcript: some View {
        TranscriptView(partials: model.partials,
                       lines: model.lines,
                       localIdentity: model.identity,
                       isRecording: model.isRecording) { width in
            summaryPanel(width: width)
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
}

#Preview {
    ContentView()
}
