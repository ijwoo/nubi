import AppIntents
import EventKit
import Foundation

/// 권한 상태를 사람이 읽는 말로. 거부와 "아직 묻지 않음" 은 다른 상황이고,
/// 설계도 다르게 간다 — 앞의 것은 사용자가 거절한 것이고 뒤의 것은 우리가 안 물은 것이다.
func spikeAuthLabel(_ status: EKAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: "아직 묻지 않음"
    case .restricted: "제한됨"
    case .denied: "거부됨"
    case .fullAccess: "전체 허용"
    case .writeOnly: "쓰기만 허용"
    @unknown default: "알 수 없음(\(status.rawValue))"
    }
}

/// 잠금화면 승인 버튼이 실제로 무엇을 할 수 있는지.
///
/// 궁금한 것은 셋이다. 앱이 포그라운드로 올라오는가, 네트워크를 칠 수 있는가,
/// 얼마나 오래 돌 수 있는가. 승인 게이트는 relay 에 답을 보내야 하므로
/// 네트워크가 안 되면 설계가 달라진다 — 앱을 깨워서 보내야 한다.
struct ApproveSpikeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "승인 (스파이크)"

    /// 기본값은 false 다. true 면 버튼을 누를 때 앱이 열리고, 그러면 무엇이
    /// 가능한지가 아니라 앱이 무엇을 했는지를 재게 된다.
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        let started = Date()
        SpikeLog.write("[승인버튼] 시작")

        // 네트워크. 확장이 직접 칠 수 있으면 relay 응답을 여기서 보낼 수 있다.
        do {
            // 캐시를 끈다. 빌드 1 에서 두 번째부터 1ms 가 나왔는데, 그건 왕복이
            // 아니라 URLCache 였다. 매번 실제로 나가는지가 알고 싶은 것이다.
            let url = URL(string: "https://example.com/?t=\(Int(Date().timeIntervalSince1970 * 1000))")!
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = 8
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            SpikeLog.write("[승인버튼] 네트워크 성공 HTTP \(code)")
        } catch {
            SpikeLog.write("[승인버튼] 네트워크 실패 \(error.localizedDescription)")
        }

        SpikeLog.write("[승인버튼] 끝 \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return .result()
    }
}

/// 제어 센터·잠금화면 버튼이 EventKit 에 닿는지.
///
/// 빠른 모드의 완료 조건 가운데 "잠금 상태에서 제어 센터 버튼만으로 미리알림이
/// 추가된다" 가 여기에 달려 있다. 읽기와 쓰기를 따로 시도한다 — 권한이
/// 나뉘어 있고, 읽기만 되는 결과도 설계상 의미가 있다.
struct EventKitSpikeIntent: AppIntent {
    static let title: LocalizedStringResource = "EventKit 확인 (스파이크)"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        let started = Date()
        let store = EKEventStore()
        // 요청하기 전의 상태를 먼저 남긴다. 확장에서 대화상자가 뜨지 않는다면
        // 이 줄이 "아직 묻지 않음" 인 채로 거부로 떨어지는 것을 보여준다.
        SpikeLog.write("[EventKit] 시작 — 일정 \(spikeAuthLabel(EKEventStore.authorizationStatus(for: .event))), 미리알림 \(spikeAuthLabel(EKEventStore.authorizationStatus(for: .reminder)))")

        // 읽기 — 오늘 일정 개수만 센다. 내용은 기록하지 않는다.
        do {
            let granted = try await store.requestFullAccessToEvents()
            if granted {
                let now = Date()
                let end = now.addingTimeInterval(24 * 3600)
                let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
                SpikeLog.write("[EventKit] 일정 읽기 성공 — \(store.events(matching: predicate).count)건")
            } else {
                SpikeLog.write("[EventKit] 일정 권한 거부됨")
            }
        } catch {
            SpikeLog.write("[EventKit] 일정 읽기 실패 \(error.localizedDescription)")
        }

        // 쓰기 — 미리알림을 하나 넣는다. 스파이크 표시를 붙여 나중에 지우기 쉽게.
        do {
            let granted = try await store.requestFullAccessToReminders()
            if granted {
                let reminder = EKReminder(eventStore: store)
                reminder.title = "스파이크 확인 \(Int(Date().timeIntervalSince1970))"
                reminder.calendar = store.defaultCalendarForNewReminders()
                try store.save(reminder, commit: true)
                SpikeLog.write("[EventKit] 미리알림 쓰기 성공")
            } else {
                SpikeLog.write("[EventKit] 미리알림 권한 거부됨")
            }
        } catch {
            SpikeLog.write("[EventKit] 미리알림 쓰기 실패 \(error.localizedDescription)")
        }

        SpikeLog.write("[EventKit] 끝 \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return .result()
    }
}
