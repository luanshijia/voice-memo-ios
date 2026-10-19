# VoiceMemo iOS

VoiceMemo iOS 是会议录音客户端。主 App 采集麦克风音频；用户可手动启动 ReplayKit 广播扩展采集符合 iOS 录制规则的系统播放音频。两路分别加入家里的 LiveKit 房间，电脑端负责识别、归档与会后纪要。

音频和转写数据发往用户自己的 Windows 主机。App 源码不包含 LiveKit 长期 key/secret；连接前通过 TLS 代理 `/token` 获取短期票据。字段与场次规则以 [`../notes/契约-App与电脑端.md`](../notes/契约-App与电脑端.md) 为准。

## 当前代码基线

- 2026-10-19 源码 tag：`v0.9.16`，build `81`。
- 主界面：五个顶部控制按钮、第一遍/定稿字幕、会中提要面板（自动/手动档位、状态和要点）及底部状态栏。
- 收包端按消息类型校验必填字段和类型；schema 整数采用跨端安全范围，`summary.clock` 只接受 ASCII `HH:mm`。
- tag 或 CI 编译成功都不能代替真机运行验收。当前包和 CI 状态以 GitHub Actions 实际结果为准。

## 目录

| 路径 | 内容 |
|---|---|
| `project.yml` | XcodeGen 工程定义及两个 target 的版本号单一来源 |
| `Sources/ContentView.swift` | 主界面与字幕显示 |
| `Sources/SessionModel.swift` | 会话状态、消息分发与诊断 |
| `Sources/VoiceRoom.swift` | LiveKit 连接和消息收发校验 |
| `Sources/LiveKitConfig.swift` | 配置、短期 token 请求、App Group 广播卡 |
| `Broadcast/` | ReplayKit 广播扩展 |
| `Sources/NetProbe.swift`、`Sources/BroadcastProbe.swift` | 网络与扩展诊断 |

## 构建与安装

本机 Windows 环境没有 Xcode/Swift 工具链，IPA 通过 GitHub Actions 的 macOS runner 构建。版本号只改 `project.yml` 中两个 target 的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`，提交并推送后由 Actions 构建；不要手改生成的 Xcode 工程。

服务端仓库内的 `tools/ops/vm-watch-ci37.sh` 可盯 CI、下载和检查 IPA。CI 产物未签名，安装时由 SideStore 在设备侧签名。装包后如需验收网络、收包、音频来源和长时间录音，必须在实际 iPhone 上进行；CI 只能证明指定提交通过了云端编译与打包步骤。

## 当前界面与音频限制

- 「录屏」按钮启动系统 ReplayKit 选择器，不会保存屏幕视频；用户必须在系统面板中手动开始。
- ReplayKit 能否采到某个 App 的播放声由 iOS 和来源 App 决定。VoIP 通话可能只产生静音，不能把扩展已连接当作对方声音已采到。
- 会中提要由电脑端生成并通过共同契约发送，App 在字幕区下方显示状态和要点；会后完整纪要仍在电脑端生成并保存。
