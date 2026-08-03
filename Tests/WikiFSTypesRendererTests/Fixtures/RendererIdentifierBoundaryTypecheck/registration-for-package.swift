import WikiFSTypes

let registrationID = RendererRegistrationID(rawValue: "viewer")!
let version = RendererPackageVersion(rawValue: "1.2.3")!
_ = RendererReference(packageID: registrationID, version: version, registrationID: registrationID)
