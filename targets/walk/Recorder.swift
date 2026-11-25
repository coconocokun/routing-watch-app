import Combine
import Foundation
import HealthKit
import WatchConnectivity

@MainActor
final class Recorder: NSObject, ObservableObject {
    static let shared = Recorder()
    @Published private(set) var store = TrialStore()
    @Published private(set) var reachable = false
    @Published private(set) var phase = "Waiting for iPhone"
    @Published private(set) var problem: String?
    private let health = HKHealthStore()
    private let heart = HKQuantityType(.heartRate)
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var liveQuery: HKAnchoredObjectQuery?
    private var recoveryInProgress = false
    private var storageReadable = true
    private var finishing = false
    private var collectionReady = false

    var current: StudyWorkout? { store.active.flatMap { store.workouts[$0] } }
    var last: StudyWorkout? { store.workouts.values.filter { $0.finalized != nil }.max { $0.start < $1.start } }
    var canStart: Bool { storageReadable && store.pending != nil && store.active == nil && !recoveryInProgress && phase != "Requesting access…" }

    override init() {
        super.init()
        do { store = try TrialStore.load() }
        catch {
            storageReadable = false
            problem = "Saved measurements could not be read. Keep the app installed and contact the study team."
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func recover() async {
        guard let workout = current, session == nil, !recoveryInProgress else { return }
        recoveryInProgress = true
        defer { recoveryInProgress = false }
        do {
            if let recovered = try await health.recoverActiveWorkoutSession() {
                let config = HKWorkoutConfiguration()
                config.activityType = .walking
                config.locationType = .outdoor
                attach(recovered, config: config)
                collectionReady = true
                beginQuery(trial: workout.trial, since: Date(timeIntervalSince1970: Double(workout.start) / 1000))
                phase = recovered.state == .paused ? "Paused" : "Recording"
                started(workout)
                if workout.stop != nil { recovered.end() }
                return
            }
        } catch { problem = "The previous workout could not be recovered." }
        await finalize(trial: workout.trial, stop: workout.stop ?? ms(), verified: nil, interrupted: true)
    }

    @discardableResult
    private func commit(_ change: (inout TrialStore) -> Void) -> Bool {
        guard storageReadable else { return false }
        var next = store
        change(&next)
        do { try next.save(); store = next; return true }
        catch { problem = "Watch storage could not save the workout. Free storage and try again."; return false }
    }

    func start() async {
        guard canStart, let trial = store.pending else { return }
        let title = store.pendingTitle ?? "Walking trial"
        phase = "Requesting access…"
        problem = nil
        do {
            guard HKHealthStore.isHealthDataAvailable() else { throw RecorderError("HealthKit is unavailable on this Watch.") }
            try await health.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [heart])
            guard store.pending == trial, !store.cancelled.contains(trial) else { phase = "Waiting for iPhone"; return }
            guard health.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
                throw RecorderError("Allow Walking Study to save workouts in Health settings.")
            }
            let config = HKWorkoutConfiguration()
            config.activityType = .walking
            config.locationType = .outdoor
            let workoutSession = try HKWorkoutSession(healthStore: health, configuration: config)
            let now = Date()
            let workout = StudyWorkout(trial: trial, session: UUID().uuidString.lowercased(), title: title, start: ms(now))
            guard commit({
                $0.active = trial; $0.pending = nil; $0.pendingTitle = nil; $0.workouts[trial] = workout
            }) else { throw RecorderError("The workout could not be saved locally.") }
            attach(workoutSession, config: config)
            phase = "Starting…"
            workoutSession.startActivity(with: now)
            guard let builder else { throw RecorderError("The HealthKit recorder is unavailable.") }
            try await builder.beginCollection(at: now)
            collectionReady = true
            confirmStart()
        } catch {
            if store.active == trial { stop(interrupted: true) }
            else { phase = "Waiting for iPhone" }
            problem = error.localizedDescription
            send("ERROR", trial, ["message": error.localizedDescription])
        }
    }

    private func attach(_ next: HKWorkoutSession, config: HKWorkoutConfiguration) {
        session = next
        next.delegate = self
        let workoutBuilder = next.associatedWorkoutBuilder()
        workoutBuilder.dataSource = HKLiveWorkoutDataSource(healthStore: health, workoutConfiguration: config)
        builder = workoutBuilder
    }

