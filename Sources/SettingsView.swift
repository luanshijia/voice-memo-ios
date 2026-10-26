import SwiftUI

/// 设置页:连接参数、黑匣子信息都收在这里,平时主界面干净
struct SettingsView: View {
    @ObservedObject var model: SessionModel
    let worker: SettingsWorker

    var body: some View {
        NavigationStack {
            Form {
                stateSection          // 固定信息(环境 / 身份 / 版本)—— 按用户口径放最上面
                connectionSection     // 固定(可编辑)
                logSection            // 状态与步骤使用同一份可复制文本
                crashSection          // 有才显示
            }
            .font(.body)
        }
    }

    private var connectionSection: some View {
        Section {
            TextField("wss://100.64.0.2:7443", text: configurationBinding(.serverURL, value: model.serverURL))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
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
            if let reason = worker.lockReason {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("连接参数")
        }
        .disabled(worker.isLocked)
    }

    private func configurationBinding(_ field: ConfigurationField, value: String) -> Binding<String> {
        Binding(get: { value }, set: { worker.update(field, value: $0) })
    }

    /// 显示与复制使用同一份状态摘要和步骤日志，不包含登记凭据。
    private var logText: String {
        """
        版本：\(appVersion)
        电脑入口：\(model.serverURL)
        身份：\(model.identity)
        媒体连接：\(model.livekWord)
        采集计时：\(Int(model.recordedSeconds)) 秒
        已识别音频：\(Int(model.serverSeconds)) 秒
        字幕条数：\(model.lines.count)

        \(model.notesText.isEmpty ? "暂无日志" : model.notesText)
        """
    }

    @ViewBuilder private var crashSection: some View {
        if let crash = CrashLog.previousCrashFile {
            Section("上次异常(黑匣子文件)") {
                Text(crash).font(.footnote.monospaced()).textSelection(.enabled)
                Button("清空黑匣子") { CrashLog.clear() }
            }
        } else if let failed = CrashLog.lastFailure {
            Section("上次异常") {
                Text(failed).font(.footnote.monospaced()).textSelection(.enabled)
                Button("清空黑匣子") { CrashLog.clear() }
            }
        }
    }

    /// 长按文本使用系统选择与复制。
    private var logSection: some View {
        Section {
            Text(logText)
                .font(.footnote.monospaced())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
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

    /// 字段左对齐，值右对齐；静态信息不使用成功状态色。
    private func valueRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    /// 版本从包里读真值(以前写死 "build 12",排查时会误导)
    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(v) · build \(b)"
    }
}
