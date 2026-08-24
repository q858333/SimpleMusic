import Combine
import Foundation

@MainActor
final class DownloadQueue {
    typealias DownloadOperation = @MainActor @Sendable (
        URL,
        @escaping @MainActor @Sendable (Double) -> Void,
        @escaping @MainActor @Sendable (String) throws -> Void
    ) async throws -> MusicTrack

    enum RecoveryDisposition: Equatable {
        case indexed
        case cleaned
    }

    typealias RecoveryOperation = @MainActor @Sendable (String) async throws -> RecoveryDisposition

    private enum PendingRecoveryAction {
        case retry(autoPlayEligible: Bool)
        case remove
    }

    private(set) var jobs: [DownloadJob]
    var jobsPublisher: AnyPublisher<[DownloadJob], Never> { subject.eraseToAnyPublisher() }

    private let subject: CurrentValueSubject<[DownloadJob], Never>
    private let store: any DownloadQueuePersisting
    private let operation: DownloadOperation
    private let settingsStore: SettingsStore
    private let recovery: RecoveryOperation
    private let onReload: @MainActor () -> Void
    private let onPlay: @MainActor (MusicTrack) -> Void
    private let maximumActiveCount: Int
    private let now: @MainActor () -> Date
    private let log: @MainActor (String) -> Void
    private let persistenceWritesEnabled: Bool
    private var activeTasks = [UUID: Task<Void, Never>]()
    private var attemptAutoPlay = [UUID: Bool]()
    private var successfulTracks = [UUID: MusicTrack]()
    private var consumedPlayIDs = Set<UUID>()
    private var persistedProgressBuckets = [UUID: Int]()
    private var pendingCancellationAttempts = [UUID: UInt64]()
    private var pendingCancellationActions = [UUID: PendingRecoveryAction]()
    private var pendingRemovalAttempts = [UUID: UInt64]()
    private var recoveryTokens = [UUID: UInt64]()
    private var recoveryTasks = [UUID: Task<Void, Never>]()
    private var pendingRecoveryActions = [UUID: PendingRecoveryAction]()
    private var schedulingOrder = [UUID: UInt64]()
    private var nextSchedulingOrder: UInt64 = 0
    private var launchRecoveryTask: Task<Void, Never>?

