import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

/// 알람이 울릴 때 화면에 뜨는 것.
///
/// **알람도 실시간 활동입니다.** 시스템이 우리 위젯으로 그립니다 — 이걸 안
/// 만들면 알람은 걸리는데 얼굴이 없습니다. 대화창과 같은 검은 판, 같은 말풍이로
/// 맞춥니다.
@available(iOS 26.0, *)
struct NubiAlarmWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<NubiAlarm>.self) { context in
            HStack(spacing: 13) {
                Malpoongi(size: 40, mood: .waiting)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.metadata?.label ?? "알람")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(when(context.state))
                        .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 11) {
                        Malpoongi(size: 30, mood: .waiting)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(context.attributes.metadata?.label ?? "알람").font(.headline)
                            Text(when(context.state))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            } compactLeading: {
                Malpoongi(size: 18, mood: .waiting)
            } compactTrailing: {
                Image(systemName: "alarm.fill").font(.caption2.weight(.bold))
            } minimal: {
                Malpoongi(size: 18, mood: .waiting)
            }
        }
    }

    /// 몇 시 알람인가. 끝나가는 카운트다운이면 남은 시각입니다.
    private func when(_ state: AlarmPresentationState) -> String {
        switch state.mode {
        case let .alert(alert): String(format: "%d:%02d", alert.time.hour, alert.time.minute)
        case let .countdown(down): Format.time(down.fireDate)
        case .paused: "멈춤"
        @unknown default: ""
        }
    }
}
