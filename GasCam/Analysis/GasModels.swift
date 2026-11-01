import Foundation
import CoreGraphics

// MARK: - Parameters

/// Which colour signal is used as the sensor response.
enum SignalChannel: String, CaseIterable, Identifiable, Codable {
    case red, green, blue, luma, redChroma
    var id: String { rawValue }
    var label: String {
        switch self {
        case .red: return "R"
        case .green: return "G"
        case .blue: return "B"
        case .luma: return "Y (亮度)"
        case .redChroma: return "r = R/(R+G+B)"
        }
    }
}

/// Sign of the expected optical change. The LSPR film in the test video shows R decreasing.
enum ResponsePolarity: String, CaseIterable, Identifiable, Codable {
    case decrease, increase, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .decrease: return "下降 (−ΔS)"
        case .increase: return "上升 (+ΔS)"
        case .both: return "双向 |ΔS|"
        }
    }
}

/// All tunables of the detector. Defaults were validated on A001_10312104_C067.mov
/// (ethanol puff on the TPI LSPR plate, 1080p 100 fps) with tools/gas_reference.py.
struct GasParams: Equatable, Codable {
    var channel: SignalChannel = .red
    var polarity: ResponsePolarity = .decrease
    /// Box-blur radius (analysis pixels). Applied twice ≈ Gaussian.
    var blurRadius: Int = 2
    /// Frames averaged for the baseline (reference) image.
    var baselineFrames: Int = 30
    /// Temporal EMA weight of the newest frame (1 = no smoothing).
    var emaAlpha: Float = 0.5
    /// Pixel is "active" when response > max(minPercent, kSigma · baseline noise).
    var kSigma: Float = 4
    var minPercent: Float = 2
    /// Consecutive active frames needed before an arrival is registered.
    var confirmFrames: Int = 2
    /// Fraction of valid ROI pixels that must have been reached before a source estimate is shown.
    var minArrivedFraction: Float = 0.01
    /// Heat-map colour scale: response (%) that maps to the top colour.
    var displayMaxPercent: Float = 12
    /// Arrival map colour span (s).
    var arrivalSpan: Float = 1.0
    /// Below this asymmetry the source is reported as a point (gas came from above the plate).
    var directionConfMin: Float = 0.25
    /// Clear the arrival map after this many quiet seconds (0 = never). The last result stays as a ghost.
    var autoRearmSeconds: Double = 5
    /// Slowly follow baseline drift on pixels that are not reacting.
    var baselineTracking: Bool = false
    /// Max analysis rate (Hz). Camera may run faster; extra frames are only recorded/displayed.
    var analysisRate: Double = 30
    /// Lock AE / AWB / AF when a new baseline is taken (strongly recommended for measurements).
    var lockCameraOnBaseline: Bool = true

    /// Changing these invalidates the baseline.
    func requiresRebaseline(comparedTo o: GasParams) -> Bool {
        channel != o.channel || blurRadius != o.blurRadius || baselineFrames != o.baselineFrames
    }
}

/// Normalised rectangle (0…1, origin top-left of the upright image).
struct NormRect: Equatable, Codable {
    var x0: CGFloat
    var y0: CGFloat
    var x1: CGFloat
    var y1: CGFloat

    static let defaultROI = NormRect(x0: 0.05, y0: 0.05, x1: 0.95, y1: 0.60)

    var width: CGFloat { x1 - x0 }
    var height: CGFloat { y1 - y0 }

    func clamped(minSize: CGFloat = 0.08) -> NormRect {
        var r = self
        r.x0 = min(max(0, r.x0), 1 - minSize)
        r.y0 = min(max(0, r.y0), 1 - minSize)
        r.x1 = max(min(1, r.x1), r.x0 + minSize)
        r.y1 = max(min(1, r.y1), r.y0 + minSize)
        return r
    }
}

// MARK: - Results

struct GasSource: Equatable {
    enum Mode: String {
        /// Gas entered the plate from one side: arrow from plume centroid through the entry point.
        case direction
        /// Plume spread radially: the source is above/at the entry point.
        case point
    }
    /// Centroid of the earliest-reached pixels (where gas first touched the plate), normalised.
    var earliest: CGPoint
    /// Centroid of every pixel reached so far, normalised.
    var centroid: CGPoint
    /// Unit vector (image coords, y down) pointing towards the source.
    var direction: CGVector
    /// |E − C| / plume radius. 0 = radial spreading, ~1 = one-sided entry.
    var confidence: Float
    /// Upstream point on the ROI edge (direction mode) or the entry point (point mode), normalised.
    var sourcePoint: CGPoint
    var mode: Mode
    /// Screen angle in degrees: 0 = right, 90 = up, 180 = left, −90 = down.
    var angleDeg: Double
    var arrivedCount: Int
    /// Seconds since the baseline finished.
    var firstArrival: Double
}

enum GasPhase: Equatable {
    case waiting
    case baseline(progress: Float)
    case monitoring
    case detected
}

struct GasFrameResult: Equatable {
    var phase: GasPhase = .waiting
    var time: Double = 0
    var meanResponse: Float = 0
    var maxResponse: Float = 0
    var activeFraction: Float = 0
    var hotspot: CGPoint? = nil
    var source: GasSource? = nil
    /// Result of the previous event, kept after auto re-arm.
    var lastSource: GasSource? = nil
    var validPixels: Int = 0
    var noiseMedianPercent: Float = 0
}

enum OverlayMode: String, CaseIterable, Identifiable, Codable {
    case live, heat, arrival
    var id: String { rawValue }
    var label: String {
        switch self {
        case .live: return "LIVE"
        case .heat: return "HEAT"
        case .arrival: return "ARRIVAL"
        }
    }
}
