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
        // 앞 턴의 성격을 물려받습니다. 지도 이야기 뒤의 "다른 데" 는 지도입니다.
        let route = Router.route(utterance, after: Thread.last?.source)
        await LiveAnswer.thinking(about: utterance, steps: steps(for: route))
        let started = Date()
        // 앞의 말을 같이 보냅니다. 없으면 "액션으로" 같은 말이 통하지 않습니다.
        let history = Array(Thread.load().suffix(6))
        // **답이 없는 것도 답으로 만듭니다.** 어딘가에서 멈추면 대화창이 "생각 중"
        // 인 채로 남고, 사람은 고장난 줄 압니다.
        let answer = await within(seconds: 30) { await respond(route, history: history) }
            ?? NubiAnswer(headline: "시간이 너무 걸립니다",
                          detail: "다시 시도해 주세요.", failed: true)
        let turn = Turn(asked: utterance, headline: answer.headline, detail: answer.detail,
                        source: answer.source, failed: answer.failed, at: Date(),
                        viaIntent: viaIntent, map: answer.map, confirm: answer.confirm)
        Thread.append(turn)
        await LiveAnswer.show(turn)
        NubiLog.write("[요청] \(utterance) → \(answer.headline) (\(Int(Date().timeIntervalSince(started) * 1000))ms)")
        return turn
    }

    /// 답을 만드는 동안 보여줄 줄. **실제로 하는 일만 적습니다.**
    ///
    /// 일정 조회나 추가는 두 자리 밀리초에 끝나서 보여줄 단계가 없습니다.
    /// 모델에 가는 것만 기다릴 만합니다.
    private static func steps(for route: NubiIntent) -> [NubiAttributes.StepLine] {
        if case let .places(query) = route {
            let what = query.isEmpty ? Places.lastQuery : query
            return [.init(label: "지도", detail: "\(what) 찾는 중…", done: false)]
        }
        guard case .ask = route else { return [] }
        var lines: [NubiAttributes.StepLine] = []
        if Events.canReadEvents {
            let brief = Events.todayBrief()
            lines.append(.init(label: "일정", detail: brief.isEmpty ? "오늘 없음" : brief, done: true))
        }
        lines.append(.init(label: "답", detail: "만드는 중…", done: false))
        return lines
    }

    /// 지우거나 옮길 일정을 찾아 **적어두기만** 합니다.
    ///
    /// 되돌릴 수 없는 동작이라 여기서 하지 않습니다. 사람이 버튼을 눌러야 합니다.
    /// 여럿이 걸리면 아무것도 적어두지 않고 무엇인지 되묻습니다 — 잘못 고른 하나를
    /// 지우는 것이 안 지우는 것보다 나쁩니다.
    private static func propose(_ kind: Pending.Kind, _ spoken: Spoken) async -> NubiAnswer {
        PendingStore.clear()
        let name = spoken.title
        guard name != "새 일정" else {
            return NubiAnswer(headline: "무엇을 \(kind.verb)할까요",
                              detail: "‘내일 운동 취소’ 처럼 이름을 같이 말해주세요.",
                              source: .events, failed: true)
        }
        do {
            let upcoming = try Events.upcoming(days: 14)
            let hits = upcoming.filter { $0.title.contains(name) }
            guard let only = hits.first, hits.count == 1 else {
                if hits.isEmpty {
                    return NubiAnswer(headline: "‘\(name)’ 일정이 없습니다",
                                      detail: "앞으로 2주 안에는 보이지 않습니다.",
                                      source: .events, failed: true)
                }
                return NubiAnswer(headline: "여러 개가 걸립니다",
                                  detail: hits.prefix(5).map { "· \(Format.short($0.start)) \($0.title)" }
                                      .joined(separator: "\n"),
                                  source: .events, failed: true)
            }
            guard kind == .delete || spoken.hasClock else {
                return NubiAnswer(headline: "언제로 옮길까요",
                                  detail: "‘\(only.title) 3시로 옮겨줘’ 처럼 시각을 말해주세요.",
                                  source: .events, failed: true)
            }
            let pending = Pending(kind: kind, eventId: only.id, title: only.title,
                                  at: only.start, to: kind == .move ? spoken.start : nil)
            PendingStore.hold(pending)
            return NubiAnswer(headline: pending.question, detail: pending.detail,
                              source: .events, confirm: kind.verb)
        } catch {
            return NubiAnswer(headline: "일정을 읽을 수 없습니다",
                              detail: error.localizedDescription, source: .events, failed: true)
        }
    }

    /// 사람이 눌렀을 때 실제로 합니다.
    @discardableResult
    static func confirmPending() async -> Turn? {
        guard let pending = PendingStore.take() else { return nil }
        let answer: NubiAnswer
        do {
            switch pending.kind {
            case .delete:
                try Events.remove(eventId: pending.eventId)
                answer = NubiAnswer(headline: "‘\(pending.title)’ 을 지웠습니다",
                                    detail: Format.short(pending.at), source: .events)
            case .move:
                guard let to = pending.to else { return nil }
                try Events.move(eventId: pending.eventId, to: to)
                answer = NubiAnswer(headline: "‘\(pending.title)’ 을 옮겼습니다",
                                    detail: "\(Format.short(pending.at)) → \(Format.short(to))",
                                    source: .events)
            }
        } catch {
            answer = NubiAnswer(headline: "\(pending.kind.verb)하지 못했습니다",
                                detail: error.localizedDescription, source: .events, failed: true)
        }
        let turn = Turn(asked: "승인", headline: answer.headline, detail: answer.detail,
                        source: answer.source, failed: answer.failed, at: Date(), viaIntent: true)
        Thread.append(turn)
        await LiveAnswer.show(turn)
        NubiLog.write("[승인] \(answer.headline)")
        return turn
    }

    /// 시한 안에 못 끝내면 nil.
    private static func within<T: Sendable>(
        seconds: Double, _ work: @Sendable @escaping () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    static func respond(to utterance: String, history: [Turn] = []) async -> NubiAnswer {
        await respond(Router.route(utterance, after: Thread.last?.source), history: history)
    }

    static func respond(_ route: NubiIntent, history: [Turn] = []) async -> NubiAnswer {
        switch route {
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
        case let .places(asked):
            // 빈 말은 "같은 것을 더" 입니다. 그때는 마지막으로 찾던 것을 더 넓게 봅니다.
            let query = asked.isEmpty ? Places.lastQuery : asked
            guard !query.isEmpty else {
                return NubiAnswer(headline: "무엇을 찾을까요",
                                  detail: "근처 카페, 주변 약국 처럼 말해주세요.",
                                  source: .places, failed: true)
            }
            Places.lastQuery = query
            do {
                return Format.places(try await Places.find(query, limit: asked.isEmpty ? 8 : 4),
                                     query: query)
            } catch {
                return NubiAnswer(headline: "찾지 못했습니다",
                                  detail: error.localizedDescription, source: .places, failed: true)
            }
        case let .editEvent(kind, spoken):
            return await propose(kind, spoken)
        case let .completeReminder(name):
            do {
                let open = try await Events.openReminders()
                let hits = open.filter { $0.title.contains(name) }
                guard let only = hits.first, hits.count == 1 else {
                    if hits.isEmpty {
                        return NubiAnswer(headline: "그런 미리알림이 없습니다",
                                          detail: name, source: .reminders, failed: true)
                    }
                    return NubiAnswer(headline: "여러 개가 걸립니다",
                                      detail: hits.map { "· \($0.title)" }.joined(separator: "\n"),
                                      source: .reminders, failed: true)
                }
                try Events.complete(only)
                // "우유 사기 완료" 라고 물었는데 "우유 사기 완료" 라고 답하면
                // 메아리처럼 들립니다. 무엇이 일어났는지를 말합니다.
                return NubiAnswer(headline: "‘\(only.title)’ 을 끝냈습니다",
                                  detail: "안 끝난 것 \(max(0, open.count - 1))개 남았습니다.",
                                  source: .reminders)
            } catch {
                return NubiAnswer(headline: "미리알림을 바꿀 수 없습니다",
                                  detail: error.localizedDescription, source: .reminders, failed: true)
            }
        case .reminders:
            do {
                return Format.reminders(try await Events.openReminders())
            } catch {
                return NubiAnswer(headline: "미리알림을 읽을 수 없습니다",
                                  detail: error.localizedDescription, source: .reminders, failed: true)
            }
        case let .addReminder(spoken):
            do {
                // 시각을 말했으면 그때, 날짜만 말했으면 그날 아침 9시, 둘 다 없으면
                // 마감 없이. 마감이 없으면 울리지 않으므로 답에도 그렇게 적습니다.
                let due: Date? = spoken.hasClock ? spoken.start
                    : spoken.hasDay ? Calendar.current.date(byAdding: .hour, value: 9, to: spoken.start)
                    : nil
                try Events.addReminder(spoken.title, due: due)
                let when = spoken.hasClock ? spoken.spoken
                    : spoken.hasDay ? "\(spoken.spoken.replacingOccurrences(of: " 종일", with: "")) 오전 9:00"
                    : nil
                return NubiAnswer(
                    headline: when.map { "\($0) \(spoken.title)" } ?? spoken.title,
                    detail: when == nil ? "미리알림에 넣었습니다. 시각을 말하면 그때 알려드립니다."
                                        : "미리알림에 넣었습니다.",
                    source: .reminders)
            } catch {
                return NubiAnswer(headline: "미리알림을 추가할 수 없습니다",
                                  detail: error.localizedDescription, source: .reminders, failed: true)
            }
        case let .ask(question):
            do {
                return try await Model.answer(to: question, history: history)
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

/// 답 한 줄을 한 시간 뒤 미리알림으로 넣습니다.
///
/// **어떤 답에도 붙는 다음 손길입니다.** 잠금화면에서 답을 읽고 나서 "이따 다시"
/// 를 누를 자리가 없었습니다. 길찾기 같은 것은 답이 무엇을 가리키는지 알아야
/// 하지만 이건 몰라도 됩니다.
struct RemindLaterIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "한 시간 뒤 알림"
    static let openAppWhenRun = false

    /// **물은 말이 제목입니다.** 답이 아니라.
    ///
    /// 답을 제목으로 넣었더니 미리알림 목록에 문단이 통째로 박혔습니다. 한 시간
    /// 뒤에 보고 싶은 것은 "무엇을 물었는가" 이고, 답은 메모로 따라갑니다.
    @Parameter(title: "무엇을")
    var what: String

    @Parameter(title: "메모")
    var note: String

    @Parameter(title: "턴")
    var stamp: Int

    init() { what = ""; note = ""; stamp = 0 }
    init(_ what: String, note: String, stamp: Int) {
        self.what = String(what.prefix(60))
        self.note = String(note.prefix(400))
        self.stamp = stamp
    }

    func perform() async throws -> some IntentResult {
        let due = Date().addingTimeInterval(3600)
        let title = what.isEmpty ? String(note.prefix(30)) : what
        let answer: NubiAnswer
        do {
            try Events.addReminder(title, due: due, note: note)
            answer = NubiAnswer(headline: "\(Format.time(due)) \(title)",
                                detail: "미리알림에 넣었습니다.", source: .reminders)
        } catch {
            answer = NubiAnswer(headline: "알림을 넣을 수 없습니다",
                                detail: error.localizedDescription, source: .reminders, failed: true)
        }
        let turn = Turn(asked: "한 시간 뒤 알림", headline: answer.headline, detail: answer.detail,
                        source: answer.source, failed: answer.failed, at: Date(), viaIntent: true)
        Thread.append(turn)
        await LiveAnswer.show(turn)
        NubiLog.write("[알림] \(answer.headline)")
        return .result()
    }
}

/// 잠금화면에서 승인을 누르는 버튼.
///
/// **누르기 전에는 아무것도 하지 않았습니다.** 적어둔 일을 여기서 꺼내 합니다.
struct ConfirmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "승인"
    static let openAppWhenRun = false

    @Parameter(title: "턴")
    var stamp: Int

    init() { stamp = 0 }
    init(stamp: Int) { self.stamp = stamp }

    func perform() async throws -> some IntentResult {
        await Nubi.confirmPending()
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
