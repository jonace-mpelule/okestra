import Foundation
import XCTest

@testable import DeviceCore
@testable import DeviceTransport

final class LocalDevicesTests: XCTestCase {
  func testDiscoverySeparatesPhonesFromRemoteTunnelAndEmulators() {
    let devices = LocalAndroidDevice.parse(
      """
      * daemon started successfully
      List of devices attached
      USB123 device usb:1-2 product:panther model:Pixel_7 device:panther transport_id:1
      USB456 unauthorized usb:1-3 transport_id:2
      192.168.1.20:42157 offline transport_id:3
      adb-phone-abc._adb-tls-connect._tcp device model:SM_S901B transport_id:4
      127.0.0.1:61009 device model:sdk_gphone64_x86_64 transport_id:5
      emulator-5554 device model:sdk_gphone64_x86_64 transport_id:6
      [::1]:61009 device transport_id:7
      """)
    XCTAssertEqual(
      devices.map(\.id),
      ["USB123", "USB456", "192.168.1.20:42157", "adb-phone-abc._adb-tls-connect._tcp"])
    XCTAssertEqual(devices[0].title, "Pixel 7")
    XCTAssertEqual(devices[0].status, "USB")
    XCTAssertTrue(devices[0].ready)
    XCTAssertFalse(devices[1].ready)
    XCTAssertTrue(devices[1].status.contains("allow USB debugging"))
    XCTAssertTrue(devices[2].wireless)
    XCTAssertFalse(devices[2].ready)
    XCTAssertEqual(devices[3].status, "Wi-Fi")
  }
  func testWirelessAddressAndCodeValidation() throws {
    XCTAssertEqual(try WirelessDeviceAddress.validate(" 192.168.1.20:42157 "), "192.168.1.20:42157")
    XCTAssertEqual(try WirelessDeviceAddress.validate("[fe80::1%en0]:42157"), "[fe80::1%en0]:42157")
    XCTAssertEqual(try WirelessDeviceAddress.validate("phone.local:5555"), "phone.local:5555")
    for bad in [
      "", "192.168.1.20", "phone:0", "phone:65536", "--help:5555", "phone:5555;reboot",
      "phone :5555", ":5555", "fe80::1:5555", "[]:5555",
    ] {
      XCTAssertThrowsError(try WirelessDeviceAddress.validate(bad), bad)
    }
    XCTAssertEqual(try WirelessDeviceAddress.validateCode("012345"), "012345")
    for bad in ["12345", "1234567", "１２３４５６", "12 345", "12345x"] {
      XCTAssertThrowsError(try WirelessDeviceAddress.validateCode(bad))
    }
  }
  private func fixture() throws -> (URL, DeviceSession) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cli = root.appendingPathComponent("okestra")
    let adb = root.appendingPathComponent("adb")
    // Resolve via pwd so temporary paths never need interpolation into shell code.
    try Data(
      """
      #!/bin/sh
      [ "$1" = android ] && [ "$2" = adb-path ] || exit 91
      printf '%s/adb\\n' "$PWD"
      """.utf8
    ).write(to: cli)
    try Data(
      """
      #!/bin/sh
      case "$1" in
      devices) printf 'List of devices attached\\nUSB123 unauthorized usb:1-2\\n' ;;
      pair)
        [ "$#" = 2 ] || exit 92
        read -r code
        [ "$code" = 012345 ] || exit 93
        printf 'Successfully paired to %s\\n' "$2" ;;
      connect)
        case "$2" in
        fail.local:5555) printf 'failed to connect to fail.local:5555\\n' ;;
        *) printf 'connected to %s\\n' "$2" ;;
        esac ;;
      *) exit 94 ;;
      esac
      """.utf8
    ).write(to: adb)
    for url in [cli, adb] {
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    return (
      root,
      DeviceSession(
        cli: cli.path, workingDirectory: root.path, profile: nil, targetSerial: "USB123")
    )
  }
  func testLocalDiscoveryRequiresNoPairedServerAndRefusesUnauthorizedDevice() throws {
    let (root, operation) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertEqual(try operation.localDevices().first?.state, "unauthorized")
    let missing = DeviceSession(
      cli: root.appendingPathComponent("okestra").path, workingDirectory: root.path,
      profile: "must-not-use-server", targetSerial: "MISSING")
    XCTAssertThrowsError(try missing.stream()) { error in
      XCTAssertTrue(error.localizedDescription.contains("Phone disconnected"))
    }
    XCTAssertThrowsError(try operation.stream()) { error in
      XCTAssertTrue(error.localizedDescription.contains("allow USB debugging"))
    }
  }
  func testWirelessPairingUsesStdinAndConnectionRejectsAdbFailureOutput() throws {
    let (root, operation) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertTrue(
      try operation.pairWireless(address: "phone.local:37123", code: "012345").contains(
        "Paired with"))
    XCTAssertEqual(try operation.connectWireless(address: "phone.local:42157"), "phone.local:42157")
    XCTAssertThrowsError(try operation.connectWireless(address: "fail.local:5555"))
  }
}
