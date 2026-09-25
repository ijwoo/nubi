import EventKit
import Foundation

/// EventKit 을 감쌉니다. 읽기와 쓰기 권한이 따로라 실패하는 자리도 따로입니다.
///
/// **확장은 권한을 요청하지 않습니다.** 확장에서 `requestFullAccess` 를 부르면
/// 대화상자 없이 거부로 굳고, 사용자는 거절한 기억이 없어 설정에서 고칠 생각도
/// 못 합니다 — [스파이크에서 확인한 것](../../../docs/benchmarks/2026-09-24-lockscreen-spike.md)
/// 입니다. 그래서 요청은 앱만 하고, 확장은 상태를 읽기만 합니다.
enum Events {
    enum Failure: Error, LocalizedError {
        case needsPermission(String)

        var errorDescription: String? {
            switch self {
            case let .needsPermission(what): "\(what) 권한이 없습니다. 누비를 한 번 열어 허용해 주세요."
            }
        }
    }

    static var canReadEvents: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    static var canWriteReminders: Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        return status == .fullAccess || status == .writeOnly
    }

    /// 앱에서만 부릅니다.
    static func requestAll() async -> (events: Bool, reminders: Bool) {
        let store = EKEventStore()
        let events = (try? await store.requestFullAccessToEvents()) ?? false
        let reminders = (try? await store.requestFullAccessToReminders()) ?? false
        NubiLog.write("[권한] 일정 \(events ? "허용" : "거부"), 미리알림 \(reminders ? "허용" : "거부")")
        return (events, reminders)
    }

    struct Item: Identifiable, Hashable {
        let id: String
        let title: String
        let start: Date
        let allDay: Bool
    }

    /// 오늘 0시부터 `days` 날만큼. `days: 1` 이 오늘 하루입니다.
    static func upcoming(days: Int, from origin: Date = Date()) throws -> [Item] {
        guard canReadEvents else { throw Failure.needsPermission("일정") }
        let store = EKEventStore()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: origin)
        guard let end = calendar.date(byAdding: .day, value: days, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { Item(id: $0.eventIdentifier ?? UUID().uuidString,
                        title: $0.title ?? "제목 없음", start: $0.startDate, allDay: $0.isAllDay) }
    }

    /// 하루치만. 서랍 요약에 씁니다.
    static func onDay(offset: Int) -> [Item] {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        return (try? upcoming(days: 1, from: day)) ?? []
    }

    @discardableResult
    static func addEvent(title: String, start: Date, allDay: Bool) throws -> String {
        guard canReadEvents else { throw Failure.needsPermission("일정") }
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = title
        event.calendar = store.defaultCalendarForNewEvents
        event.isAllDay = allDay
        event.startDate = start
        // 길이를 말하지 않으면 한 시간입니다. 종일이면 그날 전부입니다.
        event.endDate = allDay
            ? Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
            : start.addingTimeInterval(3600)
        try store.save(event, span: .thisEvent, commit: true)
        return title
    }

    struct ReminderItem: Identifiable, Hashable {
        let id: String
        let title: String
        let due: Date?
    }

    /// 안 끝난 미리알림만.
    static func openReminders() async throws -> [ReminderItem] {
        guard canWriteReminders else { throw Failure.needsPermission("미리알림") }
        let store = EKEventStore()
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                let items = (found ?? []).map {
                    ReminderItem(id: $0.calendarItemIdentifier,
                                 title: $0.title ?? "제목 없음",
                                 due: $0.dueDateComponents?.date)
                }
                continuation.resume(returning: items.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) })
            }
        }
    }

    static func remove(_ item: ReminderItem) throws {
        let store = EKEventStore()
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }

    static func remove(eventId: String) throws {
        let store = EKEventStore()
        guard let event = store.event(withIdentifier: eventId) else { return }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    static func complete(_ item: ReminderItem) throws {
        let store = EKEventStore()
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
    }

    /// 미리알림을 넣습니다.
    ///
    /// **마감만 적으면 울리지 않습니다.** 알람을 따로 붙여야 알림이 옵니다 —
    /// 미리알림 앱에서 손으로 시각을 넣으면 앱이 대신 해주는 일입니다.
    /// 넣었다고 답해놓고 아무 소리도 안 나던 자리입니다.
    @discardableResult
    static func addReminder(_ title: String, due: Date? = nil, note: String = "") throws -> String {
        guard canWriteReminders else { throw Failure.needsPermission("미리알림") }
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        if !note.isEmpty { reminder.notes = note }
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return title
    }

    /// 모델에게 넘길 오늘 요약. 없으면 빈 문자열입니다.
    static func todayBrief() -> String {
        guard canReadEvents, let items = try? upcoming(days: 1), !items.isEmpty else { return "" }
        return items.prefix(5).map {
            $0.allDay ? "\($0.title)(종일)" : "\(Format.time($0.start)) \($0.title)"
        }.joined(separator: ", ")
    }
}
