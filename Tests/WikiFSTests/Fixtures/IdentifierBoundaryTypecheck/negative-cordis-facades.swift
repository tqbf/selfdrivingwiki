import WikiFSEngine

func profileMemberIsUnavailable(_ services: AppServices) {
    _ = services.profile
}

func contextMemberIsUnavailable(_ services: AppServices) {
    _ = services.context
}

func requireIsUnavailable(_ lifetime: ProfileLifetime) async throws {
    _ = try await lifetime.require("service")
}

func findIsUnavailable(_ lifetime: ProfileLifetime) async throws {
    _ = try await lifetime.find("service")
}

func supplyIsUnavailable(_ lifetime: ProfileLifetime) async throws {
    _ = try await lifetime.supply("service", value: "value")
}
