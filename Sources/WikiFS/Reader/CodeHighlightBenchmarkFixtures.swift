// pattern: Functional Core

import Foundation

/// Deterministic source fixtures for the ordinary-fence release probe.
/// The maximum Scala fixture is syntactically complete at the accepted byte
/// limit and contains nested expressions, generics, interpolation, and
/// collection transformations.
enum CodeHighlightBenchmarkFixtures {
    static let nestedScalaMaximumID = "nested-scala-maximum-v1"

    static func source(language: CodeLanguage, bytes: Int) -> String {
        switch language {
        case .scala:
            return nestedScalaMaximum(bytes: bytes)
        case .java:
            return exactBytes(bytes, repeatedUnit: "class Example { int value = 12345; } // fixture\n")
        case .html:
            return exactBytes(bytes, repeatedUnit: "<div class=\"example\">fixture 12345</div>\n")
        case .swift:
            return exactBytes(bytes, repeatedUnit: "let value = 12345 // fixture\n")
        case .json:
            return exactBytes(bytes, repeatedUnit: "{\"value\": 12345, \"fixture\": true}\n")
        }
    }

    static func nestedScalaMaximum(
        bytes: Int = CodeHighlightingPolicy.maximumHighlightedSourceBytes
    ) -> String {
        precondition(bytes >= 2, "nested Scala fixture needs space for a closing comment")

        var units: [String] = []
        var byteCount = 0
        var index = 0
        while true {
            let unit = nestedScalaUnit(index: index)
            let nextCount = byteCount + unit.utf8.count
            guard nextCount <= bytes - 2 else { break }
            units.append(unit)
            byteCount = nextCount
            index += 1
        }

        let commentBytes = bytes - byteCount
        return units.joined() + "//" + String(repeating: "x", count: commentBytes - 2)
    }

    static func representativeFencedBlocks() -> String {
        let fixtures: [(CodeLanguage, String)] = [
            (.java, "class Example { int value = 1; }"),
            (.scala, nestedScalaUnit(index: 0)),
            (.html, "<div class=\"example\">value</div>"),
            (.swift, "let value = 1"),
            (.json, "{\"value\": 1}"),
        ]
        let fences = fixtures.map { language, source in
            "~~~\(language.rawValue)\n\(source)\n~~~"
        }
        return Array(repeating: fences, count: 20).flatMap { $0 }.joined(separator: "\n\n")
    }

    private static func nestedScalaUnit(index: Int) -> String {
        """
        object NestedFixture\(index) {
          final case class Box[A](value: A) {
            def map[B](transform: A => B): Box[B] = Box(transform(value))
          }
          def render(seed: Int): String = {
            val rows: Vector[Box[Map[String, List[Int]]]] = Vector.tabulate(8) { outer =>
              Box(Map(s"key-$seed-$outer" -> List.tabulate(4) { inner => (seed + outer) * (inner + 1) }))
            }
            rows.map { box =>
              box.map(_.values.flatten.map { value => s"${value * 2}:${value + seed}" }.mkString("[", ",", "]")).value
            }.mkString("{", ";", "}")
          }
        }

        """
    }

    private static func exactBytes(_ bytes: Int, repeatedUnit: String) -> String {
        precondition(bytes >= 0, "fixture byte count must be nonnegative")
        let repeated = String(repeating: repeatedUnit, count: bytes / repeatedUnit.utf8.count + 1)
        let end = repeated.utf8.index(repeated.utf8.startIndex, offsetBy: bytes)
        return String(decoding: repeated.utf8[..<end], as: UTF8.self)
    }
}
