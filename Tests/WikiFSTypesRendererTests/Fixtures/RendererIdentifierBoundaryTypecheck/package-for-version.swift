import WikiFSTypes

let packageID = RendererPackageID(rawValue: "org.example.viewer")!
let registrationID = RendererRegistrationID(rawValue: "viewer")!
_ = RendererReference(packageID: packageID, version: packageID, registrationID: registrationID)
