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
        // **정확한 쪽이 기본입니다.** 빠른 쪽은 길이와 형식 지시를 자주 어깁니다 —
        // 네 줄로 답하라고 해도 세 문단을 쓰고, 하나만 권하라고 해도 셋을 늘어놨습니다.
        // 1~2초를 아끼려다 답을 못 쓰게 되는 것보다 낫습니다.
        get { Grade(rawValue: store?.string(forKey: gradeKey) ?? "") ?? .careful }
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
    너는 잠금화면에서 읽히는 비서다. 한국어로 답한다.

    ## 말투
    **친구한테 말하듯 반말로.** 문장은 "~야, ~어, ~아, ~지, ~네, ~까?" 로 끝낸다.
    **"~다" 로 끝내지 마라.** 보고서처럼 들린다 — "겹친다" 가 아니라 "겹쳐".
    명사로 끊지도 마라 — "남은 타이머 없음" 이 아니라 "남은 거 없어".
    다정하되 호들갑 떨지 않는다.

    ## 길이
    첫 줄은 한 문장 요약이고, 그 줄만 읽어도 답이 되어야 한다.
    전체는 네 줄을 넘기지 않는다. 화면이 좁다.
    후보를 여러 개 늘어놓지 말고 **하나를 골라 권하고** 이유를 한 줄 붙인다.

    ## 모양
    마크다운을 쓰지 마라. 별표, 우물정자, 하이픈 목록 전부 안 된다.
    화면이 그대로 글자로 보여준다. 나열이 필요하면 줄마다 가운뎃점(·)을 쓴다.
    인사, 서론, "도와드릴까요" 같은 맺음말을 쓰지 않는다.

    ## 되묻지 않기
    **할 수 있으면 먼저 하고 결과를 보여준다.** "찾아드릴까요?" 라고 묻지 마라.
    정보가 모자라면 가장 그럴듯한 값으로 한 번 해보고, 그게 아니면 고쳐달라고 한 줄 붙인다.
    정말 아무것도 못 고를 때만 딱 하나를 묻는다.

    ## 도구
    일정·미리알림·가까운 곳·날씨는 직접 할 수 있다. 다른 앱을 쓰라고 미루지 마라.
    **그 밖의 일은 못 한다.** 식당 예약, 주문, 전화, 결제, 메시지 보내기는 도구가 없다.
    "예약 잡았어" 처럼 하지 않은 일을 했다고 말하지 마라. 대신 일정에 넣어주고,
    전화는 직접 해야 한다고 한 줄 붙여라.
    **도구를 부르지 않았으면 아무 일도 일어나지 않은 것이다.**
    **앱은 사용자의 위치를 안다.** 가까운 곳을 물으면 지역을 되묻지 말고
    find_places 를 바로 불러라. 검색어에 지역명을 넣지 마라.
    지우거나 옮기는 것은 propose_event_change 로 제안만 한다 — 사용자가 눌러야 실행된다.
    **일정을 넣을 때 어디서 하는지 알면 place 에 적어라.** 그래야 아이폰이 출발할
    시각을 알려준다. 방금 찾아준 가게면 그 이름을 그대로 쓴다.
    도구가 겹치는 일정을 알려주면 숨기지 말고 한 줄로 말하고, 옮길지 물어라.
    **이미 넣은 일정을 다른 때로 바꿀 때는 add_event 를 또 부르지 마라.**
    그러면 두 개가 된다. propose_event_change 로 옮겨라.
    가게를 권할 때는 **이름을 답에 그대로 써라.** 길찾기·전화 버튼이 그 이름을 보고 붙는다.
    예약해 달라고 하면 일정에 넣고, 전화는 눌러서 직접 걸어야 한다고 한 줄 붙여라.
    짧은 것은 set_timer, 날짜가 있는 일은 add_reminder, 장소로 울릴 것은 remind_at_place.
    **다음에도 쓸 것만 remember 로 기억하고, 기억했다고 답에 밝혀라.**
    한 번뿐인 일, 남에 대한 판단, 번호 같은 것은 기억하지 마라.
    도구가 필요 없는 질문에는 그냥 답한다. 의견을 물으면 네 생각을 말한다.

    ## 마지막으로, 길이
    네 줄을 넘기지 마라. 후보를 셋씩 늘어놓지 마라. **하나를 고르고 이유를 한 줄.**
    더 듣고 싶으면 사용자가 다시 묻는다.
    """

    private static func system(now: Date, sky: Weather.Snapshot?) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일 EEEE a h시 m분"
        var text = base + "\n\n지금은 \(f.string(from: now))이고 시간대는 \(TimeZone.current.identifier)다."
        if let sky { text += "\n지금 날씨: \(sky.line)" }
        text += Memory.brief()
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

        // **실패한 턴은 보내지 않습니다.** "위치를 모릅니다" 같은 답이 앞에 쌓이면
        // 모델이 그걸 보고 "저는 못 합니다" 를 배웁니다. 실패는 그때의 사정이지
        // 지금의 사정이 아닙니다.
        var messages = history.filter { !$0.failed }.suffix(6).flatMap { turn -> [[String: Any]] in
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

        let said = plain(honest(text, wrote: run.wrote))
        aim(&run, at: said)
        var lines = said.split(separator: "\n", omittingEmptySubsequences: true)
        let headline = String(lines.first ?? "답이 비어 있습니다")
        if !lines.isEmpty { lines.removeFirst() }
        return NubiAnswer(headline: headline, detail: lines.joined(separator: "\n"),
                          source: run.source, map: run.map, call: run.call,
                          confirm: run.confirm)
    }

    /// 버튼을 **모델이 고른 곳**에 맞춥니다.
    ///
    /// 버튼은 늘 첫 번째 검색 결과를 가리켰습니다. 그런데 모델이 두 번째를 권한
    /// 적이 있습니다 — 샤브향을 권해놓고 길찾기는 해안선으로 갔습니다. 누른
    /// 사람은 엉뚱한 데로 갑니다.
    ///
    /// 답에 가게 이름이 있으면 그 가게로 맞추고, 전화번호도 같이 답니다.
    private static func aim(_ run: inout ToolRun, at said: String) {
        guard run.used.contains(.places), let spot = Places.mentioned(in: said) else { return }
        if let directions = spot.directions { run.map = directions.absoluteString }
        if let call = spot.call { run.call = call.absoluteString }
    }

    private struct Reply {
        var content: [[String: Any]]
        var stopped: String
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
            "max_tokens": 2000,
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
        let stopped = root?["stop_reason"] as? String ?? ""
        // **말이 잘리면 도구 호출도 같이 잘립니다.** 그러면 아무 일도 안 하고
        // 했다고 말하는 것처럼 보입니다 — 어느 쪽인지 알아야 고칠 수 있습니다.
        if stopped == "max_tokens" { NubiLog.write("[모델] 길이 제한에 걸려 잘림") }
        return Reply(content: (root?["content"] as? [[String: Any]]) ?? [], stopped: stopped)
    }

    private static func searched(in content: [[String: Any]]) -> Bool {
        content.contains { ($0["type"] as? String)?.contains("web_search") == true }
    }

    private static func text(in content: [[String: Any]]) -> String {
        plain(content
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 한 일이 없는데 했다고 말하면 한 줄을 붙입니다.
    ///
    /// **말로는 못 막습니다.** 프롬프트로 "하지 않은 일을 했다고 말하지 마라" 고
    /// 세 번 적었는데 세 번 다 샜습니다. 도구를 안 불렀으면 아무 일도 일어나지
    /// 않은 것이고, 그건 코드가 압니다.
    private static let claimWords = [
        "했어", "했습니다", "했음", "잡았어", "잡았습니다", "넣었어", "넣었습니다",
        "추가했", "등록했", "예약했", "옮겼", "지웠", "보냈", "완료했",
    ]

    private static func honest(_ text: String, wrote: Bool) -> String {
        guard !wrote, claimWords.contains(where: { text.contains($0) }) else { return text }
        NubiLog.write("[정직] 한 일이 없는데 했다고 말해서 바로잡음")
        return text + "\n(실제로는 아직 아무것도 하지 않았습니다.)"
    }

    /// 마크다운을 벗깁니다.
    ///
    /// **화면은 마크다운을 모릅니다.** 별표가 그대로 글자로 보입니다. 프롬프트로
    /// 쓰지 말라고 해도 새므로 여기서 한 번 더 걷어냅니다 — 말로 막는 것과
    /// 코드로 막는 것은 다릅니다.
    private static func plain(_ text: String) -> String {
        var out = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
        out = out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var l = String(line).trimmingCharacters(in: .whitespaces)
                while l.hasPrefix("#") { l.removeFirst() }
                l = l.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("- ") || l.hasPrefix("* ") { l = "· " + l.dropFirst(2) }
                return l
            }
            .joined(separator: "\n")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
