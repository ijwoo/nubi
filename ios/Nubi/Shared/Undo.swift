import Foundation

/// 방금 한 것을 되돌립니다.
///
/// **되돌릴 길이 없으면 사람이 조심해서 말합니다.** 일정이 잘못 들어갈까 봐,
/// 알람이 엉뚱한 시각에 걸릴까 봐 말을 고르게 됩니다. 한 마디로 물릴 수 있으면
/// 편하게 말하게 되고, 그게 이 물건을 쓰게 만드는 쪽입니다.
///
/// **마지막 하나만** 들고 있습니다. 여러 단계를 되돌리는 것은 사람이 지금
/// 무엇이 지워지는지 모르게 만듭니다 — 승인 게이트와 같은 이유입니다.
///
/// 지운 일정은 되살릴 수 없습니다. 그건 애초에 승인을 받고 지웁니다.
enum Undo {
    struct Mark: Codable {
        enum Kind: String, Codable {
            case event, reminder, alarm, timer, memory, completed, moved
        }

        var kind: Kind
        /// 되돌릴 대상. 일정은 eventIdentifier, 알람은 UUID, 알림은 식별자입니다.
        var id: String
        /// 사람에게 보여줄 이름.
        var label: String
        var at: Date
        /// 옮긴 일정을 되돌릴 때 쓸 원래 시각.
        var from: Date?
    }

    private static let key = "undo.last"
    private static var store: UserDefaults? { UserDefaults(suiteName: NubiLog.group) }

    static var last: Mark? {
        guard let data = store?.data(forKey: key),
              let mark = try? JSONDecoder().decode(Mark.self, from: data),
              // 한참 전 것을 "방금" 이라고 되돌리면 안 됩니다.
              Date().timeIntervalSince(mark.at) < 3600
        else { return nil }
        return mark
    }

    static func note(_ kind: Mark.Kind, id: String, label: String, from: Date? = nil) {
        let mark = Mark(kind: kind, id: id, label: label, at: Date(), from: from)
        guard let data = try? JSONEncoder().encode(mark) else { return }
        store?.set(data, forKey: key)
    }

    static func clear() { store?.removeObject(forKey: key) }

    /// 되돌린 것의 설명. 되돌릴 게 없으면 nil.
    static func undo() async -> String? {
        guard let mark = last else { return nil }
        clear()
        switch mark.kind {
        case .event:
            try? Events.remove(eventId: mark.id)
            return "‘\(mark.label)’ 일정을 뺐습니다"
        case .moved:
            guard let from = mark.from else { return nil }
            try? Events.move(eventId: mark.id, to: from)
            return "‘\(mark.label)’ 을 \(Format.short(from)) 로 되돌렸습니다"
        case .reminder:
            try? Events.removeReminder(id: mark.id)
            return "‘\(mark.label)’ 할일을 뺐습니다"
        case .completed:
            try? Events.uncomplete(id: mark.id)
            return "‘\(mark.label)’ 을 다시 안 끝난 것으로 되돌렸습니다"
        case .alarm:
            _ = Alarms.cancel(id: mark.id)
            return "‘\(mark.label)’ 알람을 껐습니다"
        case .timer:
            await Timers.cancel(id: mark.id)
            return "‘\(mark.label)’ 알림을 껐습니다"
        case .memory:
            Memory.remove(id: mark.id)
            return "‘\(mark.label)’ 기억을 지웠습니다"
        }
    }

    /// 되돌릴 게 있으면 그 이름. 화면에 "방금 그거 취소" 를 띄울지 정합니다.
    static var pending: String? { last?.label }
}
