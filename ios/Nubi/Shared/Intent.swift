import Foundation

/// 발화가 무엇을 원하는지.
///
/// 맥의 Router 와 같은 규칙입니다 — **모델을 쓰지 않고 코드로 가릅니다.**
/// 의도 판별에 모델을 부르면 "내일 일정 뭐야" 한 마디에 왕복이 두 번 붙고,
/// 빠른 모드의 목표가 수 초인데 그 절반을 여기서 씁니다.
enum NubiIntent: Equatable {
    /// 일정 조회. `days` 는 오늘부터 몇 날을 볼 것인가.
    case events(days: Int, label: String)
    /// 미리알림 추가. 되돌릴 수 있고 상대가 없으므로 묻지 않고 실행합니다.
    case addReminder(title: String)
    /// 그 외. 모델이 답합니다.
    case ask(String)
}

enum Router {
    /// 일정 조회로 읽는 말. 앞의 것이 먼저 걸립니다 — "내일" 이 "일정" 보다 먼저여야
    /// "내일 일정" 이 오늘로 새지 않습니다.
    private static let eventPhrases: [(keys: [String], days: Int, label: String)] = [
        (["모레"], 3, "모레"),
        (["내일"], 2, "내일"),
        (["이번 주", "이번주", "주간"], 7, "이번 주"),
        (["오늘", "일정", "스케줄", "약속"], 1, "오늘"),
    ]

    /// 미리알림으로 읽는 말. 문장에서 이 말을 덜어낸 나머지가 제목이 됩니다.
    private static let reminderPhrases = [
        "미리알림에 추가", "미리 알림에 추가", "미리알림 추가", "미리 알림 추가",
        "미리알림으로", "미리 알림으로", "미리알림", "미리 알림",
        "할 일 추가", "할일 추가", "리마인더",
    ]

    static func route(_ utterance: String) -> NubiIntent {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .ask("") }

        // 미리알림이 먼저입니다. "내일 장보기 미리알림" 은 일정 조회가 아닙니다 —
        // 일정 낱말을 먼저 보면 이 문장이 조회로 새고, 사용자는 추가한 줄 압니다.
        if let phrase = reminderPhrases.first(where: { text.contains($0) }) {
            return .addReminder(title: title(from: text, removing: phrase))
        }
        for phrase in eventPhrases where phrase.keys.contains(where: { text.contains($0) }) {
            return .events(days: phrase.days, label: phrase.label)
        }
        return .ask(text)
    }

    /// 문장에서 명령어를 덜어내고 남은 것을 제목으로 씁니다.
    ///
    /// 아무것도 안 남으면 원문을 그대로 둡니다. 빈 제목의 미리알림은 나중에
    /// 무엇이었는지 알 수 없어서 없느니만 못합니다.
    private static func title(from text: String, removing phrase: String) -> String {
        var rest = text.replacingOccurrences(of: phrase, with: " ")
        for tail in ["해줘", "해 줘", "추가", "넣어줘", "등록"] {
            rest = rest.replacingOccurrences(of: tail, with: " ")
        }
        let cleaned = rest
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? text : cleaned
    }
}
