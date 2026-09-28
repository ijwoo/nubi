import SwiftUI

/// 누비가 아는 것.
///
/// **보이고 지울 수 있는 것이 기능이 아니라 조건입니다.** 한 번 잘못 들어간
/// 기억은 그 뒤 모든 답의 바닥이 됩니다. 무엇을 아는지 못 보면 왜 이상한 답이
/// 나오는지도 알 수 없습니다.
struct MemoryView: View {
    @State private var facts = Memory.all()
    @State private var adding = false
    @State private var draft = ""
    @State private var kind = Memory.Kind.fact
    @State private var refused = ""
    @State private var confirmClear = false

    var body: some View {
        List {
            if facts.isEmpty {
                Section {
                    Text("아직 아는 게 없습니다.")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("대화 중에 ‘나 매운 거 못 먹어’ 처럼 말하면 기억합니다. 여기서 직접 넣어도 됩니다.")
                }
            }
            ForEach(Memory.Kind.allCases, id: \.self) { group in
                let rows = facts.filter { $0.kind == group }
                if !rows.isEmpty {
                    Section(group.label) {
                        ForEach(rows) { fact in
                            row(fact)
                        }
                        .onDelete { offsets in
                            for index in offsets { forget(rows[index]) }
                        }
                    }
                }
            }
            if !facts.isEmpty {
                Section {
                    Button("전부 지우기", role: .destructive) { confirmClear = true }
                } footer: {
                    Text("\(facts.count) / \(Memory.limit)개. 꽉 차면 오래된 것부터 밀려납니다.")
                }
            }
        }
        .navigationTitle("기억")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("추가", systemImage: "plus") { adding = true }
            }
        }
        .sheet(isPresented: $adding) { sheet }
        .confirmationDialog("기억을 전부 지울까요", isPresented: $confirmClear) {
            Button("지우기", role: .destructive) {
                Memory.clear()
                facts = []
                Haptic.tap()
            }
        } message: {
            Text("되돌릴 수 없습니다.")
        }
    }

    private func row(_ fact: Memory.Fact) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(fact.text)
            HStack(spacing: 6) {
                Text(when(fact.at))
                if fact.stale {
                    Text("오래됨")
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Ink.warn.opacity(0.18), in: Capsule())
                }
                // 좌표가 있어야 "집에 도착하면" 이 됩니다. 이름만 있으면 글자입니다.
                if fact.coordinate != nil {
                    Label("자리 알고 있음", systemImage: "mappin")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var sheet: some View {
        NavigationStack {
            Form {
                TextField("한 줄로", text: $draft, axis: .vertical)
                Picker("종류", selection: $kind) {
                    ForEach(Memory.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if !refused.isEmpty {
                    Text(refused).font(.footnote).foregroundStyle(Ink.warn)
                }
            }
            .navigationTitle("기억 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("취소") { close() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("저장") { save() }
                        .font(.body.weight(.semibold))
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        do {
            // 장소를 직접 넣으면 지금 서 있는 자리로 봅니다. 이 화면에서 다른
            // 자리를 고를 길이 없고, 없는 것보다 낫습니다.
            try Memory.remember(draft, kind: kind, at: kind == .place ? Places.here() : nil)
            facts = Memory.all()
            Haptic.tap()
            close()
        } catch {
            refused = error.localizedDescription
        }
    }

    private func forget(_ fact: Memory.Fact) {
        Memory.remove(fact)
        facts = Memory.all()
    }

    private func close() {
        adding = false
        draft = ""
        refused = ""
        kind = .fact
    }

    private func when(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일"
        return f.string(from: date) + "부터"
    }
}
