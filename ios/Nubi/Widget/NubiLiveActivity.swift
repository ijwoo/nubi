import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// 잠금화면 위의 대화창.
///
/// 물은 것은 오른쪽, 답은 왼쪽. **앱을 열지 않고 읽고, 앱을 열지 않고 다시 묻습니다.**
/// 묻기 버튼은 시스템 입력창을 부르고, 잠금은 풀리지 않습니다.
struct NubiLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NubiAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                if !context.state.asked.isEmpty {
                    HStack {
                        Spacer(minLength: 40)
                        Text(context.state.asked)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: context.state.thinking ? "ellipsis.bubble" : "bubble.left.fill")
                        .font(.title3)
                        .foregroundStyle(context.state.failed ? .red : .teal)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.headline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(context.state.failed ? .red : .primary)
                        if !context.state.detail.isEmpty {
                            Text(context.state.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Button(intent: AskNubiIntent(utterance: nil)) {
                        Label("묻기", systemImage: "text.cursor")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    ForEach(Quick.all, id: \.self) { phrase in
                        Button(intent: QuickAskIntent(phrase)) {
                            Text(phrase).font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .disabled(context.state.thinking)
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
                DynamicIslandExpandedRegion(.bottom) {
                    Button(intent: AskNubiIntent(utterance: nil)) {
                        Label("묻기", systemImage: "text.cursor").font(.caption)
                    }
                    .disabled(context.state.thinking)
                }
            } compactLeading: {
                Image(systemName: "bubble.left.fill").foregroundStyle(.teal)
            } compactTrailing: {
                if context.state.thinking { Image(systemName: "ellipsis") }
            } minimal: {
                Image(systemName: "bubble.left.fill").foregroundStyle(.teal)
            }
        }
    }
}

/// 글자를 치지 않고 누르기만 하는 한 마디. 잠금화면은 좁으므로 둘까지입니다.
enum Quick {
    static let all = ["오늘 일정", "내일 일정"]
}
