import ActivityKit
import Foundation

/// 승인 요청 하나를 나타내는 Live Activity.
///
/// ContentState 는 일부러 작게 둔다. 푸시 페이로드가 aps 래퍼까지 포함해
/// 4KB 이고, 본문은 폰이 만들 수 있으므로 여기에는 id 와 상태만 담는다.
struct SpikeAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var step: Int
        var status: String
    }

    var requestId: String
    var what: String
}
