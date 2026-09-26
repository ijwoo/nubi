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
                        Malpoongi(size: 30, mood: .of(context.state))
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
                Malpoongi(size: 18, mood: .of(context.state))
            } compactTrailing: {
                Text(badge(context.state))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Tone.of(context.state).color)
            } minimal: {
                Malpoongi(size: 18, mood: .of(context.state))
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
        if state.failed || !state.confirm.isEmpty { return .warning }
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

/// **채팅처럼 보입니다.** 물은 말이 오른쪽 말풍선, 답이 왼쪽 말풍선.
///
/// 전에는 "Q." 접두사와 출처와 시각이 위에 깔리고 답이 제목처럼 굵었습니다.
/// 잠금화면에서 읽는 사람에게 그건 전부 곁가지였습니다 — **답 말고는 시선을
/// 끌면 안 됩니다.** 출처와 시각은 앱에 있습니다.
private struct Card: View {
    let state: NubiAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.asked.isEmpty { Mine(text: state.asked) }
            Theirs(state: state)
            Actions(state: state).padding(.top, 5)
        }
    }
}

/// 내가 한 말. 오른쪽.
private struct Mine: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 56)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 15, bottomLeadingRadius: 15,
                        bottomTrailingRadius: 5, topTrailingRadius: 15,
                        style: .continuous
                    ).fill(.primary.opacity(0.07)))
        }
    }
}

/// 누비가 한 말. 왼쪽, 말풍이와 함께.
private struct Theirs: View {
    let state: NubiAttributes.ContentState

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Malpoongi(size: 28, mood: .of(state))
            VStack(alignment: .leading, spacing: 5) {
                Text(said)
                    .font(.subheadline)
                    .foregroundStyle(state.failed ? Tone.warning.color : .primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if state.thinking {
                    ForEach(state.steps, id: \.self) { StepRow(step: $0) }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 15, bottomLeadingRadius: 5,
                    bottomTrailingRadius: 15, topTrailingRadius: 15,
                    style: .continuous
                ).fill(.primary.opacity(0.07)))
            Spacer(minLength: 24)
        }
    }

    /// 한 덩이로 붙입니다. 제목과 설명을 나누면 답이 두 개처럼 보입니다.
    private var said: String {
        state.detail.isEmpty ? state.headline : "\(state.headline)\n\(state.detail)"
    }
}

/// 한 단계. **실제로 한 일만 여기 옵니다.**
private struct StepRow: View {
    let step: NubiAttributes.StepLine

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: step.done ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(step.done ? Tone.done.color : Tone.working.color)
            Text(step.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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
            // 승인이 기다리면 그것이 첫 버튼입니다. 다른 손길보다 먼저입니다.
            if !state.confirm.isEmpty {
                Button(intent: ConfirmIntent(stamp: state.stamp)) {
                    Label(state.confirm, systemImage: "checkmark.shield.fill")
                        .font(.caption2.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(Tone.warning.color)
            } else if let url = URL(string: state.map), !state.map.isEmpty {
                Button(intent: OpenURLIntent(url)) {
                    Label("길찾기", systemImage: "location.fill")
                        .font(.caption2.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(Tone.done.color)
            } else {
                Button(intent: RemindLaterIntent(state.asked, note: state.headline, stamp: state.stamp)) {
                    Label("1시간 뒤", systemImage: "bell")
                        .font(.caption2.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(Tone.done.color)
            }

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

extension Malpoongi.Mood {
    /// 아직 아무것도 안 물었으면 듣는 얼굴입니다. 색만으로는 "듣는 중" 과
    /// "생각 중" 이 구별되지 않아서 표정이 그 일을 합니다.
    static func of(_ state: NubiAttributes.ContentState) -> Malpoongi.Mood {
        if state.failed || !state.confirm.isEmpty { return .waiting }
        if state.thinking { return .thinking }
        return state.asked.isEmpty ? .listening : .done
    }
}

/// 글자를 치지 않고 누르기만 하는 한 마디. 잠금화면은 좁으므로 둘까지입니다.
enum Quick {
    static let all = ["오늘", "내일"]
}
