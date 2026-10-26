# VoiceMemo iOS

VoiceMemo iOS 是会议录音客户端。主 App 采集麦克风音频；用户可手动启动 ReplayKit 广播扩展采集符合 iOS 录制规则的系统播放音频。两路分别加入家里的 LiveKit 房间，电脑端负责识别、归档与会后纪要。

音频和转写数据发往用户自己的 Windows 主机。App 源码不包含 LiveKit 长期 key/secret；已登记设备经 TLS 代理 `/v1/meetings/start` 申请电脑端签发的会议号和短期票据。实时消息与会议控制的正本分别在电脑端仓库的 `contracts/wire-v2.json`、`contracts/session-control-v1.json`。

## 当前代码基线

- 当前待编译源码版本：`0.9.20 / build 89`。实时消息校验器与控制接口常量分别由电脑端 `wire-v2.json`、`session-control-v1.json` 生成；本轮源码尚未通过 Mac CI 或真机检查。
- 最近一个已核验 IPA：build 86，GitHub Actions `39196411913`，源码提交 `7237250`；产物 `dist/ci-build86-wire-contract/VoiceMemo-unsigned-ipa/VoiceMemo-unsigned.ipa`，SHA-256：`A061201E93EE1E30809ED7C5FCC3FEA0682F7C413429F7C1A00480CBEC8A1494`。主 App 与 ReplayKit 扩展均为 `0.9.18 / 86`。这是编译与打包验证，不是设备安装或真机验收。
- build 88 的 Mac CI 曾编译成功，但不验证本轮 build 89 源码；用户已将打包交给 Hermes，本轮不下载 IPA。所有 V2 正式设备项目仍为“待检测”。
- 当前主界面：五个顶部控制按钮、第一遍/定稿字幕、会中提要面板（档位、状态和要点）及底部状态栏。
- 收包端按消息类型校验必填字段和类型；schema 整数采用跨端安全范围，`summary.clock` 只接受 ASCII `HH:mm`。
- tag 或 CI 编译成功都不能代替真机运行验收。当前包和 CI 状态以 GitHub Actions 实际结果为准。

## 目录

| 路径 | 内容 |
|---|---|
| `project.yml` | XcodeGen 工程定义及App版本号单一来源 |
| `Sources/ContentView.swift` | 主界面与字幕显示 |
| `Sources/SessionModel.swift` | 会议工人状态的界面投影 |
| `Sources/VoiceRoom.swift` | LiveKit 连接和消息收发校验 |
| `Sources/LiveKitConfig.swift` | 配置、短期 token 请求、App Group 广播卡 |
| `Broadcast/` | 留档的旧广播源码，退出全部构建目标 |
| `Sources/NetProbe.swift`、`Sources/BroadcastProbe.swift` | 网络与扩展诊断 |

## 构建与安装

本机 Windows 环境没有 Xcode/Swift 工具链，IPA 通过 GitHub Actions 的 macOS runner 构建。版本号只改 `project.yml` 中App的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`，提交并推送后由 Actions 构建；不要手改生成的 Xcode 工程。

服务端仓库内的 `tools/ops/vm-watch-ci37.sh` 可盯 CI、下载和检查 IPA。CI 产物未签名，安装时由 SideStore 在设备侧签名。装包后如需验收网络、收包、音频来源和长时间录音，必须在实际 iPhone 上进行；CI 只能证明指定提交通过了云端编译与打包步骤。

## CB08架构升级候选

当前源码分为设置、输入、连接、会议四页；会议管家助手统一调度 SettingsWorker、InputWorker、ConnectionWorker、MeetingWorker。SessionModel仅保留界面读取投影。电脑端会议管家签发会议号、动作修订号和分段绑定。

- 手机面对面使用原生麦克风，身份为 `device-livekit`。
- CB08面对面/通话使用独立 `external_audio` 通道和 `device-external` 身份，BLE Opus解码为16kHz单声道PCM后交给LiveKit手动音频模式。手机麦克风不作为这条路线的输入。
- UI当前只允许一个主要输入；暂停确认后可选择另一输入，继续时保留会议号并创建新段。
- 连接、选中输入、提交PCM、电脑识别是不同事实，界面分别显示。开始/暂停/继续/结束只在会议页；外设控制台负责扫描、连接和设备信息。
- CB08下推为普通面对面，上推为通话。场景tag只是记录，不能替用户切换实体拨杆。通话贴附手机并使用听筒；AirPods路线目前无支持证据。
- ReplayKit扩展已退出构建。Broadcast目录及旧适配源码按批准留档，不进入任何新包；历史来源记录继续可读。
- `Shared/SessionControlV2.generated.swift` 和 `Contracts/` 是电脑端机器契约生成快照，不直接手改。

候选实现/云端构建通过不等于已部署或真机验收。精确版本、IPA摘要、CI与现场状态只在电脑端 `notes/STATE.md` 维护。正式启用V2手机前，电脑端需在维护窗口切换同版V2 API；不要把新App对旧运行进程的失败当作CB08蓝牙失败。

CB08回调帧边界、真实音频时长、电话后台、设备键交叉控制、两路各2小时录音仍需真机验收。App没有新增本地回放页；声音内容以电脑端原始WAV及转写核对。
