import Foundation

/// 답이 만들어지는 동안 화면에 흘려보내는 것.
///
/// **5초에서 10초 동안 아무것도 없었습니다.** 물어놓고 빈 화면을 보는 시간이
/// 그만큼이었고, 실제로 느린 것보다 그게 더 느리게 느껴졌습니다.
///
/// 이제 둘을 흘려보냅니다 — **무엇을 하고 있는지**와 **답의 첫 글자부터.**
/// 걸리는 시간은 그대로인데 기다리는 느낌이 거의 없어집니다.
///
/// 모델은 배경에서 돌고 화면은 앞에 있습니다. 여기가 둘 사이입니다.
@MainActor
@Observable
final class Airing {
    static let shared = Airing()

    /// 방금 물은 말.
    ///
    /// **답이 끝나야 대화에 쌓입니다.** 그래서 기다리는 동안 내가 뭘 물었는지가
    /// 화면에 없었습니다 — 답이 온 뒤에야 물음과 답이 함께 나타났습니다.
    private(set) var asked = ""
    /// 지금까지 흘러나온 답.
    private(set) var draft = ""
    /// 실제로 부른 도구들. **하는 일만 적습니다** — 안 하는 일을 그리면 안 됩니다.
    private(set) var steps: [Step] = []
    private(set) var live = false

    struct Step: Identifiable, Hashable {
        var id: String { label }
        var label: String
        var done: Bool
    }

    private init() {}

    func begin(asking question: String) {
        asked = question
        draft = ""
        steps = []
        live = true
    }

    func append(_ piece: String) { draft += piece }

    /// 도구를 부르기 직전.
    func starting(_ label: String) {
        guard !steps.contains(where: { $0.label == label && !$0.done }) else { return }
        steps.append(Step(label: label, done: false))
    }

    /// 도구가 끝난 뒤.
    func finished(_ label: String) {
        guard let index = steps.lastIndex(where: { $0.label == label }) else { return }
        steps[index].done = true
    }

    /// 다음 바퀴로 넘어갑니다. 답을 쓰다가 도구를 부르면 쓰던 것은 버립니다 —
    /// 도구 결과를 보고 다시 쓸 것이기 때문입니다.
    func rewind() { draft = "" }

    func end() {
        live = false
        asked = ""
        draft = ""
        steps = []
    }
}