    private func started(_ workout: StudyWorkout) {
        send("STARTED", workout.trial, ["watch_session_id": workout.session, "watch_started_at_ms": workout.start])
    }

    private func confirmStart() {
        guard phase == "Starting…", collectionReady, let workout = current, workout.stop == nil,
              let session, session.state == .running else { return }
        beginQuery(trial: workout.trial, since: Date(timeIntervalSince1970: Double(workout.start) / 1000))
        phase = "Recording"
        started(workout)
    }

    private func sample(_ raw: HKQuantitySample, flags: [String] = []) -> HeartSample {
        HeartSample(sample_id: raw.uuid.uuidString.lowercased(), watch_seq: 0,
            sample_start_at_ms: ms(raw.startDate), sample_end_at_ms: ms(raw.endDate),
            bpm: raw.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
            source_id: raw.sourceRevision.source.bundleIdentifier, quality_flags: flags)
    }

    private func beginQuery(trial: String, since: Date) {
        if let liveQuery { health.stop(liveQuery) }
        let livePredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate),
            HKQuery.predicateForObjects(from: [HKDevice.local()])
        ])
        let query = HKAnchoredObjectQuery(type: heart, predicate: livePredicate, anchor: nil, limit: HKObjectQueryNoLimit) {
            [weak self] _, samples, _, _, _ in
            Task { @MainActor in self?.cache(samples, trial: trial) }
        }
        query.updateHandler = { [weak self] _, samples, _, _, _ in
            Task { @MainActor in self?.cache(samples, trial: trial) }
        }
        liveQuery = query
        health.execute(query)
    }

    private func cache(_ raws: [HKSample]?, trial: String) {
        guard store.active == trial, var workout = current else { return }
        var existing = Set(workout.samples.map(\.sample_id))
        let new = (raws ?? []).compactMap { $0 as? HKQuantitySample }.map { sample($0) }.filter {
            existing.insert($0.sample_id).inserted && $0.bpm.isFinite && $0.bpm > 0
        }
        guard !new.isEmpty else { return }
        for var sample in new {
            sample.watch_seq = workout.samples.count + 1
            workout.samples.append(sample)
        }
        if !commit({ $0.workouts[trial] = workout }) { stop(interrupted: true) }
    }

    func pause() { session?.pause() }
    func resume() { session?.resume() }

    func stop(interrupted: Bool = false) {
        guard let workout = current, workout.stop == nil else { return }
        _ = commit {
            $0.workouts[workout.trial]?.stop = max(workout.start, ms())
            $0.workouts[workout.trial]?.interrupted = interrupted || workout.interrupted
        }
        phase = "Saving samples…"
        session?.end()
    }

    private func workoutSamples(_ workout: HKWorkout) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: heart, predicate: HKQuery.predicateForObjects(from: workout),
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (samples as? [HKQuantitySample]) ?? []) }
            }
            health.execute(query)
        }
    }

    private func workoutEnded(date: Date, interrupted: Bool) async {
        guard !finishing, let workout = current else { return }
        finishing = true
        defer { finishing = false }
        phase = "Saving samples…"
        var final: [HeartSample]?
        if let builder {
            do {
                try await builder.endCollection(at: date)
                if let saved = try await builder.finishWorkout() {
                    let raws = try await workoutSamples(saved)
                    if !raws.isEmpty || workout.samples.isEmpty { final = raws.map { sample($0) } }
                }
            } catch {
                problem = "The Watch could not finish the HealthKit workout. Cached readings will be flagged."
            }
        }
        await finalize(trial: workout.trial, stop: ms(date), verified: final,
                       interrupted: interrupted || workout.interrupted || final == nil)
    }

    private func finalize(trial: String, stop: Int64, verified: [HeartSample]?, interrupted: Bool) async {
        guard var workout = store.workouts[trial] else { return }
        if let liveQuery { health.stop(liveQuery) }
        liveQuery = nil
        session = nil
        builder = nil
        collectionReady = false
        if store.deletions.contains(trial) {
            if commit({ $0.active = nil; $0.workouts[trial] = nil; $0.deletions.remove(trial); $0.cancelled.insert(trial) }) {
                phase = "Waiting for iPhone"
                send("DELETED", trial, [:])
            }
            return
        }
        let input = verified ?? workout.samples.map { entry in
            var flagged = entry
            flagged.quality_flags.append("unverified_workout_source")
            return flagged
        }
        var ids = Set<String>()
        workout.samples = input.filter { $0.bpm.isFinite && $0.bpm > 0 && ids.insert($0.sample_id).inserted }
            .sorted { ($0.sample_start_at_ms, $0.sample_id) < ($1.sample_start_at_ms, $1.sample_id) }
        for index in workout.samples.indices { workout.samples[index].watch_seq = index + 1 }
        workout.stop = max(workout.start, stop)
        workout.finalized = max(workout.stop ?? stop, ms())
        workout.interrupted = interrupted
        workout.count = workout.samples.count
        workout.digest = checksum(workout.samples)
        guard commit({ $0.active = nil; $0.workouts[trial] = workout }) else { return }
        phase = "Waiting to sync"
        if workout.samples.isEmpty { problem = "No heart-rate samples were available. Check Health access and Watch fit." }
        send("STOPPED", trial, ["watch_session_id": workout.session, "watch_stopped_at_ms": workout.stop ?? stop])
        flush(trial: trial)
    }

    func flush(trial: String? = nil) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        for workout in store.workouts.values where (trial == nil || workout.trial == trial) && !workout.acknowledged {
            guard let stop = workout.stop, let done = workout.finalized, let digest = workout.digest, let count = workout.count else { continue }
            for offset in stride(from: 0, to: workout.samples.count, by: 50) {
                let batchID = "\(workout.session)-\(offset / 50 + 1)"
                if workout.acked.contains(batchID) { continue }
                let batch = Array(workout.samples[offset..<min(offset + 50, workout.samples.count)])
                guard let data = try? JSONEncoder().encode(batch), let rows = try? JSONSerialization.jsonObject(with: data) else { continue }
                send("HR_BATCH", workout.trial, ["watch_session_id": workout.session, "batch_id": batchID,
                    "seq_start": offset + 1, "seq_end": offset + batch.count, "samples": rows, "sha256": checksum(batch)],
                    key: batchID)
            }
            send("FINAL_MANIFEST", workout.trial, ["watch_session_id": workout.session, "watch_started_at_ms": workout.start,
                "watch_stopped_at_ms": stop, "finalized_at_ms": done, "final_sample_count": count, "final_checksum": digest,
                "interrupted": workout.interrupted], key: "\(workout.session)-manifest")
        }
    }

    private func send(_ type: String, _ trial: String, _ payload: [String: Any], key: String? = nil) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let session = WCSession.default
        let envelope: [String: Any] = ["protocol_version": "1.0", "message_id": UUID().uuidString,
            "type": type, "trial_id": trial, "sender_device": "watch", "sent_at_ms": ms(), "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8) else { return }
        let deliveryKey = key ?? UUID().uuidString
        let message = ["envelope": json, "key": deliveryKey]
        if !session.outstandingUserInfoTransfers.contains(where: { $0.userInfo["key"] as? String == deliveryKey }) {
            session.transferUserInfo(message)
        }
        if session.isReachable && type != "HR_BATCH" { session.sendMessage(message, replyHandler: nil, errorHandler: nil) }
    }

    nonisolated private static func decode(_ message: [String: Any]) -> [String: Any]? {
        guard let json = message["envelope"] as? String, json.utf8.count <= 100_000,
              let envelope = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              envelope["sender_device"] as? String == "phone" else { return nil }
        return envelope
    }

    private func received(_ json: String) {
        guard let m = Self.decode(["envelope": json]), let id = m["trial_id"] as? String, UUID(uuidString: id) != nil,
              let mid = m["message_id"] as? String, UUID(uuidString: mid) != nil,
              let type = m["type"] as? String, let p = m["payload"] as? [String: Any],
              let sentAt = (m["sent_at_ms"] as? NSNumber)?.int64Value, sentAt > 0 else { return }
        guard m["protocol_version"] as? String == "1.0" else {
            problem = "Update the iPhone and Watch apps to matching versions."
            send("ERROR", id, ["message": problem ?? "Protocol mismatch."])
            return
        }
        guard !store.processed.contains(mid) else { return }
        switch type {
        case "PREPARE":
            send("WATCH_READY", id, ["workout_available": current == nil && storageReadable])
        case "START":
            if let current, current.trial == id {
                if phase == "Recording" || phase == "Paused" { started(current) }
            } else if store.workouts[id] != nil { flush(trial: id) }
            else if store.cancelled.contains(id) { return }
            else if current != nil || (store.pending != nil && store.pending != id) {
                send("ERROR", id, ["message": "Another study walk is active on the Watch."])
            } else if commit({ $0.pending = id; $0.pendingTitle = p["title"] as? String }) {
                problem = nil
                phase = "Confirm start"
            }
        case "PAUSE", "RESUME":
            guard let current, current.trial == id, sentAt >= (current.lastPhonePauseCommand ?? 0),
                  commit({ $0.workouts[id]?.lastPhonePauseCommand = sentAt }) else { return }
            if type == "PAUSE" && phase == "Recording" { pause() }
            if type == "RESUME" && phase == "Paused" { resume() }
        case "STOP":
            guard commit({
                $0.cancelled.insert(id)
                if $0.pending == id { $0.pending = nil; $0.pendingTitle = nil }
            }) else { return }
            if store.active == id { stop(interrupted: p["interrupted"] as? Bool == true) }
            else if store.workouts[id] != nil { flush(trial: id) }
            else {
                if current == nil { phase = "Waiting for iPhone" }
                send("CANCELLED", id, [:])
            }
        case "SYNC_REQUEST":
            if let current, current.trial == id, phase == "Recording" || phase == "Paused" { started(current) }
            flush(trial: id)
        case "BATCH_ACK":
            guard let workout = store.workouts[id], workout.session == p["watch_session_id"] as? String,
                  let batch = p["batch_id"] as? String,
                  let number = Int(batch.split(separator: "-").last ?? ""), number > 0, number <= 2000,
                  batch == "\(workout.session)-\(number)" else { return }
            let start = (number - 1) * 50
            guard start < workout.samples.count,
                  checksum(Array(workout.samples[start..<min(start + 50, workout.samples.count)])) == p["sha256"] as? String else { return }
            _ = commit { $0.workouts[id]?.acked.insert(batch) }
        case "MANIFEST_ACK":
            guard let workout = store.workouts[id], workout.session == p["watch_session_id"] as? String,
                  workout.finalized != nil else { return }
            if commit({ $0.workouts[id]?.acknowledged = true; $0.workouts[id]?.samples = []; $0.workouts[id]?.acked = [] }),
               current == nil { phase = "Transferred" }
        case "DELETE":
            if store.active == id {
                if commit({ $0.deletions.insert(id) }) { stop(interrupted: true) }
                return
            }
            if commit({
                $0.workouts[id] = nil; $0.cancelled.insert(id)
                if $0.pending == id { $0.pending = nil; $0.pendingTitle = nil }
            }) { send("DELETED", id, [:]) }
        default: return
        }
        _ = commit {
            $0.processed.append(mid)
            if $0.processed.count > 512 { $0.processed.removeFirst($0.processed.count - 512) }
        }
    }
}

