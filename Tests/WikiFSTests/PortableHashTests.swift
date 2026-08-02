import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

struct PortableHashTests {
    @Test func portableHashDelegatesToRendererSHA256() {
        let data = Data("abc".utf8)
        #expect(portableSHA256(data) == RendererSHA256.digest(data).bytes)
    }
}
