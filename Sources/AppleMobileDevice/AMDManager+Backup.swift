//
//  AMDManager+Backup.swift
//
//
//  Created by QAQ on 2023/8/14.
//

import AnyCodable
import Foundation
import AppleMobileDeviceLibrary
import AppleMobileDeviceLibraryBackup

public extension AppleMobileDeviceManager {
    func obtainDeviceBackupInfo(
        udid: String,
        connection: ConnectionMethod = configuration.connectionMethod
    ) -> AnyCodable? {
        readFromLockdown(udid: udid, domain: "com.apple.mobile.backup", key: nil, connection: connection)
    }

    func isBackupEncryptionEnabled(
        udid: String,
        connection: ConnectionMethod = configuration.connectionMethod
    ) -> Bool? {
        guard let read = obtainDeviceBackupInfo(udid: udid, connection: connection),
              let dic = read.value as? [String: Any],
              let value = dic["WillEncrypt"] as? Bool
        else { return nil }
        return value
    }

    func disableBackupPassword(
        udid: String,
        currentPassword: String,
        connection: ConnectionMethod = configuration.connectionMethod
    ) {
        requireDevice(udid: udid, connection: connection) { device in
            guard let device else { return }
            requireLockdownClient(device: device, handshake: true) { lkd_client in
                guard let lkd_client else { return }
                requireLockdownService(client: lkd_client, serviceName: MOBILEBACKUP2_SERVICE_NAME, requiresEscrowBag: true) { mb2_service in
                    guard let mb2_service else { return }
                    requireMobileBackup2Service(device: device, mobileBackup2Service: mb2_service) { mb2_client in
                        guard let mb2_client else { return }
                        let options: [String: Codable] = [
                            "OldPassword": currentPassword,
                            "TargetIdentifier": udid,
                        ]
                        let data = try! PropertyListEncoder().encode(AnyCodable(options))
                        var query: plist_t?
                        defer { plist_free(query) }
                        _ = data.withUnsafeBytes { byte in
                            plist_from_memory(byte.baseAddress, UInt32(byte.count), &query, nil)
                        }
                        guard let query else { return }
                        mobilebackup2_send_message(mb2_client, "ChangePassword", query)
                    }
                }
            }
        }
    }

    func enableBackupPassword(
        udid: String,
        password: String,
        connection: ConnectionMethod = configuration.connectionMethod
    ) {
        requireDevice(udid: udid, connection: connection) { device in
            guard let device else { return }
            requireLockdownClient(device: device, handshake: true) { lkd_client in
                guard let lkd_client else { return }
                requireLockdownService(client: lkd_client, serviceName: MOBILEBACKUP2_SERVICE_NAME, requiresEscrowBag: true) { mb2_service in
                    guard let mb2_service else { return }
                    requireMobileBackup2Service(device: device, mobileBackup2Service: mb2_service) { mb2_client in
                        guard let mb2_client else { return }
                        let options: [String: Codable] = [
                            "NewPassword": password,
                            "TargetIdentifier": udid,
                        ]
                        let data = try! PropertyListEncoder().encode(AnyCodable(options))
                        var query: plist_t?
                        defer { plist_free(query) }
                        _ = data.withUnsafeBytes { byte in
                            plist_from_memory(byte.baseAddress, UInt32(byte.count), &query, nil)
                        }
                        guard let query else { return }
                        mobilebackup2_send_message(mb2_client, "ChangePassword", query)
                    }
                }
            }
        }
    }

