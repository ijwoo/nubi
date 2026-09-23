import ActivityKit
import SwiftUI

@main
struct SpikeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// 스파이크를 시작하고 기록을 읽는 화면.
///
/// 관찰 자체는 잠긴 화면에서 일어나므로, 이 화면이 하는 일은 실험을 걸어두고
/// 나중에 결과를 보여주는 것뿐이다.
struct ContentView: View {
    @State private var log = SpikeLog.read()
    @State private var activityState = "없음"

    var body: some View {
        NavigationStack {
            List {
                Section("1. 승인 버튼") {
                    Button("Live Activity 시작") { start() }
                    Text("시작한 뒤 폰을 잠그고, 잠금화면의 승인 버튼을 누릅니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("활동", value: activityState)
                }

                Section("2. 제어 센터 버튼") {
                    Text("설정에서 제어 센터에 “Spike EventKit” 을 추가하고, 폰을 잠근 채 누릅니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("기록") {
                    Text(log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                Section {
                    Button("새로고침") { log = SpikeLog.read() }
                    Button("기록 지우기", role: .destructive) {
                        SpikeLog.clear()
                        log = SpikeLog.read()
                    }
                }
            }
            .navigationTitle("LockScreen Spike")
        }
        .onAppear {
            // 이 줄이 승인 버튼 기록 바로 뒤에 붙으면, 버튼이 앱을 깨운 것이다.
            SpikeLog.noteForeground()
            log = SpikeLog.read()
        }
    }

    private func start() {
        let attributes = SpikeAttributes(requestId: UUID().uuidString, what: "삭제를 누르려 합니다")
        let state = SpikeAttributes.ContentState(step: 1, status: "승인 대기")
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
            activityState = "시작됨 \(activity.id.prefix(8))"
            SpikeLog.write("[앱] Live Activity 시작")
        } catch {
            activityState = "실패: \(error.localizedDescription)"
            SpikeLog.write("[앱] Live Activity 실패 \(error.localizedDescription)")
        }
    }
}
