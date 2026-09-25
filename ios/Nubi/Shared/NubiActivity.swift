import ActivityKit
import Foundation

/// 잠금화면 위의 대화창.
///
/// **대화의 마지막 한 턴을 비추는 창입니다.** 전체는 앱에 있습니다
/// ([`Thread`](Thread.swift)). 활동 하나가 대화 하나이고, 물을 때마다 새로
/// 만들지 않고 갱신합니다.
struct NubiAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var asked: String
        var headline: String
        var detail: String
        /// 답을 기다리는 중. **네트워크보다 먼저 이걸 켭니다.**
        ///
        /// 왕복이 0.8~2.5초인데 그동안 화면이 그대로면 사람이 다시 누릅니다.
        var thinking: Bool
        var failed: Bool
        /// 턴마다 달라지는 값. 같은 매개변수의 인텐트를 다시 누르면 시스템이
        /// 이미 처리한 것으로 보고 무시합니다.
        var stamp: Int
        var at: Date
    }

    var started: Date
}

enum LiveAnswer {
    static var isRunning: Bool { !Activity<NubiAttributes>.activities.isEmpty }

    /// 대화창을 올리거나 갱신합니다.
    ///
    /// **새로 만들 수 있는 것은 앞에 떠 있는 앱뿐입니다.** 확장도 배경의 앱도
    /// 갱신만 됩니다 — 배경에서 만들려 하면 "Target is not foreground" 입니다.
    /// 그래서 앱이 열릴 때 자리를 만들어 둡니다.
    @discardableResult
    static func push(_ state: NubiAttributes.ContentState) async -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NubiLog.write("[활동] 꺼져 있음 — 설정 › 누비 › 실시간 활동")
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
            // 답은 이미 대화에 쌓였습니다. 앱을 열면 거기 있습니다.
            NubiLog.write("[활동] 시작 실패 \(error.localizedDescription)")
            return false
        }
    }

    static func thinking(about question: String) async {
        await push(.init(asked: question, headline: "생각하는 중…", detail: "",
                         thinking: true, failed: false, stamp: now(), at: Date()))
    }

    /// 아직 아무것도 묻지 않았을 때의 대화창.
    ///
    /// 자리만 만들어 둡니다. **대화창을 새로 만들 수 있는 것은 앞에 떠 있는
    /// 앱뿐**이라, 여기서 안 만들면 잠금화면 버튼이 답을 놓을 곳이 없습니다.
    /// 예전에는 이 자리에서 "오늘 일정" 을 대신 물었는데, 권한이 없으면 아무것도
    /// 안 한 사람에게 실패 말풍선부터 보여주게 됩니다.
    static func welcome() async {
        await push(.init(asked: "", headline: "무엇이든 물어보세요", detail: "",
                         thinking: false, failed: false, stamp: Int(Date().timeIntervalSince1970),
                         at: Date()))
    }

    static func show(_ turn: Turn) async {
        await push(.init(asked: turn.asked, headline: turn.headline, detail: turn.detail,
                         thinking: false, failed: turn.failed, stamp: now(), at: turn.at))
    }

    static func dismissAll() {
        for activity in Activity<NubiAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// 초 단위면 충분합니다. 같은 초에 두 번 누르는 것은 막고 싶은 쪽입니다.
    private static func now() -> Int { Int(Date().timeIntervalSince1970) }
}
