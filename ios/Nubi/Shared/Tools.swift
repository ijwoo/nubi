import Foundation

/// 모델이 부를 수 있는 것들.
///
/// **낱말 규칙으로 갈래를 정하던 것을 그만둡니다.** "오늘 덥나" 를 날씨로,
/// "여자친구랑 저녁메뉴 추천" 을 그냥 답으로 보내는 일을 규칙으로 맞히려니
/// 계속 어긋났고, 어긋날 때마다 프롬프트로 회피를 가르쳐 모델까지 쓸모없어졌습니다.
///
/// 이제 **모델이 고릅니다.** 일정·미리알림·지도·날씨는 도구로 주고, 무엇을 쓸지는
/// 모델이 정합니다. 우리는 도구가 한 일만 기록합니다.
struct ToolRun {
    var map = ""
    var confirm = ""
    var used: Set<Source> = []
    /// 실제로 무언가를 **쓴** 적이 있는가.
    ///
    /// 읽기만 하고 "넣었어" 라고 말하는 일을 잡으려면 이 표시가 필요합니다.
    /// 모델이 식당을 "예약 잡았어" 라고 답한 적이 있는데, 그 턴에 돈 도구는
    /// 일정 읽기 하나뿐이었습니다.
    var wrote = false

    /// 답 아래 붙일 출처. 도구를 안 썼으면 모델입니다.
    var source: Source {
        if used.contains(.places) { return .places }
        if used.contains(.weather) { return .weather }
        if used.contains(.events) { return .events }
        if used.contains(.reminders) { return .reminders }
        if used.contains(.search) { return .search }
        return .model
    }
}

enum Tools {
    static var schema: [[String: Any]] {
        [
            tool("get_events", "사용자의 캘린더 일정을 읽는다.", [
                "day_offset": ["type": "integer", "description": "오늘이 0, 내일이 1"],
                "span_days": ["type": "integer", "description": "며칠치. 하루면 1"],
            ], ["day_offset", "span_days"]),

            tool("add_event",
                 "캘린더에 일정을 넣는다. 겹치는 일정이 있으면 넣은 뒤에 알려준다.", [
                "title": ["type": "string"],
                "start": ["type": "string", "description": "ISO8601, 예 2026-09-28T19:00:00+09:00"],
                "all_day": ["type": "boolean", "description": "시각을 모르면 true"],
                "minutes": ["type": "integer", "description": "몇 분짜리인지. 모르면 60"],
                "place": ["type": "string",
                          "description": "어디서 하는지. 가게 이름이나 주소. 방금 find_places 로 찾은 곳이면 그 이름을 그대로 쓴다 — 아이폰이 출발할 시각을 알려준다"],
            ], ["title", "start", "all_day"]),

            tool("propose_event_change",
                 "일정을 지우거나 옮길 것을 제안한다. 바로 하지 않고 사용자 승인을 받는다.", [
                "name": ["type": "string", "description": "일정 제목의 일부"],
                "action": ["type": "string", "enum": ["delete", "move"]],
                "new_start": ["type": "string", "description": "옮길 때만. ISO8601"],
            ], ["name", "action"]),

            tool("get_reminders", "안 끝난 미리알림을 읽는다.", [:], []),

            tool("add_reminder", "미리알림을 넣는다.", [
                "title": ["type": "string"],
                "due": ["type": "string", "description": "ISO8601. 시각이 없으면 비운다"],
            ], ["title"]),

            tool("complete_reminder", "미리알림 하나를 끝냈다고 표시한다.", [
                "name": ["type": "string"],
            ], ["name"]),

            tool("find_places",
                 "지금 자리에서 가까운 가게를 찾는다. 지역명은 넣지 않는다 — 언제나 현재 위치 기준이다.", [
                "query": ["type": "string",
                          "description": "간판에 쓰이는 가게 종류. '회'가 아니라 '횟집', '고기'가 아니라 '고깃집', '커피'가 아니라 '카페'"],
            ], ["query"]),

            tool("get_weather", "지금 자리의 날씨를 본다.", [:], []),
        ]
    }

