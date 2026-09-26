import SwiftUI
import UIKit

/// 대화 서랍. **잠금화면과 같은 대화입니다.**
struct ChatView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var draft = ""
    @FocusState private var typing: Bool

    private let bottom = "bottom"

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Composer(draft: $draft, busy: store.busy, typing: $typing, send: send)
        }
        .navigationTitle("대화")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.refresh() }
        .onChange(of: phase) { _, now in if now == .active { store.refresh() } }
    }

    private var transcript: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.turns.isEmpty && !store.busy {
                        Empty(text: "아직 대화가 없습니다", icon: "bubble.left.and.text.bubble.right")
                            .frame(height: 260)
                    }
                    ForEach(Array(store.turns.enumerated()), id: \.element.id) { index, turn in
                        if let mark = separator(before: index) { DayMark(text: mark) }
                        TurnRows(turn: turn, retry: { retry(turn) }, delete: { delete(turn) },
                                 confirm: approve)
                    }
                    if store.busy { ThinkingRow() }
                    Color.clear.frame(height: 1).id(bottom)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { scroll.scrollTo(bottom, anchor: .bottom) }
            .onChange(of: store.turns.count) { _, _ in jump(scroll) }
            .onChange(of: store.busy) { _, _ in jump(scroll) }
            .onChange(of: typing) { _, now in if now { jump(scroll) } }
        }
    }

    private func jump(_ scroll: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.24)) { scroll.scrollTo(bottom, anchor: .bottom) }
    }

    /// 앞 말과 10분 넘게 벌어졌을 때만 시각을 한 번 답니다.
    /// 매 줄에 달면 읽는 데 방해가 됩니다.
    private func separator(before index: Int) -> String? {
        let turn = store.turns[index]
        guard index > 0 else { return Stamp.of(turn.at) }
        return turn.at.timeIntervalSince(store.turns[index - 1].at) > 600 ? Stamp.of(turn.at) : nil
    }

    private func send() {
        let text = draft
        draft = ""
        Haptic.tap()
        Task { await store.ask(text) }
    }

    private func retry(_ turn: Turn) {
        Thread.remove(turn)
        store.refresh()
        Task { await store.ask(turn.asked) }
    }

    /// 적어둔 일을 실제로 합니다. **누르기 전에는 아무것도 하지 않았습니다.**
    private func approve() {
        Task {
            await Nubi.confirmPending()
            store.refresh()
        }
    }

    private func delete(_ turn: Turn) {
        withAnimation(.easeOut(duration: 0.2)) {
            Thread.remove(turn)
            store.refresh()
        }
    }
}

struct DayMark: View {
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
struct TurnRows: View {
    let turn: Turn
    let retry: () -> Void
    let delete: () -> Void
    let confirm: () -> Void
    @State private var shown = false

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
                    if !turn.confirm.isEmpty, PendingStore.current != nil {
                        Button(turn.confirm, systemImage: "checkmark.shield.fill", role: .destructive) {
                            Haptic.done()
                            confirm()
                        }
                        .font(.caption.weight(.bold))
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(Ink.warn)
                    }
                    if let url = URL(string: turn.map), !turn.map.isEmpty {
                        Button("길찾기", systemImage: "location.fill") {
                            Haptic.tap()
                            UIApplication.shared.open(url)
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Ink.surface, in: Bubble(mine: false))
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
                    Haptic.tap()
                }
                Button("삭제", systemImage: "trash", role: .destructive, action: delete)
            }
            Meta(turn: turn)
        }
        .padding(.bottom, 16)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 8)
        .onAppear {
            withAnimation(.easeOut(duration: 0.22)) { shown = true }
        }
    }
}

/// 답 아래 아주 작은 줄. **네트워크를 탔는지 아닌지가 여기서 보입니다.**
private struct Meta: View {
    let turn: Turn

    var body: some View {
        HStack(spacing: 5) {
            if turn.viaIntent { Image(systemName: "lock.fill").font(.system(size: 8)) }
            if let label = turn.source.label { Text(label) }
            Spacer()
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.leading, 4)
    }
}

struct ThinkingRow: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text("생각하는 중…").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Ink.surface, in: Bubble(mine: false))
        .opacity(pulse ? 0.55 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .padding(.bottom, 16)
    }
}
