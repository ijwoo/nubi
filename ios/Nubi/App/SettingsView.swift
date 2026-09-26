import EventKit
import SwiftUI
import UIKit

/// 설정. 자주 건드리는 것부터 놓습니다.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let onChange: () -> Void

    @State private var key = ""
    @State private var savedKey = Secrets.masked
    @State private var eventAuth = auth(.event)
    @State private var reminderAuth = auth(.reminder)
    @State private var log = ""
    @State private var copied = false
    @State private var showDiagnostics = false
    @State private var confirmClear = false
    @State private var keySaved = false

    var body: some View {
        NavigationStack {
            List {
                permissions
                model
                conversation
                diagnostics
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("완료") { dismiss() }.font(.body.weight(.semibold))
                }
            }
        }
    }

    private var permissions: some View {
        Section {
            LabeledContent("일정", value: eventAuth)
            LabeledContent("미리알림", value: reminderAuth)
            LabeledContent("위치", value: Places.isAllowed ? "허용" : "꺼짐")
            if !Places.isAllowed {
                Button("위치 허용") {
                    Task {
                        await Places.refreshLocation()
                        refresh()
                    }
                }
            }
            if Events.canReadEvents && Events.canWriteReminders {
                Text("일정과 미리알림 권한이 다 있습니다").font(.caption).foregroundStyle(.secondary)
            } else if isDenied {
                Button("설정 앱에서 바꾸기") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            } else {
                Button("권한 요청") {
                    Task {
                        _ = await Events.requestAll()
                        refresh()
                    }
                }
            }
        } header: {
            Text("권한")
        } footer: {
            Text("잠금화면 버튼은 여기서 허용한 뒤에야 일정을 읽습니다. 확장은 권한을 물을 수 없습니다.")
        }
    }

    private var model: some View {
        Section {
            LabeledContent("저장된 키", value: savedKey)
            SecureField("sk-ant-…", text: $key)
            Button(keySaved ? "저장됨" : "저장") {
                Secrets.apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                key = ""
                savedKey = Secrets.masked
                keySaved = true
                Haptic.done()
                onChange()
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    keySaved = false
                }
            }
            .disabled(key.isEmpty)
            LabeledContent("모델", value: Model.id)
        } header: {
            Text("모델")
        } footer: {
            Text("일정과 미리알림에는 필요 없습니다. 그 밖의 질문에만 씁니다. 저장소에도 앱 파일에도 들어가지 않습니다.")
        }
    }

    private var conversation: some View {
        Section("대화") {
            Button("기록 지우기", role: .destructive) { confirmClear = true }
                .confirmationDialog("대화를 전부 지울까요", isPresented: $confirmClear) {
                    Button("지우기", role: .destructive) {
                        Thread.clear()
                        Task { await LiveAnswer.welcome() }
                        onChange()
                    }
                } message: {
                    Text("되돌릴 수 없습니다.")
                }
        }
    }

    private var diagnostics: some View {
        Section {
            DisclosureGroup("진단 기록", isExpanded: $showDiagnostics) {
                Text(log.isEmpty ? "(비어 있음)" : log)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Button(copied ? "복사됨" : "전체 복사") {
                    UIPasteboard.general.string = report
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                Button("기록 지우기", role: .destructive) {
                    NubiLog.clear()
                    log = NubiLog.read()
                }
            }
            .onChange(of: showDiagnostics) { _, now in if now { log = NubiLog.read() } }
        } header: {
            Text("진단")
        } footer: {
            Text("\(Env.build) · \(Env.device) · iOS \(Env.system)")
        }
    }

    /// 기록만 보내면 어느 빌드에서 난 일인지 알 수 없습니다. 환경이 같이 갑니다.
    private var report: String {
        """
        빌드: \(Env.build)
        기기: \(Env.device)
        iOS: \(Env.system)

        \(log)
        """
    }

    private var isDenied: Bool {
        EKEventStore.authorizationStatus(for: .event) == .denied
            || EKEventStore.authorizationStatus(for: .reminder) == .denied
    }

    private func refresh() {
        eventAuth = Self.auth(.event)
        reminderAuth = Self.auth(.reminder)
        savedKey = Secrets.masked
        onChange()
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
