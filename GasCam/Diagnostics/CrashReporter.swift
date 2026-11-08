import Foundation
import MetricKit
import Darwin

/// Collects crash information so it can be shared from Settings → 崩溃记录:
///  • iOS crash reports (MetricKit, delivered on a later launch),
///  • uncaught Objective-C exceptions (e.g. AVFoundation argument errors) with the call stack,
///  • fatal signals (Swift runtime traps, bad memory access) with the call stack.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    static var directory: URL {
        FramePipeline.documentsURL.appendingPathComponent("CrashLogs", isDirectory: true)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    /// Pre-built path for the signal handler (no allocation-heavy work is allowed there).
    private static var signalPath: [CChar] = []

    func start() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        MXMetricManager.shared.add(self)
        handle(MXMetricManager.shared.pastDiagnosticPayloads)
        NSSetUncaughtExceptionHandler { e in CrashReporter.writeException(e) }
        let path = Self.directory.appendingPathComponent("signal_last.txt").path
        Self.signalPath = Array(path.utf8CString)
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig) { s in CrashReporter.writeSignal(s) }
        }
        Self.archiveSignalFile()
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) { handle(payloads) }

    private func handle(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads where !(p.crashDiagnostics ?? []).isEmpty {
            let url = Self.directory.appendingPathComponent("ios_crash_\(Self.stampFormatter.string(from: p.timeStampEnd)).json")
            if FileManager.default.fileExists(atPath: url.path) { continue }
            try? p.jsonRepresentation().write(to: url)
        }
    }

    private static func writeException(_ e: NSException) {
        var text = "GasCam \(appVersion)\n\(Date())\n"
        text += "\(e.name.rawValue): \(e.reason ?? "")\n\n"
        text += e.callStackSymbols.joined(separator: "\n")
        let url = directory.appendingPathComponent("exception_\(stampFormatter.string(from: Date())).txt")
        try? text.data(using: .utf8)?.write(to: url)
    }

    /// Best effort: write the signal and the call stack, then let the default handler end the app.
    private static func writeSignal(_ s: Int32) {
        signalPath.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            let fd = open(base, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            if fd >= 0 {
                let head = "GasCam \(appVersion)\nsignal \(s)\n\n" + Thread.callStackSymbols.joined(separator: "\n")
                head.utf8CString.withUnsafeBufferPointer { b in
                    if let a = b.baseAddress { _ = write(fd, a, max(0, b.count - 1)) }
                }
                close(fd)
            }
        }
        signal(s, SIG_DFL)
        raise(s)
    }

    /// A signal file from the previous run gets a dated name.
    private static func archiveSignalFile() {
        let fm = FileManager.default
        let src = directory.appendingPathComponent("signal_last.txt")
        guard fm.fileExists(atPath: src.path) else { return }
        let date = (try? src.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let dst = directory.appendingPathComponent("signal_\(stampFormatter.string(from: date)).txt")
        try? fm.moveItem(at: src, to: dst)
    }

    static func list() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.lastPathComponent != "signal_last.txt" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }

    static func clear() {
        for u in list() { try? FileManager.default.removeItem(at: u) }
    }
}
