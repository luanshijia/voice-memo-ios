import Foundation

/// 扩展写、主 App 读的结构化观测行。
///
/// 格式正本: `contracts/app-shared-v1.json#observation`。一行形如
///     `<ISO8601> obs v=1 gen=3 meeting=<uuid> state=active reason=disconnected audio_app=1200`
/// 主 App 的状态判定只认这一行;中文日志行留给人。两进程唯一的共同介质是 App Group
/// 里的这个文件,所以格式必须是机器可读、带版本、可拒绝的。
enum SharedObservation {
    struct Parsed: Equatable {
        /// 与电脑端总管同名的通道状态,见 `AppSharedContract.ChannelState`。
        let state: AppSharedContract.ChannelState
        /// 授权到手后才有;缺省表示还没拿到代次,读方不得当成有效代次。
        let generation: Int?
        let meetingID: String?
        /// 原因码,句子在显示层。未认识的码按最保守的原因显示。
        let reason: String?
        /// 累计送入的系统声样本数,替代对中文计数行的解析。
        let audioApp: Int
        let at: Date
    }

    /// 不是观测行、版本不认识、状态词不认识 —— 一律返回 nil,由调用方决定当“未知”处理。
    static func parse(_ line: Substring) -> Parsed? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let mark = parts.firstIndex(where: { $0 == "obs" }), mark + 1 < parts.count else {
            return nil
        }
        var fields: [String: String] = [:]
        for token in parts[(mark + 1)...] {
            guard let eq = token.firstIndex(of: "=") else { continue }
            fields[String(token[token.startIndex..<eq])] = String(token[token.index(after: eq)...])
        }
        guard fields["v"] == String(AppSharedContract.observationVersion),
              let raw = fields["state"],
              let state = AppSharedContract.channelState(raw) else { return nil }
        let stamp = ISO8601DateFormatter().date(from: String(parts[0])) ?? Date.distantPast
        return Parsed(state: state,
                      generation: fields["gen"].flatMap { Int($0) },
                      meetingID: fields["meeting"],
                      reason: fields["reason"],
                      audioApp: fields["audio_app"].flatMap { Int($0) } ?? 0,
                      at: stamp)
    }
}
