import Foundation

/// 말에서 날짜와 시각을 뽑아냅니다.
///
/// `내일 등운동 일정 추가해줘 오후 1시쯤` 에서 **언제**와 **무엇**을 갈라냅니다.
/// 모델을 부르지 않습니다 — 왕복 1초를 쓸 일이 아니고, 비행기 모드에서도 돌아야
/// 합니다.
struct Spoken {
    /// 시작 시각. 날짜만 말했으면 그날 0시입니다.
    var start: Date
    /// 시각을 말하지 않았다. 종일 일정이 됩니다.
    var allDay: Bool
    /// 날짜·시각·명령어를 덜어낸 나머지. 일정 제목이 됩니다.
    var title: String
    /// 사람이 읽는 말로 되돌린 것. 답에 그대로 실어 **틀렸으면 바로 보이게** 합니다.
    var spoken: String
}

enum DateTalk {
    private static let days: [(key: String, offset: Int, label: String)] = [
        ("글피", 3, "글피"), ("모레", 2, "모레"), ("내일", 1, "내일"), ("오늘", 0, "오늘"),
    ]

    /// 명령어와 군더더기. 제목에서 덜어냅니다.
    private static let noise = [
        "일정에 추가", "일정 추가", "일정 등록", "일정 잡아", "일정 넣어",
        "추가해줘", "추가해 줘", "등록해줘", "잡아줘", "넣어줘", "만들어줘",
        "추가", "등록", "일정", "캘린더", "쯤", "에",
    ]

    static func parse(_ text: String, now: Date = Date()) -> Spoken {
        var rest = text
        let calendar = Calendar.current

        var offset = 0
        var dayLabel = "오늘"
        if let day = days.first(where: { text.contains($0.key) }) {
            offset = day.offset
            dayLabel = day.label
            rest = rest.replacingOccurrences(of: day.key, with: " ")
        }

        let base = calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: now) ?? now)
        guard let clock = time(in: rest) else {
            return Spoken(start: base, allDay: true, title: clean(rest),
                          spoken: "\(dayLabel) 종일")
        }
        rest = rest.replacingOccurrences(of: clock.matched, with: " ")
        let start = calendar.date(byAdding: .minute, value: clock.hour * 60 + clock.minute, to: base) ?? base
        return Spoken(start: start, allDay: false, title: clean(rest),
                      spoken: "\(dayLabel) \(Format.time(start))")
    }

    private struct Clock {
        var hour: Int
        var minute: Int
        var matched: String
    }

    /// `오후 1시`, `1시 30분`, `7시반`, `13시` 를 읽습니다.
    private static func time(in text: String) -> Clock? {
        let pattern = #"(오전|오후|새벽|아침|저녁|밤)?\s*(\d{1,2})\s*시\s*(반|\d{1,2}\s*분)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text),
              let hourRange = Range(match.range(at: 2), in: text),
              var hour = Int(text[hourRange])
        else { return nil }

        let meridiem = Range(match.range(at: 1), in: text).map { String(text[$0]) }
        var minute = 0
        if let tail = Range(match.range(at: 3), in: text).map({ String(text[$0]) }) {
            minute = tail.contains("반") ? 30 : Int(tail.filter(\.isNumber)) ?? 0
        }

        switch meridiem {
        case "오전", "새벽", "아침": if hour == 12 { hour = 0 }
        case "오후", "저녁", "밤": if hour < 12 { hour += 12 }
        default:
            // 오전·오후를 말하지 않았을 때. **1시부터 7시는 오후, 8시부터 11시는
            // 오전**으로 읽습니다. 새벽 한 시에 일정을 잡는 일은 드뭅니다.
            // 해석한 시각을 답에 되돌려주므로 틀렸으면 바로 보입니다.
            if (1...7).contains(hour) { hour += 12 }
        }
        return Clock(hour: min(hour, 23), minute: min(minute, 59), matched: String(text[whole]))
    }

    private static func clean(_ text: String) -> String {
        var rest = text
        for word in noise { rest = rest.replacingOccurrences(of: word, with: " ") }
        let title = rest
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "새 일정" : title
    }
}
