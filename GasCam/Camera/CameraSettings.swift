import Foundation
import AVFoundation

enum VideoResolution: String, CaseIterable, Identifiable, Codable {
    case hd720, hd1080, uhd4k
    var id: String { rawValue }
    /// Sensor (landscape) dimensions.
    var width: Int {
        switch self {
        case .hd720: return 1280
        case .hd1080: return 1920
        case .uhd4k: return 3840
        }
    }
    var height: Int {
        switch self {
        case .hd720: return 720
        case .hd1080: return 1080
        case .uhd4k: return 2160
        }
    }
    var label: String {
        switch self {
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        case .uhd4k: return "4K"
        }
    }
}

enum VideoCodec: String, CaseIterable, Identifiable, Codable {
    case h264, hevc
    var id: String { rawValue }
    var label: String { self == .h264 ? "H.264" : "HEVC" }
    var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
}

struct RecordSettings: Equatable, Codable {
    var codec: VideoCodec = .hevc
    var bitrateMbps: Double = 50
    var saveToPhotos: Bool = true
    var writeCSV: Bool = true

    static let bitratePresets: [Double] = [10, 20, 35, 50, 80, 120, 200]
}

struct LensOption: Identifiable, Hashable {
    let id: String          // AVCaptureDevice.uniqueID
    let label: String       // "0.5x", "1x", "3x", "FRONT"
    let sortKey: Double
}

enum CameraControlKind: String, CaseIterable, Identifiable {
    case fps, shutter, iso, wb, focus, lens, torch
    var id: String { rawValue }
}

enum CameraPresets {
    static let frameRates: [Double] = [24, 25, 30, 48, 50, 60, 100, 120, 240]
    static let isoValues: [Float] = [25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
                                     1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800]
    /// Shutter speeds as denominators (1/x s).
    static let shutterDenominators: [Double] = [24, 25, 30, 48, 50, 60, 96, 100, 120, 125, 180, 200, 240,
                                                250, 360, 480, 500, 1000, 2000, 4000, 8000]
    static let wbPresets: [(String, Float)] = [("钨丝 3200K", 3200), ("荧光 4000K", 4000), ("4500K", 4500),
                                               ("日光 5600K", 5600), ("阴天 6500K", 6500), ("阴影 7500K", 7500)]
    static let torchPresets: [Float] = [0.05, 0.1, 0.25, 0.5, 0.75, 1.0]
}

extension Double {
    /// "1/60" style label for a shutter time in seconds.
    var shutterLabel: String {
        guard self > 0 else { return "--" }
        if self >= 0.5 { return String(format: "%.1fs", self) }
        return "1/\(Int((1 / self).rounded()))"
    }
}
