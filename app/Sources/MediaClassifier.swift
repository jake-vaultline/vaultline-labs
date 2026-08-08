import Foundation

/// Extension-based classification. Pass 1 only — deliberately does not open files.
/// Codec, resolution, frame rate and camera detection are Pass 2 (AVFoundation),
/// which is not part of v1's first milestone.
enum MediaClassifier {

    static let video: Set<String> = [
        "mov", "mp4", "m4v", "mxf", "avi", "mkv", "mts", "m2ts", "m2t", "ts",
        "braw", "r3d", "ari", "arx", "cine", "dpx", "exr", "webm", "mpg", "mpeg",
        "vob", "wmv", "flv", "insv", "3gp", "mjpeg"
    ]

    static let photo: Set<String> = [
        "jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "webp", "gif", "bmp",
        "psd", "psb", "dng", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2",
        "raf", "orf", "rw2", "pef", "x3f", "erf", "kdc", "3fr", "iiq", "gpr"
    ]

    static let audio: Set<String> = [
        "wav", "bwf", "aif", "aiff", "aifc", "mp3", "m4a", "aac", "flac", "caf",
        "ogg", "opus", "wma", "ac3", "dts"
    ]

    /// Editorial / grading / motion project documents. Some of these are bundles
    /// (directories) rather than flat files — handled in the walker.
    static let project: Set<String> = [
        "prproj", "fcpbundle", "fcpxml", "fcpxmld", "drp", "aep", "aepx", "ppj",
        "veg", "motn", "aaf", "edl", "otio", "xges", "wlmp", "imovieproj",
        "rcproject", "dra", "avid", "avp"
    ]

    static let sidecar: Set<String> = [
        "xmp", "cube", "look", "srt", "vtt", "scc", "stl", "cdl", "ccc",
        "thm", "lrv", "md5", "sha1", "mhl", "pek", "cfa", "sfk"
    ]

    static func category(forExtension raw: String) -> MediaCategory {
        let e = raw.lowercased()
        if video.contains(e)   { return .video }
        if photo.contains(e)   { return .photo }
        if audio.contains(e)   { return .audio }
        if project.contains(e) { return .project }
        if sidecar.contains(e) { return .sidecar }
        return .other
    }

    /// Directories that should be treated as a single project document rather than
    /// descended into as plain folders (they still get walked for media, because
    /// FCP libraries frequently contain the actual footage).
    static func isProjectBundle(extension raw: String) -> Bool {
        let e = raw.lowercased()
        return ["fcpbundle", "fcpxmld", "dra", "rcproject", "imovieproj", "avp"].contains(e)
    }
}
