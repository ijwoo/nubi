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
            LockScreenChat(state: context.state)
                .padding(14)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    AnswerBubble(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActionRow(thinking: context.state.thinking)
                }
            } compactLeading: {
                Mark(size: 18)
            } compactTrailing: {
                if context.state.thinking {
                    ProgressView().progressViewStyle(.circular).scaleEffect(0.6)
                }
            } minimal: {
                Mark(size: 18)
            }
        }
    }
}

/// 잠금화면에 그려지는 전부.
private struct LockScreenChat: View {
    let state: NubiAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !state.asked.isEmpty {
                // 물은 것은 오른쪽. 대화라는 것을 말없이 알리는 자리입니다.
                HStack {
                    Spacer(minLength: 44)
                    Text(state.asked)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.primary.opacity(0.07)))
                }
            }
            AnswerBubble(state: state)
            ActionRow(thinking: state.thinking)
        }
    }
}

private struct AnswerBubble: View {
    let state: NubiAttributes.ContentState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Mark(size: 26, muted: state.thinking, alarming: state.failed)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(state.headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(state.failed ? Color.red : .primary)
                    if state.thinking {
                        ProgressView().progressViewStyle(.circular).scaleEffect(0.55)
                    }
                }
                if !state.detail.isEmpty {
                    Text(state.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.primary.opacity(0.07)))
    }
}

/// 묻는 자리. 글자를 치는 쪽 하나, 안 치는 쪽 둘.
///
/// **미리 정한 한 마디가 더 자주 쓰입니다.** 잠금화면에서 글자를 치는 건 번거롭고,
/// 물어볼 것의 대부분은 정해져 있습니다.
private struct ActionRow: View {
    let thinking: Bool

    var body: some View {
        HStack(spacing: 7) {
            Button(intent: AskNubiIntent(utterance: nil)) {
                Label("묻기", systemImage: "keyboard")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)

            ForEach(Quick.all, id: \.self) { phrase in
                Button(intent: QuickAskIntent(phrase)) {
                    Text(phrase)
                        .font(.caption)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
        }
        .buttonBorderShape(.capsule)
        .disabled(thinking)
        .opacity(thinking ? 0.5 : 1)
    }
}

/// 누비의 표시. 말풍선 하나.
private struct Mark: View {
    var size: CGFloat
    var muted = false
    var alarming = false

    var body: some View {
        Image(systemName: alarming ? "exclamationmark.bubble.fill" : "bubble.left.fill")
            .font(.system(size: size * 0.55))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
    }

    private var fill: AnyShapeStyle {
        if alarming { return AnyShapeStyle(Color.red.gradient) }
        if muted { return AnyShapeStyle(Color.gray.gradient) }
        return AnyShapeStyle(
            LinearGradient(colors: [.teal, .mint], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

/// 글자를 치지 않고 누르기만 하는 한 마디. 잠금화면은 좁으므로 둘까지입니다.
enum Quick {
    static let all = ["오늘", "내일"]
}
