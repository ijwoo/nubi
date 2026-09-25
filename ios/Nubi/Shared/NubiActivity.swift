import ActivityKit
import Foundation

/// 잠금화면 위의 대화.
///
/// 활동 하나가 대화 하나입니다. 물을 때마다 새로 만들지 않고 같은 활동을 갱신합니다 —
/// 물음마다 활동이 쌓이면 잠금화면이 답으로 덮입니다.
struct NubiAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 마지막으로 물은 것. 대화라서 매번 바뀌므로 상태에 있습니다.
        var asked: String
        var headline: String
        var detail: String
        /// 답을 기다리는 중. **네트워크보다 먼저 이걸 켭니다.**
        ///
        /// 스파이크에서 잰 왕복이 0.8~2초였고, 그동안 화면이 그대로면 사람이 다시
        /// 누릅니다. 실제로 네 번 눌렸고 인텐트 둘이 같은 초에 겹쳤습니다.
        var thinking: Bool
        var failed: Bool
        /// 이 턴의 표시.
        ///
        /// **버튼을 구별하기 위한 것입니다.** 같은 매개변수를 가진 인텐트를 다시
        /// 누르면 시스템이 이미 처리한 것으로 보고 무시합니다. 첫 물음은 되는데
        /// 두 번째가 아무 반응이 없던 이유가 이것입니다. 턴마다 값이 달라지면
        /// 버튼도 다른 것이 됩니다.
        var stamp: Int
    }

    /// 대화가 시작된 시각. 상태가 아니라 속성이라 바뀌지 않습니다.
    var started: Date
}

enum LiveAnswer {
    /// 대화를 잠금화면에 올리거나 갱신합니다.
    ///
    /// 이미 떠 있으면 갱신합니다. 없으면 만듭니다. 만드는 쪽은 **앱 프로세스에서만**
    /// 됩니다 — 확장에서 부르면 "Target does not include NSSupportsLiveActivities"
    /// 로 죽습니다. 키가 있는데도 그렇습니다. 그래서 이걸 부르는 인텐트는 전부
    /// `LiveActivityIntent` 입니다.
    @discardableResult
    static func push(_ state: NubiAttributes.ContentState) async -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NubiLog.write("[활동] 꺼져 있음 — 설정 › 누비 › 실시간 활동을 켜야 합니다")
            return false
        }
        if let running = Activity<NubiAttributes>.activities.first {
            await running.update(ActivityContent(state: state, staleDate: nil))
            return true
        }
        do {
            _ = try Activity.request(
                attributes: NubiAttributes(started: Date()),
                content: .init(state: state, staleDate: nil))
            return true
        } catch {
            NubiLog.write("[활동] 시작 실패 \(error.localizedDescription)")
            return false
        }
    }

    /// 묻는 순간. 답이 오기 전에 화면이 먼저 움직입니다.
    static func thinking(about question: String) async {
        await push(.init(asked: question, headline: "생각하는 중…", detail: "",
                         thinking: true, failed: false, stamp: now()))
    }

    static func show(asked: String, _ answer: NubiAnswer) async {
        await push(.init(asked: asked, headline: answer.headline, detail: answer.detail,
                         thinking: false, failed: answer.failed, stamp: now()))
    }

    /// 초 단위면 충분합니다. 같은 초에 두 번 누르는 것은 막고 싶은 쪽입니다.
    private static func now() -> Int { Int(Date().timeIntervalSince1970) }

    static func dismissAll() {
        for activity in Activity<NubiAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
