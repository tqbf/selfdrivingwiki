#if os(macOS)
import AVFoundation
import Foundation
import Speech

/// The macOS 26 on-device speech implementation over `SpeechAnalyzer` and
/// `SpeechTranscriber` file input. No microphone access and no legacy
/// `SFSpeechRecognizer` authorization call: file analysis asks for neither,
/// and permission behavior is confirmed in the signed app and daemon, not
/// assumed here.
///
/// Cancellation is cooperative: the analyzer is cancelled explicitly on
/// task cancellation, and cancellation is rechecked after Apple APIs that
/// can return normally during shutdown.
public struct SystemSpeechTranscriber: SpeechTranscribing {
    public init() {}

    // MARK: - Readiness

    public func readiness(localeID: String) async -> SpeechReadiness {
        guard SpeechTranscriber.isAvailable else {
            return .needsSetup(.speechUnavailable)
        }
        let requested = Locale(identifier: localeID)
        let supported = await SpeechTranscriber.supportedLocales
        guard Self.matches(requested, in: supported) else {
            return .needsSetup(.localeUnsupported)
        }
        let installed = await SpeechTranscriber.installedLocales
        guard Self.matches(requested, in: installed) else {
            return .needsSetup(.assetsNotInstalled)
        }
        return .ready
    }

    /// Exact identifier match first, then language-region fallback matching
    /// (a request for `en-US` may resolve to an installed `en_US` or the
    /// base language when the engine lists it).
    static func matches(_ requested: Locale, in candidates: [Locale]) -> Bool {
        if candidates.contains(requested) { return true }
        let requestedID = requested.identifier(.bcp47)
        for candidate in candidates {
            let candidateID = candidate.identifier(.bcp47)
            if candidateID.caseInsensitiveCompare(requestedID) == .orderedSame {
                return true
            }
            if candidate.language.languageCode?.identifier
                == requested.language.languageCode?.identifier {
                return true
            }
        }
        return false
    }

    /// The best installed locale for a requested identifier, or nil.
    static func resolvedLocale(for localeID: String) async -> Locale? {
        let requested = Locale(identifier: localeID)
        let installed = await SpeechTranscriber.installedLocales
        if let exact = installed.first(where: {
            $0.identifier(.bcp47).caseInsensitiveCompare(
                requested.identifier(.bcp47)) == .orderedSame
        }) {
            return exact
        }
        return installed.first(where: {
            $0.language.languageCode?.identifier
                == requested.language.languageCode?.identifier
        })
    }

    // MARK: - Asset installation

    /// The missing-model installation. The CALLER gates this behind the
    /// explicit user confirmation; nothing here prompts.
    public func installMissingAssets(
        localeID: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechSetupGuidance.speechUnavailable
        }
        guard let locale = await Self.resolvedLocale(for: localeID) else {
            throw SpeechSetupGuidance.localeUnsupported
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription)
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]) else {
            // Nothing to install — treat as success.
            onProgress?(1)
            return
        }
        // Foundation Progress: poll fractionCompleted on a detached task so
        // the caller sees coarse install progress without KVO on the main
        // thread.
        let progressTask = Task.detached(priority: .utility) {
            var reported = 0.0
            while !Task.isCancelled {
                let fraction = min(max(request.progress.fractionCompleted, 0), 1)
                if fraction - reported >= 0.01 || fraction >= 1.0 {
                    reported = fraction
                    onProgress?(fraction)
                }
                if fraction >= 1.0 { break }
                // A cancelled poll task ends the loop via Task.isCancelled;
                // the sleep error itself is irrelevant.
                // swiftlint:disable:next silent_try_optional
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { progressTask.cancel() }
        try await request.downloadAndInstall()
        onProgress?(1)
    }

    // MARK: - Transcription

    public func transcribeFile(
        at audioURL: URL,
        localeID: String,
        deadline: ContinuousClock.Instant,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> SpeechTranscription {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechSetupGuidance.speechUnavailable
        }
        guard let locale = await Self.resolvedLocale(for: localeID) else {
            throw SpeechSetupGuidance.localeUnsupported
        }
        // Cancellation deadline guard: one task watches the clock so a hung
        // engine cannot exceed the analysis budget. The cooperative checks
        // below handle the deadline; this task exists so defer can cancel
        // it.
        let deadlineTask = Task.detached {
            let interval = deadline - .now
            if interval > .zero {
                // The deadline task is cancelled in defer; the sleep's
                // cancellation error carries no information.
                // swiftlint:disable:next silent_try_optional
                try? await Task.sleep(for: interval)
            }
        }
        defer { deadlineTask.cancel() }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            throw SpeechTranscriptionError.unreadableAudio
        }
        let durationSeconds = Self.fileDuration(audioFile)

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        do {
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        } catch is CancellationError {
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
        } catch {
            await analyzer.cancelAndFinishNow()
            throw SpeechSetupGuidance.engineSetupFailed
        }
        onProgress?(0.05)

        var transcript = ""
        do {
            for try await result in transcriber.results {
                if Task.isCancelled {
                    await analyzer.cancelAndFinishNow()
                    throw CancellationError()
                }
                if ContinuousClock.now >= deadline {
                    await analyzer.cancelAndFinishNow()
                    throw SpeechTranscriptionError.deadlineExceeded
                }
                let chunk = String(result.text.characters)
                if transcript.count + chunk.count
                    > SpeechTranscribers.maximumTranscriptCharacters {
                    await analyzer.cancelAndFinishNow()
                    throw SpeechTranscriptionError.transcriptTooLong
                }
                transcript += chunk
            }
            // Apple APIs may return normally during cancellation-driven
            // shutdown; recheck before declaring success.
            if Task.isCancelled {
                await analyzer.cancelAndFinishNow()
                throw CancellationError()
            }
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch is CancellationError {
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
        } catch let error as SpeechTranscriptionError {
            await analyzer.cancelAndFinishNow()
            throw error
        } catch {
            await analyzer.cancelAndFinishNow()
            throw SpeechSetupGuidance.engineSetupFailed
        }
        onProgress?(1)

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw SpeechTranscriptionError.emptyTranscription
        }
        return SpeechTranscription(
            text: trimmed,
            engine: SpeechTranscribers.systemEngineIdentifier,
            localeID: locale.identifier(.bcp47),
            durationSeconds: durationSeconds)
    }

    /// The analyzed audio's duration in seconds, when the file format
    /// reports a decodable length.
    static func fileDuration(_ file: AVAudioFile) -> Double? {
        let frames = file.length
        let rate = file.processingFormat.sampleRate
        guard frames > 0, rate > 0 else { return nil }
        return Double(frames) / rate
    }
}

extension Double {
    /// Progress fractions from the engine are clamped to 0...1 before they
    /// cross the seam.
    fileprivate var clampedToUnitInterval: Double {
        min(max(self, 0), 1)
    }
}

#endif
