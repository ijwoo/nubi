import AppIntents
import Foundation

/// 한 번의 요청을 끝까지 끌고 갑니다. 앱도 잠금화면도 단축어도 여기로 옵니다.
///
/// 라우팅은 코드가 합니다. 일정 조회와 미리알림 추가는 **모델도 네트워크도 없이**
/// 끝나고, 나머지만 모델로 갑니다.
enum Nubi {
    /// 표시를 먼저 바꾸고 답을 만들고 대화에 쌓습니다.
    @discardableResult
    static func turn(_ utterance: String, viaIntent: Bool) async -> Turn {
        await LiveAnswer.thinking(about: utterance)
        let started = Date()
        let answer = await respond(to: utterance)
        let turn = Turn(asked: utterance, headline: answer.headline, detail: answer.detail,
                        source: answer.source, failed: answer.failed, at: Date(),
                        viaIntent: viaIntent)
        Thread.append(turn)
        await LiveAnswer.show(turn)
        NubiLog.write("[요청] \(utterance) → \(answer.headline) (\(Int(Date().timeIntervalSince(started) * 1000))ms)")
        return turn
    }

    static func respond(to utterance: String) async -> NubiAnswer {
        switch Router.route(utterance) {
        case let .events(offset, span, label):
            do {
                let base = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
                return Format.events(try Events.upcoming(days: span, from: base), label: label)
            } catch {
                return NubiAnswer(headline: "일정을 읽을 수 없습니다",
                                  detail: error.localizedDescription, source: .events, failed: true)
            }
        case let .addEvent(spoken):
            do {
                try Events.addEvent(title: spoken.title, start: spoken.start, allDay: spoken.allDay)
                // 해석한 시각을 되돌려줍니다. **틀렸으면 여기서 바로 보입니다.**
                return NubiAnswer(headline: "\(spoken.spoken) \(spoken.title)",
                                  detail: "일정에 넣었습니다.", source: .events)
            } catch {
                return NubiAnswer(headline: "일정을 넣을 수 없습니다",
                                  detail: error.localizedDescription, source: .events, failed: true)
            }
        case let .addReminder(title):
            do {
                try Events.addReminder(title)
                return NubiAnswer(headline: "미리알림에 넣었습니다", detail: title, source: .reminders)
            } catch {
                return NubiAnswer(headline: "미리알림을 추가할 수 없습니다",
                                  detail: error.localizedDescription, source: .reminders, failed: true)
            }
        case let .ask(question):
            do {
                return try await Model.answer(to: question)
            } catch {
                return NubiAnswer(headline: "답하지 못했습니다",
                                  detail: error.localizedDescription, source: .model, failed: true)
            }
        }
    }
}

/// 단축어가 부르는 것.
///
/// **잠금화면에서 글자를 받는 길은 단축어 앱의 "텍스트 입력 요청" 하나입니다.**
/// 인텐트가 직접 값을 요구하는 길(`requestValue`)은 첫 번만 열리고 막힙니다 —
/// 확장에서는 `LNActionExecutor 2010`, 배경의 앱에서는 `helper application`,
/// 앱을 막 닫은 직후에만 됐습니다. 여덟 빌드에 걸쳐 같은 벽이었습니다.
///
/// 그래서 묻는 일은 단축어에 맡기고, 이 인텐트는 **받은 말에 답하는 것만** 합니다.
struct AskNubiIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "누비에게 묻기"
    static let description = IntentDescription("받은 말에 답하고 잠금화면 대화창에 올립니다.")
    static let openAppWhenRun = false

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
        await Nubi.turn(text, viaIntent: true)
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

    /// 턴마다 달라지는 값. 같은 인텐트를 다시 눌러도 새 요청으로 보이게 합니다.
    @Parameter(title: "턴")
    var stamp: Int

    init() { utterance = "오늘 일정"; stamp = 0 }
    init(_ label: String, stamp: Int) {
        utterance = "\(label) 일정"
        self.stamp = stamp
    }

    func perform() async throws -> some IntentResult {
        await Nubi.turn(utterance, viaIntent: true)
        return .result()
    }
}

/// 앱을 엽니다. 대화창에서 전문을 보러 가는 길입니다.
struct OpenNubiIntent: AppIntent {
    static let title: LocalizedStringResource = "누비 열기"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult { .result() }
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
