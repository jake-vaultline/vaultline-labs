import Foundation
import Darwin

/// Read-only release diagnostic for proving what the production identity
/// collector can see under Ingest's actual sandbox entitlements. Compile this
/// file together with `Sources/VolumeIdentity.swift`, sign the executable with
/// `Resources/VaultlineIngest.entitlements`, then pass one mounted-volume path.
/// It reports presence only and never prints identifier values.
@main
struct VolumeIdentityProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data(
                "usage: VolumeIdentityProbe /Volumes/NAME\n".utf8))
            exit(64)
        }

        let path = CommandLine.arguments[1]
        let identity = VolumeHardwareIdentity.read(
            from: URL(fileURLWithPath: path, isDirectory: true))
        let evidence: [String: Any] = [
            "path_exists": FileManager.default.fileExists(atPath: path),
            "identity_available": identity != nil,
            "hardware_serial": identity?.hardwareSerial != nil,
            "media_uuid": identity?.mediaUUID != nil,
            "vendor": identity?.vendor != nil,
            "model": identity?.model != nil,
            "transport": identity?.transport != nil,
            "topology": identity?.topology != nil,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
