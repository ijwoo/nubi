import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// 잠금화면 위의 대화창.
///
/// **대화의 마지막 한 턴을 비추는 창입니다.** 전문은 앱에 있습니다. 여기는 한 문장
/// 요약과 그 아래 두어 줄까지입니다 — 잠금화면은 그 이상 안 들어갑니다.
struct NubiLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NubiAttributes.self) { context in
            Card(state: context.state)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) { Reply(state: context.state) }
                DynamicIslandExpandedRegion(.bottom) { Actions(state: context.state) }
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

private struct Card: View {
    let state: NubiAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !state.asked.isEmpty { Asked(text: state.asked).padding(.bottom, 11) }
            Reply(state: state)
            Actions(state: state).padding(.top, 14)
        }
    }
}

/// 물은 말. 오른쪽에 붙어 대화라는 것을 말없이 알립니다.
private struct Asked: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 52)
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
                        bottomTrailingRadius: 5, topTrailingRadius: 14,
                        style: .continuous
                    ).fill(.primary.opacity(0.08)))
        }
    }
}

private struct Reply: View {
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
                        .lineLimit(2)
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

/// 누르는 자리.
///
/// **글자를 치는 버튼은 여기 없습니다.** 인텐트가 직접 값을 요구하는 길은 첫 번만
/// 열리고 막힙니다. 잠금화면에서 글자를 받는 길은 단축어 앱의 "텍스트 입력 요청"
/// 하나이고, 그 버튼은 잠금화면 아래 손전등 자리에 놓입니다.
private struct Actions: View {
    let state: NubiAttributes.ContentState

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Quick.all, id: \.self) { phrase in
                Button(intent: QuickAskIntent(phrase, stamp: state.stamp)) {
                    Text(phrase)
                        .font(.caption2.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
            }
            Button(intent: OpenNubiIntent()) {
                Label("전문", systemImage: "arrow.up.forward")
                    .font(.caption2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 16)
            }
            .buttonStyle(.bordered)
            .tint(.primary)
        }
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(state.thinking)
        .opacity(state.thinking ? 0.45 : 1)
    }
}

private struct Mark: View {
    enum State { case idle, thinking, warning }

    var size: CGFloat
    var state: State

    var body: some View {
        ZStack {
            Circle().fill(fill)
            if state == .thinking {
                ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(size / 52)
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
