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
    private static let system = """
    너는 사용자의 아이폰에서 도는 비서다. 한국어로 답한다.
    첫 줄은 한 문장 요약이다. 그 줄만 읽어도 답이 되어야 한다.
    그다음 줄부터 필요한 만큼 자세히 쓴다. 세 문단을 넘기지 않는다.
    인사나 서론은 쓰지 않는다. 모르면 모른다고 한 줄로 말한다.

    너는 일정이나 미리알림을 직접 추가·수정·삭제할 수 없다. 앱의 다른 부분이 한다.
    사용자가 그런 것을 부탁했는데 네게 왔다면 **하지 않았다고 먼저 말하고**,
    "일정" 이나 "미리알림" 이라는 말을 넣어 다시 말해달라고 한 줄로 안내한다.
    했다고 말하지 않는다.
    """

    static func answer(to question: String) async throws -> NubiAnswer {
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
            "system": system,
            "messages": [["role": "user", "content": question]],
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
