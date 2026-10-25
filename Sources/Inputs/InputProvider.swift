import Foundation

/// Implemented by device adapters during S3/S5. Preparation never starts capture.
@MainActor protocol InputProvider: AnyObject {
    var binding: InputBinding { get }
    var isAvailable: Bool { get }
    func prepare() async throws
    func start(context: ExecutionContext) async throws
    func pause() async throws
    func resume(context: ExecutionContext) async throws
    func stop() async
}
