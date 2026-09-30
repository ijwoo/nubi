import SwiftUI

/// 알람과 알림.
///
/// **걸어놓고 볼 데가 없었습니다.** AlarmKit 알람은 만든 앱의 것이라 시계 앱에
/// 뜨지 않습니다. 기록에는 걸렸다고 남는데 사람은 어디서도 확인할 수 없었고,
/// 그러면 걸렸는지 못 믿습니다.
///
/// 둘을 한 화면에 둡니다. 성격은 다르지만 사람이 찾는 자리는 같습니다 —
/// "내가 뭘 걸어놨더라".
struct AlarmsView: View {
    @State private var alarms: [Alarms.Set] = []
    @State private var timers: [Timers.Running] = []
    @State private var adding = false
    @State private var at = Calendar.current.date(
        bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var label = ""
    @State private var days: Set<Int> = []
    @State private var refused = ""

    private static let dayNames = [(1, "일"), (2, "월"), (3, "화"), (4, "수"),
                                   (5, "목"), (6, "금"), (7, "토")]

    var body: some View {
        List {
            if alarms.isEmpty && timers.isEmpty {
                Section {
                    Empty(text: "걸어둔 게 없습니다", icon: "alarm")
                        .frame(height: 220)
                        .listRowBackground(Color.clear)
                } footer: {
                    Text("‘내일 7시에 깨워줘’ 처럼 말하면 알람이, ‘3분 타이머’ 라고 하면 알림이 걸립니다.")
                }
            }

            if !alarms.isEmpty {
                Section {
                    ForEach(alarms) { alarm in row(alarm) }
                        .onDelete { offsets in
                            for index in offsets { drop(alarms[index]) }
                        }
                } header: {
                    Text("알람")
                } footer: {
                    Text("무음과 집중 모드를 뚫고 끌 때까지 웁니다. 시계 앱에는 보이지 않습니다 — 누비가 건 것이라 여기에만 있습니다.")
                }
            }

            if !timers.isEmpty {
                Section {
                    ForEach(timers) { timer in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(timer.label).font(.body)
                                Text("\(Format.time(timer.fires))에 울려")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(left(timer.fires))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(Ink.accent)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { kill(timers[index]) }
                    }
                } header: {
                    Text("알림")
                } footer: {
                    Text("소리는 나지만 무음 스위치를 넘지는 못합니다. 짧은 것에 씁니다.")
                }
            }
        }
        .navigationTitle("알람")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("추가", systemImage: "plus") { adding = true }
                    .disabled(!Alarms.supported)
            }
        }
        .sheet(isPresented: $adding) { sheet }
        .task { await reload() }
    }

    private func row(_ alarm: Alarms.Set) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(alarm.label).font(.body)
                Text(alarm.repeats ? weekly(alarm) : Format.short(alarm.at))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.time(alarm.at))
                .font(.title3.weight(.semibold).monospacedDigit())
        }
    }

    private func weekly(_ alarm: Alarms.Set) -> String {
        "매주 " + Self.dayNames.filter { alarm.weekly.contains($0.0) }
            .map(\.1).joined(separator: "·")
    }

    private func left(_ fires: Date) -> String {
        let minutes = max(0, Int(fires.timeIntervalSinceNow / 60))
        return minutes >= 60 ? "\(minutes / 60)시간 \(minutes % 60)분" : "\(minutes)분"
    }

    private var sheet: some View {
        NavigationStack {
            Form {
                DatePicker("시각", selection: $at, displayedComponents: .hourAndMinute)
                TextField("무엇을 위한 알람인지", text: $label)
                Section {
                    HStack(spacing: 6) {
                        ForEach(Self.dayNames, id: \.0) { number, name in
                            Button(name) {
                                if days.contains(number) { days.remove(number) }
                                else { days.insert(number) }
                                Haptic.tap()
                            }
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(days.contains(number) ? Ink.accent : Ink.surface,
                                        in: Capsule())
                            .foregroundStyle(days.contains(number) ? .white : .secondary)
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                } header: {
                    Text("되풀이")
                } footer: {
                    Text(days.isEmpty ? "아무것도 안 고르면 한 번만 울립니다." : "")
                }
                if !refused.isEmpty {
                    Text(refused).font(.footnote).foregroundStyle(Ink.warn)
                }
            }
            .navigationTitle("알람 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("취소") { close() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("저장") { save() }.font(.body.weight(.semibold))
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        Task {
            do {
                // 지난 시각을 고르면 내일입니다. 오늘 아침 7시를 다시 걸 일은 없습니다.
                var when = at
                if when < Date(), days.isEmpty {
                    when = Calendar.current.date(byAdding: .day, value: 1, to: when) ?? when
                }
                try await Alarms.set(at: when, label: label, weekly: days.sorted())
                Haptic.done()
                await reload()
                close()
            } catch {
                refused = error.localizedDescription
            }
        }
    }

    private func drop(_ alarm: Alarms.Set) {
        _ = Alarms.cancel(label: alarm.label)
        Task { await reload() }
    }

    private func kill(_ timer: Timers.Running) {
        Task {
            _ = await Timers.cancel(label: timer.label)
            await reload()
        }
    }

    private func reload() async {
        alarms = Alarms.all()
        timers = await Timers.running()
    }

    private func close() {
        adding = false
        label = ""
        days = []
        refused = ""
    }
}
