import WikiFSCore

func readAccessCannotEscape(_ service: WikiReadService) async throws {
    let _: WikiReadAccess = try await service.asyncRead { access in access }
}

func readAccessCannotWrite(_ service: WikiReadService) async throws {
    try await service.asyncRead { access in
        _ = try access.createPage(title: "Forbidden")
    }
}

func readAccessCannotExposeStore(_ service: WikiReadService) async throws {
    try await service.asyncRead { access in
        _ = access.store
    }
}

func readAccessCannotBeCaptured(_ service: WikiReadService) async throws {
    var escaped: WikiReadAccess?
    try await service.asyncRead { access in
        escaped = access
    }
    _ = escaped
}
