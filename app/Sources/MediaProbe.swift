import Foundation
import AVFoundation
import CoreMedia
import ImageIO

/// One file's worth of Pass 2 findings. Every field optional — a probe that
/// learns two things out of five is still worth having.
struct ProbeResult {
    var codec: String?
    var resolution: String?
    var frameRate: String?
    var duration: TimeInterval = 0
    var camera: String?
    var cameraFromMetadata = false
    var captureDate: Date?
}

/// Pass 2. Opens each media file's container header to read what the filesystem
/// can't tell you: codec, resolution, frame rate, duration, camera, capture date.
///
/// Deliberately does NOT decode frames. We read headers and metadata only, which
/// is why this runs in minutes rather than hours on a full drive.
enum MediaProbe {

    /// How many files to probe at once. Media probing is I/O-bound on a spinning
    /// disk or a network volume, so more concurrency mostly buys seek thrash.
    static let concurrency = 6

    /// AVFoundation's async loaders have no built-in timeout, and some formats
    /// it doesn't fully understand — R3D without RED's own system component
    /// installed is the one that's bitten us — can hang a `load()` call rather
    /// than fail it. One hung file would otherwise permanently occupy a
    /// concurrency slot in `Prober` and the "Reading media" pass would never
    /// finish. A probe that times out is reported exactly like a probe that
    /// found nothing — both mean "no data for this file," which every caller
    /// already handles.
    private static let timeout: Duration = .seconds(8)

    static func probe(path: String, category: MediaCategory) async -> ProbeResult? {
        switch category {
        case .video, .audio:
            return await withTimeout { await probeAV(path: path) }
        case .photo:
            return probeImage(path: path)
        default:
            return nil
        }
    }

    private static func withTimeout(_ operation: @escaping @Sendable () async -> ProbeResult?) async -> ProbeResult? {
        await withTaskGroup(of: ProbeResult?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    // MARK: AVFoundation

    private static func probeAV(path: String) async -> ProbeResult? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension
        let asset = AVURLAsset(url: url, options: [
            // We never play these; skip the work of preparing for playback.
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])

        var out = ProbeResult()

        if let dur = try? await asset.load(.duration), dur.isNumeric {
            let seconds = CMTimeGetSeconds(dur)
            if seconds.isFinite, seconds > 0 { out.duration = seconds }
        }

        if let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first {
            if let fds = try? await track.load(.formatDescriptions), let fd = fds.first {
                out.codec = CodecNames.name(for: CMFormatDescriptionGetMediaSubType(fd), ext: ext)
            }
            if let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                // Apply rotation so a vertical clip isn't filed as its raw buffer size.
                let applied = size.applying(transform)
                out.resolution = CodecNames.resolutionBucket(
                    width: Int(abs(applied.width).rounded()),
                    height: Int(abs(applied.height).rounded())
                )
            }
            if let fps = try? await track.load(.nominalFrameRate) {
                out.frameRate = CodecNames.frameRateLabel(fps)
            }
        } else if let tracks = try? await asset.loadTracks(withMediaType: .audio),
                  let track = tracks.first,
                  let fds = try? await track.load(.formatDescriptions), let fd = fds.first {
            out.codec = CodecNames.name(for: CMFormatDescriptionGetMediaSubType(fd), ext: ext)
        }

        // Metadata: camera make/model and real capture date.
        var make: String?, model: String?
        if let items = try? await asset.load(.metadata) {
            for item in items {
                guard let key = item.identifier else { continue }
                switch key {
                // NOTE on the double-optional dance below: `load(.stringValue)`
                // already returns an optional, and `try?` wraps it again. The
                // `if let` peels exactly one level, so the assigned value stays
                // a plain String?/Date?.
                case .quickTimeMetadataMake, .quickTimeUserDataMake:
                    if make == nil, let v = try? await item.load(.stringValue) { make = v }
                case .quickTimeMetadataModel, .quickTimeUserDataModel:
                    if model == nil, let v = try? await item.load(.stringValue) { model = v }
                case .commonIdentifierCreationDate, .quickTimeMetadataCreationDate:
                    if out.captureDate == nil, let v = try? await item.load(.dateValue) {
                        out.captureDate = v
                    }
                default: break
                }
            }
        }
        if out.captureDate == nil,
           let item = try? await asset.load(.creationDate),
           let v = try? await item.load(.dateValue) {
            out.captureDate = v
        }

        if let cam = CodecNames.normalizeCamera(make: make, model: model) {
            out.camera = cam
            out.cameraFromMetadata = true
        } else if let guess = CodecNames.cameraFromConvention(path: path) {
            out.camera = guess
        }

        return out
    }

    // MARK: Stills

    private static func probeImage(path: String) -> ProbeResult? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }

        var out = ProbeResult()

        if let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            out.resolution = CodecNames.resolutionBucket(width: w, height: h)
        }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        if let cam = CodecNames.normalizeCamera(
            make: tiff?[kCGImagePropertyTIFFMake] as? String,
            model: tiff?[kCGImagePropertyTIFFModel] as? String
        ) {
            out.camera = cam
            out.cameraFromMetadata = true
        } else if let guess = CodecNames.cameraFromConvention(path: path) {
            out.camera = guess
        }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            out.captureDate = f.date(from: raw)
        }

        return out
    }
}
