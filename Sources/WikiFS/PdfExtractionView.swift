import SwiftUI
import WikiFSEngine
import WikiFSCore
import WikiFSEngine

/// The local pdf2md output surface, shown above `AgentActivityView` in the
/// ingest sheet when the source is a PDF.
///
/// PDFs are converted to Markdown by the bundled `pdf2md`/docling subprocess
/// *before* the agent runs. That needs a one-time ~2 GB download (docling, the
/// granite model, torch). This view owns that lifecycle: it probes readiness on
/// appear, warns and offers a visible download when the dependencies are
/// missing, streams the download progress, and once ready shows the live
/// conversion log (`launcher.extractionLog`).
struct PdfExtractionView: View {
    @Bindable var launcher: AgentLauncher
    /// Whether the source being ingested is a PDF. When false the whole section is
    /// greyed out — the source (e.g. Markdown) is sent to the agent as-is and there
    /// is nothing to extract.
    let isPdf: Bool
    @State private var model = PdfExtractionModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("PDF Extraction", systemImage: "doc.viewfinder")
                .font(.subheadline)
                .fontWeight(.medium)
            if isPdf {
                content
            } else {
                notApplicable
            }
        }
        .opacity(isPdf ? 1 : 0.5)
        .task { if isPdf { await model.check() } }
    }

    private var notApplicable: some View {
        Text("Source isn’t a PDF — it’s sent to the agent as-is, so there’s nothing to extract.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking local PDF extraction dependencies…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .needsDownload:
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Local PDF extraction isn’t set up. Converting PDFs on-device needs a one-time ~2 GB download (docling, the granite model, torch). Until then, the PDF is sent to the agent as-is.",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Download Dependencies (~2 GB)") {
                    Task { await model.download() }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))

        case .downloading:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Downloading ~2 GB — this can take several minutes…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                logBox(model.downloadLog.isEmpty ? "Starting download…" : model.downloadLog,
                       isPlaceholder: model.downloadLog.isEmpty)
            }

        case .ready:
            VStack(alignment: .leading, spacing: 6) {
                if launcher.isExtracting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(launcher.extractionPID.map { "Converting… (pid \($0))" } ?? "Converting…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                logBox(launcher.extractionLog.isEmpty
                       ? "Dependencies ready. pdf2md output appears here when you run the ingest."
                       : launcher.extractionLog,
                       isPlaceholder: launcher.extractionLog.isEmpty)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry Download") {
                    Task { await model.download() }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func logBox(_ text: String, isPlaceholder: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(isPlaceholder ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Color.clear.frame(height: 1).id(Self.bottomAnchor)
            }
            .onChange(of: text) {
                withAnimation(.linear(duration: 0.12)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
        .frame(height: 72)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private static let bottomAnchor = "pdf-extraction-bottom"
}

/// Owns the dependency-readiness lifecycle for `PdfExtractionView`. Kept as a
/// `@MainActor @Observable` reference type so the streaming download progress can
/// be funneled back from the subprocess's background pipe through an
/// `AsyncStream` (a `Sendable` boundary) without capturing the view's state.
@MainActor
@Observable
final class PdfExtractionModel {
    enum Phase: Equatable {
        case checking
        case needsDownload
        case downloading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .checking
    private(set) var downloadLog = ""

    func check() async {
        // Don't re-probe once we've moved past the initial check (e.g. a finished
        // download already flipped us to `.ready`).
        guard phase == .checking else { return }
        // Two independent halves: uv packages cached AND the granite model weights
        // on disk. Both must be present or the first convert would stall on a
        // hidden download.
        let packages = await PdfExtractionService.probeReady()
        let weights = PdfExtractionService.modelWeightsPresent()
        phase = (packages && weights) ? .ready : .needsDownload
    }

    func download() async {
        downloadLog = ""
        phase = .downloading

        let (stream, continuation) = AsyncStream<String>.makeStream()
        let pump = Task { @MainActor in
            for await chunk in stream { appendProgress(chunk) }
        }

        do {
            try await PdfExtractionService.preDownload { chunk in
                continuation.yield(chunk)
            }
            continuation.finish()
            await pump.value
            phase = .ready
        } catch {
            continuation.finish()
            await pump.value
            phase = .failed(error.localizedDescription)
        }
    }

    private func appendProgress(_ chunk: String) {
        // uv redraws progress in place with carriage returns; turn them into
        // newlines so the scrolling log advances instead of overwriting a line
        // the ScrollView never repaints.
        downloadLog += chunk.replacingOccurrences(of: "\r", with: "\n")
        if downloadLog.count > 8_000 {
            downloadLog = "…\n" + downloadLog.suffix(8_000)
        }
    }
}
