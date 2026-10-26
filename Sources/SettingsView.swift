import SwiftUI
import UIKit

/// 设置页:连接参数、黑匣子信息都收在这里,平时主界面干净
struct SettingsView: View {
    @ObservedObject var model: SessionModel
    let worker: SettingsWorker
    @State private var copiedAt = ""

    var body: some View {
        NavigationStack {
            Form {
#if CB08_PROBE
                Section("诊断") {
                    NavigationLink("CB08 设备与 Opus 探测") {
                        CB08ProbeView()
                    }
                }
#endif
                stateSection          // 固定信息(环境 / 身份 / 版本)—— 按用户口径放最上面
                connectionSection     // 固定(可编辑)
                logSection            // 主 App 步骤与一键复制
                crashSection          // 有才显示
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var connectionSection: some View {
        Section {
            TextField("wss://100.64.0.2:7443", text: configurationBinding(.serverURL, value: model.serverURL))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .font(.system(size: 14, design: .monospaced))
            TextField("控制手机", text: configurationBinding(.deviceID, value: model.deviceID))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(model.isRecording)
            TextField("使用者", text: configurationBinding(.userID, value: model.userID))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(model.isRecording)
            SecureField("设备登记凭据", text: configurationBinding(.credential, value: model.deviceToken))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(model.isRecording)
            Button("恢复默认连接参数") { worker.reset() }
            if let reason = worker.lockReason {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(worker.snapshot.problems, id: \.self) { problem in
                Text(problem).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("连接参数")
        }
        .disabled(worker.isLocked)
    }

    private func configurationBinding(_ field: ConfigurationField, value: String) -> Binding<String> {
        Binding(get: { value }, set: { worker.update(field, value: $0) })
    }

    /// 复制走的内容:一眼能看全「这台手机现在是什么状态」
    private var debugBundle: String {
        """
        server=\(model.serverURL)
        identity=\(model.identity)
        LivK=\(model.livekWord)
        录=\(Int(model.recordedSeconds)) 收=\(Int(model.serverSeconds)) 句=\(model.lines.count)
        麦克风模式=\(model.micModeText)(宽谱=\(model.micIsWide))
        version=\(appVersion)
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

    /// 主 App 日志与一键复制。
    private var logSection: some View {
        Section {
            Text("主程序").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if model.notes.isEmpty {
                Text("还没有步骤记录").font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text(model.notesText)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }
            Button {
                UIPasteboard.general.string = debugBundle
                copiedAt = "已复制 \(debugBundle.count) 字符"
            } label: {
                Label("复制排错信息", systemImage: "square.and.arrow.up")
            }
            if !copiedAt.isEmpty {
                Text(copiedAt).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } header: {
            Text("日志")
        }
    }

    // MARK: - 状态段(全固定 → 放设置页最上面)

    private var stateSection: some View {
        Section {
            valueRow("身份", model.identity)
            valueRow("版本", appVersion)
        } header: {
            Text("注册状态")
        }
    }

    /// 值那一列统一款式:等宽小字 + 绿色,与 App Group / 扩展 两行完全一致
    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
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
