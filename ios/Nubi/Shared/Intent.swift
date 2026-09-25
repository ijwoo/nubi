import Foundation

/// 발화가 무엇을 원하는지.
///
/// 맥의 Router 와 같은 규칙입니다 — **모델을 쓰지 않고 코드로 가릅니다.**
/// 의도 판별에 모델을 부르면 "내일 일정 뭐야" 한 마디에 왕복이 두 번 붙고,
/// 빠른 모드의 목표가 수 초인데 그 절반을 여기서 씁니다.
enum NubiIntent: Equatable {
    /// `offset` 일 뒤부터 `span` 날만큼.
    case events(offset: Int, span: Int, label: String)
    /// 캘린더에 일정을 넣습니다.
    case addEvent(Spoken)
    /// 미리알림 추가. 되돌릴 수 있고 상대가 없으므로 묻지 않고 실행합니다.
    case addReminder(Spoken)
    /// 그 외. 모델이 답합니다.
    case ask(String)
}

extension Spoken: Equatable {
    static func == (a: Spoken, b: Spoken) -> Bool {
        a.start == b.start && a.allDay == b.allDay && a.title == b.title
    }
}

enum Router {
    /// **기준일과 길이를 따로 듭니다.**
    ///
    /// 전에는 "오늘부터 N 날" 하나로 뒀는데, 그러면 "내일 일정" 이 오늘 것까지
    /// 읽습니다. 실기기에서 오늘 있는 추석 연휴가 내일 일정으로 나왔습니다.
    private static let days: [(key: String, offset: Int, span: Int, label: String)] = [
        ("이번 주", 0, 7, "이번 주"), ("이번주", 0, 7, "이번 주"),
        ("모레", 2, 1, "모레"), ("내일", 1, 1, "내일"), ("오늘", 0, 1, "오늘"),
    ]

    /// 일정을 묻는다는 것을 확실히 하는 말.
    ///
    /// **날짜 낱말만으로는 부족합니다.** "오늘 저녁 메뉴 추천" 이 일정 조회로
    /// 샜습니다 — "오늘" 하나에 걸린 것입니다.
    private static let calendarWords = ["일정", "스케줄", "약속", "캘린더", "뭐 있"]

    /// 넣으라는 말. 조회와 추가를 가릅니다.
    private static let addWords = ["추가", "등록", "잡아", "넣어", "만들어", "저장"]

    /// 미리알림으로 읽는 말. **일정보다 먼저 봅니다.**
    private static let reminderPhrases = [
        "미리알림에 추가", "미리 알림에 추가", "미리알림 추가", "미리 알림 추가",
        "미리알림으로", "미리 알림으로", "미리알림", "미리 알림",
        "할 일 추가", "할일 추가", "리마인더",
    ]

    static func route(_ utterance: String) -> NubiIntent {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .ask("") }

        // "내일 장보기 미리알림" 은 일정 조회가 아닙니다. 일정 낱말을 먼저 보면
        // 이 문장이 조회로 새고, 사용자는 추가한 줄 압니다.
        if let phrase = reminderPhrases.first(where: { text.contains($0) }) {
            // 날짜와 시각을 같이 읽습니다. **마감이 없는 미리알림은 울리지
            // 않습니다** — 넣었다고 답해놓고 아무 일도 안 일어나던 자리입니다.
            return .addReminder(DateTalk.parse(text.replacingOccurrences(of: phrase, with: " ")))
        }

        let asksCalendar = calendarWords.contains { text.contains($0) }
        let asksAdd = addWords.contains { text.contains($0) }
        let day = days.first { text.contains($0.key) }
        let hasClock = text.range(of: #"\d{1,2}\s*시"#, options: .regularExpression) != nil

        // "내일 오후 1시에 운동하기 추가해줘" 가 모델로 샜던 자리입니다.
        // **"일정" 이라는 말이 없어도** 날짜나 시각이 있으면 캘린더 일입니다.
        if asksAdd, asksCalendar || day != nil || hasClock {
            return .addEvent(DateTalk.parse(text))
        }

        if let day, asksCalendar || text == day.key {
            return .events(offset: day.offset, span: day.span, label: day.label)
        }
        if asksCalendar { return .events(offset: 0, span: 1, label: "오늘") }

        return .ask(text)
    }

}
