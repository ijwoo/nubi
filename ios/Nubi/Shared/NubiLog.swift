import Foundation

/// 앱과 확장이 같은 App Group 파일에 남기는 기록.
///
/// TestFlight 로 받으면 Xcode 콘솔이 없습니다. 확장에서 일어난 일은 확장 안에서만
/// 알 수 있고, 잠금 상태에서는 화면에 띄울 수도 없습니다.
/// [스파이크](../../docs/benchmarks/2026-09-24-lockscreen-spike.md)에서 이 통로가
/// 유일한 출구였고, 여기서도 그렇습니다.
enum NubiLog {
    static let group = "group.dev.jaewoo.nubi"
    /// 무한히 자라면 읽을 수 없습니다. 최근 것만 남깁니다.
    private static let keepLines = 300

    private static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("nubi.log")
    }

    static func write(_ line: String) {
        guard let url else { return }
        let stamped = "\(Self.stamp(Date()))  \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(stamped.utf8))
        } else {
            try? Data(stamped.utf8).write(to: url)
        }
        trim()
    }

    static func read() -> String {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "(아직 기록 없음)"
        }
        return text
    }

    static func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func trim() {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > keepLines else { return }
        let kept = lines.suffix(keepLines).joined(separator: "\n")
        try? Data(kept.utf8).write(to: url)
    }

    /// 로컬 시각으로 남깁니다. 스파이크는 UTC 로 남겼는데, 폰 화면의 시계와
    /// 대조하려면 매번 9시간을 빼야 했습니다.
    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}
