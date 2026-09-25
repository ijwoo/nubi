import Foundation

/// 한 번의 요청이 낳는 것.
struct NubiAnswer: Equatable {
    /// 한 문장 요약. 잠금화면에 들어가야 하므로 짧습니다.
    let headline: String
    /// 나머지. 앱에서 전문으로 보입니다.
    let detail: String
    let source: Source
    let failed: Bool

    init(headline: String, detail: String = "", source: Source = .none, failed: Bool = false) {
        self.headline = headline
        self.detail = detail
        self.source = source
        self.failed = failed
    }
}

/// 일정 목록을 사람이 읽는 줄로.
///
/// **모델을 부르지 않습니다.** 일정 세 건을 읽어주는 데 왕복 1초를 쓸 이유가
/// 없고, 키가 없어도 비행기 모드여도 이 기능은 돌아야 합니다.
enum Format {
    static func events(_ items: [Events.Item], label: String) -> NubiAnswer {
        guard !items.isEmpty else {
            return NubiAnswer(headline: "\(label) 일정이 없습니다", source: .events)
        }
        let lines = items.map { item in
            item.allDay ? "· \(item.title) (종일)" : "· \(time(item.start)) \(item.title)"
        }
        // 하나뿐이면 제목이 곧 전부입니다. 상세에 같은 줄을 또 두지 않습니다.
        guard items.count > 1 else {
            return NubiAnswer(headline: "\(label) \(lines[0].dropFirst(2))", source: .events)
        }
        return NubiAnswer(headline: "\(label) 일정 \(items.count)건",
                          detail: lines.joined(separator: "\n"), source: .events)
    }

    static func reminders(_ items: [Events.ReminderItem]) -> NubiAnswer {
        guard !items.isEmpty else {
            return NubiAnswer(headline: "안 끝난 미리알림이 없습니다", source: .reminders)
        }
        let lines = items.prefix(8).map { item in
            item.due.map { "· \(short($0)) \(item.title)" } ?? "· \(item.title)"
        }
        guard items.count > 1 else {
            return NubiAnswer(headline: String(lines[0].dropFirst(2)), source: .reminders)
        }
        return NubiAnswer(headline: "안 끝난 것 \(items.count)개",
                          detail: lines.joined(separator: "\n"), source: .reminders)
    }

    /// 오늘이면 시각만, 아니면 날짜까지.
    static func short(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "a h:mm" : "M/d a h:mm"
        return f.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "a h:mm"
        return f.string(from: date)
    }
}
