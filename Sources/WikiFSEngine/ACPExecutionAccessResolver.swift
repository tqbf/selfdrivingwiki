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
    private static let fullAccessValue = "bypassPermissions"

    static func configuration(
        for access: AgentExecutionAccess,
        options: [SessionConfigOption]
    ) -> ACPConfigOptionApplication? {
        guard access == .fullAccess,
              let modeOption = options.first(where: { $0.id.value == modeConfigID }),
              case .select(let select) = modeOption.kind,
              select.currentValue.value != fullAccessValue,
              ACPModelSelectionResolver.configOptionValues(from: select.options).contains(fullAccessValue)
        else {
            return nil
        }

        return ACPConfigOptionApplication(configID: modeConfigID, value: fullAccessValue)
    }
}
#endif
