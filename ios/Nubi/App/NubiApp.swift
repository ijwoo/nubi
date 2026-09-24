import EventKit
import SwiftUI
import UIKit

@main
struct NubiApp: App {
    var body: some Scene {
        WindowGroup { HomeView() }
    }
}

/// 물어보고 답을 읽는 화면.
///
/// 잠금화면 버튼과 음성이 주 입구이고 이 화면은 그것들이 안 될 때의 출구입니다 —
/// 권한을 주고, 키를 넣고, 무엇이 일어났는지 기록으로 확인하는 자리.
struct HomeView: View {
    @State private var utterance = ""
    @State private var answer: NubiAnswer?
    @State private var busy = false
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("내일 일정 뭐야", text: $utterance)
                            .focused($typing)
                            .submitLabel(.send)
                            .onSubmit { ask() }
                        if busy { ProgressView() }
                    }
                    ForEach(Samples.all, id: \.self) { sample in
                        Button(sample) {
                            utterance = sample
                            ask()
                        }
                        .font(.callout)
                    }
                } header: {
                    Text("묻기")
                } footer: {
                    Text("일정과 미리알림은 폰 안에서 끝납니다. 그 밖의 질문만 모델에 갑니다.")
                }

                if let answer {
                    Section("답") {
                        Text(answer.headline)
                            .font(.headline)
                            .foregroundStyle(answer.failed ? .red : .primary)
                        if !answer.detail.isEmpty {
                            Text(answer.detail)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                }

                NavigationLink("설정과 기록") { SettingsView() }
            }
            .navigationTitle("누비")
        }
    }

    private func ask() {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        typing = false
        busy = true
        Task {
            let result = await Nubi.respond(to: text)
            answer = result
            LiveAnswer.show(asked: text, result)
            busy = false
        }
    }
}

enum Samples {
    static let all = ["오늘 일정", "내일 일정 뭐야", "우유 사기 미리알림"]
}

/// 권한, 키, 기록. 셋 다 "안 될 때 여는 자리" 입니다.
struct SettingsView: View {
    @State private var key = ""
    @State private var saved = Secrets.masked
    @State private var eventAuth = auth(.event)
    @State private var reminderAuth = auth(.reminder)
    @State private var log = NubiLog.read()
    @State private var copied = false

    var body: some View {
        List {
            Section("환경") {
                LabeledContent("빌드", value: Env.build)
                LabeledContent("기기", value: Env.device)
                LabeledContent("iOS", value: Env.system)
            }

            Section {
                LabeledContent("일정", value: eventAuth)
                LabeledContent("미리알림", value: reminderAuth)
                Button("권한 요청") {
                    Task {
                        _ = await Events.requestAll()
                        refresh()
                    }
                }
            } header: {
                Text("권한")
            } footer: {
                Text("잠금화면 버튼은 여기서 허용한 뒤에야 일정을 읽습니다. 확장은 권한을 물을 수 없습니다.")
            }

            Section {
                LabeledContent("저장된 키", value: saved)
                SecureField("sk-ant-…", text: $key)
                Button("저장") {
                    Secrets.apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    key = ""
                    saved = Secrets.masked
                }
                .disabled(key.isEmpty)
            } header: {
                Text("모델 키")
            } footer: {
                Text("일정과 미리알림에는 필요 없습니다. 그 밖의 질문에만 씁니다. 키체인에 저장되고 저장소에는 들어가지 않습니다.")
            }

            Section {
                Text(log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                HStack {
                    Text("기록")
                    Spacer()
                    Button(copied ? "복사됨" : "전체 복사") {
                        UIPasteboard.general.string = report
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    }
                    .font(.caption).textCase(nil)
                }
            }

            Section {
                Button("새로고침") { refresh() }
                Button("잠금화면에서 내리기") { LiveAnswer.dismissAll() }
                Button("기록 지우기", role: .destructive) {
                    NubiLog.clear()
                    log = NubiLog.read()
                }
            }
        }
        .navigationTitle("설정과 기록")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 기록만 보내면 어느 빌드에서 난 일인지 알 수 없습니다. 빌드 2 를 올려두고
    /// 빌드 1 의 기록을 읽느라 한 번 헛돌았습니다 — 환경이 기록과 같이 가야 합니다.
    private var report: String {
        """
        빌드: \(Env.build)
        기기: \(Env.device)
        iOS: \(Env.system)

        \(log)
        """
    }

    private func refresh() {
        eventAuth = Self.auth(.event)
        reminderAuth = Self.auth(.reminder)
        saved = Secrets.masked
        log = NubiLog.read()
    }

    private static func auth(_ type: EKEntityType) -> String {
        switch EKEventStore.authorizationStatus(for: type) {
        case .notDetermined: "아직 묻지 않음"
        case .restricted: "제한됨"
        case .denied: "거부됨"
        case .fullAccess: "허용"
        case .writeOnly: "쓰기만"
        @unknown default: "알 수 없음"
        }
    }
}

/// 기록과 같이 보내야 하는 것들.
enum Env {
    static var system: String { UIDevice.current.systemVersion }

    static var build: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let number = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(number))"
    }

    /// `iPhone19,2` 같은 식별자. 마케팅 이름보다 기종을 정확히 가릅니다.
    static var device: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
