import Foundation

/// Shared user/hardware intent vocabulary. Unsupported actions are rejected.
enum CaptureAction: Equatable { case start, pause, resume, end, cancelStart, recover }

enum CaptureActionResult: Equatable {
    case submitted
    case rejected(String)
}
