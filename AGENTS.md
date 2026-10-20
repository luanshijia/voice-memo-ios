# AGENTS.md — VoiceMemo iOS 客户端(app-ios)

> 本文件给在**本目录**工作的编码代理(Codex / Claude Code / Hermes)。**先读本文件**。
> 家里服务端与工具在**另一个仓库**(上级目录 `..`,即 `voice-memo` 项目根,那里也有一份 AGENTS.md);
> 本仓库只放 iOS 客户端。两边各自独立提交、独立版本。

## 这是什么

录音与实时字幕客户端:从麦克风(或 ReplayKit 广播扩展采到的"对方声音")取音频 →
经 `wss://<家里地址>:7443`(TLS 代理)推到家里的 LiveKit → 实时接收家里的定稿文字并显示。
**App 不做识别、不做纪要**,识别与会后处理全在家里那台 Windows 上完成。

## 工程结构(单一真相源 = `project.yml`)

| 文件 | 作用 |
|---|---|
| `project.yml` | XcodeGen 工程定义。**版本号四处全在这一个文件**:两个 target 各自的 `CFBundleShortVersionString` / `CFBundleVersion` |
| `Sources/ContentView.swift` | 当前主界面:顶部 5 个按钮、第一遍/定稿字幕、会中提要面板与贴底状态栏 |
| `Sources/SessionModel.swift` | 会话与状态模型:连接、计时、`summode` 上行、服务端消息分发与字段诊断 |
| `Sources/VoiceRoom.swift` | LiveKit 连接与数据通道;收包按契约校验版本、必填字段、类型及范围,错误消息记诊断后丢弃 |
| `Sources/LiveKitConfig.swift`、`Shared/MeetingControlClient.swift` | 设备登记信息、会议申请、短期票据、停止与报告回执；会议 UUID 由电脑端签发 |
| `Shared/SessionControl.generated.swift` | 从电脑端 `contracts/session-control-v1.json` 生成的控制路径与通道常量，不手改 |
| `Broadcast/` | ReplayKit 广播扩展，独立申请系统声音通道并加入电脑端当前会议 |
| `Sources/NetProbe.swift`、`Sources/BroadcastProbe.swift` | 网络、App Group 与广播扩展状态探针 |

## 怎么出包(唯一路径:CI)

```bash
# 1) 改版本号:project.yml 里四处(两个 target 各两处)
# 2) 按本轮实际改动列出显式路径提交；只有用户授权本次出包时才推送
git add -- project.yml Sources/SessionModel.swift Shared/MeetingControlClient.swift
git commit -m "..."
# 3) 获出包授权后推送，再由 GitHub Actions xcodegen + xcodebuild archive → 未签名 IPA
git push
# 4) 盯 CI 并把包取到桌面(脚本在服务端仓库)
bash ../tools/ops/vm-watch-ci37.sh <run-id> <标签> <桌面文件名>
```

- 本机**没有 Xcode / Swift 工具链** → **不要在本机尝试编译或跑测试**;编译错误只能靠 CI 暴露(每次约 2~4 分钟,runner 忙时要排队)。
- 本仓库是 **public**;CI 产物是**未签名** IPA,装机走 SideStore 侧载。

## 红线

- **不做识别、不做纪要**:App 只负责采集、推流、显示。
- **主链路(推流 / 字幕 / 断线重连 / 数据协议)的改动要先给方案、经批准再动手**;改完必须真机验证,CI 通过 ≠ 能用。
- **不要把真密钥写进源码**：App 保存本机设备凭据，经 TLS 代理 `/v1/meetings/start` 请求短期票据；LiveKit 长期凭据只存在电脑端 `secrets/livekit.json`。
- **共同契约**：实时消息以电脑端 `contracts/wire-v2.json` 为正本，会议控制以 `contracts/session-control-v1.json` 为正本；Swift 生成文件由电脑端工具生成并经离线门禁核对。`sumstatus.code` 刻意由 App 前向兼容,未知码不能整条丢弃。
- **界面几何保持一致**:同一排按钮等高同圆角;改文案不要连带改版式。
- 版本号只改 `project.yml`,不要手改生成出来的 `.xcodeproj`。

## 审查时重点看什么

1. `SessionModel` 的 `onTranscript` 分支是否覆盖服务端所有 `type` —— 历史上"所有非 `final` 的都当 partial",会中提要消息踩过这个坑;
2. 断线重连与「录 / 收」两个计数器的一致性(传输落后 >5 秒要变红);
3. `VoiceRoom` 数据通道:可靠发送 + topic;上行消息是否带序号(防重复/乱序);
4. 广播扩展的生命周期与 App Group 共享(`group.com.luanshijia.voicememo`),扩展不能写坏主 App 的共享文件;
5. 有没有把密钥 / 证书 / 大件提交进仓库。

## 已知坑(踩过,别再踩)

- iOS **图标缓存**:换图标后覆盖安装可能仍显示旧图标 → 删 App 重装或重启手机;
- 免费自签 **7 天有效**,装机走 SideStore;设置页 "App Group" 行是否变绿可判断广播扩展是否接通;
- 点「停止」那声「嘟」与橙色指示灯**关不掉**(iOS 限制,Apple 官方口径);
- 同一身份重复连接会被服务端按 `DUPLICATE_IDENTITY` 踢掉 → "停止后立即开始"要等上一次断开落地;
- `gh run download` 的产物解压路径是**相对当前目录** → 脚本里必须先 `cd` 到目标目录,否则静默取不到包。
