import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 사진 하나.
///
/// **대화에 통째로 넣지 않습니다.** 대화 기록은 App Group 의 JSON 하나이고
/// 거기에 사진을 담으면 백 턴이 수십 메가가 됩니다. 파일로 따로 두고 이름만
/// 들고 다닙니다.
///
/// **보내기 전에 줄입니다.** 긴 변 1568픽셀이면 모델이 보는 데 충분하고, 그
/// 위로는 값만 더 나갑니다. 4000픽셀짜리를 그대로 보내면 한 장에 토큰이
/// 수천입니다.
enum Shot {
    /// 긴 변 상한. 이 위로는 알아보는 정확도가 안 올라갑니다.
    private static let side: CGFloat = 1568
    private static let folder = "shots"

    private static var home: URL? {
        guard let box = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: NubiLog.group) else { return nil }
        let dir = box.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 줄여서 넣고 이름을 돌려줍니다.
    static func keep(_ data: Data) -> String? {
        guard let home, let small = shrink(data) else { return nil }
        let name = "\(Int(Date().timeIntervalSince1970)).jpg"
        do {
            try small.write(to: home.appendingPathComponent(name))
            sweep()
            return name
        } catch {
            NubiLog.write("[사진] 저장 실패 \(error.localizedDescription)")
            return nil
        }
    }

    static func load(_ name: String) -> Data? {
        guard !name.isEmpty, let home else { return nil }
        return try? Data(contentsOf: home.appendingPathComponent(name))
    }

    /// 모델에게 보낼 모양.
    static func base64(_ name: String) -> String? {
        load(name)?.base64EncodedString()
    }

    /// 긴 변을 맞춰 줄이고 JPEG 로 굽습니다. UIKit 없이 ImageIO 만 씁니다 —
    /// 확장에서도 같은 코드가 돌아야 합니다.
    private static func shrink(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let out = NSMutableData()
        guard let sink = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(sink, image, [kCGImageDestinationLossyCompressionQuality: 0.7]
            as CFDictionary)
        guard CGImageDestinationFinalize(sink) else { return nil }
        return out as Data
    }

    /// 서른 장만 둡니다. 대화가 백 턴이면 사진도 그만큼 쌓입니다.
    private static func sweep() {
        guard let home,
              let names = try? FileManager.default.contentsOfDirectory(atPath: home.path)
        else { return }
        let old = names.sorted().dropLast(30)
        for name in old {
            try? FileManager.default.removeItem(at: home.appendingPathComponent(name))
        }
    }

    static func clear() {
        guard let home else { return }
        try? FileManager.default.removeItem(at: home)
    }
}
