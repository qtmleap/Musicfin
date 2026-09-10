import Foundation

/// 監視の解除処理をまとめて保持する箱。
///
/// `@MainActor` の型の `deinit` は nonisolated なので、そこから隔離されたプロパティに
/// 触れられない。解除処理をこの箱に預けておけば、箱自身の `deinit` で安全に後始末できる。
nonisolated final class CleanupBox: @unchecked Sendable {
    private var actions: [() -> Void] = []

    func add(_ action: @escaping () -> Void) {
        actions.append(action)
    }

    /// NotificationCenter のブロック監視をまとめて登録する。
    func observe(
        _ name: Notification.Name,
        handler: @escaping @Sendable (Notification) -> Void
    ) {
        let token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main,
            using: handler
        )
        add { NotificationCenter.default.removeObserver(token) }
    }

    deinit {
        for action in actions { action() }
    }
}
