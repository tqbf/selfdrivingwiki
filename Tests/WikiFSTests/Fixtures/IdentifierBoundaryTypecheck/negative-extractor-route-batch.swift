import Foundation
import WikiFSCore
import WikiFSTypes

do {
    // extractorKindIsRejectedByRouteAPI
    func acceptsRoute(_ route: ExtractorRouteID) {}

    acceptsRoute(ExtractorKind.pdf)
}

do {
    // mimeTypeIsRejectedByRouteAPI
    func acceptsRoute(_ route: ExtractorRouteID) {}

    acceptsRoute(try ExtractorMIMEType(validating: "application/pdf"))
}

do {
    // stringIsRejectedByRouteAPI
    func acceptsRoute(_ route: ExtractorRouteID) {}

    acceptsRoute("application/pdf")
}

do {
    // routeIsRejectedByKindAPI
    func acceptsKind(_ kind: ExtractorKind) {}

    acceptsKind(ExtractorRouteID.canonicalPDF)
}

do {
    // extractorKindIsRejectedByMIMEAPI
    func acceptsMIME(_ mimeType: ExtractorMIMEType) {}

    acceptsMIME(ExtractorKind.pdf)
}
