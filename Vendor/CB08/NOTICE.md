# CB08 iOS SDK binary notice

- Upstream: https://github.com/SonicloudTech/sonicloud_opensdk
- Pinned commit: `f10cd9bf2a2341566d923818602ac93fb9246091`
- Files: `PNode.h`, `libPNote.a`
- SHA-256 `PNode.h`: `79FA55C3F7BC0C14648444F3A1A0E6C21B58CA3608BE123A9347FA18B158FF8B`
- SHA-256 `libPNote.a`: `7B969C287AE056988455A26DABE35E97A2A4FFC0F4F8937E056884E80AE5565A`
- Binary size: 1,206,824 bytes. Upstream inspection reports arm64 iOS device objects; no simulator slice.

The repository README states that its MIT notice does not automatically apply to the prebuilt static library. The project owner reports written vendor permission covering this public app-ios repository, public GitHub Actions builds, and test IPA distribution (2026-10-25). The permission document itself is not stored here; this notice records the reported scope and does not extend it.

Do not log or commit device recordings, identifiers, tokens, or other private device data. Keep SDK diagnostics limited to event names, status codes, packet sizes, and aggregate counters.
