import SwiftUI

enum Drawer: Hashable { case events, reminders, chat, lock }

/// 홈. **서랍 넷과 입력줄 하나.**
///
/// 관련된 것끼리 서랍에 들어가 있고, 어디서 시작하든 묻는 것이 가장 빠른 길이라
/// 입력줄은 여기 그대로 둡니다. 홈에서 물으면 대화 서랍으로 넘어갑니다.
struct HomeView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var path: [Drawer] = []
    @State private var draft = ""
    @State private var showSettings = false
    @State private var today: [Events.Item] = []
    @State private var open: [Events.ReminderItem] = []
    @FocusState private var typing: Bool

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 10) {
                        if !Setup.isDone {
                            SetupCard(onChange: reload)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        drawers
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                Composer(draft: $draft, busy: store.busy, typing: $typing,
                         suggestions: Suggestion.all, send: send)
            }
            .navigationTitle("누비")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("설정")
                }
            }
            .navigationDestination(for: Drawer.self) { drawer in
                switch drawer {
                case .events: EventsView()
                case .reminders: RemindersView()
                case .chat: ChatView()
                case .lock: LockScreenView(onChange: reload)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView(onChange: reload) }
        }
        .task { await start() }
        .onChange(of: phase) { _, now in
            // 앞에 있을 때만 위치를 물을 수 있습니다.
            Places.foreground = now == .active
            if now == .active {
                reload()
                // 앱이 앞에 올 때마다 자리를 갱신합니다. **잠금 상태에서는 새로
                // 못 잡습니다** — 잠금화면 버튼이 쓰는 것은 이때 잡아둔 값입니다.
                Task {
                    await store.refreshPlace()
                    await Briefing.reschedule()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nubiOpenSettings)) { _ in
            showSettings = true
        }
    }

    private var drawers: some View {
        VStack(spacing: 10) {
            DrawerRow(icon: "calendar", tint: Ink.accent, title: "일정",
                      note: eventsNote) { go(.events) }
            DrawerRow(icon: "checklist", tint: Ink.done, title: "미리알림",
                      note: open.isEmpty ? "안 끝난 것이 없습니다" : "안 끝난 것 \(open.count)개") { go(.reminders) }
            DrawerRow(icon: "bubble.left.and.text.bubble.right", tint: Ink.accent.opacity(0.75), title: "대화",
                      note: store.turns.last?.headline ?? "아직 없습니다") { go(.chat) }
            DrawerRow(icon: "lock.display", tint: store.liveIsOn ? Ink.accent : .secondary,
                      title: "잠금화면",
                      note: store.liveIsOn ? "대화창이 떠 있습니다" : "대화창이 꺼져 있습니다") { go(.lock) }
        }
    }

    private var eventsNote: String {
        guard !today.isEmpty else { return "오늘 일정이 없습니다" }
        let next = today.first { !$0.allDay && $0.start > Date() } ?? today[0]
        return next.allDay ? "오늘 \(today.count)건 · \(next.title)"
                           : "오늘 \(today.count)건 · \(Format.time(next.start)) \(next.title)"
    }

    private func go(_ drawer: Drawer) {
        Haptic.tap()
        path.append(drawer)
    }

    private func start() async {
        Places.foreground = true
        reload()
        await store.revive()
        await store.refreshPlace()
        await Briefing.reschedule()
    }

    private func reload() {
        withAnimation(.easeOut(duration: 0.2)) { store.refresh() }
        today = Events.onDay(offset: 0)
        Task { open = (try? await Events.openReminders()) ?? [] }
    }

    private func send() {
        let text = draft
        draft = ""
        typing = false
        Haptic.tap()
        path = [.chat]
        Task { await store.ask(text) }
    }
}

enum Suggestion {
    static let all = ["오늘 일정", "오늘 할일", "근처 카페", "내일 3시 회의 일정 추가"]
}

/// 서랍 한 칸.
struct DrawerRow: View {
    let icon: String
    let tint: Color
    let title: String
    let note: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(Press())
    }
}

/// 아래 고정 입력줄.
struct Composer: View {
    @Binding var draft: String
    let busy: Bool
    @FocusState.Binding var typing: Bool
    var suggestions: [String] = []
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
                .transition(.opacity)
            }
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("무엇이든 물어보세요", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($typing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Ink.surface, in: Capsule())
                    .onSubmit(send)
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
                    .background(Ink.accent.opacity(ready ? 1 : 0.3), in: Circle())
                    .scaleEffect(ready ? 1 : 0.94)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: ready)
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
