import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Summarizes a conversation transcript into ≤50 words of key context about
/// a person. Uses Apple Intelligence on-device LLM (iOS 26+) if available,
/// otherwise falls back to truncating the transcript.
actor ContextSummarizer {

    func summarize(transcript: String, subject: String) async -> String {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if let s = await summarizeWithFoundationModels(transcript: clean, subject: subject) {
                return enforceWordLimit(s, words: 50)
            }
        }
        #endif
        return enforceWordLimit(firstSentences(clean), words: 50)
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func summarizeWithFoundationModels(transcript: String, subject: String) async -> String? {
        let instructions = """
        You extract durable personal context to attach to a contact card.
        You are given a transcript of a spoken interaction with \(subject).
        Write a note, ≤50 words, capturing only facts worth remembering about \
        \(subject): their job, interests, relationships, plans, preferences, \
        things said about their life. Omit pleasantries, weather, small talk, \
        filler, speech artifacts, and anything said by other speakers. Third \
        person. No preamble.
        """
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: transcript)
            return response.content
        } catch {
            print("[Summarizer] FoundationModels error: \(error.localizedDescription)")
            return nil
        }
    }
    #endif

    private func firstSentences(_ text: String) -> String {
        // Rough fallback: take up to ~50 words worth.
        let words = text.split(whereSeparator: { $0.isWhitespace })
        return words.prefix(50).joined(separator: " ")
    }

    private func enforceWordLimit(_ text: String, words: Int) -> String {
        let parts = text.split(whereSeparator: { $0.isWhitespace })
        guard parts.count > words else { return text }
        return parts.prefix(words).joined(separator: " ") + "…"
    }
}
