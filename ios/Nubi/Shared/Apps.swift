import Foundation

/// 다른 앱 열기.
///
/// **여는 것까지가 한계입니다.** 유튜브뮤직에서 곡을 틀어달라고 하면 앱을 열고
/// 검색 결과까지 데려다줍니다 — 재생 버튼은 사람이 눌러야 합니다. 다른 앱이
/// 재생을 시작하는 길을 유튜브뮤직이 안 열어놨습니다.
///
/// **주소는 https 를 먼저 씁니다.** `youtubemusic://` 같은 앱 전용 주소는 앱이
/// 없으면 **조용히 아무 일도 안 일어납니다.** https 는 앱이 있으면 앱으로,
/// 없으면 사파리로 갑니다 — 어느 쪽이든 사람이 뭐가 일어났는지 압니다.
/// 길찾기에서 배운 것입니다.
enum Apps {
    struct Known {
        let name: String
        /// 사람이 부를 법한 이름들. 띄어쓰기 없이 견줍니다.
        let aliases: [String]
        /// 그냥 열기.
        let home: String
        /// 검색어까지 넣어 열기. 없으면 검색을 못 합니다.
        let search: String?
    }

    static let all: [Known] = [
        .init(name: "유튜브뮤직", aliases: ["유튜브뮤직", "윰", "youtubemusic", "ytmusic"],
              home: "https://music.youtube.com/",
              search: "https://music.youtube.com/search?q="),
        .init(name: "유튜브", aliases: ["유튜브", "youtube"],
              home: "https://www.youtube.com/",
              search: "https://www.youtube.com/results?search_query="),
        .init(name: "애플뮤직", aliases: ["애플뮤직", "applemusic", "뮤직"],
              home: "https://music.apple.com/kr/",
              search: "https://music.apple.com/kr/search?term="),
        .init(name: "스포티파이", aliases: ["스포티파이", "spotify"],
              home: "https://open.spotify.com/",
              search: "https://open.spotify.com/search/"),
        .init(name: "넷플릭스", aliases: ["넷플릭스", "넷플", "netflix"],
              home: "https://www.netflix.com/", search: nil),
        .init(name: "카카오톡", aliases: ["카카오톡", "카톡", "kakaotalk"],
              home: "kakaotalk://", search: nil),
        .init(name: "인스타그램", aliases: ["인스타그램", "인스타", "instagram"],
              home: "https://www.instagram.com/", search: nil),
        .init(name: "네이버", aliases: ["네이버", "naver"],
              home: "https://m.naver.com/",
              search: "https://search.naver.com/search.naver?query="),
        .init(name: "쿠팡", aliases: ["쿠팡", "coupang"],
              home: "https://www.coupang.com/",
              search: "https://www.coupang.com/np/search?q="),
        .init(name: "배달의민족", aliases: ["배달의민족", "배민", "배달"],
              home: "baemin://", search: nil),
        .init(name: "토스", aliases: ["토스", "toss"], home: "supertoss://", search: nil),
        .init(name: "카카오T", aliases: ["카카오t", "카카오택시", "택시"],
              home: "kakaot://", search: nil),
        .init(name: "당근", aliases: ["당근", "당근마켓"], home: "karrot://", search: nil),
        .init(name: "카카오맵", aliases: ["카카오맵", "카카오지도"], home: "kakaomap://", search: nil),
        .init(name: "네이버지도", aliases: ["네이버지도", "네이버맵"], home: "nmap://", search: nil),
        .init(name: "지도", aliases: ["지도", "애플지도", "maps"], home: "maps://", search: nil),
        .init(name: "캘린더", aliases: ["캘린더", "달력"], home: "calshow://", search: nil),
        .init(name: "미리알림", aliases: ["미리알림", "리마인더"], home: "x-apple-reminderkit://", search: nil),
        .init(name: "시계", aliases: ["시계", "알람앱"], home: "clock-alarm://", search: nil),
        .init(name: "설정", aliases: ["설정", "세팅"], home: "App-prefs://", search: nil),
    ]

    static func find(_ said: String) -> Known? {
        let wanted = said.replacingOccurrences(of: " ", with: "").lowercased()
        guard !wanted.isEmpty else { return nil }
        // 정확히 맞는 것을 먼저. "지도" 가 "네이버지도" 를 집으면 안 됩니다.
        if let exact = all.first(where: { $0.aliases.contains(wanted) }) { return exact }
        return all.first { app in app.aliases.contains { wanted.contains($0) } }
    }

    /// 열 주소. 검색어가 있고 그 앱이 검색을 받으면 검색으로 갑니다.
    static func url(_ app: Known, query: String) -> URL? {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, let search = app.search else { return URL(string: app.home) }
        let escaped = wanted.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? wanted
        return URL(string: search + escaped)
    }

    /// 목록을 모델에게 한 줄로. **없는 앱을 열겠다고 말하지 않게** 하려면
    /// 무엇이 있는지 알아야 합니다.
    static var names: String { all.map(\.name).joined(separator: ", ") }
}
