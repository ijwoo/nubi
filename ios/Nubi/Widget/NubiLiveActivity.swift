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
                // **재질은 쓰지 않습니다.** ultraThinMaterial 을 얹었더니 잠금화면에서
                // 검은 덩어리로 굳었습니다 — 위젯은 배경을 흐릴 수 없어서 재질이
                // 그렇게 렌더됩니다. 검은 판에 회색 말풍선, 흰 글씨로 갑니다.
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
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
                    VStack(alignment: .leading, spacing: 7) {
                        if let ends = context.state.timerEnds {
                            Ticking(ends: ends, label: context.state.timerLabel)
                        }
                        Actions(state: context.state)
                    }
                }
            } compactLeading: {
                Malpoongi(size: 18, mood: .of(context.state))
            } compactTrailing: {
                if let ends = context.state.timerEnds {
                    TickingText(ends: ends)
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .frame(width: 42)
                        .foregroundStyle(Tone.working.color)
                } else {
                    Text(badge(context.state))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Tone.of(context.state).color)
                }
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

/// 잠금화면 카드의 색.
///
/// **검은 판 위에 회색 말풍선, 흰 글씨.** 배경화면이 밝든 어둡든 같게 보입니다.
/// 시스템 색(`.primary`, `.secondary`)을 쓰면 잠금화면의 밝기에 따라 흐려집니다.
enum Skin {
    static let theirs = Color(white: 0.20)
    static let mine = Color(white: 0.28)
    static let text = Color.white
    static let faint = Color.white.opacity(0.6)
}

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
        VStack(alignment: .leading, spacing: 7) {
            if !state.asked.isEmpty { Mine(text: state.asked) }
            Theirs(state: state)
            if let ends = state.timerEnds {
                Ticking(ends: ends, label: state.timerLabel)
                    // 말풍이 너비만큼 들여서 말풍선과 왼쪽을 맞춥니다.
                    .padding(.leading, 34)
            }
            if state.hasAction { Actions(state: state).padding(.top, 3) }
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
                .foregroundStyle(Skin.faint)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 15, bottomLeadingRadius: 15,
                        bottomTrailingRadius: 5, topTrailingRadius: 15,
                        style: .continuous
                    ).fill(Skin.mine))
        }
    }
}

/// 누비가 한 말. 왼쪽, 말풍이와 함께.
private struct Theirs: View {
    let state: NubiAttributes.ContentState

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Malpoongi(size: 26, mood: .of(state))
            VStack(alignment: .leading, spacing: 5) {
                // **세 줄이 잠금화면의 한계입니다.** 네 줄이면 버튼이 잘립니다.
                // 나머지는 앱에 있습니다.
                Text(said)
                    .font(.subheadline)
                    .foregroundStyle(state.failed ? Tone.warning.color : Skin.text)
                    .lineLimit(state.hasAction ? 3 : 4)
                    .fixedSize(horizontal: false, vertical: true)
                if state.thinking {
                    ForEach(state.steps, id: \.self) { StepRow(step: $0) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 5, bottomLeadingRadius: 15,
                    bottomTrailingRadius: 15, topTrailingRadius: 15,
                    style: .continuous
                ).fill(Skin.theirs))
            Spacer(minLength: 0)
        }
    }

    /// 한 덩이로 붙입니다. 제목과 설명을 나누면 답이 두 개처럼 보입니다.
    private var said: String {
        state.detail.isEmpty ? state.headline : "\(state.headline)\n\(state.detail)"
    }
}

/// 흐르는 초.
///
/// **앱도 확장도 돌지 않는 동안 스스로 셉니다.** `Text(timerInterval:)` 은
/// 위젯이 직접 갱신하므로 우리가 1초마다 밀어 올릴 필요가 없습니다 — 그렇게
/// 했다면 갱신 한도에 금방 걸렸을 겁니다.
///
/// 다 흐르면 0:00 에 멈춰 있습니다. 그 순간 알림이 같이 오므로 못 보고
/// 지나가지는 않고, 다음에 무엇이든 물으면 사라집니다.
private struct Ticking: View {
    let ends: Date
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "timer")
                .font(.system(size: 11, weight: .bold))
            TickingText(ends: ends)
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(width: 46, alignment: .leading)
            if !label.isEmpty, label != "타이머" {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(Skin.faint)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Tone.working.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Skin.theirs))
    }
}

/// 남은 시간 글자 하나.
///
/// **지난 시각으로 범위를 만들면 죽습니다.** `Date.now...ends` 는 끝이 앞서면
/// 안 되는 범위이고, 위젯은 타이머가 끝난 뒤에도 다시 그려질 수 있습니다.
private struct TickingText: View {
    let ends: Date

    private var left: ClosedRange<Date>? {
        let now = Date.now
        return ends > now ? now...ends : nil
    }

    var body: some View {
        if let left {
            Text(timerInterval: left, countsDown: true)
        } else {
            Text("0:00")
        }
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
                .foregroundStyle(Skin.faint)
                .lineLimit(1)
        }
    }
}

/// 누르는 자리.
///
/// **뜻이 있을 때만 나옵니다.** 늘 떠 있던 오늘·내일·전문은 뺐습니다.
/// 대화창을 그냥 탭하면 앱이 열리니 전문 버튼은 같은 일을 하나 더 둔 것이었고,
/// 오늘·내일은 잠금화면 컨트롤과 단축어가 이미 합니다. 겹치는 버튼이 답이
/// 들어갈 자리를 먹고 있었습니다.
private struct Actions: View {
    let state: NubiAttributes.ContentState

    var body: some View {
        HStack(spacing: 7) {
            if !state.confirm.isEmpty {
                Button(intent: ConfirmIntent(stamp: state.stamp)) {
                    Label(state.confirm, systemImage: "checkmark.shield.fill")
                        .font(.caption2.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(Tone.warning.color)
            } else {
                if !state.map.isEmpty {
                    Button(intent: DirectionsIntent(state.map)) {
                        Label("길찾기", systemImage: "location.fill")
                            .font(.caption2.weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Tone.done.color)
                }
                // **예약 도구는 없지만 전화는 넘길 수 있습니다.** 가게 번호는
                // 찾을 때 이미 받아놓고 버리고 있었습니다.
                if !state.call.isEmpty {
                    Button(intent: DirectionsIntent(state.call)) {
                        Label("전화", systemImage: "phone.fill")
                            .font(.caption2.weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Tone.working.color)
                }
            }
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
