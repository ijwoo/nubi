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
        /// 내일. 아침 브리핑은 전날 밤에 미리 쓰므로 하루 앞을 알아야 합니다.
        var nextSky: String?
        var nextHigh: Int?
        var nextLow: Int?

        /// 내일 한 줄. 모르면 빈 문자열입니다.
        var nextLine: String {
            guard let nextSky else { return "" }
            guard let nextHigh, let nextLow else { return nextSky }
            return "\(nextSky) \(nextLow)°/\(nextHigh)°"
        }

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
                "날씨를 못 받았습니다. 잠시 뒤에 다시 물어봐 주세요."
            }
        }
    }

    private static let cacheKey = "weather.now"
    private static let stampKey = "weather.at"
    /// 실패한 시각. **실패해도 매번 다시 두드리면 답이 느려지기만 합니다.**
    private static let failedKey = "weather.failed"
    /// 애플 날씨가 마지막으로 거절한 시각과 연달아 거절한 횟수.
    private static let appleFailedKey = "weather.apple.failed"
    private static let appleMissesKey = "weather.apple.misses"
    /// 몇 번 연달아 거절당하면 물러날까.
    private static let patience = 3
    private static var store: UserDefaults? { UserDefaults(suiteName: NubiLog.group) }

    /// 애플에 물어볼 만한가.
    ///
    /// **한 번 튕겼다고 물러나지 않습니다.** 애플 날씨가 멀쩡한데 일시적으로
    /// 한 번 거절당하면, 더 정확한 쪽을 하루 동안 안 쓰게 됩니다.
    ///
    /// 세 번 연달아 거절당하면 그때는 성질이 다릅니다 — `error 2` 는 계약이나
    /// 서비스 등록 문제라 몇 분 뒤에 풀리지 않습니다. 그때 하루 물러납니다.
    /// 하루 뒤에는 다시 봅니다. 계약이 풀렸을 수도 있습니다.
    private static var askApple: Bool {
        guard (store?.integer(forKey: appleMissesKey) ?? 0) >= patience,
              let failed = store?.object(forKey: appleFailedKey) as? Date
        else { return true }
        return Date().timeIntervalSince(failed) > 24 * 3600
    }

    private static func appleMissed() {
        let misses = (store?.integer(forKey: appleMissesKey) ?? 0) + 1
        store?.set(misses, forKey: appleMissesKey)
        store?.set(Date(), forKey: appleFailedKey)
        if misses == patience { NubiLog.write("[날씨] 애플을 하루 쉽니다") }
    }

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
            guard askApple else { throw Failure.notReady }
            weather = try await WeatherService.shared.weather(for: location)
        } catch {
            if askApple {
                NubiLog.write("[날씨] 애플 실패 \(error.localizedDescription)")
                appleMissed()
            }
            // **막다른 길로 두지 않습니다.** 키 없이 되는 곳이 있습니다.
            do {
                let snapshot = try await OpenMeteo.now(at: here)
                remember(snapshot)
                return snapshot
            } catch {
                store?.set(Date(), forKey: failedKey)
                throw Failure.notReady
            }
        }

        // 애플이 답했으면 셈을 지웁니다. 연달아 거절당한 것만 셉니다.
        store?.removeObject(forKey: appleMissesKey)

        let current = weather.currentWeather
        let soon = weather.hourlyForecast.forecast
            .filter { $0.date > Date() && $0.date < Date().addingTimeInterval(12 * 3600) }
        let wet = soon.first { $0.precipitationChance >= 0.5 }?.date
        let days = weather.dailyForecast.forecast
        let today = days.first
        let next = days.dropFirst().first

        let snapshot = Snapshot(
            celsius: Int(current.temperature.converted(to: .celsius).value.rounded()),
            condition: current.condition.description,
            wetFrom: wet,
            highest: today.map { Int($0.highTemperature.converted(to: .celsius).value.rounded()) },
            lowest: today.map { Int($0.lowTemperature.converted(to: .celsius).value.rounded()) },
            nextSky: next?.condition.description,
            nextHigh: next.map { Int($0.highTemperature.converted(to: .celsius).value.rounded()) },
            nextLow: next.map { Int($0.lowTemperature.converted(to: .celsius).value.rounded()) })
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
