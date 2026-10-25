import Foundation

/// Captured before an async action. Every result must still belong to this
/// generation and registration before it can update the current session.
struct SessionOperation {
    let generation: Int
    let config: LiveKitConfig

    func isCurrent(generation current: Int, config latest: LiveKitConfig) -> Bool {
        generation == current && config.url == latest.url &&
            config.device == latest.device && config.userID == latest.userID
    }
}
