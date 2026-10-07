import Combine
import Foundation
import HsToolKit

// The seam that lets tests drive reachability; production uses HsToolKit's manager as is.
extension ReachabilityManager: IConnectionManager {
    var isConnected: Bool {
        isReachable
    }

    var isConnectedPublisher: AnyPublisher<Bool, Never> {
        $isReachable
    }
}
