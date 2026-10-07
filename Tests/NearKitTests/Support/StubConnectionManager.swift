import Combine
import Foundation
@testable import NearKit

/// Reachability under test control, known synchronously like HsToolKit `ReachabilityManager`.
final class StubConnectionManager: IConnectionManager {
    private let subject: CurrentValueSubject<Bool, Never>

    init(connected: Bool) {
        subject = CurrentValueSubject(connected)
    }

    var isConnected: Bool {
        subject.value
    }

    var isConnectedPublisher: AnyPublisher<Bool, Never> {
        subject.removeDuplicates().eraseToAnyPublisher()
    }

    func set(connected: Bool) {
        subject.send(connected)
    }
}
