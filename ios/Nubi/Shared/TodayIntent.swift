import AppIntents
import Foundation

/// 제어 센터·잠금화면 컨트롤이 부르는 것. 대화창을 살리는 입구이기도 합니다.
///
/// **모델도 네트워크도 쓰지 않습니다.** EventKit 만 읽습니다. 스파이크에서 잰
/// 값이 근거입니다 — 잠금 상태에서 EventKit 에 닿고, 첫 호출 492ms, 그 뒤 65ms
/// 였습니다 ([벤치마크](../../../docs/benchmarks/2026-09-24-lockscreen-spike.md)).
///
/// **`LiveActivityIntent` 여야 합니다.** 평범한 `AppIntent` 는 확장에서 돌고,
/// 거기서는 대화창을 만들 수도 갱신할 수도 없습니다.
struct TodayEventsIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "오늘 일정"
    static let description = IntentDescription("오늘 일정을 잠금화면 대화창에 띄웁니다.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await Nubi.turn("오늘 일정", viaIntent: true)
        return .result()
    }
}
