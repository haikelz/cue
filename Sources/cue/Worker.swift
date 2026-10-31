import Foundation

/// A serial queue behind an async API. osascript, tmux and codex calls block for up to a minute, so
/// they run here, one at a time, off the main thread and off Swift's task pool, which blocking calls
/// would starve.
final class Worker: Sendable {
    private let queue: DispatchQueue

    init(_ label: String, qos: DispatchQoS = .userInitiated) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in queue.async { done.resume(returning: work()) } }
    }
}
