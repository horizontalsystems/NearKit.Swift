import Alamofire
import Foundation

enum NetworkErrors {
    /// True for failures that come from the device's connectivity rather than from the chain or
    /// the kit: DNS not ready after the app resumes, a dropped socket, a timeout. These clear
    /// themselves within seconds and are not worth showing as a sync error right away.
    ///
    /// Only transport failures count, as Android's `IOException`: an HTTP error status (429, 401,
    /// 503) is reported at once. HsToolKit `NetworkManager` throws those as its own `ResponseError`,
    /// which is neither `URLError` nor `AFError`, so it is not transient; transport failures arrive
    /// as `AFError.sessionTaskFailed` wrapping a `URLError`.
    static func isTransient(_ error: Error) -> Bool {
        let cause = (error as? NoEndpointAvailable)?.underlying ?? error

        if cause is URLError {
            return true
        }
        if let afError = cause.asAFError {
            switch afError {
            case .sessionTaskFailed, .explicitlyCancelled:
                return true
            default:
                return afError.underlyingError is URLError
            }
        }
        return false
    }

    /// DNS failure: the network is usually just not up yet.
    static func isDnsFailure(_ error: Error) -> Bool {
        let cause = (error as? NoEndpointAvailable)?.underlying ?? error
        let urlError = cause as? URLError ?? cause.asAFError?.underlyingError as? URLError
        guard let urlError else {
            return false
        }
        return urlError.code == .cannotFindHost || urlError.code == .dnsLookupFailed
    }
}
