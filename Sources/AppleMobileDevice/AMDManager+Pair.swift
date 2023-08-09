//
//  AMDManager+Pair.swift
//
//
//  Created by QAQ on 2023/8/11.
//

import AnyCodable
import Foundation
import AppleMobileDeviceLibrary

public extension AppleMobileDeviceManager {
    class PairRecord: CodableRecord {
        public var deviceCertificate: Data? { valueFor("DeviceCertificate") }
        public var escrowBag: Data? { valueFor("EscrowBag") }
        public var hostCertificate: Data? { valueFor("HostCertificate") }
        public var hostID: String? { valueFor("HostID") }
        public var hostPrivateKey: Data? { valueFor("HostPrivateKey") }
        public var rootCertificate: Data? { valueFor("RootCertificate") }
        public var rootPrivateKey: Data? { valueFor("RootPrivateKey") }
        public var systemBUID: String? { valueFor("SystemBUID") }
        public var wifiMACAddress: String? { valueFor("WiFiMACAddress") }
    }

    func obtainSystemBUID() -> String? {
        var buf: UnsafeMutablePointer<CChar>?
        defer { if let buf { free(buf) } }
        guard usbmuxd_read_buid(&buf) == 0, let buf else { return nil }
        let ret = String(cString: buf)
        return ret.isEmpty ? nil : ret
    }

    func obtainPairRecord(udid: String) -> PairRecord? {
        var result: AnyCodable?
        var buf: UnsafeMutablePointer<CChar>?
        defer { if let buf { free(buf) } }
        var len: Int32 = 0
        usbmuxd_read_pair_record(udid, &buf, &len)
        if let buf, len > 0 {
            let data = Data(bytes: buf, count: Int(len))
            result = try? PropertyListDecoder().decode(AnyCodable.self, from: data)
        }
        guard let result else { return nil }
        return .init(store: result)
    }

    func isDevicePaired(udid: String, connection: ConnectionMethod = configuration.connectionMethod) -> Bool? {
        var result: Bool?
        requireDevice(udid: udid, connection: connection) { device in
            guard let device else { return }
            result = false
            requireLockdownClient(device: device, handshake: true) { client in
                guard client != nil else { return }
                result = true
            }
        }
        return result
    }

    func sendPairRequest(udid: String, connection: ConnectionMethod = configuration.connectionMethod) {
        requireDevice(udid: udid, connection: connection) { device in
            guard let device else { return }
            requireLockdownClient(device: device, handshake: false) { client in
                guard let client else { return }
                lockdownd_pair(client, nil)
            }
        }
    }

    func unpaireDevice(udid: String, connection: ConnectionMethod = configuration.connectionMethod) {
        requireDevice(udid: udid, connection: connection) { device in
            guard let device else { return }
            requireLockdownClient(device: device, handshake: true) { client in
                guard let client else { return }
                lockdownd_unpair(client, nil)
            }
        }
    }

    func isDeviceWirelessConnectionEnabled(udid: String, connection: ConnectionMethod = configuration.connectionMethod) -> Bool? {
        let deviceInfo = obtainDeviceInfo(
            udid: udid,
            domain: "com.apple.mobile.wireless_lockdown",
            key: nil,
            connection: connection
        )
        return deviceInfo?.valueFor("EnableWifiConnections")
    }

    func setDeviceWirelessConnectionEnabled(udid: String, enabled: Bool, connection: ConnectionMethod = configuration.connectionMethod) {
        requireDevice(udid: udid, connection: connection) { device in
            guard let device else { return }
            requireLockdownClient(device: device, handshake: true) { client in
                guard let client else { return }
                let bool = plist_new_bool(enabled ? 1 : 0)
                lockdownd_set_value(
                    client,
                    "com.apple.mobile.wireless_lockdown",
                    "EnableWifiConnections",
                    bool
                )
            }
        }
    }
}
