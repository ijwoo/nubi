import CoreLocation
import Foundation

/// 카카오 로컬 검색.
///
/// **애플 지도는 한국 가게에 약합니다.** "회" 로 8982km 떨어진 곳을 돌려준 적이
/// 있고, "횟집" 이라고 바꿔도 잘 안 잡혔습니다.
///
/// 네이버 지역검색은 쓰지 않았습니다 — **좌표 기준 정렬이 없습니다.** 검색어만
/// 받아서 "근처" 를 못 합니다. 카카오는 좌표·반경·거리순을 다 받습니다.
///
/// 키가 없으면 애플 지도로 돌아갑니다. 키는 저장소에 들어가지 않습니다.
enum Kakao {
    static var isReady: Bool { Secrets.kakaoKey != nil }

    static func search(_ query: String, near origin: CLLocationCoordinate2D,
                       radius: Int, limit: Int) async throws -> [Places.Spot] {
        guard let key = Secrets.kakaoKey else { return [] }
        var parts = URLComponents(string: "https://dapi.kakao.com/v2/local/search/keyword.json")!
        parts.queryItems = [
            .init(name: "query", value: query),
            .init(name: "x", value: String(origin.longitude)),
            .init(name: "y", value: String(origin.latitude)),
            // 카카오는 2만 미터까지 받습니다.
            .init(name: "radius", value: String(min(radius, 20000))),
            .init(name: "sort", value: "distance"),
            .init(name: "size", value: String(min(limit, 15))),
        ]
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 8
        request.setValue("KakaoAK \(key)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            NubiLog.write("[카카오] HTTP \(code)")
            throw Places.Failure.nothingFound(query)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let documents = root["documents"] as? [[String: Any]]
        else { return [] }

        return documents.compactMap { doc in
            guard let name = doc["place_name"] as? String,
                  let x = Double(doc["x"] as? String ?? ""),
                  let y = Double(doc["y"] as? String ?? "")
            else { return nil }
            let away = Double(doc["distance"] as? String ?? "") ?? 0
            return Places.Spot(name: name, distance: away,
                               coordinate: CLLocationCoordinate2D(latitude: y, longitude: x))
        }
    }
}

/// 길찾기를 어느 앱으로 열까.
enum MapApp: String, CaseIterable, Identifiable {
    case kakao, naver, apple

    var id: String { rawValue }
    var label: String {
        switch self {
        case .kakao: "카카오맵"
        case .naver: "네이버지도"
        case .apple: "애플 지도"
        }
    }

    private static let key = "map.app"
    private static var store: UserDefaults? { UserDefaults(suiteName: NubiLog.group) }

    /// 카카오 키를 넣었으면 카카오맵이 기본입니다. 찾은 곳과 여는 곳이 같은
    /// 편이 덜 헷갈립니다.
    static var chosen: MapApp {
        get {
            if let saved = store?.string(forKey: key), let app = MapApp(rawValue: saved) { return app }
            return Kakao.isReady ? .kakao : .apple
        }
        set { store?.set(newValue.rawValue, forKey: key) }
    }

    /// 걸어가는 길. 앱이 없으면 아무 일도 안 일어나므로 웹 주소로 떨어집니다.
    func directions(to spot: Places.Spot) -> URL? {
        let lat = spot.coordinate.latitude, lon = spot.coordinate.longitude
        let name = spot.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        switch self {
        case .kakao:
            return URL(string: "kakaomap://route?ep=\(lat),\(lon)&by=FOOT")
        case .naver:
            return URL(string: "nmap://route/walk?dlat=\(lat)&dlng=\(lon)&dname=\(name)&appname=dev.jaewoo.nubi")
        case .apple:
            return URL(string: "maps://?daddr=\(lat),\(lon)&dirflg=w")
        }
    }
}
