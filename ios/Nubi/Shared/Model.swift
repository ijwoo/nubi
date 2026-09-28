import Foundation

/// 모델. **갈래를 고르는 것도 모델이 합니다.**
///
/// 낱말 규칙으로 갈래를 정하던 것을 그만뒀습니다. "오늘 덥나" 를 날씨로 보내려면
/// 낱말을 더 넣어야 하고, 넣을수록 "여자친구랑 저녁메뉴 추천" 같은 말이 엉뚱한
/// 곳으로 샙니다. 어긋날 때마다 프롬프트로 회피를 가르쳤더니 모델이 "지도나 검색
/// 앱에서 찾으세요" 라고 답하는 물건이 됐습니다.
///
/// 이제 일정·미리알림·지도·날씨를 [도구](Tools.swift)로 주고 무엇을 쓸지는 모델이
/// 정합니다. 대신 왕복이 붙습니다 — 그래서 자주 쓰는 몇 마디는
/// [빠른 길](FastPath.swift)로 남겨 뒀습니다.
enum Model {
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
    static var searches: Bool {
        get { store?.object(forKey: searchKey) as? Bool ?? true }
        set { store?.set(newValue, forKey: searchKey) }
    }

    enum Failure: Error, LocalizedError, Equatable {
        case noKey
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .noKey: "모델 키가 없습니다. 설정에서 넣어주세요."
            case let .http(code, body): "모델이 답하지 않았습니다 (HTTP \(code)) \(body.prefix(120))"
            }
        }
    }

    /// **첫 줄이 한 문장 요약이어야 합니다.** 잠금화면은 그 줄만 보여줍니다.
    private static let base = """
    너는 사용자의 아이폰에서 도는 비서다. 한국어로 답한다.
    첫 줄은 한 문장 요약이다. 그 줄만 읽어도 답이 되어야 한다.
    그다음 줄부터 필요한 만큼 자세히 쓴다. 세 문단을 넘기지 않는다.
    인사나 서론은 쓰지 않는다.

    일정·미리알림·가까운 곳·날씨는 도구로 직접 할 수 있다. 필요하면 바로 쓴다.
    **다른 앱을 쓰라고 미루지 마라.** 네가 할 수 있는 일이다.
    지우거나 옮기는 것은 propose_event_change 로 제안만 한다 — 사용자가 눌러야 실행된다.
    도구가 필요 없는 질문에는 그냥 답한다. 추천이나 의견을 물으면 네 생각을 말한다.
    """

    private static func system(now: Date, sky: Weather.Snapshot?) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일 EEEE a h시 m분"
        var text = base + "\n\n지금은 \(f.string(from: now))이고 시간대는 \(TimeZone.current.identifier)다."
        if let sky { text += "\n지금 날씨: \(sky.line)" }
        return text
    }

    /// 한 번의 물음. 도구를 쓰면 쓰고, 안 쓰면 바로 답합니다.
    ///
    /// 도구를 세 번까지 돌립니다. 그 이상은 답을 못 내고 맴도는 것이라, 거기서
    /// 멈추고 지금까지 말한 것을 돌려줍니다.
    static func answer(to question: String, history: [Turn] = [],
                       now: Date = Date()) async throws -> NubiAnswer {
        guard let key = Secrets.apiKey else { throw Failure.noKey }
        let sky = await Weather.quiet()

        var messages = history.suffix(6).flatMap { turn -> [[String: Any]] in
            [["role": "user", "content": String(turn.asked.prefix(400))],
             ["role": "assistant", "content": String(turn.full.prefix(800))]]
        }
        messages.append(["role": "user", "content": question])

        var run = ToolRun()
        var text = ""

        for _ in 0..<4 {
            let reply = try await send(key: key, system: system(now: now, sky: sky), messages: messages)
            text = Self.text(in: reply.content)
            if Self.searched(in: reply.content) { run.used.insert(.search) }

            let calls = reply.content.filter { $0["type"] as? String == "tool_use" }
            guard !calls.isEmpty else { break }

            messages.append(["role": "assistant", "content": reply.content])
            var results: [[String: Any]] = []
            for call in calls {
                guard let name = call["name"] as? String, let id = call["id"] as? String else { continue }
                let input = call["input"] as? [String: Any] ?? [:]
                let out = await Tools.run(name, input, into: &run)
                NubiLog.write("[도구] \(name) → \(out.prefix(60))")
                results.append(["type": "tool_result", "tool_use_id": id, "content": out])
            }
            messages.append(["role": "user", "content": results])
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let headline = String(lines.first ?? "답이 비어 있습니다")
        if !lines.isEmpty { lines.removeFirst() }
        return NubiAnswer(headline: headline, detail: lines.joined(separator: "\n"),
                          source: run.source, map: run.map, confirm: run.confirm)
    }

    private struct Reply {
        var content: [[String: Any]]
    }

    private static func send(key: String, system: String,
                             messages: [[String: Any]]) async throws -> Reply {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var tools: [[String: Any]] = Tools.schema
        if searches {
            tools.append(["type": grade.searchTool, "name": "web_search", "max_uses": 3])
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": id,
            "max_tokens": 900,
            "system": system,
            "messages": messages,
            "tools": tools,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw Failure.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return Reply(content: (root?["content"] as? [[String: Any]]) ?? [])
    }

    private static func searched(in content: [[String: Any]]) -> Bool {
        content.contains { ($0["type"] as? String)?.contains("web_search") == true }
    }

    private static func text(in content: [[String: Any]]) -> String {
        content
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
