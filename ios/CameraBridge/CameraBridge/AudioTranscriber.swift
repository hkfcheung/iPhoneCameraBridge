import Foundation
import Speech
import AVFoundation

/// Transcribes 16-bit mono PCM at 16 kHz (as sent by the ESP32) using Apple's
/// on-device Speech framework. One-shot: pass the full buffer, get the string.
actor AudioTranscriber {

    private let recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var authorized: Bool?

    private func ensureAuthorized() async -> Bool {
        if let a = authorized { return a }
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        let ok = (status == .authorized)
        authorized = ok
        if !ok { print("[Transcriber] not authorized: \(status.rawValue)") }
        return ok
    }

    func transcribe(pcm: Data, sampleRate: Double) async -> String? {
        guard await ensureAuthorized() else { return nil }
        guard let recognizer, recognizer.isAvailable else {
            print("[Transcriber] recognizer unavailable")
            return nil
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: true) else {
            return nil
        }
        let frameCount = AVAudioFrameCount(pcm.count / 2)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        pcm.withUnsafeBytes { raw in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: Int16.self),
                  let dst = buffer.int16ChannelData?.pointee else { return }
            dst.update(from: src, count: Int(frameCount))
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        if #available(iOS 13.0, *) {
            request.requiresOnDeviceRecognition = true
        }
        request.append(buffer)
        request.endAudio()

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            var finished = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                if finished { return }
                if let error = error {
                    finished = true
                    print("[Transcriber] error: \(error.localizedDescription)")
                    cont.resume(returning: nil)
                    return
                }
                if let result = result, result.isFinal {
                    finished = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                }
            }
            _ = task  // keep reference alive until callback fires
        }
    }
}
