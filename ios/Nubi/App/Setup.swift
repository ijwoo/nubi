import EventKit
import SwiftUI

/// 준비가 끝났는가.
///
/// **권한도 키도 단축어도 없으면 이 앱은 아무것도 못 합니다.** 그런데 지금까지
/// 아무 안내가 없었습니다. 끝날 때까지만 대화 위에 붙습니다.
enum Setup {
    private static let key = "setup.shortcut.done"
    private static var store: UserDefaults? { UserDefaults(suiteName: NubiLog.group) }

    static var hasPermission: Bool { Events.canReadEvents && Events.canWriteReminders }
    static var hasKey: Bool { Secrets.apiKey != nil }

    /// 단축어는 앱이 확인할 방법이 없습니다. 사람이 끝냈다고 표시합니다.
    static var hasShortcut: Bool {
        get { store?.bool(forKey: key) ?? false }
        set { store?.set(newValue, forKey: key) }
    }

    static var isDone: Bool { hasPermission && hasKey && hasShortcut }
}

struct SetupCard: View {
    let onChange: () -> Void
    @State private var showHow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("시작하기")
                .font(.subheadline.weight(.bold))

            Step(done: Setup.hasPermission, title: "일정·미리알림 권한",
                 note: "잠금화면 버튼이 일정을 읽으려면 필요합니다.",
                 action: "허용") {
                Task {
                    _ = await Events.requestAll()
                    onChange()
                }
            }
            Step(done: Setup.hasKey, title: "모델 키",
                 note: "일정과 미리알림에는 없어도 됩니다. 그 밖의 질문에만 씁니다.",
                 action: "넣기") { showHow = false; openSettings() }
            Step(done: Setup.hasShortcut, title: "잠금화면 단축어",
                 note: "잠금을 풀지 않고 글자를 넣는 유일한 길입니다.",
                 action: "방법 보기") { showHow = true }
        }
        .padding(16)
        .background(Ink.theirs, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .sheet(isPresented: $showHow) {
            NavigationStack { ShortcutGuide(onDone: onChange) }
        }
    }

    /// 설정 시트는 대화 화면이 들고 있습니다. 여기서는 알림만 보냅니다.
    private func openSettings() {
        NotificationCenter.default.post(name: .nubiOpenSettings, object: nil)
    }

    private struct Step: View {
        let done: Bool
        let title: String
        let note: String
        let action: String
        let run: () -> Void

        var body: some View {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? Ink.accent : .secondary)
                    .font(.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .strikethrough(done, color: .secondary)
                        .foregroundStyle(done ? .secondary : .primary)
                    if !done {
                        Text(note).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if !done {
                    Button(action, action: run)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(Ink.accent)
                }
            }
        }
    }
}

extension Notification.Name {
    static let nubiOpenSettings = Notification.Name("nubi.open.settings")
}

/// 단축어 만드는 순서.
///
/// 앱이 대신 만들어 줄 수 없습니다. 단축어 생성은 사용자만 합니다.
struct ShortcutGuide: View {
    @Environment(\.dismiss) private var dismiss
    let onDone: () -> Void

    var body: some View {
        List {
            Section("1. 단축어 만들기") {
                Line(1, "단축어 앱을 열고 오른쪽 위 + 를 누릅니다")
                Line(2, "텍스트 입력 요청 을 찾아 추가합니다")
                Line(3, "프롬프트에 무엇을 물어볼까요 라고 적습니다")
                Line(4, "아래에 누비에게 묻기 를 추가합니다")
                Line(5, "무엇을 칸에 앞 단계의 입력한 텍스트 를 넣습니다")
                Line(6, "이름을 누비 로 저장합니다")
            }
            Section("2. 잠금화면에 올리기") {
                Line(1, "잠금화면을 길게 눌러 사용자화 를 누릅니다")
                Line(2, "잠금화면 쪽을 고르고 아래 버튼 자리를 탭합니다")
                Line(3, "목록에서 단축어 를 고르고 누비 를 선택합니다")
            }
            Section {
                Text("손전등 자리가 그 자리입니다. 누르면 키보드가 뜨고, 보내면 대화창이 생각하는 중 으로 바뀝니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("다 했습니다") {
                    Setup.hasShortcut = true
                    onDone()
                    dismiss()
                }
                .font(.body.weight(.semibold))
            }
        }
        .navigationTitle("잠금화면 단축어")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("닫기") { dismiss() }
            }
        }
    }

    private struct Line: View {
        let n: Int
        let text: String
        init(_ n: Int, _ text: String) { self.n = n; self.text = text }

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Text("\(n)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(Ink.accent)
                    .frame(width: 16, alignment: .trailing)
                Text(text).font(.callout)
            }
        }
    }
}
