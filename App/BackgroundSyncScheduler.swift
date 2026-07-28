import BackgroundTasks
import Foundation

enum BackgroundSyncScheduler {
    static let identifier = "com.hdwei.ShareToObsidian.sync"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // iOS may reject scheduling based on system policy; foreground sync still handles the queue.
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let completion = BackgroundTaskCompletion(task: task)

        let syncTask = Task {
            let summary = await CaptureSyncRunner.syncQueued(
                bridgeAddress: CaptureSettingsStore.bridgeAddress,
                bearerToken: CaptureSettingsStore.bridgeToken,
                enrichSyncedMissingMetadata: true
            )
            completion.complete(success: summary.lastError == nil && !Task.isCancelled)
        }

        task.expirationHandler = {
            syncTask.cancel()
            completion.complete(success: false)
        }
    }
}

private final class BackgroundTaskCompletion {
    private let task: BGAppRefreshTask
    private let lock = NSLock()
    private var didComplete = false

    init(task: BGAppRefreshTask) {
        self.task = task
    }

    func complete(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !didComplete else {
            return
        }
        didComplete = true
        task.setTaskCompleted(success: success)
    }
}
