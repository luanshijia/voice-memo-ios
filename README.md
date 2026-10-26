# VoiceMemo iOS

手机负责采集、推流和文字显示，用户自己的Windows主机负责识别、录音归档与会后纪要。主App由统一管家助手调度四个业务工人，当前候选支持iPhone麦克风与独立CB08输入。ReplayKit扩展退出新构建。

电脑端机器正本：实时消息contracts/wire-v2.json，分段采集会控contracts/session-control-v2.json，输入清单contracts/input-manifest-v1.json；V1保留旧手机请求的兼容对账。App不包含LiveKit长期key/secret，登记设备经TLS代理取得短期票据。

当前版本唯一来源为project.yml，精确提交、CI、IPA与真机验收只在电脑端notes/STATE.md维护。历史构建不代表当前候选通过；CI与实机/生产分开验收。

## 目录

| 路径 | 内容 |
|---|---|
| `project.yml` | XcodeGen 工程定义及App版本号单一来源 |
| `Sources/ContentView.swift` | 主界面与字幕显示 |
| `Sources/SessionModel.swift` | 会议工人状态的界面投影 |
| `Sources/VoiceRoom.swift` | LiveKit 连接和消息收发校验 |
| `Sources/Business/` | 设置、输入、连接、会议状态及动作所有者 |
| `Shared/MeetingClient.swift` | V2持久请求、电脑授权、报告保存回执 |
| `Sources/Inputs/` | 手机/CB08设备适配、Opus解码 |
| `Broadcast/` | 留档的旧广播源码，退出全部构建目标 |
| `Sources/NetProbe.swift` | 网络入口探测 |

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
