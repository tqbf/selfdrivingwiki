#if os(macOS)
import Cordis
import WikiFSEngine

public enum WikiCtlPluginCatalog {
    public static func build(
        makeTantivyRuntime: @escaping SearchRuntimeFactory.Factory = SearchRuntimeCompositionFactory.defaultRuntimeFactory
    ) throws -> PluginCatalog {
        try CLIPluginCatalog.build(makeTantivyRuntime: makeTantivyRuntime)
    }
}
#endif
