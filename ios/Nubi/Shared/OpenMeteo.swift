import CoreLocation
import Foundation

/// 키가 없는 날씨.
///
/// **WeatherKit 이 며칠째 `error 2` 입니다.** 앱 ID 에 WEATHERKIT 이 등록돼
/// 있고, ipa 에 권한이 들어 있고, 프로파일에도 있습니다. 스크립트로 볼 수 있는
/// 것은 다 맞습니다. 남은 것은 동의 대기 중인 계약인데 그건 웹에서만 됩니다.
///
/// 날씨는 기능이 하나 빠진 게 아니라 **약속이 깨진 자리**입니다. 아침 브리핑도
/// 모델에게 주는 맥락도 같이 죽습니다. 남의 승인을 기다릴 일이 아닙니다.
///
/// Open-Meteo 는 가입도 키도 없고 한국은 기상청 모델을 섞어 씁니다.
/// 기상청 API 를 직접 쓰지 않은 이유는 **키를 또 받아야 하고** 격자 좌표로
/// 바꿔야 해서입니다 — 지금 필요한 것은 오늘 되는 것입니다.
enum OpenMeteo {
    static func now(at spot: CLLocationCoordinate2D) async throws -> Weather.Snapshot {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            .init(name: "latitude", value: String(spot.latitude)),
            .init(name: "longitude", value: String(spot.longitude)),
            .init(name: "current", value: "temperature_2m,weather_code"),
            .init(name: "hourly", value: "precipitation_probability"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            // 시각을 초로 받습니다. 지역 시간 문자열을 파싱하다 어긋날 자리를 없앱니다.
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "2"),
        ]
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 8

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any],
              let celsius = current["temperature_2m"] as? Double
        else {
            NubiLog.write("[날씨] Open-Meteo HTTP \(code)")
            throw Weather.Failure.notReady
        }

        let daily = root["daily"] as? [String: Any]
        let highs = daily?["temperature_2m_max"] as? [Double]
        let lows = daily?["temperature_2m_min"] as? [Double]

        return Weather.Snapshot(
            celsius: Int(celsius.rounded()),
            condition: describe(current["weather_code"] as? Int ?? 0),
            wetFrom: wetFrom(root["hourly"] as? [String: Any]),
            highest: highs?.first.map { Int($0.rounded()) },
            lowest: lows?.first.map { Int($0.rounded()) })
    }

    /// 앞으로 12시간 안에 비가 올 것 같은 가장 이른 시각.
    private static func wetFrom(_ hourly: [String: Any]?) -> Date? {
        // **비어 있는 시각이 섞여 옵니다.** 통째로 [Int] 로 받으려 하면 그 하나
        // 때문에 변환이 실패하고 비 소식이 조용히 사라집니다.
        guard let times = hourly?["time"] as? [Any],
              let chances = hourly?["precipitation_probability"] as? [Any]
        else { return nil }
        let until = Date().addingTimeInterval(12 * 3600)
        for (index, raw) in times.enumerated() {
            guard let seconds = raw as? Double else { continue }
            let when = Date(timeIntervalSince1970: seconds)
            guard when > Date(), when < until else { continue }
            guard let chance = chances[safe: index] as? Int else { continue }
            if chance >= 50 { return when }
        }
        return nil
    }

    /// WMO 날씨 코드. 화면에 그대로 나가므로 사람 말로 적습니다.
    private static func describe(_ code: Int) -> String {
        switch code {
        case 0: "맑음"
        case 1: "대체로 맑음"
        case 2: "구름 조금"
        case 3: "흐림"
        case 45, 48: "안개"
        case 51, 53, 55: "이슬비"
        case 56, 57: "어는 이슬비"
        case 61: "약한 비"
        case 63: "비"
        case 65: "강한 비"
        case 66, 67: "어는 비"
        case 71: "약한 눈"
        case 73: "눈"
        case 75: "강한 눈"
        case 77: "싸락눈"
        case 80, 81: "소나기"
        case 82: "강한 소나기"
        case 85, 86: "소나기눈"
        case 95: "뇌우"
        case 96, 99: "우박 섞인 뇌우"
        default: "알 수 없음"
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
