import ActivityKit
import SwiftUI
import WidgetKit

/// 답을 잠금화면에 둡니다. **앱을 열지 않아도 읽히는 것**이 이 슬라이스의 완료 조건
/// 가운데 하나입니다.
struct NubiLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NubiAttributes.self) { context in
            VStack(alignment: .leading, spacing: 6) {
                Text(context.attributes.asked)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(context.state.headline)
                    .font(.headline)
                    .foregroundStyle(context.state.failed ? .red : .primary)
                if !context.state.detail.isEmpty {
                    Text(context.state.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
            .padding()
            .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.headline).font(.callout)
                        if !context.state.detail.isEmpty {
                            Text(context.state.detail).font(.caption2)
                                .foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "calendar")
            } compactTrailing: {
                Text(context.state.failed ? "!" : "")
            } minimal: {
                Image(systemName: "calendar")
            }
        }
    }
}
