import WikiFSTypes

let packageID = RendererPackageID(rawValue: "org.example.viewer")!
let registrationID = RendererRegistrationID(rawValue: "viewer")!
let logical = LogicalRendererReference(packageID: packageID, registrationID: registrationID)
_ = RendererPreferenceReference.exact(logical)
