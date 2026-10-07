import Combine
import Foundation

/// Timer loop that drives sync cycles and follows reachability (EvmKit `ApiRpcSyncer`, TronKit
/// `SyncTimer`, Android `SyncTimer`). Background handling is the app's `pause()`/`resume()` only; the kit does not
/// observe `UIApplication`.
final class ApiSyncer {
    weak var delegate: IApiSyncerDelegate?

    private let connectionManager: IConnectionManager
    private let syncInterval: TimeInterval

    private(set) var state: SyncerState = .notReady(error: SyncError.notStarted) {
        didSet {
            if state != oldValue {
                delegate?.didUpdateSyncerState(state)
            }
        }
    }

    private var isStarted = false
    private var isPaused = false
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(connectionManager: IConnectionManager, syncInterval: TimeInterval) {
        self.connectionManager = connectionManager
        self.syncInterval = syncInterval

        connectionManager.isConnectedPublisher
            .sink { [weak self] connected in
                self?.handleUpdate(reachable: connected)
            }
            .store(in: &cancellables)
    }

    deinit {
        stopTimer()
    }

    func start() {
        isStarted = true
        handleUpdate(reachable: connectionManager.isConnected)
    }

    func stop() {
        isStarted = false
        isPaused = false
        state = .notReady(error: SyncError.notStarted)
        stopTimer()
    }

    func pause() {
        guard isStarted, !isPaused else { return }
        isPaused = true
        stopTimer()
    }

    func resume() {
        guard isStarted, isPaused else { return }
        isPaused = false
        if connectionManager.isConnected {
            startTimer()
        }
    }

    private func handleUpdate(reachable: Bool) {
        guard isStarted else { return }

        if reachable {
            state = .ready
            if !isPaused {
                startTimer()
            }
        } else {
            state = .notReady(error: SyncError.noNetworkConnection)
            stopTimer()
        }
    }

    private func startTimer() {
        // invalidate and create in the same main-queue block, otherwise queued calls create zombie timers
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            stopTimer()
            timer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
                self?.delegate?.sync()
            }
            timer?.tolerance = 0.5
            delegate?.sync()
        }
    }

    /// A timer can only be invalidated from the run loop it was installed on, and `startTimer` always
    /// installs it on main. Called from anywhere else the invalidation is dropped and the timer keeps
    /// firing for the life of the app. Both callers that matter arrive off-main: `deinit`, on whichever
    /// queue released the kit, and the reachability callback, which publishes on its own queue. So a
    /// flapping connection used to leave one live timer behind per change - harmless work, since the
    /// block holds `self` weakly, but a wake-up of the main thread every cycle forever.
    /// EvmKit `ApiRpcSyncer` and TronKit `SyncTimer` share the gap; we do not, hence the hop.
    private func stopTimer() {
        let timer = timer
        self.timer = nil

        guard let timer else { return }

        if Thread.isMainThread {
            timer.invalidate()
        } else {
            DispatchQueue.main.async { timer.invalidate() }
        }
    }
}
