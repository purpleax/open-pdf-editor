import Foundation

/// Runs document work on threads with large stacks.
///
/// MuPDF walks document structures recursively, and the threads GCD and
/// OperationQueue use have 512 KB stacks, which a hostile file can exhaust.
/// These threads have 16 MB, like nothing short of the main thread.
public final class EngineExecutor: @unchecked Sendable {
    public enum Priority: Int, Sendable {
        case low = 0, normal = 1, high = 2
    }

    public static let stackSize = 16 * 1024 * 1024

    /// Page rendering: several threads.
    public static let render = EngineExecutor(name: "Rendering",
                                              threads: max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
    /// Everything else: text, search, outline, attachments.
    public static let background = EngineExecutor(name: "Document", threads: 2)

    private let condition = NSCondition()
    private var queues: [[@Sendable () -> Void]] = [[], [], []]

    public init(name: String, threads: Int) {
        for index in 0..<max(threads, 1) {
            let thread = Thread { [self] in run() }
            thread.stackSize = Self.stackSize
            thread.name = "\(name) \(index + 1)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Runs `work` on one of the threads, higher priorities first, and in
    /// order within a priority.
    public func async(_ priority: Priority = .normal, _ work: @escaping @Sendable () -> Void) {
        condition.lock()
        queues[priority.rawValue].append(work)
        condition.signal()
        condition.unlock()
    }

    private func run() {
        while true {
            condition.lock()
            while queues.allSatisfy(\.isEmpty) { condition.wait() }
            let index = queues.lastIndex { !$0.isEmpty }!
            let work = queues[index].removeFirst()
            condition.unlock()
            autoreleasepool { work() }
        }
    }
}