private struct RecorderError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

extension Recorder: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let available = session.isReachable
        Task { @MainActor in reachable = available; flush() }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let available = session.isReachable
        Task { @MainActor in reachable = available; if available { flush() } }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let json = userInfo["envelope"] as? String { Task { @MainActor in received(json) } }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let json = message["envelope"] as? String { Task { @MainActor in received(json) } }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        if let envelope = Self.decode(message), envelope["type"] as? String == "PING",
           envelope["protocol_version"] as? String == "1.0" {
            replyHandler(["watch_time_ms": ms()])
        } else { replyHandler([:]) }
    }
}

extension Recorder: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo state: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in
            guard session === workoutSession, let workout = current else { return }
            if state == .ended { await workoutEnded(date: date, interrupted: workout.stop == nil) }
            if state == .running && fromState != .paused { confirmStart() }
            if state == .paused {
                phase = "Paused"
                send("PAUSED", workout.trial, ["watch_session_id": workout.session])
            }
            if state == .running && fromState == .paused {
                phase = "Recording"
                send("RESUMED", workout.trial, ["watch_session_id": workout.session])
            }
        }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            guard session === workoutSession, let workout = current else { return }
            problem = error.localizedDescription
            send("ERROR", workout.trial, ["message": error.localizedDescription])
            await workoutEnded(date: Date(), interrupted: true)
        }
    }
}
