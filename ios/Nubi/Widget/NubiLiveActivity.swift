import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// 잠금화면 위의 대화창.
///
/// 상태마다 모양이 다릅니다. **기다릴 때는 무엇을 하고 있는지**, 끝나면 **결론
/// 한 줄과 다음 손길**을 보여줍니다. 전문은 앱에 있습니다.
struct NubiLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NubiAttributes.self) { context in
            Card(state: context.state)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    HStack(alignment: .top, spacing: 11) {
                        Orb(size: 30, state: .of(context.state))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.state.headline)
                                .font(.headline).lineLimit(2)
                            if !context.state.meta.isEmpty {
                                Text(context.state.meta)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Actions(state: context.state)
                }
            } compactLeading: {
                Orb(size: 18, state: .of(context.state))
            } compactTrailing: {
                Text(badge(context.state))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Tone.of(context.state).color)
            } minimal: {
                Orb(size: 18, state: .of(context.state))
            }
        }
    }

    /// 오브 하나로 상태를 전합니다. 옆의 글자는 그 상태를 한 마디로 굳힙니다.
    private func badge(_ state: NubiAttributes.ContentState) -> String {
        if state.failed { return "확인" }
        if state.thinking {
            let done = state.steps.filter(\.done).count
            return state.steps.isEmpty ? "…" : "\(done)/\(state.steps.count)"
        }
        return ""
    }
}

// MARK: - 색

/// 상태마다 쓰는 색. **하나의 상태에 하나의 색입니다.**
enum Tone {
    case working, done, warning

    static func of(_ state: NubiAttributes.ContentState) -> Tone {
        if state.failed { return .warning }
        if state.thinking { return .working }
        return .done
    }

    var color: Color {
        switch self {
        case .working: Color(red: 0.36, green: 0.35, blue: 0.85)
        case .done: Color(red: 0.06, green: 0.71, blue: 0.51)
        case .warning: Color(red: 0.96, green: 0.62, blue: 0.07)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [color, color.opacity(0.72)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - 잠금화면 카드

private struct Card: View {
    let state: NubiAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.thinking { Asked(text: state.asked).padding(.bottom, 11) } else { Header(state: state) }
            Reply(state: state).padding(.top, state.thinking ? 0 : 9)
            if state.thinking {
                Bar(value: state.progress).padding(.top, 12)
            } else {
                Actions(state: state).padding(.top, 13)
            }
        }
    }
}

/// 기다리는 동안은 물은 말이 오른쪽에 붙습니다. 대화라는 것을 말없이 알립니다.
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

/// 답이 오면 물은 말은 한 줄로 줄고, 오른쪽에 출처와 시각이 붙습니다.
private struct Header: View {
    let state: NubiAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            if !state.asked.isEmpty {
                Text("Q. \(state.asked)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !state.meta.isEmpty {
                Text(state.meta)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

private struct Reply: View {
    let state: NubiAttributes.ContentState

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Orb(size: state.thinking ? 30 : 34, state: .of(state))
            VStack(alignment: .leading, spacing: state.thinking ? 6 : 3) {
                Text(state.headline)
                    .font(state.thinking ? .subheadline.weight(.semibold) : .title3.weight(.bold))
                    .foregroundStyle(state.failed ? Tone.warning.color : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if state.thinking {
                    ForEach(state.steps, id: \.self) { StepRow(step: $0) }
                } else if !state.detail.isEmpty {
                    Text(state.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, state.thinking ? 2 : 0)
            Spacer(minLength: 0)
        }
    }
}

/// 한 단계. **실제로 한 일만 여기 옵니다.**
private struct StepRow: View {
    let step: NubiAttributes.StepLine

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: step.done ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(step.done ? Tone.done.color : Tone.working.color)
            Text(step.label)
                .font(.caption2.weight(.semibold))
                .frame(width: 30, alignment: .leading)
            Text(step.detail)
                .font(.caption2)
                .foregroundStyle(step.done ? .secondary : Tone.working.color)
                .lineLimit(1)
        }
    }
}

private struct Bar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule().fill(Tone.working.gradient)
                    .frame(width: max(18, geo.size.width * value))
            }
        }
        .frame(height: 4)
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
            // 어떤 답에도 붙는 다음 손길. 답 한 줄을 한 시간 뒤 미리알림으로 넣습니다.
            Button(intent: RemindLaterIntent(state.headline, stamp: state.stamp)) {
                Label("1시간 뒤", systemImage: "bell")
                    .font(.caption2.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(Tone.done.color)

            ForEach(Quick.all, id: \.self) { phrase in
                Button(intent: QuickAskIntent(phrase, stamp: state.stamp)) {
                    Text(phrase)
                        .font(.caption2.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 16)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
            }

            Button(intent: OpenNubiIntent()) {
                Image(systemName: "arrow.up.forward")
                    .font(.caption2.weight(.bold))
                    .frame(minHeight: 16)
                    .padding(.horizontal, 2)
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

/// 상태를 전하는 오브 하나.
struct Orb: View {
    var size: CGFloat
    var state: Tone

    var body: some View {
        ZStack {
            Circle().fill(state.gradient)
            switch state {
            case .working:
                Circle()
                    .fill(.white)
                    .frame(width: size * 0.3, height: size * 0.3)
                    .offset(y: -size * 0.1)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.44, weight: .heavy))
                    .foregroundStyle(.white)
            case .warning:
                Image(systemName: "exclamationmark")
                    .font(.system(size: size * 0.46, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

/// 글자를 치지 않고 누르기만 하는 한 마디. 잠금화면은 좁으므로 둘까지입니다.
enum Quick {
    static let all = ["오늘", "내일"]
}
