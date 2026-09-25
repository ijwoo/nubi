import Foundation

/// 자유 질문에 답하는 모델.
///
/// **Haiku 급입니다.** 빠른 모드의 목표가 수 초이고, 여기서 하는 일은 몇 문장을
/// 만드는 것입니다 ([ADR 0011](../../../docs/adr/0011-remote-engine-hybrid-client.md)).
enum Model {
    static let id = "claude-haiku-4-5"

    enum Failure: Error, LocalizedError {
        case noKey
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .noKey: "모델 키가 없습니다. 설정에서 넣어주세요."
            case let .http(code, body): "모델이 답하지 않았습니다 (HTTP \(code)) \(body.prefix(120))"
            }
        }
    }

    /// **첫 줄이 한 문장 요약이어야 합니다.**
    ///
    /// 잠금화면은 그 줄만 보여주고 앱이 전문을 보여줍니다. 길이를 `max_tokens`
    /// 로만 묶으면 문장이 중간에서 잘립니다.
    private static let base = """
    너는 사용자의 아이폰에서 도는 비서다. 한국어로 답한다.
    첫 줄은 한 문장 요약이다. 그 줄만 읽어도 답이 되어야 한다.
    그다음 줄부터 필요한 만큼 자세히 쓴다. 세 문단을 넘기지 않는다.
    인사나 서론은 쓰지 않는다. 모르면 모른다고 한 줄로 말한다.

    일정과 미리알림은 앱의 다른 부분이 다룬다. 너는 직접 읽거나 쓰지 않는다.
    그런 부탁이 네게 왔다면 **하지 않았다고 먼저 말하고** 이렇게 안내한다.
    일정은 "오늘 일정", "내일 3시 회의 일정 추가" 처럼,
    미리알림은 "오늘 할일", "우유 사기 미리알림" 처럼 말하면 앱이 처리한다.
    앱이 못 한다고 말하지 않는다 — 말투만 바꾸면 된다.
    """

    /// 지금이 언제이고 오늘 무엇이 있는지.
    ///
    /// **모델은 오늘이 며칠인지도 모릅니다.** 그래서 "오늘 저녁 추천" 에 일반론만
    /// 답했습니다. 토큰 몇십 개로 답이 구체적으로 바뀝니다.
    private static func system(now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일 EEEE a h시 m분"
        var text = base + "\n\n지금은 \(f.string(from: now))이다."
        let brief = Events.todayBrief()
        if !brief.isEmpty { text += "\n사용자의 오늘 일정: \(brief)" }
        return text
    }

    /// 앞의 말을 같이 보냅니다.
    ///
    /// 없으면 "영화 추천" 다음의 "액션으로" 가 무슨 말인지 모릅니다. 대화 화면을
    /// 만들어 놓고 정작 대화가 안 되던 자리입니다. 여섯 턴이면 충분하고,
    /// 그보다 길면 잠금화면 한 마디에 붙는 값이 커집니다.
    private static func messages(_ history: [Turn], _ question: String) -> [[String: String]] {
        var list: [[String: String]] = []
        for turn in history.suffix(6) {
            list.append(["role": "user", "content": String(turn.asked.prefix(400))])
            list.append(["role": "assistant", "content": String(turn.full.prefix(800))])
        }
        list.append(["role": "user", "content": question])
        return list
    }

    static func answer(to question: String, history: [Turn] = [],
                       now: Date = Date()) async throws -> NubiAnswer {
        guard let key = Secrets.apiKey else { throw Failure.noKey }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": id,
            "max_tokens": 700,
            "system": system(now: now),
            "messages": messages(history, question),
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw Failure.http(code, String(data: data, encoding: .utf8) ?? "")
        }

        let text = Self.text(in: data)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let headline = String(lines.first ?? "답이 비어 있습니다")
        if !lines.isEmpty { lines.removeFirst() }
        return NubiAnswer(headline: headline,
                          detail: lines.joined(separator: "\n"),
                          source: .model)
    }

    /// 응답의 `content` 는 블록 배열입니다. `text` 블록만 이어 붙입니다.
    private static func text(in data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = root["content"] as? [[String: Any]]
        else { return "" }
        return blocks
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
