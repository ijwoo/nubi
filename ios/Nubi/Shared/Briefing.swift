import Foundation
import UserNotifications

/// 아침 브리핑.
///
/// **지금까지 누비는 물어야만 답했습니다.** 비서의 절반은 묻기 전에 말하는
/// 쪽인데 그게 통째로 비어 있었습니다.
///
/// 내용을 그때그때 만들 수 없으므로 **앱이 열릴 때 일주일치를 미리 계산해
/// 예약합니다.** 배경에서 깨어나 계산하는 방법도 있지만 iOS 가 언제 깨울지
/// 약속하지 않습니다 — 아침 7시에 와야 하는 알림에 그 불확실을 걸 수 없습니다.
enum Briefing {
    private static let idPrefix = "briefing."
    private static let onKey = "briefing.on"
    private static let hourKey = "briefing.hour"
    private static let minuteKey = "briefing.minute"
    /// 일주일치. 그 안에 앱을 한 번은 엽니다.
    private static let days = 7

    private static var store: UserDefaults? { UserDefaults(suiteName: NubiLog.group) }

    static var isOn: Bool {
        get { store?.bool(forKey: onKey) ?? false }
        set { store?.set(newValue, forKey: onKey) }
    }

    static var hour: Int {
        get { store?.object(forKey: hourKey) as? Int ?? 8 }
        set { store?.set(newValue, forKey: hourKey) }
    }

    static var minute: Int {
        get { store?.object(forKey: minuteKey) as? Int ?? 0 }
        set { store?.set(newValue, forKey: minuteKey) }
    }

    static var timeLabel: String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// 답이 오면 알림으로도 보낼까.
    ///
    /// **잠금화면 버튼을 누르면 1~2초 뒤에 화면이 꺼집니다.** 모델 답은 그
    /// 뒤에 도착해서 아무도 못 봅니다. 알림은 화면을 다시 켭니다 — 우리가
    /// 대기 시간을 늘릴 수는 없으니 도착을 알리는 수밖에 없습니다.
    private static let echoKey = "briefing.echo"

    static var echoesAnswers: Bool {
        get { store?.object(forKey: echoKey) as? Bool ?? true }
        set { store?.set(newValue, forKey: echoKey) }
    }

    /// 밖에서 물어 답이 늦게 온 것만 알립니다. 앱에서 보고 있는 것과 즉시
    /// 끝난 일정 조회까지 울리면 시끄럽기만 합니다.
    static func echo(_ turn: Turn, took: TimeInterval) async {
        guard echoesAnswers, turn.viaIntent, took > 0.8 else { return }
        let content = UNMutableNotificationContent()
        content.title = turn.asked.isEmpty ? "누비" : turn.asked
        content.body = turn.headline
        content.sound = nil
        let request = UNNotificationRequest(identifier: "echo.\(turn.id)",
                                            content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// 그날 아침에 할 말 한 줄.
    ///
    /// 없는 것은 말하지 않습니다. 일정도 할일도 없으면 그렇게만 말합니다 —
    /// 빈 하루에 억지로 할 말을 붙이면 다음부터 안 읽게 됩니다.
    static func line(for day: Date) async -> String {
        var parts: [String] = []
        let events = (try? Events.upcoming(days: 1, from: day)) ?? []
        if let first = events.first(where: { !$0.allDay }) ?? events.first {
            parts.append(events.count > 1 ? "일정 \(events.count)건" : "일정 1건")
            parts.append(first.allDay ? first.title : "\(Format.time(first.start)) \(first.title)")
        }
        let end = Calendar.current.date(byAdding: .day, value: 1,
                                        to: Calendar.current.startOfDay(for: day)) ?? day
        let due = ((try? await Events.openReminders()) ?? []).filter { ($0.due ?? .distantFuture) < end }
        if !due.isEmpty { parts.append("할일 \(due.count)개") }
        return parts.isEmpty ? "오늘은 잡힌 게 없습니다" : parts.joined(separator: " · ")
    }

    /// 예약을 다시 깝니다. 앱이 앞에 올 때마다 부릅니다.
    static func reschedule() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) })
        guard isOn else { return }

        let calendar = Calendar.current
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: Date()) else { continue }
            var when = calendar.dateComponents([.year, .month, .day], from: day)
            when.hour = hour
            when.minute = minute
            guard let fireDate = calendar.date(from: when), fireDate > Date() else { continue }

            let content = UNMutableNotificationContent()
            content.title = "오늘"
            content.body = await line(for: day)
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "\(idPrefix)\(offset)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
            try? await center.add(request)
        }
        NubiLog.write("[브리핑] \(timeLabel) 예약")
    }
}
