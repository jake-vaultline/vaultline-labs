import Foundation
import CoreMedia

enum CodecNames {

    /// FourCC → human name. What a post supervisor calls it, not what the
    /// container calls it.
    private static let table: [String: String] = [
        // Apple ProRes
        "apco": "ProRes 422 Proxy",
        "apcs": "ProRes 422 LT",
        "apcn": "ProRes 422",
        "apch": "ProRes 422 HQ",
        "ap4h": "ProRes 4444",
        "ap4x": "ProRes 4444 XQ",
        "aprh": "ProRes RAW",
        "aprn": "ProRes RAW HQ",
        // H.264 / HEVC
        "avc1": "H.264",
        "avc3": "H.264",
        "h264": "H.264",
        "hvc1": "HEVC",
        "hev1": "HEVC",
        "dvh1": "HEVC (Dolby Vision)",
        "dvhe": "HEVC (Dolby Vision)",
        // Avid
        "AVdh": "DNxHR",
        "AVdn": "DNxHD",
        // Older / misc
        "mp4v": "MPEG-4",
        "mpg2": "MPEG-2",
        "mx5p": "MPEG IMX",
        "dvc ": "DV",
        "dvcp": "DV PAL",
        "jpeg": "Motion JPEG",
        "mjpa": "Motion JPEG A",
        "png ": "PNG",
        "rle ": "Animation",
        "v210": "Uncompressed 10-bit",
        "2vuy": "Uncompressed 8-bit",
        // Audio
        "lpcm": "PCM",
        "aac ": "AAC",
        "mp4a": "AAC",
        "alac": "ALAC",
        ".mp3": "MP3"
    ]

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),  UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "????"
    }

    /// `ext` refines a couple of cases the FourCC alone gets wrong.
    static func name(for code: FourCharCode, ext: String = "") -> String {
        let raw = fourCC(code)
        var name = table[raw] ?? raw.trimmingCharacters(in: .whitespaces).uppercased()

        // XAVC is Sony's wrapper around H.264/HEVC, not a codec AVFoundation
        // reports. Only claim it where the container makes it unambiguous —
        // guessing "XAVC" from an .mp4 would be wrong more often than right.
        if ext.lowercased() == "mxf", name == "H.264" { name = "XAVC-I (H.264)" }

        return name
    }

    // MARK: Resolution buckets

    static func resolutionBucket(width: Int, height: Int) -> String {
        let w = max(width, height)
        switch w {
        case 7000...:      return "8K"
        case 5800..<7000:  return "6K"
        case 4800..<5800:  return "5K"
        case 3600..<4800:  return "4K"
        case 2400..<3600:  return "2.5K"
        case 1800..<2400:  return "1080p"
        case 1200..<1800:  return "720p"
        default:           return "SD"
        }
    }

    // MARK: Frame rates

    private static let common: [Double] = [
        23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 100, 119.88, 120, 240
    ]

    static func frameRateLabel(_ fps: Float) -> String? {
        let v = Double(fps)
        guard v > 0.5 else { return nil }
        let snapped = common.min(by: { abs($0 - v) < abs($1 - v) }) ?? v
        guard abs(snapped - v) < 0.6 else {
            return String(format: "%.2f fps", v)
        }
        return snapped == snapped.rounded()
            ? String(format: "%.0f fps", snapped)
            : String(format: "%.3g fps", snapped)
    }

    // MARK: Cameras

    /// Tidies vendor strings into what people actually say. Sony writes
    /// "ILME-FX6"; nobody calls it that out loud.
    private static let modelAliases: [String: String] = [
        "ILME-FX6":  "Sony FX6",
        "ILME-FX3":  "Sony FX3",
        "ILME-FX30": "Sony FX30",
        "ILCE-7SM3": "Sony a7S III",
        "ILCE-7M4":  "Sony a7 IV",
        "ILCE-1":    "Sony a1",
        "PXW-FX9":   "Sony FX9",
        "EOS R5 C":  "Canon R5 C",
        "EOS R5":    "Canon R5",
        "EOS C70":   "Canon C70",
        "FC3582":    "DJI Mavic 3",
        "FC7303":    "DJI Mini 2"
    ]

    static func normalizeCamera(make: String?, model: String?) -> String? {
        let mk = (make ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let md = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !md.isEmpty || !mk.isEmpty else { return nil }

        if let alias = modelAliases[md] { return alias }

        // Apple already writes "iPhone 15 Pro" as the model — don't prefix it.
        if md.lowercased().hasPrefix("iphone") || md.lowercased().hasPrefix("ipad") { return md }
        if md.isEmpty { return mk }
        if mk.isEmpty { return md }

        let mkWord = mk.split(separator: " ").first.map(String.init) ?? mk
        return md.lowercased().contains(mkWord.lowercased())
            ? md
            : "\(mkWord.capitalized) \(md)"
    }

    /// Last-resort guess from where the file sits and what it's called. Only used
    /// when no metadata was found, and reported as a lower-confidence source.
    static func cameraFromConvention(path: String) -> String? {
        let p = path.uppercased()
        let name = (path as NSString).lastPathComponent.uppercased()

        if p.contains("/XDROOT/") || p.contains("/PRIVATE/M4ROOT/") { return "Sony (card structure)" }
        if name.hasPrefix("DJI_") { return "DJI (filename)" }
        if name.hasPrefix("MVI_") { return "Canon (filename)" }
        if name.hasPrefix("GX") || name.hasPrefix("GOPR") { return "GoPro (filename)" }
        if name.range(of: #"^C\d{4}\."#, options: .regularExpression) != nil { return "Sony (filename)" }
        if name.range(of: #"^A\d{3}_"#, options: .regularExpression) != nil { return "ARRI/RED (filename)" }
        return nil
    }
}
