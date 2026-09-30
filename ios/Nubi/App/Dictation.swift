import AVFoundation
import Foundation
import Speech

/// 말로 적기.
///
/// **키보드에도 마이크가 있습니다.** 그런데 그걸 쓰려면 입력줄을 눌러 키보드를
/// 띄우고, 마이크를 찾아 누르고, 말하고, 다시 보내기를 눌러야 합니다. 걸으면서
/// 할 수 있는 동작이 아닙니다.
///
/// 여기서는 한 번 눌러 말하고 한 번 더 눌러 보냅니다. 키보드가 안 떠서 화면도
/// 안 가립니다.
///
/// **기기 안에서 알아듣습니다.** 되는 기기에서는 `requiresOnDeviceRecognition`
/// 을 켭니다 — 말한 것이 밖으로 나가지 않고, 비행기 모드에서도 됩니다.
@MainActor
@Observable
final class Dictation {
    private(set) var listening = false
    private(set) var heard = ""
    private(set) var refused = ""

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var canListen: Bool { recognizer?.isAvailable ?? false }

    /// 말하기를 시작합니다. 권한이 없으면 그 자리에서 묻습니다.
    func start() async {
        guard !listening else { return }
        refused = ""
        guard await allowed() else {
            refused = "마이크나 받아쓰기 권한이 없습니다. 설정에서 허용해 주세요."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            refused = "지금은 받아쓰기를 쓸 수 없습니다."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let ask = SFSpeechAudioBufferRecognitionRequest()
            ask.shouldReportPartialResults = true
            // 기기 안에서 되면 그쪽으로. 말이 밖으로 안 나갑니다.
            if recognizer.supportsOnDeviceRecognition { ask.requiresOnDeviceRecognition = true }
            request = ask

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                ask.append(buffer)
            }
            engine.prepare()
            try engine.start()

            heard = ""
            listening = true
            task = recognizer.recognitionTask(with: ask) { [weak self] result, error in
                guard let self else { return }
                Task { @MainActor in
                    if let result { self.heard = result.bestTranscription.formattedString }
                    if error != nil || result?.isFinal == true { self.stop() }
                }
            }
        } catch {
            refused = "마이크를 열지 못했습니다."
            stop()
        }
    }

    /// 멈춥니다. 들은 말은 그대로 남습니다.
    func stop() {
        guard listening || engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func allowed() async -> Bool {
        let speech = await withCheckedContinuation { go in
            SFSpeechRecognizer.requestAuthorization { go.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await withCheckedContinuation { go in
            AVAudioApplication.requestRecordPermission { go.resume(returning: $0) }
        }
    }
}
