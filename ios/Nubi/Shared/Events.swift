import CoreLocation
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
        let end: Date
        let allDay: Bool
        let place: String
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
                        title: $0.title ?? "제목 없음", start: $0.startDate, end: $0.endDate,
                        allDay: $0.isAllDay, place: $0.location ?? "") }
    }

    /// 하루치만. 서랍 요약에 씁니다.
    static func onDay(offset: Int) -> [Item] {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        return (try? upcoming(days: 1, from: day)) ?? []
    }

    /// 일정을 넣습니다.
    ///
    /// **장소를 같이 넣으면 아이폰이 출발할 시각을 알려줍니다.** 캘린더가 교통
    /// 상황을 보고 "지금 나가야 합니다" 를 띄우는 기능인데, 좌표가 붙은
    /// 일정에만 붙습니다. 그래서 가게를 찾아준 다음 일정을 넣을 때는 그때
    /// 받아둔 좌표를 같이 넘깁니다 — 우리가 이동 시간을 계산할 이유가 없습니다.
    /// 되풀이. "매주 화목 8시 반 하체운동" 을 한 건으로 넣습니다.
    struct Repeat {
        enum Every: String { case daily, weekly, monthly, yearly }
        let every: Every
        /// 1 이 일요일, 7 이 토요일. 주 단위일 때만 씁니다.
        var days: [Int] = []
        /// 몇 번 하고 끝낼까. 0 이면 끝이 없습니다.
        var times: Int = 0

        var rule: EKRecurrenceRule {
            let frequency: EKRecurrenceFrequency = switch every {
            case .daily: .daily
            case .weekly: .weekly
            case .monthly: .monthly
            case .yearly: .yearly
            }
            let weekdays = days.compactMap { EKWeekday(rawValue: $0) }
                .map { EKRecurrenceDayOfWeek($0) }
            return EKRecurrenceRule(
                recurrenceWith: frequency, interval: 1,
                daysOfTheWeek: weekdays.isEmpty ? nil : weekdays,
                daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                daysOfTheYear: nil, setPositions: nil,
                end: times > 0 ? EKRecurrenceEnd(occurrenceCount: times) : nil)
        }
    }

    @discardableResult
    static func addEvent(title: String, start: Date, allDay: Bool,
                         minutes: Int = 60, place: String = "",
                         at spot: CLLocationCoordinate2D? = nil,
                         repeats: Repeat? = nil) throws -> String {
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
            : start.addingTimeInterval(TimeInterval(max(5, minutes) * 60))
        if !place.isEmpty {
            let located = EKStructuredLocation(title: place)
            if let spot { located.geoLocation = CLLocation(latitude: spot.latitude,
                                                           longitude: spot.longitude) }
            event.structuredLocation = located
        }
        if let repeats { event.recurrenceRules = [repeats.rule] }
        try store.save(event, span: .thisEvent, commit: true)
        noteAdded(title, start)
        return title
    }

    /// 이 시간대에 이미 있는 일정.
    ///
    /// **모델이 알아서 눈치채기를 기다리지 않습니다.** 겹친다고 짚어준 적이
    /// 있었지만 그건 일정을 읽다가 우연히 본 것이었고, 다음에도 그런다는 보장이
    /// 없었습니다. 코드가 먼저 확인해서 알려주면 언제나 짚습니다.
    ///
    /// 종일 일정은 세지 않습니다 — 하루를 통째로 덮어서 전부 겹침이 됩니다.
    static func clashes(with start: Date, minutes: Int = 60,
                        ignoring id: String = "") -> [Item] {
        let end = start.addingTimeInterval(TimeInterval(max(5, minutes) * 60))
        // 앞뒤로 하루씩 넉넉히 읽고 실제로 겹치는 것만 거릅니다.
        let from = Calendar.current.date(byAdding: .day, value: -1, to: start) ?? start
        guard let around = try? upcoming(days: 3, from: from) else { return [] }
        return around.filter { item in
            !item.allDay && item.id != id && item.start < end && start < item.end
        }
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

    static func move(eventId: String, to start: Date) throws {
        let store = EKEventStore()
        guard let event = store.event(withIdentifier: eventId) else { return }
        let length = event.endDate.timeIntervalSince(event.startDate)
        event.startDate = start
        event.endDate = start.addingTimeInterval(length)
        try store.save(event, span: .thisEvent, commit: true)
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

    // MARK: 방금 넣은 것

    /// 마지막으로 넣은 일정. 두 번 넣는 것을 막는 데만 씁니다.
    private static let lastAddKey = "event.lastAdd"
    private static var store: UserDefaults? { UserDefaults(suiteName: NubiLog.group) }

    struct JustAdded {
        let title: String
        let start: Date
        let at: Date
    }

    static var justAdded: JustAdded? {
        guard let row = store?.dictionary(forKey: lastAddKey),
              let title = row["title"] as? String,
              let start = row["start"] as? Double,
              let at = row["at"] as? Double else { return nil }
        return JustAdded(title: title, start: Date(timeIntervalSince1970: start),
                         at: Date(timeIntervalSince1970: at))
    }

    private static func noteAdded(_ title: String, _ start: Date) {
        store?.set(["title": title, "start": start.timeIntervalSince1970,
                    "at": Date().timeIntervalSince1970], forKey: lastAddKey)
    }

    /// 두 제목이 같은 것을 가리키는가.
    ///
    /// **글자 두 개씩 겹치는 비율로 봅니다.** "여자친구와 저녁 - 샤브향
    /// 수원매탄점" 과 "여자친구 저녁 샤브샤브" 는 낱말로는 '저녁' 하나만
    /// 겹치는데 사람이 보기엔 같은 약속입니다.
    static func similar(_ a: String, _ b: String) -> Double {
        func grams(_ text: String) -> Set<String> {
            let letters = Array(text.filter { $0.isLetter || $0.isNumber })
            guard letters.count > 1 else { return Set(letters.map(String.init)) }
            return Set((0..<(letters.count - 1)).map { String(letters[$0...$0 + 1]) })
        }
        let x = grams(a), y = grams(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return 2 * Double(x.intersection(y).count) / Double(x.count + y.count)
    }

    /// 자리에 닿으면 울리는 미리알림.
    ///
    /// **우리가 지켜보지 않습니다.** 미리알림 앱에서 손으로 만드는 것과 같은
    /// 물건이고, 울타리는 시스템이 봅니다. 그래서 앱이 꺼져 있어도 오고,
    /// 위치 권한을 "항상" 으로 올릴 이유도 없습니다.
    @discardableResult
    static func addPlaceReminder(_ title: String, place: String,
                                 at spot: CLLocationCoordinate2D,
                                 onArrival: Bool = true) throws -> String {
        guard canWriteReminders else { throw Failure.needsPermission("미리알림") }
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = store.defaultCalendarForNewReminders()
        let located = EKStructuredLocation(title: place)
        located.geoLocation = CLLocation(latitude: spot.latitude, longitude: spot.longitude)
        // 100m. 더 좁히면 도심에서 안 울리고, 더 넓히면 지나가다 울립니다.
        located.radius = 100
        let alarm = EKAlarm()
        alarm.structuredLocation = located
        alarm.proximity = onArrival ? .enter : .leave
        reminder.addAlarm(alarm)
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
