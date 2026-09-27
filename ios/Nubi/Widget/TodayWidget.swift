import AppIntents
import SwiftUI
import WidgetKit

/// 홈 화면 위젯.
///
/// **잠금화면에만 살면 하루에 몇 번 안 보입니다.** 오늘 일정과 안 끝난 할일을
/// 홈에 두면 묻지 않아도 눈에 들어옵니다.
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.jaewoo.nubi.todaywidget", provider: TodayProvider()) { entry in
            TodayFace(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("오늘")
        .description("오늘 일정과 안 끝난 할일.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TodayEntry: TimelineEntry {
    let date: Date
    let events: [Events.Item]
    let openCount: Int
    let blocked: Bool
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: Date(), events: [], openCount: 0, blocked: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        Task { completion(await load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        Task {
            let entry = await load()
            // 다음 일정이 시작할 때와, 아니면 30분 뒤에 다시 그립니다.
            let soon = entry.events.first { $0.start > Date() }?.start
            let next = min(soon ?? .distantFuture, Date().addingTimeInterval(1800))
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func load() async -> TodayEntry {
        guard Events.canReadEvents else {
            return TodayEntry(date: Date(), events: [], openCount: 0, blocked: true)
        }
        let events = (try? Events.upcoming(days: 1)) ?? []
        let open = ((try? await Events.openReminders()) ?? []).count
        return TodayEntry(date: Date(), events: events, openCount: open, blocked: false)
    }
}

private struct TodayFace: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Malpoongi(size: 22, mood: entry.blocked ? .waiting : .listening)
                Text(entry.blocked ? "권한이 필요합니다" : title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 8)

            if entry.blocked {
                Text("누비를 열어 일정 권한을 허용해 주세요.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if entry.events.isEmpty {
                Text("오늘 일정이 없습니다")
                    .font(.subheadline.weight(.semibold))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entry.events.prefix(family == .systemSmall ? 2 : 3), id: \.id) { item in
                        Row(item: item)
                    }
                }
            }
            Spacer(minLength: 4)
            if entry.openCount > 0 {
                Label("할일 \(entry.openCount)개", systemImage: "checklist")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var title: String {
        entry.events.isEmpty ? "오늘" : "오늘 \(entry.events.count)건"
    }

    private struct Row: View {
        let item: Events.Item

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(item.allDay ? "종일" : Format.time(item.start))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color(red: 0.36, green: 0.35, blue: 0.85))
                    .frame(width: 52, alignment: .leading)
                Text(item.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
        }
    }
}

/// 잠금화면 위젯.
///
/// 대화창은 물어봐야 뜹니다. **이건 묻지 않아도 늘 거기 있습니다.** 시계 아래
/// 한 줄, 또는 동그라미 하나로 다음 일정을 말합니다.
struct NextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.jaewoo.nubi.next", provider: TodayProvider()) { entry in
            NextFace(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("다음 일정")
        .description("잠금화면에 다음 일정을 한 줄로.")
        .supportedFamilies([.accessoryInline, .accessoryRectangular, .accessoryCircular])
    }
}

private struct NextFace: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    /// 지나간 일정은 다음이 아닙니다. 아직 안 온 것 중 가장 이른 것.
    private var next: Events.Item? {
        entry.events.first { $0.start > Date() } ?? entry.events.first
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(inline)
        case .accessoryCircular:
            Gauge(value: Double(min(entry.events.count, 6)), in: 0...6) {
                Image(systemName: "calendar")
            } currentValueLabel: {
                Text("\(entry.events.count)")
            }
            .gaugeStyle(.accessoryCircular)
        default:
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.events.isEmpty ? "오늘" : "오늘 \(entry.events.count)건")
                    .font(.caption2.weight(.bold))
                    .widgetAccentable()
                if let next {
                    Text(next.allDay ? "종일" : Format.time(next.start))
                        .font(.caption2)
                    Text(next.title).font(.caption.weight(.semibold)).lineLimit(1)
                } else {
                    Text("일정이 없습니다").font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var inline: String {
        guard let next else { return "오늘 일정 없음" }
        return next.allDay ? next.title : "\(Format.time(next.start)) \(next.title)"
    }
}
