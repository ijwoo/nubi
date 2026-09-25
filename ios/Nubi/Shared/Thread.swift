import Foundation

/// 답이 어디서 나왔는가. 네트워크를 탔는지 아닌지가 여기서 보입니다.
enum Source: String, Codable {
    case events, reminders, model, none

    var label: String? {
        switch self {
        case .events: "일정"
        case .reminders: "미리알림"
        case .model: "모델"
        case .none: nil
        }
    }
}

/// 한 번 묻고 한 번 답한 것.
struct Turn: Codable, Identifiable, Hashable {
    var id = UUID()
    var asked: String
    /// 한 문장 요약. **잠금화면은 이것만 보여줍니다.**
    var headline: String
    /// 나머지. 앱에서만 보입니다.
    var detail: String
    var source: Source
    var failed: Bool
    var at: Date
    /// 앱 밖에서 물었는가. 잠금화면과 단축어가 여기 해당합니다.
    var viaIntent: Bool

    var full: String { detail.isEmpty ? headline : "\(headline)\n\(detail)" }
}

/// 대화 하나. **앱과 잠금화면이 같이 씁니다.**
///
/// 잠금화면에서 물은 것이 앱에 없고 앱에서 물은 것이 잠금화면에 한 줄만 남던
/// 것을 없앱니다. 둘이 같은 파일을 보므로 잠금화면은 마지막 한 턴을 비추는
/// 창이 되고, 앱은 전체를 스크롤합니다.
///
/// 앱과 확장이 동시에 쓰면 한쪽이 덮일 수 있습니다. 사람이 한 번에 한 군데서만
/// 묻는 물건이라 잠금장치를 두지 않았습니다 — **여기서 다투면 그때 답니다.**
enum Thread {
    /// 오래된 것부터 버립니다. 잠금화면용 물건이라 길게 들고 있을 이유가 없습니다.
    static let limit = 100

    private static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: NubiLog.group)?
            .appendingPathComponent("thread.json")
    }

    static func load() -> [Turn] {
        guard let url, let data = try? Data(contentsOf: url),
              let turns = try? JSONDecoder().decode([Turn].self, from: data)
        else { return [] }
        return turns
    }

    static func append(_ turn: Turn) {
        var turns = load()
        turns.append(turn)
        if turns.count > limit { turns.removeFirst(turns.count - limit) }
        save(turns)
    }

    static func remove(_ turn: Turn) {
        save(load().filter { $0.id != turn.id })
    }

    static func clear() { save([]) }

    static var last: Turn? { load().last }

    private static func save(_ turns: [Turn]) {
        guard let url, let data = try? JSONEncoder().encode(turns) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
