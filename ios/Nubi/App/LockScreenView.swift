import SwiftUI

enum Moods {
    static let all: [(mood: Malpoongi.Mood, label: String)] = [
        (.listening, "듣는 중"), (.thinking, "생각 중"), (.done, "완료"), (.waiting, "확인 필요"),
    ]
}

/// 잠금화면 서랍. 대화창을 켜고 끄고, 단축어 만드는 법을 봅니다.
struct LockScreenView: View {
    @Environment(Store.self) private var store
    let onChange: () -> Void

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: store.liveIsOn ? "lock.display" : "lock.slash")
                        .foregroundStyle(store.liveIsOn ? Ink.accent : .secondary)
                    Text(store.liveIsOn ? "대화창이 떠 있습니다" : "대화창이 꺼져 있습니다")
                    Spacer()
                }
                if store.liveIsOn {
                    Button("잠금화면에서 내리기", role: .destructive) {
                        LiveAnswer.dismissAll()
                        store.liveIsOn = false
                        onChange()
                    }
                } else {
                    Button("잠금화면에 띄우기") {
                        Task {
                            await store.revive()
                            Haptic.done()
                            onChange()
                        }
                    }
                }
            } header: {
                Text("대화창")
            } footer: {
                Text("내리면 잠금화면에서 다시 못 띄웁니다. 앱을 열거나 제어 센터의 누비 버튼을 눌러야 돌아옵니다.")
            }

            Section {
                NavigationLink("단축어 만드는 법") { ShortcutGuide(onDone: onChange) }
            } header: {
                Text("글자로 묻기")
            } footer: {
                Text("잠금을 풀지 않고 묻는 길은 단축어 하나입니다. 대화창 안의 버튼으로는 글자를 넣을 수 없습니다.")
            }

            Section {
                HStack(spacing: 0) {
                    ForEach(Moods.all, id: \.label) { item in
                        VStack(spacing: 7) {
                            Malpoongi(size: 42, mood: item.mood)
                            Text(item.label).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("말풍이")
            } footer: {
                Text("잠금화면 대화창에서 지금 무엇을 하고 있는지 표정으로 말합니다.")
            }

            Section {
                Label("오늘 · 내일 버튼으로 일정을 봅니다", systemImage: "calendar")
                Label("전문 버튼으로 앱을 엽니다", systemImage: "arrow.up.forward")
                Label("제어 센터의 누비 버튼으로도 띄웁니다", systemImage: "switch.2")
            } header: {
                Text("대화창에서 할 수 있는 것")
            }
        }
        .navigationTitle("잠금화면")
        .navigationBarTitleDisplayMode(.inline)
    }
}
