import Foundation
#if canImport(AlarmKit)
import AlarmKit
#endif

/// 진짜 알람.
///
/// **타이머는 알림이라 무음 스위치를 못 넘습니다.** 시계 앱 알람만 넘는데,
/// iOS 26 부터 앱도 같은 것을 걸 수 있습니다 — 무음과 집중 모드를 뚫고,
/// 화면을 덮고, 끌 때까지 울립니다.
///
/// 그래서 **알림과 성격이 다릅니다.** 라면 3분은 알림이고, 아침 7시는
/// 알람입니다. 잘못 고르면 못 일어나거나 시끄럽습니다.
///
/// 이름과 시각은 우리가 들고 있습니다. `AlarmManager` 는 걸린 알람의 목록을
/// 주지만 **무슨 알람인지는 돌려주지 않습니다.**
enum Alarms {
    struct Set: Codable, Identifiable, Hashable {
        var id: UUID
        var label: String
        var at: Date
        /// 1 이 일요일, 7 이 토요일. 비어 있으면 한 번만.
        var weekly: [Int] = []

        var repeats: Bool { !weekly.isEmpty }
    }

    enum Failure: Error, LocalizedError {
        case tooOld
        case denied

        var errorDescription: String? {
            switch self {
            case .tooOld: "이 아이폰에서는 알람을 걸 수 없습니다. iOS 26 부터 됩니다."
            case .denied: "알람 권한이 없습니다. 사용자가 앱에서 허용해야 합니다."
            }
        }
    }

    static var supported: Bool {
        if #available(iOS 26.0, *) { true } else { false }
    }

    // MARK: 우리가 들고 있는 것

    private static let key = "alarms.set"
    private static var store: UserDefaults? { UserDefaults(suiteName: NubiLog.group) }

    /// 걸어둔 것들. **시스템에 실제로 남아 있는 것만** 돌려줍니다 — 사용자가
    /// 설정에서 지웠을 수도 있습니다.
    static func all() -> [Set] {
        let mine = saved()
        guard #available(iOS 26.0, *), let live = try? AlarmManager.shared.alarms else { return mine }
        let ids = Swift.Set(live.map(\.id))
        let kept = mine.filter { ids.contains($0.id) }
        if kept.count != mine.count { remember(kept) }
        return kept.sorted { $0.at < $1.at }
    }

    private static func saved() -> [Set] {
        guard let data = store?.data(forKey: key),
              let rows = try? JSONDecoder().decode([Set].self, from: data) else { return [] }
        return rows
    }

    private static func remember(_ rows: [Set]) {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        store?.set(data, forKey: key)
    }

    // MARK: 권한

    /// 앱에서만 부릅니다.
    @discardableResult
    static func authorize() async -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        switch AlarmManager.shared.authorizationState {
        case .authorized: return true
        case .denied: return false
        default:
            let state = try? await AlarmManager.shared.requestAuthorization()
            let ok = state == .authorized
            NubiLog.write("[알람] 권한 \(ok ? "허용" : "거부")")
            return ok
        }
    }

    static var isAllowed: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return AlarmManager.shared.authorizationState == .authorized
    }

    // MARK: 걸기

    /// `at` 의 시·분만 씁니다. 되풀이면 요일이 날짜를 대신합니다.
    @discardableResult
    static func set(at when: Date, label: String, weekly: [Int] = []) async throws -> Set {
        guard #available(iOS 26.0, *) else { throw Failure.tooOld }
        // **앞에 있을 때는 그 자리에서 물어봅니다.** 설정으로 보내면 거기서
        // 흐름이 끊깁니다 — 위치 권한에서 배운 것입니다.
        if !isAllowed, Places.foreground { await authorize() }
        guard isAllowed else { throw Failure.denied }

        let name = label.isEmpty ? "알람" : label
        let parts = Calendar.current.dateComponents([.hour, .minute], from: when)
        let time = Alarm.Schedule.Relative.Time(hour: parts.hour ?? 7, minute: parts.minute ?? 0)
        let days = weekly.compactMap(weekday)
        let schedule: Alarm.Schedule = days.isEmpty
            ? .fixed(when)
            : .relative(.init(time: time, repeats: .weekly(days)))

        let attributes = AlarmAttributes<NubiAlarm>(
            presentation: AlarmPresentation(alert: alert(name)),
            metadata: NubiAlarm(label: name),
            tintColor: .init(red: 0.424, green: 0.412, blue: 0.878))

        let id = UUID()
        _ = try await AlarmManager.shared.schedule(
            id: id, configuration: .alarm(schedule: schedule, attributes: attributes))

        let row = Set(id: id, label: name, at: when, weekly: weekly)
        remember(saved() + [row])
        NubiLog.write("[알람] \(Format.short(when)) \(name)\(days.isEmpty ? "" : " 되풀이")")
        return row
    }

    @discardableResult
    static func cancel(id: String) -> Bool {
        guard #available(iOS 26.0, *), let uuid = UUID(uuidString: id) else { return false }
        try? AlarmManager.shared.cancel(id: uuid)
        remember(saved().filter { $0.id != uuid })
        return true
    }

    /// 이름이 비면 전부 끕니다.
    @discardableResult
    static func cancel(label: String = "") -> [Set] {
        let mine = all()
        let hits = label.isEmpty ? mine : mine.filter { $0.label.contains(label) }
        guard #available(iOS 26.0, *), !hits.isEmpty else { return [] }
        for row in hits { try? AlarmManager.shared.cancel(id: row.id) }
        remember(mine.filter { hit in !hits.contains { $0.id == hit.id } })
        return hits
    }

    // MARK: 속

    @available(iOS 26.0, *)
    private static func alert(_ name: String) -> AlarmPresentation.Alert {
        let stop = AlarmButton(text: "끄기", textColor: .white, systemImageName: "stop.fill")
        if #available(iOS 26.1, *) {
            return AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: name))
        }
        return AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: name),
                                       stopButton: stop)
    }

    @available(iOS 26.0, *)
    private static func weekday(_ number: Int) -> Locale.Weekday? {
        switch number {
        case 1: .sunday
        case 2: .monday
        case 3: .tuesday
        case 4: .wednesday
        case 5: .thursday
        case 6: .friday
        case 7: .saturday
        default: nil
        }
    }
}

#if canImport(AlarmKit)
/// 알람에 딸려 가는 것. 화면에 이름을 보여주려면 필요합니다.
@available(iOS 26.0, *)
struct NubiAlarm: AlarmMetadata {
    var label: String = "알람"
}
#endif
