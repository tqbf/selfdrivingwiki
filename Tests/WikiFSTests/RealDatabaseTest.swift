import Testing
import Foundation
@testable import WikiFSCore

struct RealDatabaseTest {
    @Test func testRealHallucinations() throws {
        let pagesDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/CloudStorage/SelfDrivingWiki-MyWiki/pages/by-title")
        
        let fm = FileManager.default
        guard fm.fileExists(atPath: pagesDir.path) else { return }
        let files = try fm.contentsOfDirectory(at: pagesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            
        var totalFixes = 0
        
        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            let fixed = WikiLinkFixer.applyFixes(to: content)
            
            if fixed != content {
                print("\n--- Fixed file: \(file.lastPathComponent) ---")
                totalFixes += 1
                
                let origLines = content.components(separatedBy: .newlines)
                let fixedLines = fixed.components(separatedBy: .newlines)
                
                for i in 0..<min(origLines.count, fixedLines.count) {
                    if origLines[i] != fixedLines[i] {
                        print("- \(origLines[i])")
                        print("+ \(fixedLines[i])")
                    }
                }
            }
        }
        
        print("\nTotal files modified by validator: \(totalFixes)")
        #expect(true)
    }
}
