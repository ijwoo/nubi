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
        /// 가게 번호. 카카오가 줍니다. 애플 지도 쪽은 비어 있습니다.
        var phone: String = ""

        static func == (a: Spot, b: Spot) -> Bool { a.name == b.name && a.distance == b.distance }
        func hash(into hasher: inout Hasher) { hasher.combine(name); hasher.combine(distance) }

        var away: String {
            distance < 1000 ? "\(Int(distance))m" : String(format: "%.1fkm", distance / 1000)
        }

        /// 걸어가는 길. 어느 지도 앱으로 열지는 설정이 정합니다.
        var directions: URL? { MapApp.chosen.directions(to: self) }

        /// 거는 주소. **예약은 못 해도 전화는 넘길 수 있습니다.**
        var call: URL? {
            let digits = phone.filter { $0.isNumber || $0 == "+" }
            return digits.count >= 7 ? URL(string: "tel:\(digits)") : nil
        }
    }

    enum Failure: Error, LocalizedError, Equatable {
        case noLocation
        case nothingFound(String)

        var errorDescription: String? {
            switch self {
            case .noLocation: "아직 위치를 모릅니다. 누비를 한 번 열면 그때 자리를 기억해 둡니다."
            case let .nothingFound(what): "근처에서 \(what)을 찾지 못했습니다."
            }
        }
    }

    // MARK: 위치

    private static let queryKey = "place.query"
    private static let latKey = "place.lat"
    private static let lonKey = "place.lon"
    private static var store: UserDefaults? { UserDefaults(suiteName: NubiLog.group) }

    /// 마지막으로 찾던 것. "다른 데 더" 가 무엇을 더 찾는지 알려면 필요합니다.
    static var lastQuery: String {
        get { store?.string(forKey: queryKey) ?? "" }
        set { store?.set(newValue, forKey: queryKey) }
    }

    private static let spotsKey = "place.spots"

    /// 방금 찾아준 곳들을 좌표째 적어둡니다.
    ///
    /// 그 다음 말이 "거기로 일정 잡아줘" 인 경우가 많습니다. 이름만 가지고
    /// 일정을 넣으면 글자일 뿐이지만, **좌표가 붙으면 아이폰이 출발 시각을
    /// 알려줍니다.** 그래서 찾아준 순간에 붙잡아 둡니다.
    static func remember(found spots: [Spot]) {
        let rows: [[String: Any]] = spots.map {
            ["name": $0.name, "lat": $0.coordinate.latitude,
             "lon": $0.coordinate.longitude, "phone": $0.phone]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return }
        store?.set(data, forKey: spotsKey)
    }

    static var remembered: [Spot] {
        guard let data = store?.data(forKey: spotsKey),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let name = row["name"] as? String,
                  let lat = row["lat"] as? Double, let lon = row["lon"] as? Double
            else { return nil }
            return Spot(name: name, distance: 0,
                        coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                        phone: row["phone"] as? String ?? "")
        }
    }

    /// 이름으로 되찾습니다. 모델이 이름을 조금 줄여 부르는 일이 있어 양쪽 다
    /// 포함으로 봅니다.
    static func spot(named name: String) -> Spot? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        guard wanted.count >= 2 else { return nil }
        return remembered.first {
            $0.name == wanted || $0.name.contains(wanted) || wanted.contains($0.name)
        }
    }

    static func coordinate(of name: String) -> CLLocationCoordinate2D? {
        spot(named: name)?.coordinate
    }

    /// 이 글 안에 방금 찾아준 가게 이름이 있는가.
    ///
    /// **모델이 고른 곳과 버튼이 가리키는 곳이 달랐습니다.** 버튼은 늘 첫 번째
    /// 결과를 가리켰는데, 모델은 두 번째를 권한 적이 있습니다 — 샤브향을
    /// 권해놓고 길찾기는 해안선으로 갔습니다. 답에서 이름을 찾아 맞춥니다.
    static func mentioned(in text: String) -> Spot? {
        remembered.first { !$0.name.isEmpty && text.contains($0.name) }
    }

    static var lastKnown: CLLocationCoordinate2D? {
        guard let store, store.object(forKey: latKey) != nil else { return nil }
        return CLLocationCoordinate2D(latitude: store.double(forKey: latKey),
                                      longitude: store.double(forKey: lonKey))
    }

    static var isAllowed: Bool {
        let status = CLLocationManager().authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    /// 지금 자리.
    ///
    /// **시스템이 이미 들고 있는 마지막 좌표를 먼저 봅니다.** 이건 배경에서도
    /// 곧바로 읽힙니다. 새로 잡으려 하면 잠금 상태에서는 8초를 기다리다 빈손으로
    /// 돌아옵니다 — `근처 헬스장` 이 8347ms 만에 실패하던 이유였습니다.
    /// 좌표가 쓸 만한가. (0, 0) 은 바다 한가운데이고 자리를 모른다는 뜻입니다.
    private static func usable(_ c: CLLocationCoordinate2D) -> Bool {
        CLLocationCoordinate2DIsValid(c) && !(abs(c.latitude) < 0.001 && abs(c.longitude) < 0.001)
    }

    static func here() -> CLLocationCoordinate2D? {
        if isAllowed, let known = CLLocationManager().location, usable(known.coordinate) {
            remember(known.coordinate)
            return known.coordinate
        }
        return lastKnown.flatMap { usable($0) ? $0 : nil }
    }

    private static func remember(_ coordinate: CLLocationCoordinate2D) {
        store?.set(coordinate.latitude, forKey: latKey)
        store?.set(coordinate.longitude, forKey: lonKey)
    }

    /// 앱 안에서 도는가. 확장에서는 위치를 물을 수 없습니다.
    static var inApp: Bool { Bundle.main.bundleURL.pathExtension != "appex" }

    /// 앱이 지금 앞에 있는가.
    ///
    /// **앞에 없을 때 권한을 물으면 대화상자가 뜰 수 없고 답도 영영 오지 않습니다.**
    /// 잠금화면에서 "근처 헬스장" 을 물었을 때 대화창이 "찾는 중" 에서 멈춘
    /// 이유였습니다. 확장은 이 값을 세우지 않으므로 늘 거짓입니다.
    nonisolated(unsafe) static var foreground = false

    /// 앱에서만 부릅니다.
    ///
    /// **허용 여부를 먼저 따지지 않습니다.** 아직 안 물어본 상태에서 막으면
    /// 묻는 데까지 가질 못합니다 — 권한 대화상자가 안 뜨던 이유였습니다.
    static func refreshLocation() async {
        guard inApp, let fix = await Locator.shared.current(mayAsk: foreground) else { return }
        remember(fix.coordinate)
        NubiLog.write("[위치] 갱신")
    }

    // MARK: 찾기

    /// 가까운 데 없으면 한 번 더 넓혀 봅니다. **없다고만 하면 쓸모가 없습니다.**
    static func findWidening(_ query: String, limit: Int = 4) async throws -> (spots: [Spot], wide: Bool) {
        do {
            return (try await find(query, limit: limit), false)
        } catch Failure.nothingFound {
            return (try await find(query, limit: limit, radius: 15000), true)
        }
    }

    static func find(_ query: String, limit: Int = 4, radius: CLLocationDistance = 5000) async throws -> [Spot] {
        // 앞에 있을 때만 새로 잡아봅니다. 처음 묻는 사람은 여기서 허용을 봅니다.
        if here() == nil, inApp, foreground { await refreshLocation() }
        guard let origin = here() else { throw Failure.noLocation }
        // 카카오 키가 있으면 그쪽이 먼저입니다. 한국 가게는 애플보다 훨씬 잘 잡습니다.
        if Kakao.isReady {
            let spots = try await Kakao.search(query, near: origin, radius: Int(radius), limit: limit)
            guard !spots.isEmpty else { throw Failure.nothingFound(query) }
            remember(found: spots)
            return spots
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        // 2km 안에서만 봅니다. "근처" 라고 물었는데 지하철로 갈 거리를 주면 안 됩니다.
        request.region = MKCoordinateRegion(center: origin, latitudinalMeters: radius,
                                            longitudinalMeters: radius)
        let response = try await MKLocalSearch(request: request).start()
        let from = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let spots = response.mapItems.compactMap { item -> Spot? in
            guard let name = item.name, let place = item.placemark.location else { return nil }
            return Spot(name: name, distance: from.distance(from: place),
                        coordinate: place.coordinate)
        }
        .sorted { $0.distance < $1.distance }
        // **지도는 반경을 힌트로만 받습니다.** 근처에 없으면 멀리 있는 것을
        // 돌려줍니다 — "근처 카페" 에 8982km 떨어진 곳이 나온 적이 있습니다.
        // 근처라고 물었으면 근처가 아닌 것은 답이 아닙니다.
        let near = Array(spots.filter { $0.distance < radius }.prefix(limit))
        guard !near.isEmpty else { throw Failure.nothingFound(query) }
        remember(found: near)
        return near
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

    func current(mayAsk: Bool) async -> CLLocation? {
        switch manager.authorizationStatus {
        case .notDetermined:
            // 앞에 없으면 묻지 않습니다. 물어봐야 답이 오지 않습니다.
            guard mayAsk, await requestPermission() else { return nil }
        case .authorizedWhenInUse, .authorizedAlways:
            break
        default:
            return nil
        }
        return await requestFix()
    }

    /// 기다리는 모든 자리에 시한을 둡니다.
    ///
    /// 대리자가 끝내 답하지 않는 경우가 있습니다. 그러면 대화창이 "찾는 중" 에서
    /// 영영 멈춥니다. **답이 없는 것도 답으로 만들어야 합니다.**
    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            askingPermission = continuation
            manager.requestWhenInUseAuthorization()
            arm(seconds: 20) { [weak self] in
                self?.askingPermission?.resume(returning: Places.isAllowed)
                self?.askingPermission = nil
            }
        }
    }

    private func requestFix() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            waitingForFix = continuation
            manager.requestLocation()
            arm(seconds: 8) { [weak self] in self?.finish(nil) }
        }
    }

    private func arm(seconds: Double, _ giveUp: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            giveUp()
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
