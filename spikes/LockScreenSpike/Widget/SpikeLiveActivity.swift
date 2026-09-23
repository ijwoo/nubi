import ActivityKit
import SwiftUI
import WidgetKit

/// 잠금화면에 승인 버튼 하나를 띄운다.
///
/// 확인하려는 것은 모양이 아니라 동작이다 — 잠긴 상태에서 이 버튼을 눌렀을 때
/// 앱이 열리는지, 버튼의 인텐트가 네트워크를 칠 수 있는지.
struct SpikeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpikeAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text(context.attributes.what)
                    .font(.headline)
                Text("\(context.state.status) · 스텝 \(context.state.step)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(intent: ApproveSpikeIntent()) {
                    Text("승인")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.what).font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Button(intent: ApproveSpikeIntent()) { Text("승인") }
                }
            } compactLeading: {
                Image(systemName: "hand.raised")
            } compactTrailing: {
                Text("\(context.state.step)")
            } minimal: {
                Image(systemName: "hand.raised")
            }
        }
    }
}
