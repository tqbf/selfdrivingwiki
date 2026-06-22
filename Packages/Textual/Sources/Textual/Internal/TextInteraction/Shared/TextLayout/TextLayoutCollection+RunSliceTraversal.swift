#if TEXTUAL_ENABLE_TEXT_SELECTION
  import Foundation

  extension TextLayoutCollection {
    func indexPathsForRunSlices(in range: TextRange) -> some Sequence<IndexPath> {
      IndexPathSequence(
        range: range,
        next: self.indexPathForRunSlice(after:),
        previous: self.indexPathForRunSlice(before:)
      )
    }
  }

  extension TextLayoutCollection {
    fileprivate func indexPathForRunSlice(after indexPath: IndexPath) -> IndexPath? {
      let layout = layouts[indexPath.layout]
      let line = layout.lines[indexPath.line]
      let run = line.runs[indexPath.run]

      if indexPath.runSlice + 1 < run.slices.count {
        return IndexPath(
          runSlice: indexPath.runSlice + 1,
          run: indexPath.run,
          line: indexPath.line,
          layout: indexPath.layout
        )
      }

      if indexPath.run + 1 < line.runs.count {
        return IndexPath(
          run: indexPath.run + 1,
          line: indexPath.line,
          layout: indexPath.layout
        )
      }

      if indexPath.line + 1 < layout.lines.count {
        return IndexPath(
          line: indexPath.line + 1,
          layout: indexPath.layout
        )
      }

      if indexPath.layout + 1 < layouts.count {
        return IndexPath(layout: indexPath.layout + 1)
      }

      return nil
    }

    fileprivate func indexPathForRunSlice(before indexPath: IndexPath) -> IndexPath? {
      if indexPath.runSlice > 0 {
        return IndexPath(
          runSlice: indexPath.runSlice - 1,
          run: indexPath.run,
          line: indexPath.line,
          layout: indexPath.layout
        )
      }

      if indexPath.run > 0 {
        let previousRun = layouts[indexPath.layout].lines[indexPath.line].runs[indexPath.run - 1]
        return IndexPath(
          runSlice: previousRun.slices.endIndex - 1,
          run: indexPath.run - 1,
          line: indexPath.line,
          layout: indexPath.layout
        )
      }

      if indexPath.line > 0 {
        let previousLine = layouts[indexPath.layout].lines[indexPath.line - 1]
        let lastRunIndex = previousLine.runs.endIndex - 1
        let lastRun = previousLine.runs[lastRunIndex]

        return IndexPath(
          runSlice: lastRun.slices.endIndex - 1,
          run: lastRunIndex,
          line: indexPath.line - 1,
          layout: indexPath.layout
        )
      }

      if indexPath.layout > 0 {
        let previousLayout = layouts[indexPath.layout - 1]
        let lastLineIndex = previousLayout.lines.endIndex - 1
        let lastLine = previousLayout.lines[lastLineIndex]
        let lastRunIndex = lastLine.runs.endIndex - 1
        let lastRun = lastLine.runs[lastRunIndex]
        return IndexPath(
          runSlice: lastRun.slices.endIndex - 1,
          run: lastRunIndex,
          line: lastLineIndex,
          layout: indexPath.layout - 1
        )
      }

      return nil
    }
  }

  // MARK: Link ranges

  extension TextLayoutCollection {
    /// The URL carried by the run at a run-slice index path, or `nil`.
    ///
    /// `TextRun.url` is uniform across all slices of a run (AttributedString
    /// runs split on attribute changes, and `.link` is one of those attributes),
    /// so a run-slice's URL is its run's URL.
    fileprivate func url(at indexPath: IndexPath) -> URL? {
      guard layouts.indices.contains(indexPath.layout) else { return nil }
      let layout = layouts[indexPath.layout]
      guard layout.lines.indices.contains(indexPath.line) else { return nil }
      let line = layout.lines[indexPath.line]
      guard line.runs.indices.contains(indexPath.run) else { return nil }
      return line.runs[indexPath.run].url
    }

    /// The range of the whole link containing `position`, or `nil` if the
    /// position is not on a link.
    ///
    /// Expands outward from the position's run slice over adjacent slices whose
    /// run shares the same URL, bounded to a single layout so two same-URL links
    /// in neighboring paragraphs never merge into one selection.
    @available(macOS 10.0, *)
    @available(iOS, unavailable)
    @available(visionOS, unavailable)
    func linkRange(for position: TextPosition) -> TextRange? {
      let indexPath = position.indexPath
      guard layouts.indices.contains(indexPath.layout) else { return nil }
      guard let targetURL = url(at: indexPath) else { return nil }

      var startIndexPath = indexPath
      while let previous = indexPathForRunSlice(before: startIndexPath),
        previous.layout == indexPath.layout,
        url(at: previous) == targetURL
      {
        startIndexPath = previous
      }

      var endIndexPath = indexPath
      while let next = indexPathForRunSlice(after: endIndexPath),
        next.layout == indexPath.layout,
        url(at: next) == targetURL
      {
        endIndexPath = next
      }

      return TextRange(
        start: TextPosition(indexPath: startIndexPath, affinity: .downstream),
        end: TextPosition(indexPath: endIndexPath, affinity: .upstream)
      )
    }
  }
#endif
