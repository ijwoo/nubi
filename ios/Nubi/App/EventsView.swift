import SwiftUI

/// 일정 서랍.
struct EventsView: View {
    private enum Span: String, CaseIterable, Identifiable {
        case today = "오늘", tomorrow = "내일", week = "이번 주"
        var id: String { rawValue }
        var days: Int { self == .week ? 7 : 1 }
        var offset: Int { self == .tomorrow ? 1 : 0 }
    }

    @State private var span = Span.today
    @State private var items: [Events.Item] = []
    @State private var problem: String?
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $span) {
                ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            if let problem {
                Notice(text: problem)
            } else if items.isEmpty {
                Empty(text: "\(span.rawValue) 일정이 없습니다", icon: "calendar")
            } else {
                List {
                    ForEach(items) { item in
                        EventRow(item: item)
                            .swipeActions(edge: .trailing) {
                                Button("삭제", systemImage: "trash", role: .destructive) {
                                    Haptic.tap()
                                    try? Events.remove(eventId: item.id)
                                    withAnimation(.easeOut(duration: 0.22)) {
                                        items.removeAll { $0.id == item.id }
                                    }
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .refreshable { load() }
            }
        }
        .padding(.top, 10)
        .navigationTitle("일정")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Haptic.tap(); adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("일정 추가")
            }
        }
        .sheet(isPresented: $adding) { AddEvent(onSaved: load) }
        .onAppear(perform: load)
        .onChange(of: span) { _, _ in
            withAnimation(.easeOut(duration: 0.18)) { load() }
        }
    }

    private func load() {
        do {
            let base = Calendar.current.date(byAdding: .day, value: span.offset, to: Date()) ?? Date()
            items = try Events.upcoming(days: span.days, from: base)
            problem = nil
        } catch {
            items = []
            problem = error.localizedDescription
        }
    }
}

private struct EventRow: View {
    let item: Events.Item

    var body: some View {
        HStack(spacing: 12) {
            Capsule().fill(Ink.accent).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body)
                Text(item.allDay ? "종일" : "\(day) \(Format.time(item.start))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    private var day: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일"
        return f.string(from: item.start)
    }
}

/// 직접 넣기. 말로 넣는 쪽은 라우터가 받습니다.
private struct AddEvent: View {
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void

    @State private var title = ""
    @State private var start = Calendar.current.date(bySetting: .minute, value: 0, of: Date().addingTimeInterval(3600)) ?? Date()
    @State private var allDay = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("무엇을", text: $title)
                Toggle("종일", isOn: $allDay.animation(.easeOut(duration: 0.18)))
                DatePicker("언제", selection: $start,
                           displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(Ink.warn)
                }
            }
            .navigationTitle("일정 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("저장", action: save)
                        .font(.body.weight(.semibold))
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        do {
            try Events.addEvent(title: title.trimmingCharacters(in: .whitespaces),
                                start: allDay ? Calendar.current.startOfDay(for: start) : start,
                                allDay: allDay)
            Haptic.done()
            onSaved()
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

struct Empty: View {
    let text: String
    let icon: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Notice: View {
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26)).foregroundStyle(Ink.warn)
            Text(text).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
