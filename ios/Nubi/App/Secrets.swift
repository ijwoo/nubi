import Foundation
import Security

/// API 키를 키체인에 둡니다.
///
/// 이 저장소는 공개입니다 ([ADR 0001](../../../docs/adr/0001-separate-public-repo.md)).
/// 키를 코드에 박을 수 없고, 빌드에 넣으면 TestFlight 로 받은 `.ipa` 안에 들어갑니다.
/// 그래서 **사용자가 설정 화면에서 붙여넣고, 여기 저장됩니다.**
///
/// 확장과 공유하지 않습니다. 키가 필요한 것은 앱의 자유 질문뿐이고, 잠금화면
/// 버튼은 EventKit 만 씁니다 — 나눌 이유가 없으면 나누지 않습니다.
enum Secrets {
    private static let service = "dev.jaewoo.nubi"
    private static let account = "anthropic-api-key"

    static var apiKey: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let key = String(data: data, encoding: .utf8),
                  !key.isEmpty
            else { return nil }
            return key
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(base as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(newValue.utf8)
            // 첫 잠금 해제 뒤부터 읽힙니다. 재부팅 직후 잠긴 상태에서는 못 읽지만,
            // 키가 필요한 것은 앱을 열고 묻는 경우뿐이라 그때는 이미 풀려 있습니다.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// 화면에 그대로 띄우지 않습니다. 있는지만 보여줍니다.
    static var masked: String {
        guard let key = apiKey else { return "없음" }
        return key.count > 12 ? "\(key.prefix(8))…\(key.suffix(4))" : "설정됨"
    }
}
