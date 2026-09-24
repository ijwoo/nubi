import Foundation

/// 자유 질문에 답하는 모델.
///
/// **Haiku 급입니다.** 빠른 모드의 목표가 수 초이고, 여기서 하는 일은 한두 문장을
/// 만드는 것입니다 ([ADR 0011](../../../docs/adr/0011-remote-engine-hybrid-client.md)).
/// 온디바이스 모델은 나중에 오프라인 폴백으로만 봅니다 — 지원 기기가 한정되고
/// 한국어 품질이 미확인입니다.
enum Model {
    static let id = "claude-haiku-4-5"

    enum Failure: Error, LocalizedError {
        case noKey
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .noKey: "API 키가 없습니다. 설정에서 넣어주세요."
            case let .http(code, body): "모델이 답하지 않았습니다 (HTTP \(code)) \(body.prefix(120))"
            }
        }
    }

    /// 잠금화면 한 줄에 들어가야 하므로 길이를 시스템 프롬프트로 묶습니다.
    /// `max_tokens` 만으로 묶으면 문장이 중간에서 잘립니다.
    private static let system = """
    너는 사용자의 아이폰에서 도는 비서다. 한국어로, 두 문장 안에 답한다.
    인사나 서론 없이 답만 말한다. 모르면 모른다고 한 줄로 말한다.
    """

    static func answer(to question: String) async throws -> NubiAnswer {
        guard let key = Secrets.apiKey else { throw Failure.noKey }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": id,
            "max_tokens": 300,
            "system": system,
            "messages": [["role": "user", "content": question]],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw Failure.http(code, String(data: data, encoding: .utf8) ?? "")
        }

        let text = Self.text(in: data)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return NubiAnswer(
            headline: String(lines.first ?? "답이 비어 있습니다"),
            detail: lines.count > 1 ? lines.dropFirst().joined(separator: "\n") : "")
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
