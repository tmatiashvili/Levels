// SPIKE-001 throwaway code. Not kept after the spike.
//
// A tiny append-only log. Every line is saved to Documents/push-log.txt at once,
// so nothing is lost if iOS suspends or ends the app after a push.

import Foundation
import Observation

@MainActor
@Observable
final class PushLog {
    static let shared = PushLog()

    /// Oldest first, exactly as stored in the file.
    private(set) var lines: [String] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let formatter: DateFormatter

    private init() {
        let documents = URL.documentsDirectory
        fileURL = documents.appending(path: "push-log.txt")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        // Local time with offset, for example 2026-11-24 10:15:03.412 +04:00
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS xxx"
        self.formatter = formatter

        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines = text.split(separator: "\n").map(String.init)
        }
    }

    /// The whole log as text, for Share and Copy.
    var text: String {
        lines.joined(separator: "\n")
    }

    /// Number of push lines for the spike subscription.
    var pushCount: Int {
        lines.filter { $0.contains("PUSH") && $0.contains(SpikeConfig.subscriptionID) }.count
    }

    func add(_ kind: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) | \(kind) | \(message)"
        lines.append(line)
        save()
    }

    func clear() {
        lines.removeAll()
        save()
        add("INFO", "log cleared")
    }

    private func save() {
        let data = Data((text + "\n").utf8)
        do {
            // completeUntilFirstUserAuthentication: the file stays writable while the
            // phone is locked, which is exactly when the pushes arrive (R3).
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Keep the line in memory; it still shows on screen.
            print("PushLog save failed: \(error)")
        }
    }
}