    init(
        store: any DownloadQueuePersisting,
        operation: @escaping DownloadOperation,
        settingsStore: SettingsStore,
        recovery: @escaping RecoveryOperation,
        onReload: @escaping @MainActor () -> Void,
        onPlay: @escaping @MainActor (MusicTrack) -> Void,
        maximumActiveCount: Int = 3,
        now: @escaping @MainActor () -> Date = Date.init,
        log: @escaping @MainActor (String) -> Void = { NSLog("%@", $0) }
    ) {
        precondition(maximumActiveCount > 0)
        self.store = store
        self.operation = operation
        self.settingsStore = settingsStore
        self.recovery = recovery
        self.onReload = onReload
        self.onPlay = onPlay
        self.maximumActiveCount = maximumActiveCount
        self.now = now
        self.log = log

        var normalizedJobs: [DownloadJob]
        var didNormalize = false
        var persistenceWritesEnabled = true
        do {
            normalizedJobs = try store.load()
        } catch {
            log("Download queue ledger could not be loaded: \(error)")
            normalizedJobs = []
            persistenceWritesEnabled = false
        }
        self.persistenceWritesEnabled = persistenceWritesEnabled
        for index in normalizedJobs.indices
        where normalizedJobs[index].state == .queued || normalizedJobs[index].state == .downloading {
            normalizedJobs[index].state = .interrupted
            normalizedJobs[index].progress = 0
            didNormalize = true
        }
        jobs = Self.sortedForDisplay(normalizedJobs)
        subject = CurrentValueSubject(jobs)

        if didNormalize && persistenceWritesEnabled {
            do {
                try store.save(jobs.filter { $0.state != .success })
            } catch {
                log("Download queue ledger could not be saved: \(error)")
            }
        }

        let reservations = jobs.compactMap { job in
            job.reservedFileName.map { (job.id, $0) }
        }
        for (id, _) in reservations {
            recoveryTokens[id] = 1
        }
        let launchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 启动恢复按账本顺序串行执行，先确认索引，再决定是否清理文件。
            for (id, fileName) in reservations {
                await self.reconcileReservation(
                    id: id,
                    fileName: fileName,
                    token: 1,
                    retryAutoPlay: nil
                )
            }
        }
        launchRecoveryTask = launchTask
        for (id, _) in reservations {
            recoveryTasks[id] = launchTask
        }
    }

    func enqueue(_ sourceURL: URL) throws -> UUID {
        try AudioDownloadValidator().validate(url: sourceURL)

        let id = UUID()
        let autoPlayEligible = settingsStore.autoPlayAfterDownload
            && !hasUnfinishedWork()
        let job = DownloadJob(
            id: id,
            sourceURL: sourceURL,
            displayName: sourceURL.lastPathComponent,
            state: .queued,
            progress: 0,
            createdAt: now(),
            attempt: 0,
            failureReason: nil,
            reservedFileName: nil
        )
        jobs.insert(job, at: 0)
        attemptAutoPlay[id] = autoPlayEligible
        schedulingOrder[id] = takeSchedulingOrder()
        sortJobs()
        do {
            try saveLedger()
        } catch {
            jobs.removeAll { $0.id == id }
            attemptAutoPlay.removeValue(forKey: id)
            schedulingOrder.removeValue(forKey: id)
            throw error
        }
        publish()
        scheduleIfNeeded()
        return id
    }

    func cancel(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let state = jobs[index].state
        guard state == .queued || state == .downloading else { return }

        if let task = activeTasks[id] {
            pendingCancellationAttempts[id] = jobs[index].attempt
            jobs[index].attempt &+= 1
            jobs[index].state = .cancelled
            attemptAutoPlay.removeValue(forKey: id)
            schedulingOrder.removeValue(forKey: id)
            persistedProgressBuckets.removeValue(forKey: id)
            persistAndPublish()
            // 底层事务完成回滚前继续占有槽位，后续意图只能在 terminal 后串行执行。
            task.cancel()
            return
        }

        jobs[index].attempt &+= 1
        jobs[index].state = .cancelled
        attemptAutoPlay.removeValue(forKey: id)
        schedulingOrder.removeValue(forKey: id)
        persistedProgressBuckets.removeValue(forKey: id)
        persistAndPublish()
        scheduleIfNeeded()
    }

    func retry(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if pendingCancellationAttempts[id] != nil {
            guard pendingCancellationActions[id] == nil else { return }
            let autoPlayEligible = settingsStore.autoPlayAfterDownload
                && !hasUnfinishedWork(excluding: id)
            pendingCancellationActions[id] = .retry(autoPlayEligible: autoPlayEligible)
            attemptAutoPlay[id] = autoPlayEligible
            schedulingOrder[id] = takeSchedulingOrder()
            return
        }
        guard pendingRemovalAttempts[id] == nil else { return }
        switch jobs[index].state {
        case .failure, .cancelled, .interrupted:
            guard pendingRecoveryActions[id] == nil else { return }
            let autoPlayEligible = settingsStore.autoPlayAfterDownload
                && !hasUnfinishedWork(excluding: id)
            attemptAutoPlay[id] = autoPlayEligible
            schedulingOrder[id] = takeSchedulingOrder()
            if let fileName = jobs[index].reservedFileName {
                pendingRecoveryActions[id] = .retry(autoPlayEligible: autoPlayEligible)
                if recoveryTasks[id] == nil {
                    startRecovery(id: id, fileName: fileName)
                }
            } else {
                queueRetry(id: id, autoPlayEligible: autoPlayEligible)
            }
        case .queued, .downloading, .success:
            return
        }
    }

    func remove(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if pendingCancellationAttempts[id] != nil {
            pendingCancellationActions[id] = .remove
            attemptAutoPlay.removeValue(forKey: id)
            schedulingOrder.removeValue(forKey: id)
            return
        }
        if let task = activeTasks[id] {
            guard pendingRemovalAttempts[id] == nil,
                  jobs[index].state == .downloading else { return }
            pendingRemovalAttempts[id] = jobs[index].attempt
            jobs[index].attempt &+= 1
            jobs[index].state = .cancelled
            attemptAutoPlay.removeValue(forKey: id)
            schedulingOrder.removeValue(forKey: id)
            persistedProgressBuckets.removeValue(forKey: id)
            persistAndPublish()
            task.cancel()
            return
        }
        if recoveryTasks[id] != nil || jobs[index].reservedFileName != nil {
            pendingRecoveryActions[id] = .remove
            attemptAutoPlay.removeValue(forKey: id)
            schedulingOrder.removeValue(forKey: id)
            if recoveryTasks[id] == nil, let fileName = jobs[index].reservedFileName {
                startRecovery(id: id, fileName: fileName)
            }
            scheduleIfNeeded()
            return
        }
        removeJob(id: id)
    }

    func play(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].state == .success,
              let track = successfulTracks[id],
              consumedPlayIDs.insert(id).inserted else { return }
        onPlay(track)
    }

    private func scheduleIfNeeded() {
        // recovery 可能删除受控文件；全部恢复收束前禁止任何新 attempt 创建同名 reservation。
        guard recoveryTasks.isEmpty else { return }
        while activeTasks.count < maximumActiveCount,
              let job = jobs.enumerated()
                .filter({ $0.element.state == .queued })
                .min(by: { lhs, rhs in
                    if let lhsOrder = schedulingOrder[lhs.element.id],
                       let rhsOrder = schedulingOrder[rhs.element.id],
                       lhsOrder != rhsOrder {
                        return lhsOrder < rhsOrder
                    }
                    if lhs.element.createdAt == rhs.element.createdAt {
                        return lhs.offset > rhs.offset
                    }
                    return lhs.element.createdAt < rhs.element.createdAt
                }) {
            start(jobID: job.element.id)
        }
    }

    private func start(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].state == .queued else { return }

        jobs[index].attempt &+= 1
        jobs[index].state = .downloading
        jobs[index].progress = 0
        jobs[index].failureReason = nil
        jobs[index].reservedFileName = nil
        let sourceURL = jobs[index].sourceURL
        let attempt = jobs[index].attempt
        schedulingOrder.removeValue(forKey: jobID)
        persistedProgressBuckets[jobID] = 0
        persistAndPublish()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let track = try await self.operation(
                    sourceURL,
                    { [weak self] progress in
                        self?.receiveProgress(id: jobID, attempt: attempt, progress: progress)
                    },
                    { [weak self] fileName in
                        guard let self else { return }
                        try self.reserve(id: jobID, attempt: attempt, fileName: fileName)
                    }
                )
                self.succeed(id: jobID, attempt: attempt, track: track)
            } catch is CancellationError {
                self.finishCancellation(id: jobID, attempt: attempt)
            } catch {
                self.fail(id: jobID, attempt: attempt, error: error)
            }
            self.finishAttempt(id: jobID, attempt: attempt)
        }
        activeTasks[jobID] = task
    }

    private func receiveProgress(id: UUID, attempt: UInt64, progress: Double) {
        guard progress.isFinite,
              let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].attempt == attempt,
              jobs[index].state == .downloading else { return }

        let boundedProgress = min(max(progress, 0), 1)
        jobs[index].progress = boundedProgress
        publish()
        let bucket = Int((boundedProgress * 20).rounded(.down))
        if persistedProgressBuckets[id] != bucket {
            persistedProgressBuckets[id] = bucket
            persistLedger()
        }
    }

    private func reserve(id: UUID, attempt: UInt64, fileName: String) throws {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].attempt == attempt,
              jobs[index].state == .downloading else { return }
        jobs[index].reservedFileName = fileName
        try saveLedger()
        publish()
    }

    private func succeed(id: UUID, attempt: UInt64, track: MusicTrack) {
        if completePendingCancellation(id: id, attempt: attempt) { return }
        if completePendingRemoval(id: id, attempt: attempt) { return }
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].attempt == attempt else { return }
        jobs[index].state = .success
        jobs[index].progress = 1
        jobs[index].failureReason = nil
        successfulTracks[id] = track
        persistedProgressBuckets.removeValue(forKey: id)
        persistAndPublish()
        onReload()

        if attemptAutoPlay[id] == true, consumedPlayIDs.insert(id).inserted {
            onPlay(track)
        }
    }

    private func fail(id: UUID, attempt: UInt64, error: Error) {
        if completePendingCancellation(id: id, attempt: attempt) { return }
        if completePendingRemoval(id: id, attempt: attempt) { return }
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].attempt == attempt else { return }
        jobs[index].state = .failure
        jobs[index].failureReason = Self.failureReason(for: error)
        attemptAutoPlay.removeValue(forKey: id)
        persistedProgressBuckets.removeValue(forKey: id)
        persistAndPublish()
    }

    private func finishCancellation(id: UUID, attempt: UInt64) {
        if completePendingCancellation(id: id, attempt: attempt) { return }
        if completePendingRemoval(id: id, attempt: attempt) { return }
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].attempt == attempt else { return }
        jobs[index].state = .cancelled
        attemptAutoPlay.removeValue(forKey: id)
        persistedProgressBuckets.removeValue(forKey: id)
        persistAndPublish()
    }

    private func finishAttempt(id: UUID, attempt: UInt64) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].attempt == attempt else { return }
        activeTasks.removeValue(forKey: id)
        attemptAutoPlay.removeValue(forKey: id)
        scheduleIfNeeded()
    }

    private func completePendingCancellation(id: UUID, attempt: UInt64) -> Bool {
        guard pendingCancellationAttempts[id] == attempt else { return false }
        pendingCancellationAttempts.removeValue(forKey: id)
        let action = pendingCancellationActions.removeValue(forKey: id)
        activeTasks.removeValue(forKey: id)

        switch action {
        case let .retry(autoPlayEligible):
            if let index = jobs.firstIndex(where: { $0.id == id }),
               let fileName = jobs[index].reservedFileName {
                pendingRecoveryActions[id] = .retry(autoPlayEligible: autoPlayEligible)
                startRecovery(id: id, fileName: fileName)
            } else {
                queueRetry(id: id, autoPlayEligible: autoPlayEligible)
            }
        case .remove:
            if let index = jobs.firstIndex(where: { $0.id == id }),
               let fileName = jobs[index].reservedFileName {
                pendingRecoveryActions[id] = .remove
                startRecovery(id: id, fileName: fileName)
            } else {
                removeJob(id: id)
            }
        case nil:
            persistAndPublish()
            scheduleIfNeeded()
        }
        return true
    }

    private func completePendingRemoval(id: UUID, attempt: UInt64) -> Bool {
        guard pendingRemovalAttempts[id] == attempt else { return false }
        pendingRemovalAttempts.removeValue(forKey: id)
        removeJob(id: id)
        return true
    }

    private func removeJob(id: UUID) {
        jobs.removeAll { $0.id == id }
        activeTasks.removeValue(forKey: id)?.cancel()
        attemptAutoPlay.removeValue(forKey: id)
        successfulTracks.removeValue(forKey: id)
        consumedPlayIDs.remove(id)
        persistedProgressBuckets.removeValue(forKey: id)
        pendingCancellationAttempts.removeValue(forKey: id)
        pendingCancellationActions.removeValue(forKey: id)
        pendingRemovalAttempts.removeValue(forKey: id)
        recoveryTokens.removeValue(forKey: id)
        recoveryTasks.removeValue(forKey: id)
        pendingRecoveryActions.removeValue(forKey: id)
        schedulingOrder.removeValue(forKey: id)
        persistAndPublish()
        scheduleIfNeeded()
    }

    private func nextRecoveryToken(for id: UUID) -> UInt64 {
        let token = (recoveryTokens[id] ?? 0) &+ 1
        recoveryTokens[id] = token
        return token
    }

    private func reconcileReservation(
        id: UUID,
        fileName: String,
        token: UInt64,
        retryAutoPlay: Bool?
    ) async {
        guard !Task.isCancelled,
              recoveryTokens[id] == token,
              recoveryTasks[id] != nil,
              let initialIndex = jobs.firstIndex(where: { $0.id == id }),
              jobs[initialIndex].reservedFileName == fileName else {
            finishRecovery(id: id)
            return
        }

        let result: Result<RecoveryDisposition, Error>
        do {
            result = .success(try await recovery(fileName))
        } catch {
            result = .failure(error)
        }

        guard recoveryTokens[id] == token,
              let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].reservedFileName == fileName else {
            finishRecovery(id: id)
            return
        }

        let pendingAction = pendingRecoveryActions.removeValue(forKey: id)
        recoveryTasks.removeValue(forKey: id)

        if case .remove? = pendingAction {
            removeJob(id: id)
            return
        }

        switch result {
        case let .success(disposition):
            switch disposition {
            case .indexed:
                removeJob(id: id)
            case .cleaned:
                jobs[index].state = .interrupted
                jobs[index].progress = 0
                jobs[index].failureReason = nil
                jobs[index].reservedFileName = nil
                recoveryTokens.removeValue(forKey: id)
                if case let .retry(autoPlayEligible)? = pendingAction {
                    queueRetry(id: id, autoPlayEligible: autoPlayEligible)
                } else if let retryAutoPlay {
                    queueRetry(id: id, autoPlayEligible: retryAutoPlay)
                } else {
                    persistAndPublish()
                    scheduleIfNeeded()
                }
            }
        case .failure:
            jobs[index].state = .interrupted
            jobs[index].progress = 0
            jobs[index].failureReason = .recovery
            attemptAutoPlay.removeValue(forKey: id)
            schedulingOrder.removeValue(forKey: id)
            persistedProgressBuckets.removeValue(forKey: id)
            persistAndPublish()
            scheduleIfNeeded()
        }
    }

    private func startRecovery(id: UUID, fileName: String) {
        let token = nextRecoveryToken(for: id)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcileReservation(
                id: id,
                fileName: fileName,
                token: token,
                retryAutoPlay: nil
            )
        }
        recoveryTasks[id] = task
    }

    private func finishRecovery(id: UUID) {
        recoveryTasks.removeValue(forKey: id)
        recoveryTokens.removeValue(forKey: id)
        pendingRecoveryActions.removeValue(forKey: id)
        schedulingOrder.removeValue(forKey: id)
        attemptAutoPlay.removeValue(forKey: id)
        scheduleIfNeeded()
    }

    private func queueRetry(id: UUID, autoPlayEligible: Bool) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .queued
        jobs[index].progress = 0
        jobs[index].failureReason = nil
        jobs[index].reservedFileName = nil
        pendingRemovalAttempts.removeValue(forKey: id)
        persistedProgressBuckets.removeValue(forKey: id)
        attemptAutoPlay[id] = autoPlayEligible
        persistAndPublish()
        scheduleIfNeeded()
    }

    private func takeSchedulingOrder() -> UInt64 {
        nextSchedulingOrder &+= 1
        return nextSchedulingOrder
    }

    private func hasUnfinishedWork(excluding excludedID: UUID? = nil) -> Bool {
        jobs.contains {
            $0.id != excludedID && ($0.state == .queued || $0.state == .downloading)
        } || pendingRecoveryActions.contains { id, action in
            guard id != excludedID else { return false }
            if case .retry = action { return true }
            return false
        } || pendingCancellationActions.contains { id, action in
            guard id != excludedID else { return false }
            if case .retry = action { return true }
            return false
        }
    }

    private func persistAndPublish() {
        persistLedger()
        publish()
    }

    private func persistLedger() {
        do {
            try saveLedger()
        } catch {
            log("Download queue ledger could not be saved: \(error)")
        }
    }

    private func saveLedger() throws {
        // 损坏账本保留原始字节；本进程退化为内存队列，避免后续写回覆盖取证。
        guard persistenceWritesEnabled else { return }
        try store.save(jobs.filter { $0.state != .success })
    }

    private func publish() {
        sortJobs()
        subject.send(jobs)
    }

    private func sortJobs() {
        jobs = Self.sortedForDisplay(jobs)
    }

    private static func sortedForDisplay(_ jobs: [DownloadJob]) -> [DownloadJob] {
        // 同时间戳时保留 JSON newest-first 顺序；调度器据此反向取最早提交项。
        jobs.enumerated().sorted { lhs, rhs in
            if lhs.element.createdAt == rhs.element.createdAt {
                return lhs.offset < rhs.offset
            }
            return lhs.element.createdAt > rhs.element.createdAt
        }.map(\.element)
    }

    private static func failureReason(for error: Error) -> DownloadJob.FailureReason {
        if error as? DownloadPolicyError == .cellularAccessDisabled {
            return .cellularDisabled
        }
        guard let downloadError = error as? DownloadError else { return .generic }
        switch downloadError {
        case .unsupportedURL:
            return .unsupportedURL
        case .unsupportedResponse:
            return .invalidPayload
        }
    }
}
