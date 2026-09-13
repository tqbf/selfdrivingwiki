// pattern: Value Observer

import SwiftUI
import WikiFSCore

/// Sidebar invalidation shared by the page, source, and chat producers.
/// The right sidebar renders the outline from the last accepted registration,
/// so it re-renders only when a NEW registration arrives. Every input the
/// outline depends on — page/source markdown edits, caret moves across
/// heading regions, chat transcript growth and rehydration — flows into the
/// producer's derived `InspectorOutlinePayload`, so observing that one value
/// covers them all. When the payload changes, fire the producer's
/// re-registration closure, which reads the current payload and publishes a
/// fresh registration.
@MainActor
struct SidebarRegistrationRefresh: ViewModifier {
    let outlinePayload: InspectorOutlinePayload
    let onRefresh: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: outlinePayload) { _, _ in onRefresh() }
    }
}
