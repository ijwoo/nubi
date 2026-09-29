import CoreLocation
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
    /// 걸 번호. **예약 도구는 없지만 전화는 넘길 수 있습니다.**
    var call = ""
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
        if used.contains(.timer) { return .timer }
        if used.contains(.memory) { return .memory }
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
                "repeat": ["type": "string", "enum": ["daily", "weekly", "monthly", "yearly"],
                           "description": "되풀이하면. 한 번뿐이면 비운다"],
                "repeat_days": ["type": "array", "items": ["type": "string"],
                                "description": "주마다 되풀이할 요일. 일 월 화 수 목 금 토 중에서"],
                "repeat_times": ["type": "integer", "description": "몇 번 하고 끝낼지. 끝이 없으면 비운다"],
            ], ["title", "start", "all_day"]),

            tool("propose_event_change",
                 "일정을 지우거나 옮길 것을 제안한다. 바로 하지 않고 사용자 승인을 받는다.", [
                "name": ["type": "string", "description": "일정 제목의 일부"],
                "action": ["type": "string", "enum": ["delete", "move"]],
                "new_start": ["type": "string", "description": "옮길 때만. ISO8601"],
                "at": ["type": "string",
                       "description": "같은 이름이 여럿일 때 어느 것인지. 그 일정의 시작 시각, ISO8601"],
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

            tool("set_timer",
                 "몇 분 뒤에 알린다. 라면·빨래처럼 목록에 남길 필요 없는 짧은 것에 쓴다. 날짜가 있는 일이면 add_reminder 를 쓴다.", [
                "minutes": ["type": "integer"],
                "label": ["type": "string", "description": "무엇을 위한 것인지. 예 '라면'"],
            ], ["minutes"]),

            tool("get_timers", "걸어둔 알림이 몇 분 남았는지 본다.", [:], []),

            tool("cancel_timer", "걸어둔 알림을 끈다.", [
                "label": ["type": "string", "description": "무엇을 끌지. 비우면 전부"],
            ], []),

            tool("remember",
                 "사용자가 알려준 것을 오래 기억한다. 다음에도 쓸 것만. 오늘 한 끼 같은 한 번뿐인 일은 기억하지 않는다.", [
                "text": ["type": "string", "description": "한 줄. 예 '매운 거 못 먹는다'"],
                "kind": ["type": "string", "enum": ["fact", "taste", "state", "place"],
                         "description": "fact 는 안 변하는 것, taste 는 취향, state 는 지금 상태(석 달 뒤 확인한다), place 는 자주 가는 자리"],
                "here": ["type": "boolean",
                         "description": "place 일 때, 사용자가 지금 서 있는 자리를 그 장소로 삼으면 true"],
            ], ["text", "kind"]),

            tool("forget", "기억한 것을 지운다.", [
                "about": ["type": "string", "description": "무엇에 대한 기억인지"],
            ], ["about"]),

            tool("remind_at_place",
                 "그 자리에 닿으면 알린다. 시각이 아니라 장소로 울리는 미리알림이다. "
                 + "**날짜는 가릴 수 없다** — 그 자리에 닿으면 오늘이든 다음 주든 울린다. "
                 + "‘내일 도착하면’ 처럼 날짜를 약속하지 마라.", [
                "title": ["type": "string"],
                "place": ["type": "string",
                          "description": "방금 find_places 로 찾은 가게 이름. 지금 서 있는 자리면 '여기'"],
                "on_leaving": ["type": "boolean", "description": "떠날 때 울리려면 true. 기본은 닿을 때"],
            ], ["title", "place"]),
        ]
    }

    /// 도구 하나를 사람 말로. **화면에 그대로 나갑니다.**
    ///
    /// "생각하는 중" 하나만 보여주던 자리입니다. 우리는 이미 무엇을 하는지
    /// 아는데 안 보여주고 있었습니다.
    static func label(for tool: String) -> String {
        switch tool {
        case "get_events": "일정 보는 중"
        case "add_event": "일정에 넣는 중"
        case "propose_event_change": "일정 찾는 중"
        case "get_reminders": "할일 보는 중"
        case "add_reminder": "할일 넣는 중"
        case "complete_reminder": "할일 끝내는 중"
        case "find_places": "가게 찾는 중"
        case "get_weather": "날씨 보는 중"
        case "set_timer", "cancel_timer": "알림 맞추는 중"
        case "get_timers": "알림 보는 중"
        case "remind_at_place": "장소 알림 넣는 중"
        case "remember": "기억하는 중"
        case "forget": "기억 지우는 중"
        case "web_search": "웹에서 찾는 중"
        default: "확인하는 중"
        }
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
            // **방금 넣은 것을 또 넣지 않습니다.**
            //
            // "예약하자" 로 오늘 8시 반을 넣고, 24초 뒤 "저녁약속을 내일로" 라고
            // 하자 내일 것을 하나 더 넣었습니다. 옮긴 게 아니라 둘이 됐고
            // 사용자는 옮긴 줄 알았습니다. 말로 막는 자리가 아닙니다.
            if let just = Events.justAdded, Date().timeIntervalSince(just.at) < 600,
               just.start != start, Events.similar(just.title, title) >= 0.45 {
                return "‘\(just.title)’ 을 방금 \(Format.short(just.start)) 에 넣었습니다. "
                    + "같은 약속으로 보여 새로 넣지 않았습니다. "
                    + "옮기려면 propose_event_change 를 써라. "
                    + "정말 다른 일정이면 제목을 분명히 달리해서 다시 불러라."
            }
            let repeats = repeating(input)
            do {
                try Events.addEvent(title: title, start: start, allDay: allDay,
                                    minutes: minutes, place: place,
                                    at: place.isEmpty ? nil : locate(place),
                                    repeats: repeats)
                run.wrote = true
                var said = "넣었습니다: \(Format.short(start)) \(title)"
                if !place.isEmpty { said += " (\(place))" }
                if repeats != nil { said += " · 되풀이" }
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
            return propose(kind, name: name, to: date(input["new_start"]),
                           which: date(input["at"]), into: &run)

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
                let list = found.spots.map {
                    $0.phone.isEmpty ? "\($0.name) \($0.away)" : "\($0.name) \($0.away) \($0.phone)"
                }.joined(separator: "\n")
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

        case "set_timer":
            run.used.insert(.timer)
            guard let minutes = input["minutes"] as? Int else { return "몇 분인지 모르겠습니다." }
            let label = input["label"] as? String ?? ""
            do {
                let said = try await Timers.set(minutes: minutes, label: label)
                run.wrote = true
                return said
            } catch {
                return "알림 권한이 없습니다. 사용자가 앱에서 허용해야 합니다."
            }

        case "get_timers":
            run.used.insert(.timer)
            let all = await Timers.running()
            guard !all.isEmpty else { return "걸어둔 알림이 없습니다." }
            return all.map { item in
                let left = Int(item.fires.timeIntervalSinceNow / 60)
                return "\(item.label) — \(max(0, left))분 남음 (\(Format.time(item.fires)))"
            }.joined(separator: "\n")

        case "cancel_timer":
            run.used.insert(.timer)
            let killed = await Timers.cancel(label: input["label"] as? String ?? "")
            guard !killed.isEmpty else { return "끌 알림이 없습니다." }
            run.wrote = true
            return "껐습니다: " + killed.joined(separator: ", ")

        case "remind_at_place":
            run.used.insert(.reminders)
            guard let title = input["title"] as? String,
                  let place = input["place"] as? String else { return "무엇을 어디서인지 모르겠습니다." }
            let here = isHere(place)
            guard let spot = here ? Places.here() : locate(place) else {
                return here ? "아직 위치를 모릅니다. 누비를 한 번 열면 그때 자리를 기억해 둡니다."
                    : "‘\(place)’ 가 어디인지 모릅니다. find_places 로 찾거나, "
                        + "사용자가 거기 서 있다면 remember 로 그 자리를 먼저 기억해라."
            }
            let leaving = input["on_leaving"] as? Bool ?? false
            do {
                try Events.addPlaceReminder(title, place: here ? "여기" : place,
                                            at: spot, onArrival: !leaving)
                run.wrote = true
                return "넣었습니다: \(place)\(leaving ? "를 떠나면" : "에 닿으면") \(title)"
            } catch {
                return "넣지 못했습니다: \(error.localizedDescription)"
            }

        case "remember":
            run.used.insert(.memory)
            guard let text = input["text"] as? String else { return "무엇을 기억할지 모르겠습니다." }
            let kind = Memory.Kind(rawValue: input["kind"] as? String ?? "") ?? .fact
            // 장소는 좌표가 있어야 값을 합니다. 없으면 이름만 남는 글자입니다.
            var spot: CLLocationCoordinate2D?
            if kind == .place {
                spot = (input["here"] as? Bool ?? false) ? Places.here() : locate(text)
            }
            do {
                try Memory.remember(text, kind: kind, at: spot)
                run.wrote = true
                if kind == .place, spot == nil {
                    return "기억했습니다: \(text). 다만 자리가 어딘지는 모릅니다 — "
                        + "거기 서서 다시 말해주면 좌표까지 기억합니다."
                }
                return "기억했습니다: \(text)"
            } catch {
                return error.localizedDescription
            }

        case "forget":
            run.used.insert(.memory)
            guard let about = input["about"] as? String else { return "무엇을 지울지 모르겠습니다." }
            let gone = Memory.forget(about: about)
            guard !gone.isEmpty else { return "그런 기억이 없습니다." }
            run.wrote = true
            return "지웠습니다: " + gone.map(\.text).joined(separator: ", ")

        default:
            return "모르는 도구입니다."
        }
    }

    /// 이름이 가리키는 자리.
    ///
    /// 방금 찾아준 가게가 먼저이고, 없으면 **오래 기억해둔 자리**입니다 —
    /// 집, 회사, 헬스장. 그래서 "집에 도착하면 알려줘" 가 됩니다.
    private static func locate(_ name: String) -> CLLocationCoordinate2D? {
        Places.coordinate(of: name) ?? Memory.place(named: name)?.coordinate
    }

    private static func isHere(_ name: String) -> Bool {
        ["여기", "현재 위치", "지금 자리", "이 자리", "여기에"].contains(name)
    }

    /// 되풀이 규칙을 읽습니다. 아무것도 없으면 nil — 한 번뿐인 일정입니다.
    private static func repeating(_ input: [String: Any]) -> Events.Repeat? {
        guard let raw = input["repeat"] as? String,
              let every = Events.Repeat.Every(rawValue: raw) else { return nil }
        let names = ["일": 1, "월": 2, "화": 3, "수": 4, "목": 5, "금": 6, "토": 7]
        let days = (input["repeat_days"] as? [String] ?? [])
            .compactMap { names[String($0.prefix(1))] }
        return Events.Repeat(every: every, days: days,
                             times: input["repeat_times"] as? Int ?? 0)
    }

    /// 지우거나 옮길 것을 **적어두기만** 합니다. 사람이 눌러야 실제로 합니다.
    private static func propose(_ kind: Pending.Kind, name: String,
                                to newStart: Date?, which: Date? = nil,
                                into run: inout ToolRun) -> String {
        PendingStore.clear()
        guard let upcoming = try? Events.upcoming(days: 14) else { return "일정을 읽을 수 없습니다." }
        var hits = upcoming.filter { $0.title.contains(name) }
        // **되풀이 일정이 생기면서 같은 이름이 흔해졌습니다.** 시각까지 주면
        // 그걸로 하나를 고릅니다. 1분 안쪽이면 같은 것으로 봅니다.
        if hits.count > 1, let which {
            let exact = hits.filter { abs($0.start.timeIntervalSince(which)) < 60 }
            if !exact.isEmpty { hits = exact }
        }
        guard hits.count == 1, let only = hits.first else {
            return hits.isEmpty ? "‘\(name)’ 일정이 앞으로 2주 안에 없습니다."
                : "여러 개가 걸립니다. at 에 시각을 넣어 하나를 골라라: "
                    + hits.map { "\(Format.short($0.start)) \($0.title)" }.joined(separator: ", ")
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
