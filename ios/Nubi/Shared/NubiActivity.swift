import ActivityKit
import Foundation

/// 잠금화면 위의 대화창.
///
/// **대화의 마지막 한 턴을 비추는 창입니다.** 전문은 앱에 있습니다.
struct NubiAttributes: ActivityAttributes {
    /// 답을 만드는 동안 보여주는 한 줄. **실제로 한 일만 적습니다.**
    ///
    /// 하지도 않은 단계를 그려 넣으면 화면은 그럴듯해지고 사람은 속습니다.
    /// 일정을 읽었으면 읽었다고, 모델에 물었으면 물었다고만 적습니다.
    struct StepLine: Codable, Hashable {
        var label: String
        var detail: String
        var done: Bool
    }

    struct ContentState: Codable, Hashable {
        var asked: String
        var headline: String
        var detail: String
        /// 오른쪽 위 작은 줄. 출처와 시각입니다.
        var meta: String
        var steps: [StepLine]
        /// 답을 기다리는 중. **네트워크보다 먼저 이걸 켭니다.**
        var thinking: Bool
        var failed: Bool
        /// 턴마다 달라지는 값. 같은 매개변수의 인텐트를 다시 누르면 시스템이
        /// 이미 처리한 것으로 보고 무시합니다.
        var stamp: Int
        var at: Date
        /// 길찾기 주소. 있으면 버튼이 하나 바뀝니다.
        var map: String = ""
        /// 걸 번호. 있으면 전화 버튼이 하나 더 붙습니다.
        var call: String = ""
        /// 열어줄 앱.
        var open: String = ""
        var openLabel: String = ""
        /// 걸어둔 알림이 울릴 시각. 있으면 **잠금화면에서 초가 흐릅니다.**
        var timerEnds: Date?
        var timerLabel: String = ""
        /// 승인을 기다리는 일의 버튼 이름. 있으면 얼굴이 긴장합니다.
        var confirm: String = ""

        /// 누를 것이 있는가. 없으면 말풍선 둘만 남습니다.
        var hasAction: Bool {
            !confirm.isEmpty || !map.isEmpty || !call.isEmpty || !open.isEmpty
        }

        var progress: Double {
            guard !steps.isEmpty else { return thinking ? 0.35 : 1 }
            return Double(steps.filter(\.done).count) / Double(steps.count)
        }
    }

    var started: Date
}

enum LiveAnswer {
    static var isRunning: Bool { !Activity<NubiAttributes>.activities.isEmpty }

    /// 대화창을 올리거나 갱신합니다.
    ///
    /// **새로 만들 수 있는 것은 앞에 떠 있는 앱뿐입니다.** 확장도 배경의 앱도
    /// 갱신만 됩니다 — 배경에서 만들려 하면 "Target is not foreground" 입니다.
    @discardableResult
    static func push(_ state: NubiAttributes.ContentState,
                     alerting: AlertConfiguration? = nil) async -> Bool {
        var state = state
        // **어느 턴에서 밀어 올리든 타이머는 붙습니다.** 타이머를 건 그 턴에만
        // 보이면, 다음 질문을 하는 순간 초가 사라집니다.
        if let next = await Timers.running().first {
            state.timerEnds = next.fires
            state.timerLabel = next.label
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NubiLog.write("[활동] 꺼져 있음 — 설정 › 누비 › 실시간 활동")
            return false
        }
        if let running = Activity<NubiAttributes>.activities.first {
            // **알림을 띄우는 갱신은 아일랜드를 펴줍니다.** 조용히 갱신하면
            // 접힌 채로 말풍이만 보여서 아무 일도 안 일어난 것처럼 보입니다 —
            // 시리로 물었을 때 무반응처럼 보이던 자리입니다.
            await running.update(ActivityContent(state: state, staleDate: nil),
                                 alertConfiguration: alerting)
            return true
        }
        do {
            _ = try Activity.request(
                attributes: NubiAttributes(started: Date()),
                content: .init(state: state, staleDate: nil))
            return true
        } catch {
            // 답은 이미 대화에 쌓였습니다. 앱을 열면 거기 있습니다.
            NubiLog.write("[활동] 시작 실패 \(error.localizedDescription)")
            return false
        }
    }

    /// 아직 아무것도 묻지 않았을 때의 대화창. 자리만 만들어 둡니다.
    static func welcome() async {
        await push(.init(asked: "", headline: "무엇이든 물어보세요", detail: "", meta: "",
                         steps: [], thinking: false, failed: false, stamp: now(), at: Date()))
    }

    static func thinking(about question: String, steps: [NubiAttributes.StepLine]) async {
        await push(.init(asked: question, headline: "확인하는 중", detail: "", meta: "",
                         steps: steps, thinking: true, failed: false, stamp: now(), at: Date()))
    }

    /// 밖에서 물은 답은 **눈에 띄게** 올립니다. 앱에서 보고 있을 때는
    /// 조용히 — 화면을 보고 있는 사람에게 소리를 낼 이유가 없습니다.
    @discardableResult
    static func show(_ turn: Turn, alerting: Bool = false) async -> Bool {
        let alert = alerting
            ? AlertConfiguration(title: "누비",
                                 body: LocalizedStringResource(stringLiteral: turn.headline),
                                 sound: .default)
            : nil
        return await push(.init(asked: turn.asked, headline: turn.headline, detail: turn.detail,
                                meta: turn.meta, steps: [], thinking: false, failed: turn.failed,
                                stamp: now(), at: turn.at, map: turn.map, call: turn.call,
                                open: turn.open, openLabel: turn.openLabel,
                                confirm: turn.confirm),
                          alerting: alert)
    }

    static func dismissAll() {
        for activity in Activity<NubiAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// 초 단위면 충분합니다. 같은 초에 두 번 누르는 것은 막고 싶은 쪽입니다.
    private static func now() -> Int { Int(Date().timeIntervalSince1970) }
}