    private static func tool(_ name: String, _ about: String,
                             _ props: [String: Any], _ required: [String]) -> [String: Any] {
        ["name": name, "description": about,
         "input_schema": ["type": "object", "properties": props, "required": required]]
    }

    /// 도구를 실제로 돌립니다. 돌려주는 글자가 모델에게 갑니다.
    static func run(_ name: String, _ input: [String: Any], into run: inout ToolRun) async -> String {
        switch name {
        case "get_events":
            run.used.insert(.events)
            let offset = input["day_offset"] as? Int ?? 0
            let span = input["span_days"] as? Int ?? 1
            let base = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
            guard let items = try? Events.upcoming(days: max(1, span), from: base) else {
                return "일정 권한이 없습니다. 사용자가 앱에서 허용해야 합니다."
            }
            guard !items.isEmpty else { return "그 기간에 일정이 없습니다." }
            return items.map(line).joined(separator: "\n")

        case "add_event":
            run.used.insert(.events)
            guard let title = input["title"] as? String,
                  let start = date(input["start"]) else { return "시각을 알 수 없습니다." }
            let allDay = input["all_day"] as? Bool ?? false
            let minutes = input["minutes"] as? Int ?? 60
            let place = (input["place"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            // **넣기 전에 봅니다.** 넣고 나서 보면 자기 자신이 걸립니다.
            let clashes = allDay ? [] : Events.clashes(with: start, minutes: minutes)
            do {
                try Events.addEvent(title: title, start: start, allDay: allDay,
                                    minutes: minutes, place: place,
                                    at: place.isEmpty ? nil : Places.coordinate(of: place))
                run.wrote = true
                var said = "넣었습니다: \(Format.short(start)) \(title)"
                if !place.isEmpty { said += " (\(place))" }
                guard !clashes.isEmpty else { return said }
                return said + "\n겹치는 일정이 있습니다:\n"
                    + clashes.map(line).joined(separator: "\n")
                    + "\n사용자에게 겹친다고 알리고, 옮길지 물어라."
            } catch {
                return "넣지 못했습니다: \(error.localizedDescription)"
            }

        case "propose_event_change":
            run.used.insert(.events)
            guard let name = input["name"] as? String,
                  let action = input["action"] as? String else { return "무엇을 바꿀지 모르겠습니다." }
            let kind: Pending.Kind = action == "move" ? .move : .delete
            return propose(kind, name: name, to: date(input["new_start"]), into: &run)

        case "get_reminders":
            run.used.insert(.reminders)
            guard let items = try? await Events.openReminders() else {
                return "미리알림 권한이 없습니다. 사용자가 앱에서 허용해야 합니다."
            }
            guard !items.isEmpty else { return "안 끝난 미리알림이 없습니다." }
            return items.map { item in
                item.due.map { "\(Format.short($0)) \(item.title)" } ?? item.title
            }.joined(separator: "\n")

        case "add_reminder":
            run.used.insert(.reminders)
            guard let title = input["title"] as? String else { return "무엇을 넣을지 모르겠습니다." }
            let due = date(input["due"])
            do {
                try Events.addReminder(title, due: due)
                run.wrote = true
                return due.map { "넣었습니다: \(Format.short($0)) \(title)" } ?? "넣었습니다: \(title) (마감 없음)"
            } catch {
                return "넣지 못했습니다: \(error.localizedDescription)"
            }

        case "complete_reminder":
            run.used.insert(.reminders)
            guard let name = input["name"] as? String else { return "무엇을 끝냈는지 모르겠습니다." }
            guard let open = try? await Events.openReminders() else { return "미리알림을 읽을 수 없습니다." }
            let hits = open.filter { $0.title.contains(name) }
            guard hits.count == 1, let only = hits.first else {
                return hits.isEmpty ? "그런 미리알림이 없습니다."
                    : "여러 개가 걸립니다: " + hits.map(\.title).joined(separator: ", ")
            }
            try? Events.complete(only)
            run.wrote = true
            return "끝냈습니다: \(only.title)"

        case "find_places":
            run.used.insert(.places)
            guard let query = input["query"] as? String else { return "무엇을 찾을지 모르겠습니다." }
            do {
                let found = try await Places.findWidening(query)
                run.map = found.spots[0].directions?.absoluteString ?? ""
                Places.lastQuery = query
                let list = found.spots.map { "\($0.name) \($0.away)" }.joined(separator: "\n")
                return found.wide ? "근처에는 없어 조금 넓혀 찾았습니다.\n" + list : list
            } catch {
                return error.localizedDescription
            }

        case "get_weather":
            run.used.insert(.weather)
            do {
                let sky = try await Weather.now()
                var line = sky.line
                if let high = sky.highest, let low = sky.lowest { line += " · \(low)°/\(high)°" }
                return line
            } catch {
                // **막다른 길로 두지 않습니다.** 날씨 서비스가 막혀도 웹으로는
                // 찾을 수 있습니다. 모델에게 그 길을 알려줍니다.
                run.used.remove(.weather)
                return "\(error.localizedDescription) 대신 웹에서 지금 날씨를 찾아보고 답해라."
            }

        default:
            return "모르는 도구입니다."
        }
    }

    /// 지우거나 옮길 것을 **적어두기만** 합니다. 사람이 눌러야 실제로 합니다.
    private static func propose(_ kind: Pending.Kind, name: String,
                                to newStart: Date?, into run: inout ToolRun) -> String {
        PendingStore.clear()
        guard let upcoming = try? Events.upcoming(days: 14) else { return "일정을 읽을 수 없습니다." }
        let hits = upcoming.filter { $0.title.contains(name) }
        guard hits.count == 1, let only = hits.first else {
            return hits.isEmpty ? "‘\(name)’ 일정이 앞으로 2주 안에 없습니다."
                : "여러 개가 걸립니다: " + hits.map { "\(Format.short($0.start)) \($0.title)" }
                    .joined(separator: ", ")
        }
        if kind == .move, newStart == nil { return "언제로 옮길지 알려줘야 합니다." }
        PendingStore.hold(Pending(kind: kind, eventId: only.id, title: only.title,
                                  at: only.start, to: newStart))
        run.confirm = kind.verb
        var said = "아직 하지 않았습니다. 사용자에게 \(kind.verb)할지 물어보는 중입니다: "
            + "\(only.title) \(Format.short(only.start))"
            + (newStart.map { " → \(Format.short($0))" } ?? "")
        // 옮기려는 자리가 또 겹치면 옮기나 마나입니다.
        if let newStart {
            let minutes = Int(only.end.timeIntervalSince(only.start) / 60)
            let clashes = Events.clashes(with: newStart, minutes: max(5, minutes), ignoring: only.id)
            if !clashes.isEmpty {
                said += "\n옮길 자리에도 겹치는 것이 있습니다:\n"
                    + clashes.map(line).joined(separator: "\n")
            }
        }
        return said
    }

    /// 모델에게 보여줄 일정 한 줄. **끝시각과 장소까지 줍니다** — 겹치는지,
    /// 가는 데 시간이 되는지 판단하려면 둘 다 있어야 합니다.
    private static func line(_ item: Events.Item) -> String {
        guard !item.allDay else { return "\(Format.short(item.start)) \(item.title) (종일)" }
        var text = "\(Format.short(item.start))~\(Format.time(item.end)) \(item.title)"
        if !item.place.isEmpty { text += " @\(item.place)" }
        return text
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let d = full.date(from: text) { return d }
        let loose = ISO8601DateFormatter()
        loose.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = loose.date(from: text) { return d }
        // 시간대를 안 붙여 보내는 경우가 있습니다. 여기 시간대로 읽습니다.
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return plain.date(from: text)
    }
}
