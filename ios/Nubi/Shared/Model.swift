import Foundation

/// 자유 질문에 답하는 모델.
///
/// **Haiku 급입니다.** 빠른 모드의 목표가 수 초이고, 여기서 하는 일은 몇 문장을
/// 만드는 것입니다 ([ADR 0011](../../../docs/adr/0011-remote-engine-hybrid-client.md)).
enum Model {
    /// 어떤 모델을 쓸지.
    ///
    /// **빠른 쪽과 정확한 쪽이 다릅니다.** 영화 줄거리나 최신 정보에서 틀린 답이
    /// 섞여 나왔는데, 그건 모델 급의 문제였습니다. 일정·미리알림·지도는 모델을
    /// 아예 안 타므로 이 선택은 자유 질문에만 영향을 줍니다.
    enum Grade: String, CaseIterable, Identifiable {
        case fast, careful

        var id: String { rawValue }
        var label: String { self == .fast ? "빠르게" : "정확하게" }
        var note: String { self == .fast ? "1~2초" : "3~5초, 더 정확" }
        var model: String { self == .fast ? "claude-haiku-4-5" : "claude-sonnet-5" }
        /// 모델마다 쓸 수 있는 검색 도구가 다릅니다.
        var searchTool: String {
            self == .careful ? "web_search_20260209" : "web_search_20250305"
        }
    }

    private static let gradeKey = "model.grade"
    private static let searchKey = "model.search"
    private static var store: UserDefaults? { UserDefaults(suiteName: NubiLog.group) }

    static var grade: Grade {
        get { Grade(rawValue: store?.string(forKey: gradeKey) ?? "") ?? .fast }
        set { store?.set(newValue.rawValue, forKey: gradeKey) }
    }

    static var id: String { grade.model }

    /// 웹을 찾아보게 할까.
    ///
    /// **켜면 느려지고 값이 붙습니다.** 대신 날씨·최신 영화·가게 영업시간처럼
    /// 모델이 외워둘 수 없는 것에 답할 수 있게 됩니다. 일정·미리알림·지도는
    /// 모델을 안 타므로 그쪽 속도는 그대로입니다.
    static var searches: Bool {
        get { store?.object(forKey: searchKey) as? Bool ?? true }
        set { store?.set(newValue, forKey: searchKey) }
    }



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

    날씨, 오늘의 뉴스, 가게 영업시간, 최근 개봉작처럼 **지금 사실이 바뀌는 것**은
    웹을 찾아보고 답한다. 외워둔 것으로 답하면 틀린다. 외워둔 것으로 충분한
    질문에는 찾아보지 않는다 — 느려지기만 한다.

    일정과 미리알림은 앱의 다른 부분이 다룬다. 너는 직접 읽지도 쓰지도 못한다.
    **"추가했습니다", "등록했습니다", "넣었습니다", "저장했습니다" 라고 절대 쓰지 마라.**
    너는 그렇게 할 수 없고, 그렇게 말하면 사용자는 되지도 않은 것을 믿는다.
    그런 부탁이 네게 왔다면 첫 줄에 "아직 넣지 않았습니다" 라고 쓰고,
    둘째 줄에 어떻게 말하면 되는지 한 줄로 알려준다.
    일정은 "내일 3시 회의 일정 추가", 미리알림은 "우유 사기 미리알림" 처럼 말하면 된다.

    가까운 곳도 앱이 지도로 찾는다. **"지도가 없다" 고 말하지 마라.**
    "근처 헬스장", "주변 약국" 처럼 근처·주변·가까운 을 넣어 말하면 된다고 알려준다.
    다른 지도 앱을 쓰라고 권하지 않는다.
    """

    /// 지금이 언제이고 오늘 무엇이 있는지.
    ///
    /// **모델은 오늘이 며칠인지도 모릅니다.** 그래서 "오늘 저녁 추천" 에 일반론만
    /// 답했습니다. 토큰 몇십 개로 답이 구체적으로 바뀝니다.
    private static func system(now: Date, sky: Weather.Snapshot?) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일 EEEE a h시 m분"
        var text = base + "\n\n지금은 \(f.string(from: now))이다."
        let brief = Events.todayBrief()
        if !brief.isEmpty { text += "\n사용자의 오늘 일정: \(brief)" }
        if let sky { text += "\n지금 날씨: \(sky.line)" }
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
        // 날씨를 미리 넣어둡니다. "오늘 운동 어디서" 에 비 소식을 보고 답해야 합니다.
        let sky = await Weather.quiet()

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": id,
            "max_tokens": 700,
            "system": system(now: now, sky: sky),
            "messages": messages(history, question),
        ]
        if searches {
            body["tools"] = [["type": grade.searchTool, "name": "web_search", "max_uses": 3]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw Failure.http(code, String(data: data, encoding: .utf8) ?? "")
        }

        let text = Self.text(in: data)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let headline = String(lines.first ?? "답이 비어 있습니다")
        if !lines.isEmpty { lines.removeFirst() }
        // 찾아봤으면 그렇게 적습니다. **어디서 온 답인지가 보여야 합니다.**
        return NubiAnswer(headline: headline,
                          detail: lines.joined(separator: "\n"),
                          source: Self.searched(in: data) ? .search : .model)
    }

    /// 웹을 실제로 찾아봤는가. 도구 결과 블록이 오면 찾아본 것입니다.
    private static func searched(in data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = root["content"] as? [[String: Any]]
        else { return false }
        return blocks.contains { ($0["type"] as? String)?.contains("web_search") == true }
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
