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
    /// 안 끝난 미리알림 조회.
    case reminders
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
        "할 일 추가", "할일 추가", "할 일", "할일", "리마인더", "투두",
    ]

    /// 묻는 말. 넣으라는 말과 가릅니다.
    private static let queryWords = ["뭐", "무엇", "있어", "있나", "보여", "알려", "뭔가", "목록", "리스트"]

    /// 물음표를 붙이는 말. **날짜와 시각이 있어도 이게 있으면 묻는 것입니다.**
    ///
    /// "내일 오후 4시에 뭐 먹을까" 를 일정으로 넣으면 안 됩니다.
    private static let questionWords = [
        "뭐", "무엇", "어때", "어떨", "추천", "할까", "좋을까", "어디", "언제", "왜", "어떻게", "얼마",
    ]

    /// 날짜 낱말과 의문사를 걷어내고 알맹이가 남는가.
    private static func isSubstantive(_ text: String) -> Bool {
        var rest = text
        for day in days { rest = rest.replacingOccurrences(of: day.key, with: " ") }
        for word in queryWords + addWords + ["해줘", "줘", "좀", "내", "나의", "의"] {
            rest = rest.replacingOccurrences(of: word, with: " ")
        }
        return !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func route(_ utterance: String) -> NubiIntent {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .ask("") }

        // "내일 장보기 미리알림" 은 일정 조회가 아닙니다. 일정 낱말을 먼저 보면
        // 이 문장이 조회로 새고, 사용자는 추가한 줄 압니다.
        if let phrase = reminderPhrases.first(where: { text.contains($0) }) {
            let rest = text.replacingOccurrences(of: phrase, with: " ")
            // **넣으라는 말인지 묻는 말인지는 남는 것이 가릅니다.**
            // "우유 사기 미리알림" 은 넣으라는 것이고 "오늘 할일" 은 묻는 것입니다.
            // 미리알림 낱말을 떼고 남은 것이 알맹이면 넣기, 날짜나 의문사뿐이면 조회.
            if isSubstantive(rest) {
                // 날짜와 시각을 같이 읽습니다. **마감이 없는 미리알림은 울리지
                // 않습니다** — 넣었다고 답해놓고 아무 일도 안 일어나던 자리입니다.
                return .addReminder(DateTalk.parse(rest))
            }
            return .reminders
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

        // "내일 헬스장가야돼 오후 4시에" — 넣으라는 말이 없어도 날짜와 시각이
        // 같이 있으면 일정입니다. **묻는 말이 아니어야 합니다** — "내일 오후 4시에
        // 뭐 먹을까" 를 일정으로 넣으면 안 됩니다.
        let asksQuestion = questionWords.contains { text.contains($0) } || text.hasSuffix("?")
        if !asksQuestion, day != nil, hasClock {
            return .addEvent(DateTalk.parse(text))
        }

        if let day, asksCalendar || text == day.key {
            return .events(offset: day.offset, span: day.span, label: day.label)
        }
        if asksCalendar { return .events(offset: 0, span: 1, label: "오늘") }

        return .ask(text)
    }

}
