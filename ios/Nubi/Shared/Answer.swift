import Foundation

/// 한 번의 요청이 낳는 것. 화면에도, Live Activity 에도 이 모양으로 갑니다.
struct NubiAnswer: Equatable {
    /// 한 줄. 잠금화면에 들어가야 하므로 짧습니다.
    let headline: String
    /// 펼쳤을 때 보이는 것. 없을 수도 있습니다.
    let detail: String
    /// 실패도 답입니다. 무엇이 없는지 말하고 죽지 않는 것이 완료 조건입니다.
    let failed: Bool

    init(headline: String, detail: String = "", failed: Bool = false) {
        self.headline = headline
        self.detail = detail
        self.failed = failed
    }
}

/// 일정 목록을 사람이 읽는 줄로.
///
/// **모델을 부르지 않습니다.** 일정 세 건을 읽어주는 데 왕복 1 초를 쓸 이유가
/// 없고, 키가 없어도 이 기능은 돌아야 합니다.
enum Format {
    static func events(_ items: [Events.Item], label: String) -> NubiAnswer {
        guard !items.isEmpty else {
            return NubiAnswer(headline: "\(label) 일정이 없습니다")
        }
        let lines = items.map { item in
            item.allDay ? "· \(item.title) (종일)" : "· \(time(item.start)) \(item.title)"
        }
        // 하나뿐이면 제목이 곧 전부입니다. 상세에 같은 줄을 또 두면 잠금화면에서
        // 같은 말이 두 번 보입니다.
        guard items.count > 1 else {
            return NubiAnswer(headline: "\(label) \(lines[0].dropFirst(2))")
        }
        return NubiAnswer(headline: "\(label) 일정 \(items.count)건",
                          detail: lines.joined(separator: "\n"))
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "a h:mm"
        return f.string(from: date)
    }
}
