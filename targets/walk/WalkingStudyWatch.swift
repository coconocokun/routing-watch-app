import SwiftUI
import WatchKit

final class StudyDelegate: NSObject, WKApplicationDelegate {
    func handleActiveWorkoutRecovery() {
        Task { @MainActor in await Recorder.shared.recover() }
    }
}

@main
struct WalkingStudyWatchApp: App {
    @WKApplicationDelegateAdaptor(StudyDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = Recorder.shared

    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let workout = recorder.current {
                        Label(recorder.phase, systemImage: "figure.walk")
                            .font(.caption.weight(.semibold))
                        if let sample = workout.samples.max(by: { $0.sample_end_at_ms < $1.sample_end_at_ms }) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(sample.bpm.formatted(.number.precision(.fractionLength(0))))
                                    .font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit()
                                Text("bpm").font(.caption)
                            }.foregroundStyle(.pink)
                            Text(Date(timeIntervalSince1970: Double(sample.sample_end_at_ms) / 1000), style: .relative)
                                .font(.caption2)
                        } else { Text("— bpm").font(.title2.bold()) }
                        HStack {
                            Text(Date(timeIntervalSince1970: Double(workout.start) / 1000), style: .timer)
                            Text("· \(workout.samples.count) samples")
                        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if recorder.phase == "Recording" || recorder.phase == "Paused" {
                            if recorder.phase == "Paused" { Button("Resume") { recorder.resume() } }
                            else { Button("Pause") { recorder.pause() } }
                            Button("Finish on Watch", role: .destructive) { recorder.stop() }
                        }
                    } else if recorder.store.pending != nil {
                        Text(recorder.store.pendingTitle ?? "Walking trial").font(.headline)
                        Text(recorder.phase).font(.caption).foregroundStyle(.secondary)
                        Button("Start walk") { Task { await recorder.start() } }.disabled(!recorder.canStart)
                    } else if let latest = recorder.last {
                        Text(latest.acknowledged ? "Transferred" : "Waiting to sync").font(.headline)
                        Text(latest.title).font(.caption).lineLimit(2)
                        Text("\(latest.count ?? 0) samples").font(.caption)
                        if !latest.acknowledged { Button("Retry sync") { recorder.flush(trial: latest.trial) } }
                    } else {
                        Text("Waiting for iPhone").font(.headline)
                        Text("Start a trial in Walking Study on your iPhone.").font(.caption)
                    }
                    Label(recorder.reachable ? "iPhone reachable" : "iPhone unavailable",
                          systemImage: recorder.reachable ? "iphone" : "iphone.slash")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let problem = recorder.problem { Text(problem).font(.caption2).foregroundStyle(.orange) }
                }.padding(.horizontal, 4)
            }
            .task { await recorder.recover(); recorder.flush() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { recorder.flush() } }
        }
    }
}
