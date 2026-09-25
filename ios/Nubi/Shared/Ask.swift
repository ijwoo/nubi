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
/// 누르면 시스템이 글자를 받는 창을 띄웁니다 — 인텐트에 값 없는 매개변수가 있으면
/// `requestValue` 가 그 창을 부릅니다. 잠금을 풀지 않고 묻는 경로가 이것뿐입니다.
///
/// `LiveActivityIntent` 여야 합니다. 평범한 `AppIntent` 는 확장이나 배경 앱에서
/// 돌고, 거기서는 활동을 시작할 수도 갱신할 수도 없습니다.
struct AskNubiIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "누비에게 묻기"
    static let description = IntentDescription("일정을 묻거나, 미리알림을 넣거나, 그냥 물어봅니다.")
    static let openAppWhenRun = false

    @Parameter(title: "무엇을")
    var utterance: String?

    /// 턴마다 달라지는 값. 같은 인텐트를 다시 눌러도 새 요청으로 보이게 합니다.
    @Parameter(title: "턴")
    var stamp: Int

    init() { stamp = 0 }
    init(utterance: String?, stamp: Int) {
        self.utterance = utterance
        self.stamp = stamp
    }

    /// 답을 돌려주지 않습니다.
    ///
    /// `ProvidesDialog` 를 쓰면 답이 끝난 자리에 확인 배너가 뜨고, **그 배너를
    /// 닫기 전에는 다음 입력창이 열리지 않습니다.** 실기기에서 배너가 떠 있는
    /// 동안 묻기가 17번 연속 실패했습니다.
    ///
    /// ```
    /// [묻기] 입력 없이 끝남 Couldn't communicate with a helper application.
    /// ```
    ///
    /// 빌드 8 에서 한 번 뺐다가 되돌린 적이 있는데, 그때 안 됐던 이유는 배너가
    /// 아니라 턴 표시가 없어서 같은 버튼이 무시된 것이었습니다. 둘은 다른
    /// 문제였고, 한 번에 하나씩만 바꿨어야 했습니다.
    func perform() async throws -> some IntentResult {
        let text: String
        if let given = utterance?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty {
            text = given
        } else {
            do {
                text = try await $utterance.requestValue("무엇을 물어볼까요")
            } catch {
                let reason = error.localizedDescription
                NubiLog.write("[묻기] 입력 없이 끝남 \(reason)")
                // 취소는 정상입니다. 그 밖의 실패는 고장난 버튼처럼 보이므로
                // 무엇이 막고 있는지 대화창에 적습니다.
                if reason.contains("helper") {
                    await LiveAnswer.show(asked: "", NubiAnswer(
                        headline: "지금은 글자를 넣을 수 없습니다",
                        detail: "위에 열려 있는 창을 닫거나 잠금을 풀고 다시 눌러주세요. 오늘·내일 버튼은 잠긴 채로도 됩니다.",
                        failed: true))
                }
                throw error
            }
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
