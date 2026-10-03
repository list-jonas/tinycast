import Foundation

@MainActor
final class DeliveryCompletion {
    private let onDelivered: @MainActor () -> Void
    private let onFailed: @MainActor () -> Void
    private(set) var isConfirmed = false
    private var isSettled = false

    init(
        onDelivered: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor () -> Void = {}
    ) {
        self.onDelivered = onDelivered
        self.onFailed = onFailed
    }

    func confirm() {
        guard !isSettled else { return }
        isSettled = true
        isConfirmed = true
        onDelivered()
    }

    /// Driven from a `defer`, so a delivery that returned early still says so instead of vanishing.
    func settle() {
        guard !isSettled else { return }
        isSettled = true
        onFailed()
    }
}

@MainActor
final class DeliveryQueue {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var tail: (id: UUID, task: Task<Void, Never>)?
    private var automaticTaskID: UUID?

    var isIdle: Bool { tasks.isEmpty }

    func enqueue(isAutomatic: Bool, operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        let predecessor = tail?.task
        let task = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            defer { self.finish(id: id) }
            guard !Task.isCancelled else { return }
            await operation()
        }
        tasks[id] = task
        tail = (id, task)
        if isAutomatic { automaticTaskID = id }
    }

    func cancelAutomatic() {
        guard let automaticTaskID else { return }
        tasks[automaticTaskID]?.cancel()
        self.automaticTaskID = nil
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        tail = nil
        automaticTaskID = nil
    }

    func drain() async {
        await tail?.task.value
    }

    private func finish(id: UUID) {
        tasks.removeValue(forKey: id)
        if automaticTaskID == id { automaticTaskID = nil }
        if tail?.id == id { tail = nil }
    }
}
