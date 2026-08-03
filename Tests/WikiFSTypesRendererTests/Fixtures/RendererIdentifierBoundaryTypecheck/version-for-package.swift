import WikiFSTypes

let version = RendererPackageVersion(rawValue: "1.2.3")!
let registrationID = RendererRegistrationID(rawValue: "viewer")!
_ = RendererReference(packageID: version, version: version, registrationID: registrationID)
