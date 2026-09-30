import SwiftUI
import UIKit

enum Drawer: Hashable { case events, reminders, alarms, chat, lock }

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
    @State private var runningTimer = false
    @FocusState private var typing: Bool

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 12) {
                        greeting
                        if !Setup.isDone {
                            SetupCard(onChange: reload)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        drawers
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                Composer(draft: $draft, busy: store.busy, typing: $typing,
                         suggestions: hints, send: send)
            }
            .background(Ink.ground)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
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
                case .alarms: AlarmsView()
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
                // **여는 순간에는 아직 앞이 아닙니다.** `.task` 에서 만들려고
                // 하면 "Target is not foreground" 로 거절당하고, 그러면
                // 잠금화면 버튼이 갱신할 창이 없습니다 — 가끔 아무 반응이
                // 없던 자리입니다. 앞에 온 뒤에 다시 세웁니다.
                Task { await store.revive() }
                // 앱이 앞에 올 때마다 자리를 갱신합니다. **잠금 상태에서는 새로
                // 못 잡습니다** — 잠금화면 버튼이 쓰는 것은 이때 잡아둔 값입니다.
                openPendingRoute()
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

    /// 첫 화면에서 제일 먼저 보이는 것.
    ///
    /// **서랍 넷이 먼저 오던 자리입니다.** 실제로 제일 많이 하는 일은 묻는
    /// 것인데, 서랍이 위를 다 먹고 입력줄은 바닥에 얇게 깔려 있었습니다.
    /// 이제 말풍이와 오늘 한 줄이 먼저 오고 서랍은 아래로 내려갑니다.
    private var greeting: some View {
        HStack(alignment: .center, spacing: 12) {
            Malpoongi(size: 46, mood: store.busy ? .thinking : .listening, alive: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("뭐 도와줄까")
                    .font(.title2.weight(.bold))
                Text(oneLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    /// 오늘을 한 줄로. 없는 것은 말하지 않습니다.
    private var oneLine: String {
        var parts: [String] = []
        if let next = today.first(where: { !$0.allDay && $0.start > Date() }) ?? today.first {
            parts.append(next.allDay ? next.title : "\(Format.time(next.start)) \(next.title)")
        }
        if !open.isEmpty { parts.append("할일 \(open.count)개") }
        return parts.isEmpty ? "오늘은 잡힌 게 없어" : parts.joined(separator: " · ")
    }

    private var drawers: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)], spacing: 10) {
            DrawerTile(icon: "calendar", tint: Ink.accent, title: "일정",
                       note: eventsNote) { go(.events) }
            DrawerTile(icon: "checklist", tint: Ink.done, title: "미리알림",
                       note: open.isEmpty ? "다 끝냈어" : "안 끝난 것 \(open.count)개") { go(.reminders) }
            // **걸어놓고 볼 데가 없었습니다.** 누비가 건 알람은 시계 앱에
            // 안 뜹니다. 잠금화면 설명은 처음 한 번 보는 것이라 설정으로
            // 내리고, 매일 찾을 자리를 여기 둡니다.
            DrawerTile(icon: "alarm", tint: Ink.warn, title: "알람",
                       note: alarmNote) { go(.alarms) }
            DrawerTile(icon: "bubble.left.and.text.bubble.right", tint: Ink.accent.opacity(0.75),
                       title: "대화",
                       note: store.turns.last?.headline ?? "아직 없어") { go(.chat) }
        }
    }

    /// 지금 눌릴 만한 것.
    ///
    /// **고정 넷이었습니다** — `오늘 일정 · 오늘 할일 · 근처 카페 · 내일 3시
    /// 회의 일정 추가`. 앱 열 때마다 보이는 자리인데 늘 같으니 아무도 안
    /// 누릅니다. 지금 걸려 있는 것과 시간대를 보고 고릅니다.
    private var hints: [String] {
        var list: [String] = []
        // 방금 뭔가를 했으면 물릴 길이 제일 먼저입니다.
        if Undo.pending != nil { list.append("방금 그거 취소") }
        if runningTimer { list.append("타이머 얼마 남았어") }
        if today.contains(where: { $0.start > Date() }) { list.append("오늘 일정") }
        if !open.isEmpty { list.append("오늘 할일") }

        switch Calendar.current.component(.hour, from: Date()) {
        case 6...9: list.append("오늘 날씨")
        case 11...13: list.append("점심 뭐 먹지")
        case 17...20: list.append("저녁 뭐 먹지")
        case 22...23, 0...2: if Alarms.all().isEmpty { list.append("내일 아침 7시에 깨워줘") }
        default: break
        }
        if list.count < 3 { list.append("근처 카페") }
        return Array(list.prefix(4))
    }

    private var alarmNote: String {
        let set = Alarms.all()
        guard let next = set.first else { return "걸어둔 게 없어" }
        return "\(Format.time(next.at)) \(next.label)"
    }

    private var eventsNote: String {
        guard !today.isEmpty else { return "오늘은 없어" }
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
        openPendingRoute()
        await store.revive()
        await store.refreshPlace()
        await Briefing.reschedule()
    }

    /// 잠금화면에서 누른 길찾기를 이어받습니다.
    private func openPendingRoute() {
        guard let url = Navigation.take() else { return }
        UIApplication.shared.open(url)
    }

    private func reload() {
        withAnimation(.easeOut(duration: 0.2)) { store.refresh() }
        today = Events.onDay(offset: 0)
        Task {
            open = (try? await Events.openReminders()) ?? []
            runningTimer = await !Timers.running().isEmpty
        }
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


/// 서랍 한 칸. **넷이 두 줄로 들어갑니다.**
///
/// 한 줄에 하나씩 놓던 것을 반으로 접었습니다. 서랍은 들어가는 문일 뿐인데
/// 화면 위쪽을 다 먹고 있었습니다.
struct DrawerTile: View {
    let icon: String
    let tint: Color
    let title: String
    let note: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        .frame(height: 28, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Ink.edge, lineWidth: 1))
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
                            .tint(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("무엇이든 물어봐", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.callout)
                    .focused($typing)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(Ink.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    // **묻는 곳이 주인공입니다.** 손이 가 있는 자리에 빛이 돕니다.
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(typing ? Ink.accent.opacity(0.7) : Ink.edge, lineWidth: 1))
                    .animation(.easeOut(duration: 0.2), value: typing)
                    .onSubmit(send)
                Button(action: send) {
                    Group {
                        if busy {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "arrow.up").font(.body.weight(.bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Ink.accent.opacity(ready ? 1 : 0.28), in: Circle())
                    .scaleEffect(ready ? 1 : 0.92)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: ready)
                }
                .disabled(!ready)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .background(Ink.ground)
    }

    private var ready: Bool {
        !busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
