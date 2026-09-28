import Foundation
import UserNotifications

/// "10분 뒤 알려줘".
///
/// **아이폰에는 앱이 타이머를 거는 공개 길이 없습니다.** 시계 앱의 타이머는
/// 시계 앱 것이고 우리가 못 만집니다. 그래서 알림으로 합니다 — 소리가 나고
/// 화면이 켜지는 것은 같고, 다만 무음 스위치를 넘지는 못합니다.
///
/// 미리알림으로도 되지만 그건 **목록에 남는 물건**입니다. 라면 3분은 목록에
/// 남을 일이 아닙니다.
enum Timers {
    private static let prefix = "timer."

    struct Running: Identifiable {
        let id: String
        let label: String
        let fires: Date
    }

    /// 걸어둡니다. 돌려주는 글자는 사람이 읽을 말입니다.
    static func set(minutes: Int, label: String) async throws -> String {
        let span = max(1, min(minutes, 60 * 12))
        let content = UNMutableNotificationContent()
        content.title = label.isEmpty ? "타이머" : label
        content.body = "\(span)분 지났습니다."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let fires = Date().addingTimeInterval(TimeInterval(span * 60))
        let request = UNNotificationRequest(
            identifier: "\(prefix)\(Int(fires.timeIntervalSince1970))",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(span * 60),
                                                       repeats: false))
        try await UNUserNotificationCenter.current().add(request)
        return "\(Format.time(fires))에 알립니다 (\(span)분)"
    }

    /// 걸어둔 것들.
    ///
    /// **울릴 시각은 식별자에서 읽습니다.** `nextTriggerDate()` 는 한 번만
    /// 울리는 방아쇠에 대해 nil 을 돌려주는 경우가 있고, 그러면 방금 건
    /// 타이머가 "없음" 으로 보입니다. 우리가 만든 이름이 가장 확실합니다.
    static func running() async -> [Running] {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return pending.compactMap { request -> Running? in
            guard request.identifier.hasPrefix(prefix),
                  let epoch = Double(request.identifier.dropFirst(prefix.count))
            else { return nil }
            let fires = Date(timeIntervalSince1970: epoch)
            guard fires > Date().addingTimeInterval(-5) else { return nil }
            return Running(id: request.identifier, label: request.content.title, fires: fires)
        }
        .sorted { $0.fires < $1.fires }
    }

    /// 이름이 비면 전부 지웁니다. **하나만 걸려 있으면 이름을 물을 이유가 없습니다.**
    static func cancel(label: String = "") async -> [String] {
        let all = await running()
        let hits = label.isEmpty ? all : all.filter { $0.label.contains(label) }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: hits.map(\.id))
        return hits.map(\.label)
    }
}
