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
    ///
    /// **대화창에 떴으면 대개 건너뜁니다.** 같은 말이 잠금화면에 두 번
    /// 보였습니다 — 대화창에 한 번, 그 아래 알림으로 또 한 번.
    ///
    /// **대화창이 뜨면 이제 그쪽이 소리도 냅니다.** 밖에서 물은 답은 알림을
    /// 띄우는 갱신으로 올라가서 화면을 켜고 아일랜드를 펴줍니다. 그래서 여기는
    /// **대화창을 못 띄웠을 때만** 나섭니다.
    static func echo(_ turn: Turn, took: TimeInterval, shown: Bool = false) async {
        guard echoesAnswers, turn.viaIntent, took > 0.8, !shown else { return }
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
        // 날씨는 오늘 것만 붙입니다. 일주일치를 미리 예약하므로 먼 날의 날씨는
        // 예약 시점의 추측일 뿐입니다 — 틀린 것을 적느니 안 적습니다.
        if Calendar.current.isDateInToday(day), let sky = await Weather.quiet() {
            parts.append(sky.line)
        }
        return parts.isEmpty ? "오늘은 잡힌 게 없습니다" : parts.joined(separator: " · ")
    }

    /// 누비가 직접 쓰는 아침 인사.
    ///
    /// **지금까지는 조각을 이어붙인 줄이었습니다** — "일정 2건 · 오후 8:30
    /// 하체운동 · 할일 3개 · 20° 맑음". 사실은 다 맞는데 아무도 안 읽습니다.
    /// 부품은 다 있었고 조립만 안 하고 있었습니다.
    ///
    /// **울릴 때는 모델을 부를 수 없습니다.** 알림은 일주일치를 미리 예약하고,
    /// 배경에서 깨어나는 시각을 iOS 가 약속하지 않습니다. 그래서 앱이 앞에 올
    /// 때 다음 아침 것을 미리 씁니다 — 저녁에 한 번이라도 열면 좋아지고,
    /// 안 열면 조각을 이어붙인 줄이 그대로 나갑니다.
    private static let writtenKey = "briefing.written"

    private static let voice = """
    너는 아침에 한 번 말을 거는 비서다. 한국어 반말로 쓴다.
    받은 사실만 가지고 **두 줄 이내**로 쓴다. 없는 것을 지어내지 마라.
    사실을 나열하지 말고 **그래서 뭘 하면 좋은지**를 말한다 —
    비가 오면 우산, 일정이 붙어 있으면 빠듯하다고, 할일이 몰렸으면 그렇다고.
    "~다" 로 끝내지 마라. 인사말과 맺음말을 쓰지 마라. 마크다운을 쓰지 마라.
    """

    /// 그날 아침에 할 말. 모델이 쓰고, 안 되면 조각을 이어붙인 줄입니다.
    static func written(for day: Date) async -> String {
        let plain = await line(for: day)
        let facts = await facts(for: day)
        guard !facts.isEmpty, Secrets.apiKey != nil else { return plain }

        // 사실이 그대로면 다시 쓰지 않습니다. 앱을 열 때마다 모델을 부를
        // 이유가 없습니다.
        let stamp = "\(writtenKey).\(dayKey(day))"
        let fingerprint = "\(writtenKey).mark.\(dayKey(day))"
        if store?.string(forKey: fingerprint) == facts,
           let kept = store?.string(forKey: stamp), !kept.isEmpty { return kept }

        guard let written = try? await Model.line(voice, about: facts),
              !written.isEmpty else { return plain }
        let tidy = written.replacingOccurrences(of: "\n\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        store?.set(tidy, forKey: stamp)
        store?.set(facts, forKey: fingerprint)
        NubiLog.write("[브리핑] 다음 아침 것을 새로 씀")
        return tidy
    }

    /// 모델에게 넘길 사실들. **없는 것은 적지 않습니다.**
    private static func facts(for day: Date) async -> String {
        var lines: [String] = []
        let calendar = Calendar.current
        let when = calendar.isDateInToday(day) ? "오늘" : "내일"
        lines.append("\(when) 날짜: \(dayKey(day))")

        let events = (try? Events.upcoming(days: 1, from: day)) ?? []
        if events.isEmpty {
            lines.append("일정: 없음")
        } else {
            lines.append("일정:")
            for item in events.prefix(6) {
                lines.append(item.allDay
                    ? "- \(item.title) (종일)"
                    : "- \(Format.time(item.start))~\(Format.time(item.end)) \(item.title)"
                        + (item.place.isEmpty ? "" : " @\(item.place)"))
            }
        }

        let end = calendar.date(byAdding: .day, value: 1,
                                to: calendar.startOfDay(for: day)) ?? day
        let due = ((try? await Events.openReminders()) ?? [])
            .filter { ($0.due ?? .distantFuture) < end }
        if !due.isEmpty {
            lines.append("오늘까지 할일: " + due.prefix(6).map(\.title).joined(separator: ", "))
        }

        if let sky = await Weather.quiet() {
            let forecast = calendar.isDateInToday(day) ? sky.line : sky.nextLine
            if !forecast.isEmpty { lines.append("날씨: \(forecast)") }
        }

        let known = Memory.all().filter { !$0.stale }
        if !known.isEmpty {
            lines.append("아는 것: " + known.prefix(8).map(\.text).joined(separator: ", "))
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : ""
    }

    private static func dayKey(_ day: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: day)
    }

    /// 울린 브리핑을 대화에 남깁니다.
    ///
    /// **놓치면 사라졌습니다.** 하루 중 유일하게 묻지 않고 오는 것인데 알림을
    /// 못 보면 끝이었습니다. 알림이 울릴 때 우리 코드는 돌지 않으므로, 앱이
    /// 앞에 올 때 지난 것이 있으면 그때 쌓습니다.
    private static let dueKey = "briefing.due.at"
    private static let dueBodyKey = "briefing.due.body"

    static func recordFired() {
        guard let due = store?.object(forKey: dueKey) as? Date, due < Date(),
              let body = store?.string(forKey: dueBodyKey), !body.isEmpty else { return }
        store?.removeObject(forKey: dueKey)
        store?.removeObject(forKey: dueBodyKey)
        var lines = body.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let headline = lines.first ?? body
        if !lines.isEmpty { lines.removeFirst() }
        Thread.append(Turn(asked: "아침", headline: headline,
                           detail: lines.joined(separator: "\n"),
                           source: .none, failed: false, at: due, viaIntent: true))
        NubiLog.write("[브리핑] 지난 것을 대화에 남김")
    }

    /// 예약을 다시 깝니다. 앱이 앞에 올 때마다 부릅니다.
    static func reschedule() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) })
        guard isOn else { return }

        let calendar = Calendar.current
        var nextUp = true
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: Date()) else { continue }
            var when = calendar.dateComponents([.year, .month, .day], from: day)
            when.hour = hour
            when.minute = minute
            guard let fireDate = calendar.date(from: when), fireDate > Date() else { continue }

            let content = UNMutableNotificationContent()
            content.title = "오늘"
            // **다음에 울릴 하나만** 누비가 씁니다. 먼 날은 그때 가서 다시
            // 깔리고, 미리 써봐야 그 사이에 일정이 바뀝니다.
            content.body = nextUp ? await written(for: day) : await line(for: day)
            if nextUp {
                // 이게 울리고 나면 대화에 남길 것입니다.
                store?.set(fireDate, forKey: dueKey)
                store?.set(content.body, forKey: dueBodyKey)
            }
            nextUp = false
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
