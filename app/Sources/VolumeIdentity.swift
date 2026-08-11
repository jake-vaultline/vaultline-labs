import Foundation
import DiskArbitration
import IOKit

/// Best-effort physical identity signals for a mounted volume. These values are
/// kept locally in the drive registry; the Passport client sends them only to
/// the explicitly configured service, which hashes them before persistence.
///
/// Disk Arbitration exposes these without reading media contents. Some bridges
/// omit one or more fields, so every signal is optional and identity matching
/// must remain evidence-based rather than assuming a serial always exists.
struct VolumeHardwareIdentity: Codable, Equatable {
    var hardwareSerial: String?
    var mediaUUID: String?
    var vendor: String?
    var model: String?
    var transport: String?
    var topology: String?

    var isEmpty: Bool {
        [hardwareSerial, mediaUUID, vendor, model, transport, topology]
            .allSatisfy { $0 == nil }
    }

    func merging(_ newer: VolumeHardwareIdentity) -> VolumeHardwareIdentity {
        VolumeHardwareIdentity(
            hardwareSerial: newer.hardwareSerial ?? hardwareSerial,
            mediaUUID: newer.mediaUUID ?? mediaUUID,
            vendor: newer.vendor ?? vendor,
            model: newer.model ?? model,
            transport: newer.transport ?? transport,
            topology: newer.topology ?? topology)
    }

    static func read(from volumeURL: URL) -> VolumeHardwareIdentity? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(
                kCFAllocatorDefault, session, volumeURL as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return nil }

        let identity = VolumeHardwareIdentity(
            hardwareSerial: hardwareSerial(for: disk),
            mediaUUID: uuidValue(description[key(kDADiskDescriptionMediaUUIDKey)]),
            vendor: stringValue(description[key(kDADiskDescriptionDeviceVendorKey)]),
            model: stringValue(description[key(kDADiskDescriptionDeviceModelKey)]),
            transport: stringValue(description[key(kDADiskDescriptionDeviceProtocolKey)]),
            // The media path is the compact device-tree/port topology. Do not
            // send the much larger IOService path or the user's mount path.
            topology: stringValue(description[key(kDADiskDescriptionMediaPathKey)]))
        return identity.isEmpty ? nil : identity
    }

    private static func hardwareSerial(for disk: DADisk) -> String? {
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }

        // USB serial is normally the enclosure/device identifier. The SCSI
        // inquiry serial is a useful fallback for SATA/NVMe bridges that do not
        // publish the USB property.
        let keys = [
            "USB Serial Number",
            "kUSBSerialNumberString",
            "Serial Number",
            "SerialNumber",
            "INQUIRY Unit Serial Number",
        ]
        let options = IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
        for property in keys {
            let raw = IORegistryEntrySearchCFProperty(
                media, kIOServicePlane, property as CFString,
                kCFAllocatorDefault, options)
            if let serial = stringValue(raw)?.uppercased() { return serial }
        }
        return nil
    }

    private static func key(_ value: CFString) -> String { value as String }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func uuidValue(_ value: Any?) -> String? {
        if let uuid = value as? UUID { return uuid.uuidString.uppercased() }
        if let uuid = value as? NSUUID { return uuid.uuidString.uppercased() }
        if let value, CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() {
            let uuid = value as! CFUUID
            return (CFUUIDCreateString(kCFAllocatorDefault, uuid)! as String).uppercased()
        }
        return stringValue(value)?.uppercased()
    }
}
