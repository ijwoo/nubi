import AppIntents
import SwiftUI
import WidgetKit

/// 제어 센터·잠금화면에 놓는 버튼.
///
/// 빠른 모드의 진입점 후보다. 잠긴 상태에서 이것만으로 EventKit 에 닿는지가
/// "제어 센터 버튼만으로 미리알림이 추가된다" 는 완료 조건을 가른다.
struct SpikeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.jaewoo.nubispike.control") {
            ControlWidgetButton(action: EventKitSpikeIntent()) {
                Label("EventKit 확인", systemImage: "calendar.badge.plus")
            }
        }
        .displayName("Spike EventKit")
        .description("잠금 상태에서 EventKit 에 닿는지 확인합니다.")
    }
}
