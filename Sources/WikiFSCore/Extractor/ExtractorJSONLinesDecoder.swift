import Foundation
import WikiFSTypes

public enum ExtractorJSONLinesError: Error, Equatable, Sendable {
    case frameTooLarge
    case malformedUTF8
    case malformedJSON
    case incompleteFinalFrame
    case outputAfterTerminal
}

/// Incremental bounded JSON Lines decoder for extractor standard output.
public struct ExtractorJSONLinesDecoder: Sendable {
    private let maximumFrameByteCount: Int
    private var buffer = Data()
    private var terminated = false

    public init(maximumFrameByteCount: Int = ExtractorHostLimits.maximumFrameByteCount) {
        self.maximumFrameByteCount = maximumFrameByteCount
    }

    public mutating func append(_ data: Data) throws -> [ExtractorProtocolFrame] {
        guard terminated == false else { throw ExtractorJSONLinesError.outputAfterTerminal }
        buffer.append(data)
        guard buffer.count <= maximumFrameByteCount || buffer.contains(0x0A) else {
            throw ExtractorJSONLinesError.frameTooLarge
        }
        var frames: [ExtractorProtocolFrame] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard line.count <= maximumFrameByteCount else { throw ExtractorJSONLinesError.frameTooLarge }
            guard line.isEmpty == false else { throw ExtractorJSONLinesError.malformedJSON }
            guard String(data: line, encoding: .utf8) != nil else { throw ExtractorJSONLinesError.malformedUTF8 }
            let frame: ExtractorProtocolFrame
            do {
                frame = try JSONDecoder().decode(ExtractorProtocolFrame.self, from: line)
            } catch {
                throw ExtractorJSONLinesError.malformedJSON
            }
            frames.append(frame)
            if frame.isTerminal {
                terminated = true
                guard buffer.isEmpty else { throw ExtractorJSONLinesError.outputAfterTerminal }
                break
            }
        }
        guard buffer.count <= maximumFrameByteCount else { throw ExtractorJSONLinesError.frameTooLarge }
        return frames
    }

    public mutating func finish() throws {
        guard buffer.isEmpty else { throw ExtractorJSONLinesError.incompleteFinalFrame }
    }
}
