import AppIntents
import Foundation

/// 한 번의 요청을 끝까지 끌고 갑니다. 화면도 음성도 이 함수를 부릅니다.
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
}

/// 음성과 Spotlight 로 부르는 것.
///
/// 답을 잠금화면에도 올리므로 `LiveActivityIntent` 입니다 — 음성으로 물으면 앱은
/// 배경이고, 배경에서 활동을 시작하려면 이 종류여야 합니다.
struct AskNubiIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "누비에게 묻기"
    static let description = IntentDescription("일정을 묻거나, 미리알림을 넣거나, 그냥 물어봅니다.")
    static let openAppWhenRun = false

    @Parameter(title: "무엇을", requestValueDialog: "무엇을 도와드릴까요")
    var utterance: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await Nubi.respond(to: utterance)
        // 잠금화면에도 남깁니다. 말로 물었어도 답은 눈으로 다시 보게 됩니다.
        LiveAnswer.show(asked: utterance, answer)
        let spoken = answer.detail.isEmpty ? answer.headline : "\(answer.headline). \(answer.detail)"
        return .result(dialog: IntentDialog(stringLiteral: spoken))
    }
}

/// 음성으로 부를 이름. 앱을 설치하면 바로 잡힙니다.
struct NubiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskNubiIntent(),
            phrases: [
                "\(.applicationName)에게 묻기",
                "\(.applicationName)한테 물어봐",
                "\(.applicationName)",
            ],
            shortTitle: "묻기",
            systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(
            intent: TodayEventsIntent(),
            phrases: [
                "\(.applicationName) 오늘 일정",
                "\(.applicationName)로 오늘 일정 보기",
            ],
            shortTitle: "오늘 일정",
            systemImageName: "calendar")
    }
}
