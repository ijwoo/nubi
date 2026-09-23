import ActivityKit
import Foundation
import SwiftUI
import UIKit

@main
struct SpikeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// 스파이크를 걸어두고 결과를 읽는 화면.
///
/// 관찰은 잠긴 화면에서 일어나고, TestFlight 로 받으면 Xcode 콘솔도 없다.
/// 그래서 이 화면이 유일한 출구다 — 읽고, 복사하고, 내보낼 수 있어야 한다.
struct ContentView: View {
    @State private var log = SpikeLog.read()
    @State private var activityState = "없음"
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section("환경") {
                    LabeledContent("기기", value: SpikeEnvironment.device)
                    LabeledContent("iOS", value: SpikeEnvironment.system)
                    LabeledContent("빌드", value: SpikeEnvironment.build)
                }

                Section("1. 승인 버튼") {
                    Button("Live Activity 시작") { start() }
                    Text("시작한 뒤 폰을 잠그고, 잠금화면의 승인 버튼을 누릅니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("활동", value: activityState)
                }

                Section("2. 제어 센터 버튼") {
                    Text("설정 › 제어 센터에 “Spike EventKit” 을 추가하고, 폰을 잠근 채 누릅니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Text(log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    HStack {
                        Text("기록")
                        Spacer()
                        Button(copied ? "복사됨" : "전체 복사") { copy() }
                            .font(.caption)
                            .textCase(nil)
                    }
                }

                Section {
                    Button("새로고침") { log = SpikeLog.read() }
                    ShareLink(item: report) { Text("결과 내보내기") }
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

    /// 환경까지 붙인 본문. 결과를 옮겨 적을 때 기종과 버전이 같이 가야 한다.
    private var report: String {
        """
        기기: \(SpikeEnvironment.device)
        iOS: \(SpikeEnvironment.system)
        빌드: \(SpikeEnvironment.build)

        \(log)
        """
    }

    private func copy() {
        UIPasteboard.general.string = report
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
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
        log = SpikeLog.read()
    }
}

/// 결과와 같이 기록해야 하는 것들.
///
/// 이 스파이크는 개인 폰(18 Pro)에서 재고 나중에 조작 폰(14 Pro)에서 다시 잰다.
/// 무엇이 달라졌는지 알려면 답 옆에 기종과 버전이 붙어 있어야 한다.
enum SpikeEnvironment {
    static var device: String { machine }
    static var system: String { UIDevice.current.systemVersion }

    static var build: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let number = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(number))"
    }

    /// `iPhone17,1` 같은 식별자. 마케팅 이름보다 이쪽이 기종을 정확히 가른다.
    private static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
