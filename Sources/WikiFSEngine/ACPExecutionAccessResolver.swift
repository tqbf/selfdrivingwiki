// pattern: Functional Core

#if os(macOS)
import ACPModel
import WikiFSCore

/// A validated ACP session config-option write.
struct ACPConfigOptionApplication: Equatable, Sendable {
    let configID: String
    let value: String
}

/// Resolves the provider-advertised mode needed for application-authorized
/// mutation workflows. This never guesses at provider-specific config values.
enum ACPExecutionAccessResolver {
    private static let modeConfigID = "mode"
    /// Exact provider-advertised values that authorize the agent's full-access
    /// session mode. Providers must advertise one of these IDs; mode labels are
    /// presentation text and are deliberately never used for authorization.
    private static let fullAccessValues = ["bypassPermissions", "agent-full-access"]

    static func configuration(
        for access: AgentExecutionAccess,
        options: [SessionConfigOption]
    ) -> ACPConfigOptionApplication? {
        guard access == .fullAccess,
              let modeOption = options.first(where: { $0.id.value == modeConfigID }),
              case .select(let select) = modeOption.kind
        else {
            return nil
        }

        let advertisedValues = Set(ACPModelSelectionResolver.configOptionValues(from: select.options))
        guard let fullAccessValue = fullAccessValues.first(where: { advertisedValues.contains($0) }),
              select.currentValue.value != fullAccessValue
        else {
            return nil
        }

        return ACPConfigOptionApplication(configID: modeConfigID, value: fullAccessValue)
    }
}
#endif
