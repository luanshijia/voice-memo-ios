import Foundation

/// Append the new tail; a catch-up insertion or a retained-history change rebuilds once.
struct TranscriptRows {
    struct Row: Identifiable {
        let id: UUID
        let who: String
        var text: String
    }
    private(set) var rows: [Row] = []
    private var ids: [UUID] = []
    private var previousSpeaker = ""

    mutating func update(_ lines: [TranscriptLine]) {
        let appended = lines.count >= ids.count && zip(lines, ids).allSatisfy { pair in pair.0.id == pair.1 }
        let start = appended ? ids.count : 0
        if !appended { rows = []; previousSpeaker = "" }
        for line in lines.dropFirst(start) {
            let speaker = "\(line.source)|\(line.who)"
            if speaker == previousSpeaker, !rows.isEmpty, rows[rows.count - 1].text.count < 1000 {
                let gap = line.gap ?? 0
                if gap >= 2.4 { rows[rows.count - 1].text += " " + Self.gapLabel(gap) }
                rows[rows.count - 1].text += line.text
            } else {
                rows.append(Row(id: line.id, who: line.who, text: line.text))
            }
            previousSpeaker = speaker
        }
        ids = lines.map(\.id)
    }

    private static func gapLabel(_ seconds: Double) -> String {
        guard seconds >= 30 else { return "~" }
        let total = Int(seconds.rounded()), minutes = total / 60, remainder = total % 60
        return remainder == 0 ? "~ \(minutes)分钟" : "~ \(minutes)分\(remainder)秒"
    }
}
