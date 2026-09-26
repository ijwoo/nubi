import Foundation

/// 아직 하지 않은 일.
///
/// **되돌릴 수 없는 동작은 묻고 합니다.** 일정을 지우거나 옮기는 것은 한 번
/// 하면 끝입니다. 무엇을 할지 적어두고, 사람이 누르면 그때 합니다.
///
/// 이 방식이 나중에 작업 모드의 승인 게이트가 됩니다 —
/// [ADR 0007](../../../docs/adr/0007-approval-gate-off-device.md).
struct Pending: Codable, Hashable {
    enum Kind: String, Codable {
        case delete, move

        var verb: String { self == .delete ? "삭제" : "옮기기" }
    }

    var kind: Kind
    var eventId: String
    var title: String
    /// 지금 잡혀 있는 시각.
    var at: Date
    /// 옮길 시각. 지우는 경우에는 없습니다.
    var to: Date?

    var question: String {
        switch kind {
        case .delete: "‘\(title)’ 을 지울까요?"
        case .move: "‘\(title)’ 을 옮길까요?"
        }
    }

    var detail: String {
        switch kind {
        case .delete: Format.short(at)
        case .move: "\(Format.short(at)) → \(to.map(Format.short) ?? "?")"
        }
    }
}

/// 기다리는 일은 하나뿐입니다.
///
/// 여러 개를 쌓아두면 무엇을 승인하는지 흐려집니다. 새 요청이 오면 앞의 것은
/// 버립니다 — **승인하지 않은 것은 하지 않은 것입니다.**
enum PendingStore {
    private static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: NubiLog.group)?
            .appendingPathComponent("pending.json")
    }

    static var current: Pending? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Pending.self, from: data)
    }

    static func hold(_ pending: Pending) {
        guard let url, let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 꺼내면서 지웁니다. 두 번 누르면 두 번 지워지는 일이 없어야 합니다.
    static func take() -> Pending? {
        let held = current
        clear()
        return held
    }

    static func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
