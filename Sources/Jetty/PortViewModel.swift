import Foundation
import Darwin

@MainActor
final class PortViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var projects: [Project] = []
    @Published private(set) var lastRefreshDate: Date = Date()
    @Published var killError: KillError? = nil

    struct KillError: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    // MARK: - Private

    private var timerTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        startTimer()
        Task { await refresh() }
    }

    deinit {
        timerTask?.cancel()
    }

    // MARK: - Timer

    private func startTimer() {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    // MARK: - Refresh

    func refresh() async {
        let scanned = await Task.detached(priority: .userInitiated) {
            PortScanner.scanProjects()
        }.value
        projects = scanned
        lastRefreshDate = Date()
    }

    // MARK: - Kill

    func kill(pid: Int32) {
        switch attemptKill(pid: pid_t(pid)) {
        case .success:
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                await self.refresh()
            }
        case .permissionDenied:
            killError = KillError(
                title: "Permission Denied",
                message: "Process \(pid) requires elevated privileges.\n\nTo force-kill it, run:\n\nsudo kill -9 \(pid)"
            )
        case .notFound:
            Task { await self.refresh() }
        case .unknown(let code):
            killError = KillError(
                title: "Kill Failed",
                message: "Could not terminate process \(pid). errno: \(code)"
            )
        }
    }

    // MARK: - Kill implementation

    private enum KillResult {
        case success, permissionDenied, notFound, unknown(Int32)
    }

    private func attemptKill(pid: pid_t) -> KillResult {
        var result = Darwin.kill(pid, SIGTERM)
        if result == 0 { return .success }
        let termerr = errno
        if termerr == EPERM { return .permissionDenied }
        if termerr == ESRCH { return .notFound }

        result = Darwin.kill(pid, SIGKILL)
        if result == 0 { return .success }
        let killerr = errno
        if killerr == EPERM { return .permissionDenied }
        if killerr == ESRCH { return .notFound }
        return .unknown(killerr)
    }
}
