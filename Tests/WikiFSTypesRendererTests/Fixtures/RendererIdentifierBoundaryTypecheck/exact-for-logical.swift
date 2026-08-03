import WikiFSTypes

let packageID = RendererPackageID(rawValue: "org.example.viewer")!
let version = RendererPackageVersion(rawValue: "1.2.3")!
let registrationID = RendererRegistrationID(rawValue: "viewer")!
let exact = RendererReference(packageID: packageID, version: version, registrationID: registrationID)
_ = RendererPreferenceReference.logical(exact)
