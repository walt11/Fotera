import ActivityKit
import UIKit

@MainActor final class BackupLiveActivity {
    static let shared = BackupLiveActivity()
    private var activity: Activity<BackupActivityAttributes>?
    private var latest: (BackupActivityAttributes.ContentState, Bool)?
    private var worker: Task<Void, Never>?
    private var lastSent: BackupActivityAttributes.ContentState?
    private var dismissed = false

    /// Coalesce rapid ledger updates; the newest state always wins, including disable/sign-out.
    func publish(_ state: BackupActivityAttributes.ContentState, enabled: Bool) {
        latest = (state, enabled)
        guard worker == nil else { return }
        worker = Task {
            while let (state, enabled) = latest {
                latest = nil
                await apply(state, enabled: enabled)
                try? await Task.sleep(for: .seconds(1))
            }
            worker = nil
        }
    }
    func flush() async { await worker?.value }

    private func apply(_ state: BackupActivityAttributes.ContentState, enabled: Bool) async {
        if activity == nil {
            activity = Activity<BackupActivityAttributes>.activities.first {
                $0.activityState == .active || $0.activityState == .stale
            }
        }
        if activity?.activityState == .dismissed { activity = nil; dismissed = true }
        if activity?.activityState == .ended { activity = nil }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(5 * 60))
        if !enabled || state.phase == .complete || !state.hasPendingWork {
            if let activity {
                await activity.end(content, dismissalPolicy: .immediate)
            }
            for existing in Activity<BackupActivityAttributes>.activities where existing.id != activity?.id {
                await existing.end(nil, dismissalPolicy: .immediate)
            }
            activity = nil; lastSent = nil; dismissed = false
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let activity {
            guard lastSent != state || activity.activityState == .stale else { return }
            await activity.update(content)
            lastSent = state
        } else if !dismissed, UIApplication.shared.applicationState == .active {
            do {
                activity = try Activity.request(attributes: BackupActivityAttributes(), content: content, pushType: nil)
                lastSent = state
            } catch { /* Backup continues even when iOS declines a Live Activity. */ }
        }
    }
    #if DEBUG
    func verifyLifecycle() async throws {
        for existing in Activity<BackupActivityAttributes>.activities { await existing.end(nil, dismissalPolicy: .immediate) }
        activity = nil; lastSent = nil
        let sample = BackupActivityAttributes.ContentState(completed: 42, total: 100, awaitingVerification: 3, phase: .uploading)
        guard sample.percent == 42, BackupActivityAttributes.ContentState(completed: 0, total: 0, awaitingVerification: 0, phase: .preparing).fraction == 0 else { throw ConnectionError.invalidResponse }
        await apply(sample, enabled: true)
        guard let activity else { throw ConnectionError.unavailable }
        let next = BackupActivityAttributes.ContentState(completed: 64, total: 100, awaitingVerification: 4, phase: .verifying)
        await apply(next, enabled: true)
        guard activity.content.state == next else { throw ConnectionError.invalidResponse }
    }
    #endif
}
