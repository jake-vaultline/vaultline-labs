import XCTest
@testable import VaultlineIngest

@MainActor
final class VolumeIdentityTests: XCTestCase {
    func testPassportSignalsIncludePhysicalEvidence() {
        let volume = sampleVolume(
            id: "A8A9D05F-21F5-41ED-8DAD-A877E9C21BC0",
            volumeUUID: "A8A9D05F-21F5-41ED-8DAD-A877E9C21BC0",
            hardware: VolumeHardwareIdentity(
                hardwareSerial: "SERIAL-123",
                mediaUUID: "16737B38-9E96-4C4E-BB6B-6F29292C907C",
                vendor: "Example",
                model: "Portable SSD",
                transport: "USB",
                topology: "IODeviceTree:/port/@1:1"))

        let signals = DrivePassportClient.identifiers(for: volume)
        XCTAssertEqual(signals.map(\.type), [
            "volume_uuid", "hardware_serial", "media_uuid",
            "device_model", "device_topology", "capacity",
        ])
        XCTAssertEqual(signals.first(where: { $0.type == "hardware_serial" })?.confidence, 100)
        XCTAssertEqual(signals.first(where: { $0.type == "device_model" })?.value,
                       "Example | Portable SSD")
        XCTAssertFalse(signals.contains(where: { $0.type == "transport" }))
    }

    func testNameAndCapacityFallbackIsNeverCalledAVolumeUUID() {
        let volume = sampleVolume(id: "Untitled-2000000000000")
        let signals = DrivePassportClient.identifiers(for: volume)
        XCTAssertFalse(signals.contains(where: { $0.type == "volume_uuid" }))
        XCTAssertEqual(signals, [PassportDriveIdentifier(
            type: "capacity", value: "2000000000000", confidence: 40)])
    }

    func testNewHardwareObservationDoesNotEraseEarlierEvidence() {
        let older = VolumeHardwareIdentity(
            hardwareSerial: "SERIAL-123", mediaUUID: nil,
            vendor: "Example", model: nil, transport: "USB", topology: nil)
        let newer = VolumeHardwareIdentity(
            hardwareSerial: nil, mediaUUID: "MEDIA-456",
            vendor: nil, model: "Portable SSD", transport: nil, topology: "port-1")
        XCTAssertEqual(older.merging(newer), VolumeHardwareIdentity(
            hardwareSerial: "SERIAL-123", mediaUUID: "MEDIA-456",
            vendor: "Example", model: "Portable SSD", transport: "USB", topology: "port-1"))
    }

    func testDiskArbitrationCoreFoundationUUIDConversion() {
        let expected = "16737B38-9E96-4C4E-BB6B-6F29292C907C"
        let uuid = CFUUIDCreateFromString(kCFAllocatorDefault, expected as CFString)
        XCTAssertEqual(VolumeHardwareIdentity.uuidValue(uuid), expected)
    }

    private func sampleVolume(
        id: String,
        volumeUUID: String? = nil,
        hardware: VolumeHardwareIdentity? = nil
    ) -> KnownVolume {
        KnownVolume(
            id: id,
            name: "Test Drive",
            lastPath: "/Volumes/Test Drive",
            totalBytes: 2_000_000_000_000,
            freeBytes: 1_000_000_000_000,
            isRemovable: true,
            firstSeen: Date(),
            lastSeen: Date(),
            sightings: 1,
            volumeUUID: volumeUUID,
            hardwareIdentity: hardware,
            isMounted: true)
    }
}
