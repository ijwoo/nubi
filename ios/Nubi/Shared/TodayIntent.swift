import AppIntents
import Foundation

/// 잠금화면·제어 센터 버튼이 부르는 것.
///
/// **모델도 네트워크도 쓰지 않습니다.** 확장 안에서 EventKit 만 읽고 Live Activity 를
/// 갱신합니다. 스파이크에서 잰 값이 이 설계의 근거입니다 — 잠금 상태에서 확장이
/// EventKit 에 닿고, 첫 호출 492ms, 그 뒤 65ms 였습니다.
struct TodayEventsIntent: AppIntent {
    static let title: LocalizedStringResource = "오늘 일정"
    static let description = IntentDescription("오늘 일정을 잠금화면에 띄웁니다.")
    /// 앱을 열지 않습니다. 잠금화면에서 누르는 버튼이고, 앱이 열리면 잠금 해제가
    /// 필요해져서 "버튼 하나로" 가 성립하지 않습니다.
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        let started = Date()
        let answer: NubiAnswer
        do {
            answer = Format.events(try Events.upcoming(days: 1), label: "오늘")
        } catch {
            answer = NubiAnswer(headline: "읽을 수 없습니다",
                                detail: error.localizedDescription, failed: true)
        }
        LiveAnswer.show(asked: "오늘 일정", answer)
        NubiLog.write("[오늘] \(answer.headline) — \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return .result()
    }
}
