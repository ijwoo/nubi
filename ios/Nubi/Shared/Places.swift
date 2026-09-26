import CoreLocation
import Foundation
import MapKit

/// 가까운 곳 찾기.
///
/// **모델도 웹 검색도 거치지 않습니다.** 애플 지도에 바로 묻습니다. 일정·미리알림과
/// 같은 성격이라 빠르고 값이 붙지 않습니다.
///
/// 위치는 앱이 앞에 있을 때만 새로 잡습니다. 잠금화면 버튼은 확장에서 도는데
/// 거기서는 위치를 물을 수 없으므로 **앱이 마지막으로 알던 자리**를 씁니다.
enum Places {
    struct Spot: Hashable {
        let name: String
        let distance: CLLocationDistance
        let coordinate: CLLocationCoordinate2D

        static func == (a: Spot, b: Spot) -> Bool { a.name == b.name && a.distance == b.distance }
        func hash(into hasher: inout Hasher) { hasher.combine(name); hasher.combine(distance) }

        var away: String {
            distance < 1000 ? "\(Int(distance))m" : String(format: "%.1fkm", distance / 1000)
        }

        /// 걸어가는 길. 잠금화면 버튼과 앱이 같이 씁니다.
        var directions: URL? {
            URL(string: "maps://?daddr=\(coordinate.latitude),\(coordinate.longitude)&dirflg=w")
        }
    }

    enum Failure: Error, LocalizedError {
        case noLocation
        case nothingFound(String)

        var errorDescription: String? {
            switch self {
            case .noLocation: "지금 어디인지 모릅니다. 누비를 한 번 열어 위치를 허용해 주세요."
            case let .nothingFound(what): "근처에서 \(what)을 찾지 못했습니다."
            }
        }
    }

    // MARK: 위치

    private static let latKey = "place.lat"
    private static let lonKey = "place.lon"
    private static var store: UserDefaults? { UserDefaults(suiteName: NubiLog.group) }

    static var lastKnown: CLLocationCoordinate2D? {
        guard let store, store.object(forKey: latKey) != nil else { return nil }
        return CLLocationCoordinate2D(latitude: store.double(forKey: latKey),
                                      longitude: store.double(forKey: lonKey))
    }

    static var isAllowed: Bool {
        let status = CLLocationManager().authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    /// 앱 안에서 도는가. 확장에서는 위치를 물을 수 없습니다.
    static var inApp: Bool { Bundle.main.bundleURL.pathExtension != "appex" }

    /// 앱에서만 부릅니다.
    ///
    /// **허용 여부를 먼저 따지지 않습니다.** 아직 안 물어본 상태에서 막으면
    /// 묻는 데까지 가질 못합니다 — 권한 대화상자가 안 뜨던 이유였습니다.
    static func refreshLocation() async {
        guard inApp, let here = await Locator.shared.current() else { return }
        store?.set(here.coordinate.latitude, forKey: latKey)
        store?.set(here.coordinate.longitude, forKey: lonKey)
        NubiLog.write("[위치] 갱신")
    }

    // MARK: 찾기

    static func find(_ query: String, limit: Int = 4) async throws -> [Spot] {
        // 앱 안이면 지금 자리를 잡아봅니다. 처음 묻는 사람은 여기서 허용을 봅니다.
        if lastKnown == nil, inApp { await refreshLocation() }
        guard let origin = lastKnown else { throw Failure.noLocation }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        // 2km 안에서만 봅니다. "근처" 라고 물었는데 지하철로 갈 거리를 주면 안 됩니다.
        request.region = MKCoordinateRegion(center: origin, latitudinalMeters: 2000,
                                            longitudinalMeters: 2000)
        let response = try await MKLocalSearch(request: request).start()
        let from = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let spots = response.mapItems.compactMap { item -> Spot? in
            guard let name = item.name, let place = item.placemark.location else { return nil }
            return Spot(name: name, distance: from.distance(from: place),
                        coordinate: place.coordinate)
        }
        .sorted { $0.distance < $1.distance }
        guard !spots.isEmpty else { throw Failure.nothingFound(query) }
        return Array(spots.prefix(limit))
    }
}

/// 한 번만 물어보는 위치.
///
/// `CLLocationManager` 는 대리자로만 답합니다. **허용을 묻는 것과 자리를 잡는 것이
/// 따로**라 둘 다 기다려야 합니다. 물어만 보고 바로 상태를 읽으면 아직
/// `notDetermined` 여서 빈손으로 돌아옵니다.
private final class Locator: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    static let shared = Locator()

    private let manager = CLLocationManager()
    private var askingPermission: CheckedContinuation<Bool, Never>?
    private var waitingForFix: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func current() async -> CLLocation? {
        switch manager.authorizationStatus {
        case .notDetermined:
            guard await requestPermission() else { return nil }
        case .authorizedWhenInUse, .authorizedAlways:
            break
        default:
            return nil
        }
        return await requestFix()
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            askingPermission = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    private func requestFix() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            waitingForFix = continuation
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        askingPermission?.resume(returning: Places.isAllowed)
        askingPermission = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NubiLog.write("[위치] 실패 \(error.localizedDescription)")
        finish(nil)
    }

    private func finish(_ location: CLLocation?) {
        waitingForFix?.resume(returning: location)
        waitingForFix = nil
    }
}
