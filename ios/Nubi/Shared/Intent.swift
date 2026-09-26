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
    /// 가까운 곳 찾기.
    case places(String)
    /// 미리알림 하나를 끝냈다고 표시.
    case completeReminder(String)
    /// 일정을 지우거나 옮깁니다. **바로 하지 않고 묻습니다.**
    case editEvent(Pending.Kind, Spoken)
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

    /// 가까운 곳을 찾는 말. **이 낱말이 있으면 지도에 묻습니다.**
    private static let nearWords = ["근처", "주변", "가까운", "가까이"]

    /// 넣으라는 말. 조회와 추가를 가릅니다.
    private static let addWords = ["추가", "등록", "잡아", "넣어", "만들어", "저장"]

    /// 지우라는 말과 옮기라는 말. **넣으라는 말보다 먼저 봅니다.**
    private static let dropWords = ["취소", "삭제", "지워", "없애", "빼줘", "빼 줘"]
    private static let moveWords = ["옮겨", "옮기", "변경", "바꿔", "미뤄", "당겨"]

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

    /// 앞 턴이 지도였을 때의 이어지는 말.
    ///
    /// "말고" 가 있으면 **뒤쪽이 원하는 것**입니다 — "필라테스 말고 헬스장으로"
    /// 의 답은 헬스장입니다. 앞쪽을 같이 넣으면 찾던 것을 또 찾습니다.
    private static func placeFollowUp(_ text: String) -> String? {
        let marks = ["말고", "다른", "또", "더", "대신", "말구"]
        guard marks.contains(where: { text.contains($0) }) else { return nil }
        var rest = text
        if let range = rest.range(of: "말고") ?? rest.range(of: "말구") {
            rest = String(rest[range.upperBound...])
        }
        for word in ["다른", "대신", "또", "더", "곳도", "곳", "데도", "데", "것", "거",
                     "으로", "로", "도", "좀", "찾아줘", "찾아 줘", "알려줘", "보여줘", "해줘"] {
            rest = rest.replacingOccurrences(of: word, with: " ")
        }
        // 알맹이가 안 남으면 **같은 것을 더 보여달라**는 말입니다.
        // "다른 데 더 알려줘" 가 "데" 를 찾으러 가던 자리입니다.
        return rest.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// "우유 사기 완료" 에서 "우유 사기" 를 꺼냅니다.
    ///
    /// **"완료" 와 "체크" 만 봅니다.** "오늘 운동 했어" 같은 말까지 잡으면 그냥
    /// 하는 말이 미리알림 조작이 됩니다.
    private static func completedName(in text: String) -> String? {
        // "완료함", "완료했어" 도 같은 말입니다. 끝이 "완료" 여야만 본다면
        // "오늘 운동 완료함" 이 모델로 샙니다.
        let marks = ["완료함", "완료했어", "완료했음", "완료", "체크함", "체크했어", "체크"]
        for mark in marks where text.hasSuffix(mark) {
            var name = String(text.dropLast(mark.count))
            // 날짜 낱말은 이름이 아닙니다. "오늘 운동 완료함" 의 이름은 "운동" 입니다.
            for day in ["오늘", "어제", "내일"] {
                name = name.replacingOccurrences(of: day, with: " ")
            }
            let cleaned = name.split(separator: " ", omittingEmptySubsequences: true)
                .joined(separator: " ")
            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }

    /// 무엇을 찾는지만 남깁니다. "집 근처 헬스장 찾아줘" → "헬스장".
    private static func placeQuery(from text: String, removing near: String) -> String {
        var rest = text.replacingOccurrences(of: near, with: " ")
        for word in ["찾아줘", "찾아 줘", "알려줘", "알려 줘", "추천해줘", "추천", "어디", "있어", "있나", "좀", "집", "여기", "이"] {
            rest = rest.replacingOccurrences(of: word, with: " ")
        }
        let cleaned = rest.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return cleaned.isEmpty ? "카페" : cleaned
    }

    /// 날짜 낱말과 의문사를 걷어내고 알맹이가 남는가.
    private static func isSubstantive(_ text: String) -> Bool {
        var rest = text
        for day in days { rest = rest.replacingOccurrences(of: day.key, with: " ") }
        for word in queryWords + addWords + ["해줘", "줘", "좀", "내", "나의", "의"] {
            rest = rest.replacingOccurrences(of: word, with: " ")
        }
        return !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 앞 턴이 무엇이었는지 보고 갈립니다.
    ///
    /// **"다른 곳도 필라테스 말고 헬스장으로" 가 모델로 샜습니다.** 지도 이야기를
    /// 하던 중인데 "근처" 라는 낱말이 없어서 이어지지 않았습니다. 대화는 앞말을
    /// 물려받습니다.
    static func route(_ utterance: String, after last: Source? = nil) -> NubiIntent {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .ask("") }

        if last == .places, let refined = placeFollowUp(text) {
            return .places(refined)
        }

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

        // 지우기와 옮기기가 먼저입니다. "내일 운동 일정 취소" 에는 "일정" 이
        // 들어 있어서, 나중에 보면 조회로 샙니다.
        if dropWords.contains(where: { text.contains($0) }) {
            return .editEvent(.delete, DateTalk.parse(text))
        }
        if moveWords.contains(where: { text.contains($0) }) {
            return .editEvent(.move, DateTalk.parse(text))
        }

        // "우유 사기 완료" — 있는 미리알림 하나를 끝냅니다.
        if let done = completedName(in: text) { return .completeReminder(done) }

        // "집 근처 헬스장 찾아줘" — 모델도 웹도 아니고 지도가 답합니다.
        if let near = nearWords.first(where: { text.contains($0) }) {
            return .places(placeQuery(from: text, removing: near))
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
