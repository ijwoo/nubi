import Foundation

/// 관찰 기록. 앱과 확장이 같은 App Group 파일에 줄 단위로 덧붙인다.
///
/// 확장이 무엇을 할 수 있었는지는 확장 안에서만 알 수 있고, 잠금 상태에서는
/// 화면에 띄울 수도 없다. 그래서 파일에 남기고 나중에 앱에서 읽는다.
enum SpikeLog {
    static let group = "group.dev.jaewoo.nubispike"

    private static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("spike.log")
    }

    static func write(_ line: String) {
        guard let url else { return }
        let stamped = "\(ISO8601DateFormatter().string(from: Date()))  \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
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

    /// 앱이 포그라운드로 올라왔는지 확인하기 위한 표시.
    ///
    /// 확장에서 무언가를 한 뒤 앱이 깨어났다면, 앱의 `onAppear` 가 이 줄을 남긴다.
    /// 그 줄이 버튼 기록 바로 뒤에 붙는지가 "앱을 깨우지 않고 처리되는가" 의 답이다.
    static func noteForeground() {
        write("앱이 포그라운드로 올라옴")
    }
}
