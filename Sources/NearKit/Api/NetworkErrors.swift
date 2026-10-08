import Alamofire
import Foundation
import HsToolKit

enum NetworkErrors {
    /// True for failures that come from the device's connectivity or a briefly overloaded service
    /// rather than from the chain or the kit: DNS not ready after the app resumes, a dropped socket,
    /// a timeout, a rate limit or a 5xx. These clear themselves and are not worth showing as a sync
    /// error right away (Android `NetworkErrors.isTransient`).
    ///
    /// Transport failures arrive as `AFError.sessionTaskFailed` wrapping a `URLError`; HTTP error
    /// statuses as HsToolKit's `NetworkManager.ResponseError`. Other statuses (401, 404) are
    /// reported at once.
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
        if let statusCode = statusCode(cause) {
            return statusCode == 429 || (500 ..< 600).contains(statusCode)
        }
        return false
    }

    /// HTTP 429. HsToolKit's `ResponseError` keeps no headers, so unlike Android a `Retry-After`
    /// is not available and the caller backs off on its own schedule.
    static func isRateLimited(_ error: Error) -> Bool {
        statusCode((error as? NoEndpointAvailable)?.underlying ?? error) == 429
    }

    static func statusCode(_ error: Error) -> Int? {
        (error as? NetworkManager.ResponseError)?.statusCode
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
