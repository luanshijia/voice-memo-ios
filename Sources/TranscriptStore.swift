import Foundation

/// Both realtime and catch-up use this store. The cursor acknowledges only a
/// continuous prefix, never the largest sequence number seen out of order.
struct TranscriptStore {
    struct Entry {
        let id = UUID()
        let seq: Int
        let who: String
        let source: String
        let text: String
        let gap: Double?
        let ts: Double
    }

    private(set) var epoch: String?
    private(set) var cursor = 0
    private(set) var gapMessage = ""
    private var retiredEpochs = Set<String>()
    private var received = Set<Int>()
    private var current: [Int: Entry] = [:]
    private var previous: [Entry] = []
    private let limit = 4000

    var entries: [Entry] {
        Array((previous + current.keys.sorted().compactMap { current[$0] }).suffix(limit))
    }

    /// Old in-flight pages must not switch the store back to an earlier epoch.
    @discardableResult
    mutating func merge(_ items: [Entry], epoch incoming: String?,
                        oldest: Int? = nil, truncated: Bool = false) -> Bool {
        if let incoming {
            guard UUID(uuidString: incoming) != nil, !retiredEpochs.contains(incoming) else { return false }
            if incoming != epoch {
                if let old = epoch { retiredEpochs.insert(old) }
                if epoch != nil || !current.isEmpty {
                    previous = entries
                    gapMessage = "字幕缓存已重置，部分历史字幕可能缺失"
                }
                current = [:]
                received = []
                cursor = 0
                epoch = incoming
            }
        } else if epoch != nil {
            return false // legacy/late data cannot overwrite a known epoch
        }
        if truncated, let oldest, oldest > cursor + 1 {
            cursor = oldest - 1
            received = received.filter { $0 > cursor }
            gapMessage = "部分历史字幕已超出补取范围，存在缺口"
        }
        for item in items where item.seq > cursor && current[item.seq] == nil {
            current[item.seq] = item
            received.insert(item.seq)
        }
        while received.remove(cursor + 1) != nil { cursor += 1 }
        if current.count > limit {
            for key in current.keys.sorted().prefix(current.count - limit) {
                current.removeValue(forKey: key)
            }
        }
        return true
    }
}