    func createBackup(
        udid: String,
        delegate resolver: AppleMobileDeviceBackupDelegate,
        connection: ConnectionMethod = configuration.connectionMethod
    ) {
        requireDevice(udid: udid, connection: connection) { device in
            guard let device else {
                resolver.failure(error: .unableToConnect)
                return
            }
            resolver.arrival(checkpoint: .initializedConnection)
            requireLockdownClient(device: device, handshake: true) { lkd_client in
                guard let lkd_client else {
                    resolver.failure(error: .unableToHandshake)
                    return
                }
                requireLockdownService(client: lkd_client, serviceName: AFC_SERVICE_NAME) { afc_service in
                    guard let afc_service else {
                        resolver.failure(error: .unableToStartService)
                        return
                    }
                    requireAppleFileConduitService(device: device, appleFileConduitService: afc_service) { afc_client in
                        guard let afc_client else {
                            resolver.failure(error: .unableToStartService)
                            return
                        }
                        requireLockdownService(client: lkd_client, serviceName: MOBILEBACKUP2_SERVICE_NAME, requiresEscrowBag: true) { mb2_service in
                            guard let mb2_service else {
                                resolver.failure(error: .unableToStartService)
                                return
                            }
                            resolver.arrival(checkpoint: .initializedService)
                            requireMobileBackup2Service(device: device, mobileBackup2Service: mb2_service) { mb2_client in
                                guard let mb2_client else {
                                    resolver.failure(error: .unableToStartService)
                                    return
                                }
                                backupExecute(
                                    udid: udid,
                                    device: device,
                                    lkd_client: lkd_client,
                                    afc_client: afc_client,
                                    mb2_client: mb2_client,
                                    delegate: resolver
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func backupExecute(
        udid: String,
        device: idevice_t,
        lkd_client: lockdownd_client_t,
        afc_client: afc_client_t,
        mb2_client: mobilebackup2_client_t,
        delegate resolver: AppleMobileDeviceBackupDelegate
    ) {
        defer { resolver.arrival(checkpoint: .backendCompleted) }
        if resolver.isCancelled() {
            resolver.failure(error: .cancelled)
            return
        }

        let remoteVersion = backupVersionHandshake(mb2_client: mb2_client)
        resolver.arrival(checkpoint: .negotiatedProtocol(version: String(remoteVersion)))

        let rootLocation = resolver.backupRoot()
        do {
            var isDir = ObjCBool(false)
            if FileManager.default.fileExists(atPath: rootLocation.path, isDirectory: &isDir) {
                guard isDir.boolValue else {
                    resolver.failure(error: .fileSystemFailure)
                    return
                }
            } else {
                try FileManager.default.createDirectory(
                    at: rootLocation,
                    withIntermediateDirectories: true
                )
            }
        } catch {
            resolver.failure(error: .other(error: error))
            return
        }

        var afc_lock_file: UInt64 = 0
        defer { if afc_lock_file > 0 {
            afc_file_lock(afc_client, afc_lock_file, AFC_LOCK_UN)
            afc_file_close(afc_client, afc_lock_file)
        } }
        for _ in 0 ... 60 {
            guard !resolver.isCancelled() else {
                resolver.failure(error: .cancelled)
                return
            }
            let ret = afc_file_open(afc_client, "/com.apple.itunes.lock_sync", AFC_FOPEN_RW, &afc_lock_file)
            if ret == AFC_E_SUCCESS { break }
            sleep(1)
        }
        resolver.arrival(checkpoint: .acquiredSyncLock)

        let infoLocation = rootLocation
            .appendingPathComponent("Info")
            .appendingPathExtension("plist")
        do {
            var infoDic = try backupCreateInfoPlist(
                device: device,
                lkd_client: lkd_client,
                afc_client: afc_client
            )
            if let extra = resolver.manifestExtraInformation() {
                for (key, value) in extra {
                    if infoDic.keys.contains(key) {
                        // you can not overwrite manifest object
                        // otherwise resulting non-working backup
                        assertionFailure()
                    }
                    infoDic[key] = value
                }
            }
            let data = try PropertyListEncoder().encode(infoDic)
            try data.write(to: infoLocation)
        } catch {
            resolver.failure(error: .other(error: error))
            return
        }
        resolver.arrival(checkpoint: .builtManifest)

        let backupOptions = plist_new_dict()
        defer { plist_free(backupOptions) }
        if resolver.forceFullBackupMode() {
            plist_dict_set_item(backupOptions, "ForceFullBackup", plist_new_bool(1))
        }
        guard mobilebackup2_send_request(mb2_client, "Backup", udid, udid, backupOptions) == MOBILEBACKUP2_E_SUCCESS else {
            resolver.failure(error: .unableToSendInitialCommand)
            return
        }

        resolver.arrival(checkpoint: .pendingAuthenticate)

        var mb2_error: mobilebackup2_error_t = MOBILEBACKUP2_E_SUCCESS
        messageLoop: while !resolver.isCancelled() {
            var msg_plist: plist_t?
            defer { plist_free(msg_plist) }
            var buf: UnsafeMutablePointer<CChar>?
            defer { free(buf) }
            mb2_error = mobilebackup2_receive_message(mb2_client, &msg_plist, &buf)
            switch mb2_error {
            case MOBILEBACKUP2_E_SUCCESS: break
            case MOBILEBACKUP2_E_RECEIVE_TIMEOUT: if !resolver.isCancelled() { continue messageLoop }
                resolver.failure(error: .cancelled)
                fallthrough
            default:
                resolver.failure(error: .unableToReciveCommandFromDevice)
                break messageLoop
            }
            guard let msg_plist, let buf else {
                resolver.failure(error: .unableToReciveCommandFromDevice)
                break messageLoop
            }
            guard let deviceCommand = AppleMobileDeviceBackup.DeviceCommand(rawValue: String(cString: buf)) else {
                resolver.failure(error: .receivedUnknownCommand)
                break messageLoop
            }
            resolver.arrival(checkpoint: .deviceRequested(command: deviceCommand))

            if let progress = AppleMobileDeviceBackup.mb2_decode_progress_if_possible(
                message: msg_plist,
                command: deviceCommand
            ) { resolver.progressUpdate(progress) }

            switch deviceCommand {
            case .downloadFiles:
                mb2_handle_send_files(mb2_client, msg_plist, rootLocation.path)
            case .uploadFiles:
                mb2_handle_receive_files(mb2_client, msg_plist, rootLocation.path)
            case .getFreeDiskSpace:
                mb2_handle_free_space(mb2_client, msg_plist, rootLocation.path)
            case .purgeDiskSpace:
                let empty_dict = plist_new_dict()
                mobilebackup2_send_status_response(mb2_client, -1, "Operation not supported", empty_dict)
                plist_free(empty_dict)
            case .contentsOfDirectory:
                mb2_handle_list_directory(mb2_client, msg_plist, rootLocation.path)
            case .createDirectory:
                mb2_handle_make_directory(mb2_client, msg_plist, rootLocation.path)
            case .moveFiles, .moveItems:
                mb2_handle_move_items(mb2_client, msg_plist, rootLocation.path)
            case .removeFiles, .removeItems:
                mb2_handle_remove_items(mb2_client, msg_plist, rootLocation.path)
            case .copyItem:
                mb2_handle_copy_items(mb2_client, msg_plist, rootLocation.path)
            case .disconnect:
                resolver.arrival(checkpoint: .deviceRequestDisconnect)
                break messageLoop
            case .processMessage:
                guard let data = Utils.read_plist_to_binary_data(plist: plist_array_get_item(msg_plist, 1)) else {
                    resolver.failure(error: .receivedUnknownCommand)
                    break messageLoop
                }
                guard let object = try? PropertyListDecoder().decode([String: AnyCodable].self, from: data) else {
                    resolver.failure(error: .receivedUnknownCommand)
                    break messageLoop
                }
                if let code = object["ErrorCode"]?.value as? Int {
                    if false {
                    } else if code == 0 {
                        resolver.arrival(checkpoint: .receivedSuccessCodeFromDevice)
                        break messageLoop
                    } else {
                        resolver.failure(error: .receivedErrorFromDevice(code: code))
                        if let errorMessage = object["ErrorDescription"]?.value as? String {
                            resolver.failure(error: .receivedErrorMessageFromDevice(description: errorMessage))
                        }
                        break messageLoop
                    }
                }
            }
        }
        if resolver.isCancelled() {
            resolver.failure(error: .cancelled)
        }
    }

    private func backupVersionHandshake(mb2_client: mobilebackup2_client_t) -> Double {
        var remoteVersion = 0.0
        let availableVersion: [Double] = [2.0, 2.1]
        var availableVersionCopy = availableVersion
        availableVersionCopy.withUnsafeMutableBufferPointer { bufferPointer in
            if let baseAddress = bufferPointer.baseAddress {
                var remoteVersionMutable = remoteVersion
                mobilebackup2_version_exchange(
                    mb2_client,
                    baseAddress,
                    CChar(UInt8(availableVersion.count)),
                    &remoteVersionMutable
                )
                remoteVersion = remoteVersionMutable
            }
        }
        return remoteVersion
    }

    private func backupCreateInfoPlist(
        device: idevice_t,
        lkd_client: lockdownd_client_t,
        afc_client: afc_client_t
    ) throws -> AnyCodableDictionary {
        var dic: [String: AnyCodable] = [:]
        dic["GUID"] = .init(UUID())

        do {
            guard let deviceInfo: AnyCodable = lockdownGetValue(client: lkd_client) else {
                throw AppleMobileDeviceBackup.BackupError.unableToBuildManifest
            }

            var deviceRecordBuilder: [String: Codable?] = [:]
            let deviceRecord = DeviceRecord(store: deviceInfo)
            deviceRecordBuilder["Build Version"] = deviceRecord.buildVersion
            deviceRecordBuilder["Device Name"] = deviceRecord.deviceName
            deviceRecordBuilder["Display Name"] = deviceRecord.deviceName
            deviceRecordBuilder["Product Type"] = deviceRecord.productType
            deviceRecordBuilder["Product Version"] = deviceRecord.productVersion
            deviceRecordBuilder["Serial Number"] = deviceRecord.serialNumber
            deviceRecordBuilder["Target Identifier"] = deviceRecord.uniqueDeviceID
            deviceRecordBuilder["Target Type"] = "Device"
            deviceRecordBuilder["Unique Identifier"] = deviceRecord.uniqueDeviceID?.uppercased()
            deviceRecordBuilder["Last Backup Date"] = Date()
            deviceRecordBuilder["ICCID"] = deviceRecord.integratedCircuitCardIdentity
            deviceRecordBuilder["ICCID 2"] = deviceRecord.integratedCircuitCardIdentity2
            deviceRecordBuilder["IMEI"] = deviceRecord.internationalMobileEquipmentIdentity
            deviceRecordBuilder["IMEI 2"] = deviceRecord.internationalMobileEquipmentIdentity2
            for key in deviceRecordBuilder.keys where deviceRecordBuilder[key] != nil {
                dic[key] = .init(deviceRecordBuilder[key])
            }

            // read: iPhone OS, expect: eg. iPhone 14 Pro
            // dic["Product Name"] = .init(deviceRecord.productName)
        }

        do {
            guard let applications = listApplications(device: device) else {
                throw AppleMobileDeviceBackup.BackupError.unableToListAllApplications
            }
            dic["Applications"] = .init(applications)
            dic["Installed Applications"] = .init(Array(applications.keys))
        }

        do {
            if let data = AppleMobileDeviceBackup.afc_get_file_contents(
                afc_client: afc_client,
                path: "/Books/iBooksData2.plist"
            ) {
                dic["iBooks Data 2"] = .init(data)
            }
        }

        do {
            dic["com.apple.iTunes"] = lockdownGetValue(client: lkd_client, domain: "com.apple.iTunes")

            // TODO: GET A FULL LIST
            let possibleFileNames = [
                "ApertureAlbumPrefs",
                "IC-Info.sidb",
                "IC-Info.sidv",
                "PhotosFolderAlbums",
                "PhotosFolderName",
                "PhotosFolderPrefs",
                "VoiceMemos.plist",
                "iPhotoAlbumPrefs",
                "iTunesApplicationIDs",
                "iTunesPrefs",
                "iTunesPrefs.plist",
                "PSAlbumAlbums",
                "PSElementsAlbums",
            ]
            var iTunesFilesDic: [String: Data] = [:]
            for name in possibleFileNames {
                let location = "/iTunes_Control/iTunes/" + name
                if let data = AppleMobileDeviceBackup.afc_get_file_contents(
                    afc_client: afc_client,
                    path: location
                ) {
                    iTunesFilesDic[name] = data
                }
            }
            dic["iTunes Files"] = .init(iTunesFilesDic)
        }

        return dic
    }
}

public enum AppleMobileDeviceBackup {
    public enum BackupError: Error {
        case unknown

        case cancelled
        case commandFailure
        case fileSystemFailure

        case unableToConnect
        case unableToHandshake
        case unableToStartService

        case anotherBackupIsRunning
        case unableToAcquireBackupPermission
        case unableToBuildManifest

        case unableToListAllApplications
        case unableToSendInitialCommand
        case unableToReciveCommandFromDevice
        case receivedUnknownCommand

        case unexpectedMessage
        case failedToCommunicateWithDevice
        case receivedErrorFromDevice(code: Int)
        case receivedErrorMessageFromDevice(description: String)

        case other(error: Error)
    }

    public enum Checkpoint {
        case initializedConnection
        case initializedService
        case negotiatedProtocol(version: String)
        case decidedBackupType(fullBackup: Bool)
        case acquiredSyncLock
        case builtManifest
        case pendingAuthenticate
        case authenticationCompleted
        case deviceRequested(command: DeviceCommand)
        case receivedSuccessCodeFromDevice
        case deviceRequestDisconnect
        case backendCompleted
    }

    public enum DeviceCommand: String {
        case downloadFiles = "DLMessageDownloadFiles"
        case uploadFiles = "DLMessageUploadFiles"
        case getFreeDiskSpace = "DLMessageGetFreeDiskSpace"
        case purgeDiskSpace = "DLMessagePurgeDiskSpace"
        case createDirectory = "DLMessageCreateDirectory"
        case moveFiles = "DLMessageMoveFiles"
        case moveItems = "DLMessageMoveItems"
        case removeFiles = "DLMessageRemoveFiles"
        case removeItems = "DLMessageRemoveItems"
        case copyItem = "DLMessageCopyItem"
        case disconnect = "DLMessageDisconnect"
        case processMessage = "DLMessageProcessMessage"
        case contentsOfDirectory = "DLContentsOfDirectory"
    }
}

public protocol AppleMobileDeviceBackupDelegate {
    func isCancelled() -> Bool
    func backupRoot() -> URL
    func manifestExtraInformation() -> AnyCodableDictionary?
    func forceFullBackupMode() -> Bool
    func arrival(checkpoint: AppleMobileDeviceBackup.Checkpoint)
    func failure(error: AppleMobileDeviceBackup.BackupError)
    func progressUpdate(_ progress: Double)
}

extension AppleMobileDeviceBackup {
    static func afc_read_file_info(afc_client: afc_client_t, path: String) -> [String: String]? {
        var file_info: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        defer { afc_dictionary_free(file_info) }
        guard afc_get_file_info(afc_client, path, &file_info) == AFC_E_SUCCESS,
              let file_info
        else { return nil }

        var currentIdx = 0
        var ret: [String: String] = [:]
        while true {
            defer { currentIdx += 1 }
            if let kp = file_info.advanced(by: currentIdx * 2).pointee,
               let vp = file_info.advanced(by: currentIdx * 2 + 1).pointee
            {
                let key = String(cString: kp)
                let value = String(cString: vp)
                ret[key] = value
                continue
            }
            break
        }
        return ret
    }

    static func afc_get_file_contents(afc_client: afc_client_t, path: String) -> Data? {
        guard let info = afc_read_file_info(afc_client: afc_client, path: path),
              let size_str = info["st_size"],
              let size = Int(size_str)
        else { return nil }
        var f: Int64 = 0
        guard afc_file_open(afc_client, path, AFC_FOPEN_RDONLY, &f) == AFC_E_SUCCESS,
              f > 0
        else { return nil }

        var totalRead = 0
        var data = Data(repeating: 0, count: size)
        data.withUnsafeMutableBytes { byte in
            guard let buffer = byte.baseAddress else { return }
            while totalRead < size {
                var read: UInt32 = 0
                afc_file_read(afc_client, UInt64(f), buffer + totalRead, 65535, &read)
                guard read > 0 else { break }
                totalRead += Int(read)
            }
        }

        return totalRead == size ? data : nil
    }

    static func mb2_decode_progress_if_possible(message: plist_t, command: AppleMobileDeviceBackup.DeviceCommand) -> Double? {
        var node: plist_t?
        switch command {
        case .downloadFiles, .moveFiles, .moveItems, .removeFiles, .removeItems:
            node = plist_array_get_item(message, 3)
        case .uploadFiles:
            node = plist_array_get_item(message, 2)
        default: break
        }
        if let node, plist_get_node_type(node) == PLIST_REAL {
            var out: Double = 0
            plist_get_real_val(node, &out)
            return out
        }
        return nil
    }
}
