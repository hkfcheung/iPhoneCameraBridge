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
        logLevels(pcm: pcm)
        dumpWAV(pcm: pcm, sampleRate: sampleRate)

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

    // MARK: - Diagnostics

    /// Log peak amplitude + RMS so we can tell if the PCM is silent / clipped.
    private nonisolated func logLevels(pcm: Data) {
        let count = pcm.count / 2
        guard count > 0 else {
            print("[Transcriber] PCM empty")
            return
        }
        var peak: Int32 = 0
        var sumSq: Double = 0
        pcm.withUnsafeBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<count {
                let s = Int32(p[i])
                let a = s < 0 ? -s : s
                if a > peak { peak = a }
                sumSq += Double(s) * Double(s)
            }
        }
        let rms = sqrt(sumSq / Double(count))
        let peakDb = peak == 0 ? -120.0 : 20.0 * log10(Double(peak) / 32768.0)
        let rmsDb  = rms  == 0 ? -120.0 : 20.0 * log10(rms / 32768.0)
        print(String(format: "[Transcriber] PCM %d frames  peak=%d (%.1f dBFS)  rms=%.0f (%.1f dBFS)",
                     count, peak, peakDb, rms, rmsDb))
    }

    /// Write the received PCM to Documents/last_capture.wav so we can listen to
    /// it via Xcode → Window → Devices & Simulators → Download Container.
    private nonisolated func dumpWAV(pcm: Data, sampleRate: Double) {
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("last_capture.wav")

        var header = Data()
        let numSamples = UInt32(pcm.count / 2)
        let byteRate   = UInt32(sampleRate) * 1 * 2
        let dataSize   = numSamples * 2
        let chunkSize  = 36 + dataSize

        header.append("RIFF".data(using: .ascii)!)
        header.append(UInt32(chunkSize).littleEndianData)
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(UInt32(16).littleEndianData)           // PCM fmt chunk size
        header.append(UInt16(1).littleEndianData)            // PCM format
        header.append(UInt16(1).littleEndianData)            // channels
        header.append(UInt32(sampleRate).littleEndianData)   // sample rate
        header.append(byteRate.littleEndianData)
        header.append(UInt16(2).littleEndianData)            // block align
        header.append(UInt16(16).littleEndianData)           // bits per sample
        header.append("data".data(using: .ascii)!)
        header.append(dataSize.littleEndianData)

        var out = header
        out.append(pcm)
        do {
            try out.write(to: url)
            print("[Transcriber] wrote \(out.count) bytes to \(url.lastPathComponent)")
        } catch {
            print("[Transcriber] wav write failed: \(error.localizedDescription)")
        }
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var v = self.littleEndian
        return Data(bytes: &v, count: MemoryLayout<Self>.size)
    }
}
