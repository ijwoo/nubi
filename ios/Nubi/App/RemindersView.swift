import SwiftUI

/// 미리알림 서랍. 안 끝난 것만 보여줍니다.
struct RemindersView: View {
    @State private var items: [Events.ReminderItem] = []
    @State private var problem: String?
    @State private var adding = false
    @State private var going: Set<String> = []

    var body: some View {
        Group {
            if let problem {
                Notice(text: problem)
            } else if items.isEmpty {
                Empty(text: "안 끝난 미리알림이 없습니다", icon: "checklist")
            } else {
                List {
                    ForEach(items) { item in
                        Row(item: item, done: going.contains(item.id)) { complete(item) }
                    }
                }
                .listStyle(.plain)
                .refreshable { await load() }
            }
        }
        .navigationTitle("미리알림")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Haptic.tap(); adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("미리알림 추가")
            }
        }
        .sheet(isPresented: $adding) { AddReminder { Task { await load() } } }
        .task { await load() }
    }

    private func load() async {
        do {
            items = try await Events.openReminders()
            problem = nil
        } catch {
            items = []
            problem = error.localizedDescription
        }
    }

    /// 체크를 먼저 칠하고 잠깐 뒤에 목록에서 뺍니다. 눌렀는데 아무 일도 안 일어난
    /// 것처럼 보이면 사람은 다시 누릅니다.
    private func complete(_ item: Events.ReminderItem) {
        Haptic.done()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { _ = going.insert(item.id) }
        try? Events.complete(item)
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeOut(duration: 0.25)) { items.removeAll { $0.id == item.id } }
            going.remove(item.id)
        }
    }

    private struct Row: View {
        let item: Events.ReminderItem
        let done: Bool
        let toggle: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                Button(action: toggle) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(done ? Ink.accent : .secondary)
                        .scaleEffect(done ? 1.15 : 1)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.body)
                        .strikethrough(done, color: .secondary)
                        .foregroundStyle(done ? .secondary : .primary)
                    if let due = item.due {
                        Text(Stamp.of(due)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 3)
        }
    }
}

private struct AddReminder: View {
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void

    @State private var title = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("무엇을", text: $title)
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(Ink.warn)
                }
            }
            .navigationTitle("미리알림 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("저장") {
                        do {
                            try Events.addReminder(title.trimmingCharacters(in: .whitespaces))
                            Haptic.done()
                            onSaved()
                            dismiss()
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                    .font(.body.weight(.semibold))
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
