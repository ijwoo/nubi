import CoreLocation
import Foundation

/// 누비가 아는 것.
///
/// **지금까지는 매번 다시 말해야 했습니다.** 다이어트 중인 것도, 헬스장이
/// 어딘지도 여섯 턴이 지나면 사라졌습니다. 대화 기록은 최근 것만 보내고,
/// 그래야 하기 때문입니다.
///
/// 여기 적힌 것은 **매 요청의 시스템 프롬프트에 들어갑니다.** 그래서 짧고
/// 적어야 합니다. 서른 개 · 한 줄 예순 자.
///
/// **말할 때만 기억합니다.** 대화를 몰래 훑어서 사실을 캐지 않습니다. 기억할
/// 때는 답에 그렇게 말합니다 — 조용히 기억하는 물건은 무섭습니다.
enum Memory {
    /// 프롬프트가 길어지면 매 요청이 느려지고 비싸집니다.
    static let limit = 30
    static let maxLength = 60

    struct Fact: Codable, Identifiable, Hashable {
        var id = UUID()
        var kind: Kind
        var text: String
        var at: Date
        /// 장소일 때만. 좌표가 있어야 "집에 도착하면" 이 됩니다.
        var lat: Double?
        var lon: Double?

        var coordinate: CLLocationCoordinate2D? {
            guard let lat, let lon else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }

        /// 상태는 늙습니다. 지우지는 않습니다 — 지우면 왜 잊었는지 모릅니다.
        var stale: Bool {
            guard let life = kind.life else { return false }
            return Date().timeIntervalSince(at) > life
        }
    }

    enum Kind: String, Codable, CaseIterable {
        case fact, taste, state, place

        var label: String {
            switch self {
            case .fact: "사실"
            case .taste: "선호"
            case .state: "상태"
            case .place: "장소"
            }
        }

        /// 얼마나 가는가. nil 이면 안 늙습니다.
        var life: TimeInterval? {
            self == .state ? 90 * 24 * 3600 : nil
        }
    }

    enum Refused: Error, LocalizedError {
        case looksLikeSecret
        case empty

        var errorDescription: String? {
            switch self {
            case .looksLikeSecret: "숫자가 길게 이어진 것은 기억하지 않습니다."
            case .empty: "기억할 내용이 비어 있습니다."
            }
        }
    }

    // MARK: 저장소

    private static let key = "memory.facts"
    private static var store: UserDefaults? { UserDefaults(suiteName: NubiLog.group) }

    static func all() -> [Fact] {
        guard let data = store?.data(forKey: key),
              let facts = try? JSONDecoder().decode([Fact].self, from: data) else { return [] }
        return facts
    }

    private static func save(_ facts: [Fact]) {
        guard let data = try? JSONEncoder().encode(facts) else { return }
        store?.set(data, forKey: key)
    }

    // MARK: 넣기

    /// **비밀은 받지 않습니다.**
    ///
    /// 여섯 자리 넘게 이어진 숫자가 있으면 거부합니다. 카드번호·주민번호·
    /// 비밀번호가 여기 들어갈 자리를 없앱니다. 말로 막을 일이 아닙니다.
    private static func looksLikeSecret(_ text: String) -> Bool {
        var run = 0
        for ch in text {
            run = ch.isNumber ? run + 1 : 0
            if run >= 6 { return true }
        }
        return false
    }

    @discardableResult
    static func remember(_ text: String, kind: Kind = .fact,
                         at spot: CLLocationCoordinate2D? = nil) throws -> Fact {
        let line = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
        guard !line.isEmpty else { throw Refused.empty }
        guard !looksLikeSecret(line) else {
            NubiLog.write("[기억] 숫자가 길어 거절")
            throw Refused.looksLikeSecret
        }
        var facts = all()
        let fact = Fact(kind: kind, text: line, at: Date(),
                        lat: spot?.latitude, lon: spot?.longitude)
        // 같은 것을 또 말하면 새로 쌓지 않고 덮습니다. 날짜가 새로워져야
        // 오래된 상태가 다시 최신이 됩니다 — "아직 다이어트 중" 이 그 말입니다.
        if let same = facts.firstIndex(where: { Events.similar($0.text, line) >= 0.7 }) {
            facts[same] = fact
        } else {
            facts.append(fact)
        }
        save(trimmed(facts))
        NubiLog.write("[기억] \(kind.label) \(line)")
        return fact
    }

    /// 넘치면 **늙은 상태부터**, 그다음 오래된 것부터 밀어냅니다.
    private static func trimmed(_ facts: [Fact]) -> [Fact] {
        guard facts.count > limit else { return facts }
        var kept = facts
        while kept.count > limit {
            let victim = kept.firstIndex(where: { $0.stale })
                ?? kept.indices.min(by: { kept[$0].at < kept[$1].at })
            guard let victim else { break }
            NubiLog.write("[기억] 자리가 없어 밀어냄: \(kept[victim].text)")
            kept.remove(at: victim)
        }
        return kept
    }

    // MARK: 빼기

    /// 지운 것들을 돌려줍니다. 비었으면 못 찾은 것입니다.
    @discardableResult
    static func forget(about name: String) -> [Fact] {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return [] }
        let facts = all()
        let gone = facts.filter {
            $0.text.contains(wanted) || Events.similar($0.text, wanted) >= 0.5
        }
        guard !gone.isEmpty else { return [] }
        save(facts.filter { hit in !gone.contains { $0.id == hit.id } })
        NubiLog.write("[기억] 지움: " + gone.map(\.text).joined(separator: ", "))
        return gone
    }

    static func remove(_ fact: Fact) {
        save(all().filter { $0.id != fact.id })
    }

    static func clear() {
        store?.removeObject(forKey: key)
        NubiLog.write("[기억] 전부 지움")
    }

    // MARK: 쓰기

    /// 이름으로 아는 자리를 찾습니다. "집", "헬스장".
    static func place(named name: String) -> Fact? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        guard wanted.count >= 1 else { return nil }
        return all().first {
            $0.kind == .place && $0.coordinate != nil
                && ($0.text.contains(wanted) || wanted.contains($0.text))
        }
    }

    /// 시스템 프롬프트에 붙일 글. 아는 게 없으면 빈 문자열입니다.
    ///
    /// **지금 한 말이 이것보다 우선입니다.** 다이어트 중이라고 회식 메뉴까지
    /// 샐러드를 권하면 안 씁니다.
    static func brief() -> String {
        let facts = all()
        guard !facts.isEmpty else { return "" }
        let lines = facts.map { fact in
            let mark = fact.stale ? "\(fact.kind.label), 오래됨" : fact.kind.label
            return "· (\(mark)) \(fact.text)"
        }
        return """

        ## 아는 것
        \(lines.joined(separator: "\n"))
        이건 참고다. **지금 한 말이 이것보다 우선이다.** 오래됐다고 표시된 것은
        아직 맞는지 슬쩍 확인해라. 기억을 억지로 끼워 맞추지 마라.
        """
    }
}
