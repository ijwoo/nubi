import AppIntents
import SwiftUI
import WidgetKit

/// 잠금화면과 제어 센터에 놓는 버튼.
///
/// 누르면 앱이 열리지 않고 확장 안에서 오늘 일정을 읽어 잠금화면에 띄웁니다.
/// [스파이크](../../../docs/benchmarks/2026-09-24-lockscreen-spike.md)에서 잠금
/// 상태의 확장이 EventKit 에 닿는 것을 확인했기 때문에 이 자리가 성립합니다.
struct TodayControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.jaewoo.nubi.today") {
            ControlWidgetButton(action: TodayEventsIntent()) {
                Label("오늘 일정", systemImage: "calendar")
            }
        }
        .displayName("누비 오늘 일정")
        .description("잠금화면에서 오늘 일정을 띄웁니다.")
    }
}
