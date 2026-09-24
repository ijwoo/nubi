import EventKit
import Foundation

/// EventKit 을 감쌉니다. 읽기와 쓰기 권한이 따로라 실패하는 자리도 따로입니다.
///
/// **확장은 권한을 요청하지 않습니다.** 확장에서 `requestFullAccess` 를 부르면
/// 대화상자 없이 거부로 굳고, 사용자는 거절한 기억이 없어 설정에서 고칠 생각도
/// 못 합니다 — [스파이크에서 확인한 것](../../docs/benchmarks/2026-09-24-lockscreen-spike.md)
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

    struct Item {
        let title: String
        let start: Date
        let allDay: Bool
    }

    /// 오늘 0시부터 `days` 날만큼. `days: 1` 이 오늘 하루입니다.
    static func upcoming(days: Int) throws -> [Item] {
        guard canReadEvents else { throw Failure.needsPermission("일정") }
        let store = EKEventStore()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: days, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { Item(title: $0.title ?? "제목 없음", start: $0.startDate, allDay: $0.isAllDay) }
    }

    @discardableResult
    static func addReminder(_ title: String) throws -> String {
        guard canWriteReminders else { throw Failure.needsPermission("미리알림") }
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = store.defaultCalendarForNewReminders()
        try store.save(reminder, commit: true)
        return title
    }
}
