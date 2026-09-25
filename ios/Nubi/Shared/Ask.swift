import AppIntents
import Foundation

/// 한 번의 요청을 끝까지 끌고 갑니다. 화면도 음성도 잠금화면도 이 함수를 부릅니다.
///
/// 라우팅은 코드가 합니다. 일정 조회와 미리알림 추가는 **모델도 네트워크도 없이**
/// 끝나고, 나머지만 모델로 갑니다.
enum Nubi {
    static func respond(to utterance: String) async -> NubiAnswer {
        let started = Date()
        let answer: NubiAnswer

        switch Router.route(utterance) {
        case let .events(days, label):
            do {
                answer = Format.events(try Events.upcoming(days: days), label: label)
            } catch {
                answer = NubiAnswer(headline: "일정을 읽을 수 없습니다",
                                    detail: error.localizedDescription, failed: true)
            }
        case let .addReminder(title):
            do {
                try Events.addReminder(title)
                answer = NubiAnswer(headline: "미리알림에 넣었습니다", detail: title)
            } catch {
                answer = NubiAnswer(headline: "미리알림을 추가할 수 없습니다",
                                    detail: error.localizedDescription, failed: true)
            }
        case let .ask(question):
            do {
                answer = try await Model.answer(to: question)
            } catch {
                answer = NubiAnswer(headline: "답하지 못했습니다",
                                    detail: error.localizedDescription, failed: true)
            }
        }

        NubiLog.write("[요청] \(utterance) → \(answer.headline) (\(Int(Date().timeIntervalSince(started) * 1000))ms)")
        return answer
    }

    /// 잠금화면 대화의 한 턴. **표시를 먼저 바꾸고 답을 만듭니다.**
    static func turn(_ utterance: String) async -> NubiAnswer {
        await LiveAnswer.thinking(about: utterance)
        let answer = await respond(to: utterance)
        await LiveAnswer.show(asked: utterance, answer)
        return answer
    }
}

/// 잠금화면 대화의 입력 버튼.
///
/// 누르면 시스템이 글자를 받는 창을 띄웁니다 — 값 없는 매개변수가 있으면
/// `requestValue` 가 그 창을 부릅니다. 잠금을 풀지 않고 묻는 경로가 이것뿐입니다.
///
/// **평범한 `AppIntent` 입니다.** `LiveActivityIntent` 로 두면 앱 프로세스에서
/// 도는데, 그 프로세스가 살아 있는 동안 입력창이 열리지 않습니다. 14분을 기다려도
/// 같았고, 그때 기록에 새 프로세스 줄이 없었습니다 — 시스템이 안 거둡니다.
///
/// ```
/// 18:18:20  [프로세스] 앱 빌드 14 …
/// 18:18:20  [요청] 사시미 어때 → …        성공
/// 18:18:30  [묻기] … helper application    실패
/// 18:32:43  [묻기] … helper application    14분 뒤, 새 프로세스 줄 없음
/// ```
///
/// 확장 프로세스는 누를 때마다 새로 뜹니다. 대신 활동을 **시작**할 수는 없으니,
/// 이 버튼은 이미 떠 있는 대화창을 갱신하기만 합니다.
struct AskNubiIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "누비에게 묻기"
    static let description = IntentDescription("받은 말에 답하고 잠금화면 대화창에 올립니다.")
    static let openAppWhenRun = false

    /// **단축어가 채워서 넘깁니다.**
    ///
    /// 잠금화면에서 글자를 받는 길은 단축어 앱의 "텍스트 입력 요청" 하나입니다.
    /// 인텐트가 직접 값을 요구하는 길(`requestValue`)은 첫 번만 열리고 막힙니다 —
    /// 확장에서는 `LNActionExecutor 2010`, 배경의 앱에서는 `helper application`,
    /// 앱을 막 닫은 직후에만 됐습니다. 여덟 빌드에 걸쳐 같은 벽이었습니다.
    ///
    /// 그래서 묻는 일은 단축어에 맡기고, 이 인텐트는 **받은 말에 답하는 것만**
    /// 합니다. 단축어 버튼은 잠금화면 아래 손전등 자리에 놓입니다.
    @Parameter(title: "무엇을", requestValueDialog: IntentDialog("무엇을 물어볼까요"))
    var utterance: String

    static var parameterSummary: some ParameterSummary {
        Summary("누비에게 \(\.$utterance) 묻기")
    }

    init() {}
    init(_ utterance: String) { self.utterance = utterance }

    func perform() async throws -> some IntentResult {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NubiLog.write("[묻기] 빈 입력")
            return .result()
        }
        _ = await Nubi.turn(text)
        return .result()
    }
}

/// 잠금화면에 미리 놓는 한 마디. 글자를 치지 않고 누르기만 합니다.
struct QuickAskIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "미리 정한 질문"
    static let openAppWhenRun = false

    /// 버튼에는 "오늘" 이라고만 쓰지만 묻는 말은 "오늘 일정" 입니다.
    /// 잠금화면이 좁아 표시를 줄인 것이고, 라우터에 가는 말까지 줄이면
    /// 무엇을 묻는지가 흐려집니다.
    @Parameter(title: "무엇을")
    var utterance: String

    /// 턴마다 달라지는 값. 이유는 `AskNubiIntent` 와 같습니다.
    @Parameter(title: "턴")
    var stamp: Int

    init() { utterance = "오늘 일정"; stamp = 0 }
    init(_ label: String, stamp: Int) {
        utterance = "\(label) 일정"
        self.stamp = stamp
    }

    func perform() async throws -> some IntentResult {
        _ = await Nubi.turn(utterance)
        return .result()
    }
}

/// 음성으로 부를 이름. 앱을 설치하면 바로 잡힙니다.
struct NubiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskNubiIntent(),
            phrases: ["\(.applicationName)에게 묻기", "\(.applicationName)한테 물어봐", "\(.applicationName)"],
            shortTitle: "묻기",
            systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(
            intent: TodayEventsIntent(),
            phrases: ["\(.applicationName) 오늘 일정", "\(.applicationName)로 오늘 일정 보기"],
            shortTitle: "오늘 일정",
            systemImageName: "calendar")
    }
}


/// 앱을 열어 묻습니다.
///
/// 잠금화면 입력창은 **앱 프로세스가 막 떴을 때 한 번만** 열립니다. 실기기에서
/// 그 규칙이 반복됐습니다 — 프로세스 줄 바로 뒤 첫 요청만 성공하고, 그 뒤로는
/// `Couldn't communicate with a helper application` 입니다.
///
/// 그래서 확실한 길을 하나 둡니다. 잠금을 풀어야 하지만 언제나 됩니다.
struct OpenNubiIntent: AppIntent {
    static let title: LocalizedStringResource = "누비 열기"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult { .result() }
}
