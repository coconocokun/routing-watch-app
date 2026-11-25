import CryptoKit
import Foundation

struct HeartSample: Codable {
    let sample_id: String
    var watch_seq: Int
    let sample_start_at_ms: Int64
    let sample_end_at_ms: Int64
    let bpm: Double
    let source_id: String
    var quality_flags: [String]

    var canonical: String {
        let hex = String(bpm.bitPattern, radix: 16)
        return [String(watch_seq), sample_id, String(sample_start_at_ms), String(sample_end_at_ms),
                String(repeating: "0", count: 16 - hex.count) + hex, source_id, quality_flags.joined(separator: ",")]
            .joined(separator: "\t")
    }
}

func checksum(_ samples: [HeartSample]) -> String {
    SHA256.hash(data: Data(samples.map(\.canonical).joined(separator: "\n").utf8))
        .map { String(format: "%02x", $0) }.joined()
}

func ms(_ date: Date = Date()) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

struct StudyWorkout: Codable {
    let trial: String
    let session: String
    let title: String
    var start: Int64
    var stop: Int64?
    var finalized: Int64?
    var interrupted = false
    var samples: [HeartSample] = []
    var acked: Set<String> = []
    var acknowledged = false
    var count: Int? = nil
    var digest: String? = nil
    var lastPhonePauseCommand: Int64? = nil
}

struct TrialStore: Codable {
    var active: String?
    var pending: String?
    var pendingTitle: String?
    var workouts: [String: StudyWorkout] = [:]
    var cancelled: Set<String> = []
    var deletions: Set<String> = []
    var processed: [String] = []

    private static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WalkingStudy", isDirectory: true)
    private static let file = folder.appendingPathComponent("workouts.json")

    static func load() throws -> Self {
        guard FileManager.default.fileExists(atPath: file.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        var directory = Self.folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try JSONEncoder().encode(self).write(to: Self.file, options: .atomic)
    }
}
