import ActivityKit
import SwiftUI

/// 대화 화면. **이 앱이 하는 일은 하나라서 탭바를 두지 않습니다.**
struct ChatView: View {
    @Environment(\.scenePhase) private var phase
    @State private var turns: [Turn] = []
    @State private var draft = ""
    @State private var busy = false
    @State private var showSettings = false
    @State private var liveIsOn = false
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !liveIsOn { LiveOffBar { Task { await revive() } } }
                transcript
                Composer(draft: $draft, busy: busy, typing: $typing,
                         suggestions: turns.isEmpty ? Suggestion.all : [],
                         send: send)
            }
            .navigationTitle("누비")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("설정")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(onChange: refresh)
            }
        }
        .task { await open() }
        .onReceive(NotificationCenter.default.publisher(for: .nubiOpenSettings)) { _ in
            showSettings = true
        }
        .onChange(of: phase) { _, now in
            // 잠금화면에서 물은 것이 여기 있어야 합니다. 돌아올 때마다 읽습니다.
            if now == .active { refresh() }
        }
    }

    private var transcript: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !Setup.isDone { SetupCard(onChange: refresh).padding(.bottom, 8) }
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        if let gap = separator(before: index) { DayMark(text: gap) }
                        TurnRows(turn: turn, retry: { retry(turn) }, delete: { delete(turn) })
                    }
                    if busy { ThinkingRow() }
                    Color.clear.frame(height: 1).id(bottom)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: turns.count) { _, _ in jump(scroll) }
            .onChange(of: busy) { _, _ in jump(scroll) }
            .onChange(of: typing) { _, now in if now { jump(scroll) } }
        }
    }

    private let bottom = "bottom"

    private func jump(_ scroll: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.22)) { scroll.scrollTo(bottom, anchor: .bottom) }
    }

    /// 앞 말과 10분 넘게 벌어졌을 때만 시각을 한 번 답니다.
    /// 매 줄에 달면 읽는 데 방해가 됩니다.
    private func separator(before index: Int) -> String? {
        let turn = turns[index]
        guard index > 0 else { return Stamp.of(turn.at) }
        let gap = turn.at.timeIntervalSince(turns[index - 1].at)
        return gap > 600 ? Stamp.of(turn.at) : nil
    }

    private func open() async {
        refresh()
        await revive()
    }

    /// 대화창을 살립니다. **새로 만들 수 있는 것은 앞에 떠 있는 앱뿐입니다.**
    private func revive() async {
        if LiveAnswer.isRunning { liveIsOn = true; return }
        if let last = Thread.last {
            await LiveAnswer.show(last)
        } else {
            await LiveAnswer.welcome()
        }
        liveIsOn = LiveAnswer.isRunning
    }

    private func refresh() {
        turns = Thread.load()
        liveIsOn = LiveAnswer.isRunning
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        draft = ""
        ask(text)
    }

    private func retry(_ turn: Turn) {
        Thread.remove(turn)
        refresh()
        ask(turn.asked)
    }

    private func ask(_ text: String) {
        busy = true
        Task {
            await Nubi.turn(text, viaIntent: false)
            refresh()
            busy = false
        }
    }

    private func delete(_ turn: Turn) {
        Thread.remove(turn)
        refresh()
    }
}

enum Suggestion {
    static let all = ["오늘 일정", "내일 일정", "우유 사기 미리알림"]
}

enum Stamp {
    static func of(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "a h:mm" : "M월 d일 a h:mm"
        return f.string(from: date)
    }
}

/// 대화창이 꺼져 있을 때만 내려오는 띠. 켜져 있으면 아무것도 없습니다.
private struct LiveOffBar: View {
    let turnOn: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.display").font(.caption)
            Text("잠금화면 대화창이 꺼져 있습니다").font(.caption)
            Spacer()
            Button("켜기", action: turnOn).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Ink.accent.opacity(0.12))
    }
}

private struct DayMark: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            line
            Text(text).font(.caption2).foregroundStyle(.secondary)
            line
        }
        .padding(.vertical, 12)
    }

    private var line: some View {
        Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
    }
}

/// 한 턴은 두 줄입니다 — 물은 말과 답.
private struct TurnRows: View {
    let turn: Turn
    let retry: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer(minLength: 56)
                Text(turn.asked)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Ink.mine, in: Bubble(mine: true))
            }
            HStack(alignment: .bottom, spacing: 7) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(turn.full)
                        .font(.callout)
                        .foregroundStyle(turn.failed ? Ink.warn : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if turn.failed {
                        Button("다시 시도", action: retry)
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Ink.theirs, in: Bubble(mine: false))
                .overlay(alignment: .leading) {
                    if turn.failed {
                        Ink.warn.frame(width: 3).clipShape(Capsule()).padding(.vertical, 6)
                    }
                }
                Spacer(minLength: 40)
            }
            .contextMenu {
                Button("복사", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = turn.full
                }
                Button("삭제", systemImage: "trash", role: .destructive, action: delete)
            }
            Meta(turn: turn)
        }
        .padding(.bottom, 16)
    }
}

/// 답 아래 아주 작은 줄. **네트워크를 탔는지 아닌지가 여기서 보입니다.**
private struct Meta: View {
    let turn: Turn

    var body: some View {
        HStack(spacing: 5) {
            if turn.viaIntent {
                Image(systemName: "lock.fill").font(.system(size: 8))
            }
            if let label = turn.source.label { Text(label) }
            Spacer()
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.leading, 4)
    }
}

private struct ThinkingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text("생각하는 중…").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Ink.theirs, in: Bubble(mine: false))
        .padding(.bottom, 16)
    }
}

/// 아래 고정 입력줄.
private struct Composer: View {
    @Binding var draft: String
    let busy: Bool
    @FocusState.Binding var typing: Bool
    let suggestions: [String]
    let send: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(suggestions, id: \.self) { text in
                            Button {
                                draft = text
                                send()
                            } label: {
                                Text(text).font(.caption.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(.primary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("무엇이든 물어보세요", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($typing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Ink.theirs, in: Capsule())
                Button(action: send) {
                    Group {
                        if busy {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "arrow.up").font(.callout.weight(.bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Ink.accent.opacity(ready ? 1 : 0.35), in: Circle())
                }
                .disabled(!ready)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .background(.bar)
    }

    private var ready: Bool {
        !busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
