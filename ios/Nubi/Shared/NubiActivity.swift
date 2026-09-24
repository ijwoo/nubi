import ActivityKit
import Foundation

/// 잠금화면에 답을 띄웁니다.
///
/// `ContentState` 는 작게 둡니다. 나중에 작업 모드에서 맥이 APNs 로 갱신을 보낼 때
/// `aps` 를 포함해 4KB 안에 들어가야 하고, 사람이 읽는 문장은 폰이 만듭니다.
struct NubiAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var headline: String
        var detail: String
        var failed: Bool
    }

    /// 무엇을 물었는가. 답이 바뀌어도 질문은 그대로입니다.
    var asked: String
}

enum LiveAnswer {
    /// 답을 잠금화면에 올립니다.
    ///
    /// 이미 떠 있으면 새로 만들지 않고 갱신합니다. 물어볼 때마다 활동이 쌓이면
    /// 잠금화면이 답으로 덮입니다.
    @discardableResult
    static func show(asked: String, _ answer: NubiAnswer) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NubiLog.write("[활동] 꺼져 있음 — 설정에서 실시간 활동을 켜야 합니다")
            return false
        }
        let state = NubiAttributes.ContentState(
            headline: answer.headline, detail: answer.detail, failed: answer.failed)

        if let running = Activity<NubiAttributes>.activities.first {
            Task { await running.update(ActivityContent(state: state, staleDate: nil)) }
            return true
        }
        do {
            _ = try Activity.request(
                attributes: NubiAttributes(asked: asked),
                content: .init(state: state, staleDate: Date().addingTimeInterval(3600)))
            return true
        } catch {
            NubiLog.write("[활동] 시작 실패 \(error.localizedDescription)")
            return false
        }
    }

    static func dismissAll() {
        for activity in Activity<NubiAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
