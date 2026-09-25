import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// 잠금화면 위의 대화창.
///
/// 물은 것은 위, 답은 아래, 묻는 자리는 맨 밑. **앱을 열지 않고 읽고, 앱을 열지
/// 않고 다시 묻습니다.** 좁은 자리라 세 덩이 이상은 두지 않습니다.
struct NubiLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NubiAttributes.self) { context in
            Chat(state: context.state)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Answer(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Actions(thinking: context.state.thinking, stamp: context.state.stamp)
                }
            } compactLeading: {
                Mark(size: 18, state: .idle)
            } compactTrailing: {
                if context.state.thinking {
                    ProgressView().progressViewStyle(.circular).scaleEffect(0.6)
                }
            } minimal: {
                Mark(size: 18, state: .idle)
            }
        }
    }
}

private struct Chat: View {
    let state: NubiAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !state.asked.isEmpty { Question(text: state.asked).padding(.bottom, 10) }
            Answer(state: state)
            Actions(thinking: state.thinking, stamp: state.stamp).padding(.top, 13)
        }
    }
}

/// 물은 말. 오른쪽에 붙어 대화라는 것을 말없이 알립니다.
private struct Question: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 48)
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 14, bottomLeadingRadius: 14,
                        bottomTrailingRadius: 4, topTrailingRadius: 14,
                        style: .continuous
                    )
                    .fill(.primary.opacity(0.08)))
        }
    }
}

private struct Answer: View {
    let state: NubiAttributes.ContentState

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Mark(size: 30, state: mark)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(state.failed ? Color.orange : .primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if !state.detail.isEmpty {
                    Text(state.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
        }
    }

    private var mark: Mark.State {
        if state.failed { return .warning }
        if state.thinking { return .thinking }
        return .idle
    }
}

/// 묻는 자리.
///
/// 글자를 치는 쪽 하나, 안 치는 쪽 둘, 앱을 여는 쪽 하나.
/// **잠금화면 입력창은 앱 프로세스가 막 떴을 때만 열립니다.** 그래서 마지막
/// 화살표가 필요합니다 — 느리지만 언제나 되는 길입니다.
private struct Actions: View {
    let thinking: Bool
    let stamp: Int

    var body: some View {
        HStack(spacing: 6) {
            Button(intent: AskNubiIntent(utterance: nil, stamp: stamp)) {
                Label("묻기", systemImage: "keyboard")
                    .font(.caption2.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 15)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)

            ForEach(Quick.all, id: \.self) { phrase in
                Button(intent: QuickAskIntent(phrase, stamp: stamp)) {
                    Text(phrase)
                        .font(.caption2.weight(.medium))
                        .frame(minHeight: 15)
                        .padding(.horizontal, 2)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
            }

            Button(intent: OpenNubiIntent()) {
                Image(systemName: "arrow.up.forward")
                    .font(.caption2.weight(.bold))
                    .frame(minHeight: 15)
            }
            .buttonStyle(.bordered)
            .tint(.primary)
        }
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(thinking)
        .opacity(thinking ? 0.45 : 1)
    }
}

/// 누비의 표시.
private struct Mark: View {
    enum State { case idle, thinking, warning }

    var size: CGFloat
    var state: State

    var body: some View {
        ZStack {
            Circle().fill(fill)
            if state == .thinking {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(size / 52)
            } else {
                Image(systemName: state == .warning ? "exclamationmark" : "sparkle")
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }

    private var fill: AnyShapeStyle {
        switch state {
        case .warning:
            AnyShapeStyle(LinearGradient(colors: [.orange, .yellow],
                                         startPoint: .top, endPoint: .bottom))
        case .thinking:
            AnyShapeStyle(Color.secondary.opacity(0.45))
        case .idle:
            AnyShapeStyle(LinearGradient(colors: [.teal, .mint],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }
}

/// 글자를 치지 않고 누르기만 하는 한 마디. 잠금화면은 좁으므로 둘까지입니다.
enum Quick {
    static let all = ["오늘", "내일"]
}
