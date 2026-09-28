import CoreLocation
import Foundation
import WeatherKit

/// `Weather` 라는 이름을 우리가 먼저 썼습니다. WeatherKit 의 것은 이렇게 부릅니다.
private typealias SwiftWeather = WeatherKit.Weather

/// 날씨.
///
/// **모델을 거치지 않습니다.** 애플 날씨에 바로 묻습니다 — 일정·미리알림·지도와
/// 같은 성격이라 빠르고 값이 붙지 않습니다. 모델에게 날씨를 물으면 외워둔 것으로
/// 답해서 틀립니다.
///
/// 잠금화면 확장에서도 돕니다. 위치는 [Places](Places.swift) 가 든 마지막 자리를
/// 씁니다 — 확장은 좌표를 새로 못 잡습니다.
enum Weather {
    struct Snapshot: Codable, Hashable {
        var celsius: Int
        var condition: String
        /// 비나 눈이 올 것 같은 가장 이른 시각. 없으면 없습니다.
        var wetFrom: Date?
        var highest: Int?
        var lowest: Int?

        /// 한 줄. "22° 흐림 · 19시부터 비"
        var line: String {
            var parts = ["\(celsius)° \(condition)"]
            if let wetFrom {
                let f = DateFormatter()
                f.locale = Locale(identifier: "ko_KR")
                f.dateFormat = "H시"
                parts.append("\(f.string(from: wetFrom))부터 비")
            }
            return parts.joined(separator: " · ")
        }
    }

    enum Failure: Error, LocalizedError {
        case noLocation
        case notReady

        var errorDescription: String? {
            switch self {
            case .noLocation:
                "지금 어디인지 몰라 날씨를 못 봅니다. 누비를 한 번 열면 자리를 기억해 둡니다."
            case .notReady:
                "날씨 서비스가 아직 안 열렸습니다. 권한을 켠 지 얼마 안 됐다면 30분쯤 뒤에 됩니다."
            }
        }
    }

    private static let cacheKey = "weather.now"
    private static let stampKey = "weather.at"
    /// 실패한 시각. **실패해도 매번 다시 두드리면 답이 느려지기만 합니다.**
    private static let failedKey = "weather.failed"
    private static var store: UserDefaults? { UserDefaults(suiteName: NubiLog.group) }

    /// 지금 날씨.
    ///
    /// 20분 안에 본 것이 있으면 그것을 씁니다. 잠금화면에서 누를 때마다 새로
    /// 받아오면 느리고, 20분 사이에 날씨가 바뀌지도 않습니다.
    static func now(fresh: Bool = false) async throws -> Snapshot {
        if !fresh, let cached = cached() { return cached }
        guard let here = Places.here() else { throw Failure.noLocation }
        let location = CLLocation(latitude: here.latitude, longitude: here.longitude)

        let weather: SwiftWeather
        do {
            weather = try await WeatherService.shared.weather(for: location)
        } catch {
            // 날 것의 오류를 그대로 보여주면 읽을 수 없습니다. 흔한 것은
            // 권한을 켠 직후의 전파 지연이고, 30분쯤 뒤에 됩니다.
            NubiLog.write("[날씨] 실패 \(error.localizedDescription)")
            store?.set(Date(), forKey: failedKey)
            throw Failure.notReady
        }

        let current = weather.currentWeather
        let soon = weather.hourlyForecast.forecast
            .filter { $0.date > Date() && $0.date < Date().addingTimeInterval(12 * 3600) }
        let wet = soon.first { $0.precipitationChance >= 0.5 }?.date
        let today = weather.dailyForecast.forecast.first

        let snapshot = Snapshot(
            celsius: Int(current.temperature.converted(to: .celsius).value.rounded()),
            condition: current.condition.description,
            wetFrom: wet,
            highest: today.map { Int($0.highTemperature.converted(to: .celsius).value.rounded()) },
            lowest: today.map { Int($0.lowTemperature.converted(to: .celsius).value.rounded()) })
        remember(snapshot)
        return snapshot
    }

    /// 실패해도 조용히 넘어가는 쪽. 브리핑과 모델 맥락에 씁니다.
    ///
    /// **최근에 실패했으면 아예 두드리지 않습니다.** 날씨가 안 되는 동안 모든
    /// 자유 질문이 그만큼 느려질 이유가 없습니다.
    static func quiet() async -> Snapshot? {
        if let cached = cached() { return cached }
        if let failed = store?.object(forKey: failedKey) as? Date,
           Date().timeIntervalSince(failed) < 600 { return nil }
        return try? await now()
    }

    private static func cached() -> Snapshot? {
        guard let at = store?.object(forKey: stampKey) as? Date,
              Date().timeIntervalSince(at) < 1200,
              let data = store?.data(forKey: cacheKey)
        else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private static func remember(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        store?.set(data, forKey: cacheKey)
        store?.set(Date(), forKey: stampKey)
        store?.removeObject(forKey: failedKey)
    }
}
