import Foundation
import Security

/// API 키. **앱과 확장이 같이 읽어야 합니다.**
///
/// 잠금화면 입력창은 앱 프로세스가 살아 있으면 열리지 않습니다. 그래서 묻는
/// 인텐트를 확장에서 돌리는데, 확장은 앱의 키체인 항목을 못 봅니다 — 키체인
/// 공유는 포털에 권한을 따로 등록해야 합니다.
///
/// 그래서 App Group 컨테이너의 파일에 둡니다. 기기 암호화와 파일 보호로 막히고,
/// **저장소에도 `.ipa` 에도 들어가지 않습니다** — 사용자가 설정 화면에서 넣습니다
/// ([ADR 0001](../../../docs/adr/0001-separate-public-repo.md)).
///
/// 키체인보다 약합니다. 같은 기기에서 이 App Group 을 볼 수 있는 것은 이 앱과
/// 이 앱의 확장뿐이므로 감수합니다.
enum Secrets {
    private static let service = "dev.jaewoo.nubi"
    private static let account = "anthropic-api-key"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: NubiLog.group)?
            .appendingPathComponent("key")
    }

    static var apiKey: String? {
        get {
            if let url = fileURL,
               let data = try? Data(contentsOf: url),
               let key = String(data: data, encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                return key
            }
            // 예전 빌드에서 키체인에 넣어둔 것. 앱이 열릴 때 파일로 옮깁니다.
            return keychainKey
        }
        set {
            guard let url = fileURL else { return }
            guard let newValue, !newValue.isEmpty else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            try? Data(newValue.utf8).write(
                to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// 키체인에만 있는 키를 파일로 옮깁니다. 앱이 열릴 때 한 번.
    static func migrateFromKeychain() {
        guard let url = fileURL, !FileManager.default.fileExists(atPath: url.path) else { return }
        guard let key = keychainKey else { return }
        apiKey = key
        NubiLog.write("[키] 키체인에서 App Group 으로 옮김")
    }

    private static var keychainKey: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    /// 화면에 그대로 띄우지 않습니다. 있는지만 보여줍니다.
    static var masked: String {
        guard let key = apiKey else { return "없음" }
        return key.count > 12 ? "\(key.prefix(8))…\(key.suffix(4))" : "설정됨"
    }
}
