import Foundation

/// The observe / notify pair the main-actor models share: closures kept by
/// token, all called on every change. Observers live as long as the model.
@MainActor
struct ObserverRegistry {
    private var observers: [UUID: () -> Void] = [:]

    @discardableResult
    mutating func add(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func notify() {
        observers.values.forEach { $0() }
    }
}
