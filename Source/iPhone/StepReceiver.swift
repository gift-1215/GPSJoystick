import Combine
import CoreBluetooth
import HealthKit
import OSLog
import Security

@MainActor
final class StepReceiver: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate {
    @Published private(set) var status = "請先掃描 Mac 的配對碼。"
    @Published private(set) var active = false
    @Published private(set) var authorizing = false
    @Published private(set) var saving = false
    @Published private(set) var savedSteps = 0

    private let health = HKHealthStore()
    private let stepType = HKQuantityType(.stepCount)
    @Published private var pairing: StepPairing?
    private let batchID = CBUUID(string: StepBluetooth.batchID)
    private let acknowledgementID = CBUUID(string: StepBluetooth.acknowledgementID)
    private let availableID = CBUUID(string: StepBluetooth.availableID)
    private let savedBatchKey = "lastSavedStepBatch"
    private let logger = Logger(subsystem: "local.gpsjoystick.steps", category: "Bluetooth")
    private var central: CBCentralManager?
    private var mac: CBPeripheral?
    private var batchCharacteristic: CBCharacteristic?
    private var acknowledgementCharacteristic: CBCharacteristic?
    private var availabilityCharacteristic: CBCharacteristic?
    private var reading = false
    private var acknowledging = false
    private var signaled = false
    private var nextAction: Task<Void, Never>?
    private var retryCount = 0
    private var inForeground = false
    private let pairingItem: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.gpsjoystick.steps.pairing",
        kSecAttrAccount as String: "mac"
    ]

    var hasPairing: Bool { pairing != nil }

    override init() {
        super.init()
        var query = pairingItem
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data {
            pairing = StepPairing(secret: data)
        }
        if hasPairing {
            status = "已儲存 Mac 配對碼。開啟 Mac 的步數藍牙同步後，按「開始同步」。"
        }
    }

    @discardableResult
    func pair(code: String) -> Bool {
        guard !active, !authorizing, !saving else { return false }
        guard let pairing = StepPairing(code: code) else {
            status = "這不是 GPS 搖桿的有效配對碼。"
            return false
        }
        let secret = [kSecValueData as String: pairing.secret]
        var result = SecItemUpdate(pairingItem as CFDictionary, secret as CFDictionary)
        if result == errSecItemNotFound {
            var item = pairingItem
            item[kSecValueData as String] = pairing.secret
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            result = SecItemAdd(item as CFDictionary, nil)
        }
        guard result == errSecSuccess else {
            status = "無法儲存 Mac 配對碼（\(result)）。"
            return false
        }
        self.pairing = pairing
        status = "已儲存 Mac 配對碼。請按「開始同步」。"
        return true
    }

    func start() async {
        guard !active, !authorizing, !saving, hasPairing else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            status = "此裝置無法使用 HealthKit。"
            return
        }
        authorizing = true
        defer { authorizing = false }
        if health.authorizationStatus(for: stepType) == .notDetermined {
            do {
                try await health.requestAuthorization(toShare: [stepType], read: [])
            } catch {
                status = "無法取得健康資料授權。請在「健康」檢查 App 權限。"
                return
            }
        }
        guard health.authorizationStatus(for: stepType) == .sharingAuthorized else {
            status = "請在「健康」的 App 權限中開啟此 App 的步數寫入。"
            return
        }
        active = true
        status = "正在啟動藍牙…"
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: false
        ])
    }

    func stop() {
        end("同步已停止。")
    }

    func setForeground(_ foreground: Bool) {
        inForeground = foreground
        if foreground {
            readBatch()
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central, active else { return }
        switch central.state {
        case .poweredOn:
            scan()
        case .poweredOff:
            resetTransfer()
            mac = nil
            status = "請開啟 iPhone 藍牙。開啟後會繼續尋找 Mac。"
        case .unauthorized:
            end("請在 iPhone 設定允許此 App 使用藍牙。")
        case .unsupported:
            end("此裝置不支援低功耗藍牙。")
        case .resetting, .unknown:
            resetTransfer()
            mac = nil
            status = "正在等待 iPhone 藍牙啟動…"
        @unknown default:
            end("藍牙目前無法使用。")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, active, central.isScanning, mac == nil,
              (advertisementData[CBAdvertisementDataIsConnectable] as? Bool) != false else { return }
        mac = peripheral
        central.stopScan()
        status = "正在連線到 GPS 搖桿…"
        central.connect(peripheral)
        schedule(after: .seconds(15)) {
            self.retryConnection("藍牙連線逾時")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, peripheral === mac, active, let pairing else { return }
        status = "已連線，正在準備步數同步…"
        schedule(after: .seconds(15)) {
            self.retryConnection("取得 Mac 的步數服務逾時")
        }
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(nsuuid: pairing.serviceID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === mac, active else { return }
        retryConnection("無法連線到 GPS 搖桿", error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === mac, active else { return }
        retryConnection("與 Mac 的連線已中斷", error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === mac, active, let pairing else { return }
        let serviceID = CBUUID(nsuuid: pairing.serviceID)
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            retryConnection("找不到 GPS 搖桿的步數服務", error: error)
            return
        }
        peripheral.discoverCharacteristics([batchID, acknowledgementID, availableID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === mac, active else { return }
        guard error == nil, let batch = service.characteristics?.first(where: { $0.uuid == batchID }),
              let ack = service.characteristics?.first(where: { $0.uuid == acknowledgementID }),
              let available = service.characteristics?.first(where: { $0.uuid == availableID }) else {
            retryConnection("無法取得 GPS 搖桿的步數服務欄位", error: error)
            return
        }
        batchCharacteristic = batch
        acknowledgementCharacteristic = ack
        availabilityCharacteristic = available
        peripheral.setNotifyValue(true, for: available)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === mac, active, characteristic === availabilityCharacteristic else { return }
        guard error == nil, characteristic.isNotifying else {
            retryConnection("無法訂閱步數通知", error: error)
            return
        }
        readBatch()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === mac, active else { return }
        if characteristic === availabilityCharacteristic {
            guard error == nil else { return }
            signaled = true
            readBatch()
            return
        }
        guard characteristic === batchCharacteristic, reading else { return }
        reading = false
        nextAction?.cancel()
        guard error == nil, let data = characteristic.value, let pairing else {
            retryConnection("無法讀取步數", error: error)
            return
        }
        let decoded: StepBatch?
        do {
            decoded = try pairing.open(data)
        } catch {
            retryConnection("無法驗證 Mac 傳來的步數資料", error: error)
            return
        }
        guard let decoded else {
            retryCount = 0
            status = "已連線，可在背景接收新的模擬步數。"
            if signaled {
                readBatch()
            } else if inForeground {
                schedule(after: .seconds(3)) {
                    if self.inForeground { self.readBatch() }
                }
            }
            return
        }
        let batch = decoded.adjustedForClockGap
        guard batch.isValid else {
            end("Mac 傳來的步數超出有效範圍（\(batch.count) 步）。")
            return
        }
        let receipt = pairing.acknowledgement(for: data)
        if UserDefaults.standard.string(forKey: savedBatchKey) == batch.id.uuidString {
            acknowledge(receipt)
            return
        }
        status = "正在寫入「健康」…"
        saving = true
        let transferCharacteristic = characteristic
        Task {
            defer {
                saving = false
                if batchCharacteristic !== transferCharacteristic { readBatch() }
            }
            do {
                let sample = HKQuantitySample(
                    type: stepType,
                    quantity: HKQuantity(unit: .count(), doubleValue: Double(batch.count)),
                    start: batch.start,
                    end: batch.end,
                    metadata: [
                        HKMetadataKeyWasUserEntered: true,
                        HKMetadataKeySyncIdentifier: batch.id.uuidString,
                        HKMetadataKeySyncVersion: 1,
                        "GPSJoystickSimulated": true
                    ]
                )
                try await health.save(sample)
                UserDefaults.standard.set(batch.id.uuidString, forKey: savedBatchKey)
                savedSteps += batch.count
                if peripheral === mac, active, batchCharacteristic === transferCharacteristic {
                    acknowledge(receipt)
                }
            } catch {
                if peripheral === mac, active, batchCharacteristic === transferCharacteristic {
                    end("無法寫入「健康」：\(error.localizedDescription)")
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === mac, active, characteristic === acknowledgementCharacteristic else { return }
        acknowledging = false
        guard error == nil else {
            retryConnection("步數已寫入，Mac 尚未確認", error: error)
            return
        }
        retryCount = 0
        readBatch()
    }

    private func readBatch() {
        guard active, !reading, !saving, !acknowledging, let mac, let batchCharacteristic,
              availabilityCharacteristic?.isNotifying == true else { return }
        reading = true
        signaled = false
        mac.readValue(for: batchCharacteristic)
        schedule(after: .seconds(30)) { self.retryConnection("讀取步數逾時") }
    }

    private func acknowledge(_ receipt: Data) {
        guard active, let mac, let acknowledgementCharacteristic else { return }
        acknowledging = true
        mac.writeValue(receipt, for: acknowledgementCharacteristic, type: .withResponse)
        schedule(after: .seconds(30)) { self.retryConnection("確認步數寫入逾時") }
    }

    private func scan() {
        guard active, let central, central.state == .poweredOn, mac == nil, let pairing else { return }
        if !central.isScanning {
            central.scanForPeripherals(withServices: [CBUUID(nsuuid: pairing.serviceID)])
        }
        if retryCount == 0 {
            status = "正在尋找附近的 GPS 搖桿…"
        }
        schedule(after: .seconds(15)) {
            self.status = "找不到已配對的 Mac。請確認 Mac 已喚醒、同步已開啟，並掃描這台 Mac 的配對碼。"
        }
    }

    private func retryConnection(_ message: String, error: Error? = nil) {
        guard active, let central else { return }
        let previous = mac
        mac = nil
        resetTransfer()
        if let previous, previous.state != .disconnected, central.state == .poweredOn {
            central.cancelPeripheralConnection(previous)
        }
        let detail = error.map { error in
            let systemError = error as NSError
            return "（\(systemError.localizedDescription)，\(systemError.domain) \(systemError.code)）"
        } ?? ""
        logger.notice("\(message, privacy: .public)\(detail, privacy: .public)")
        if let bluetoothError = error as? CBError,
           bluetoothError.code == .encryptionTimedOut || bluetoothError.code == .peerRemovedPairingInformation {
            end("系統仍在嘗試使用舊藍牙配對。請將兩端藍牙關閉再開啟。若藍牙設定中仍有對方的舊配對，移除後再按「開始同步」。\(detail)")
            return
        }
        status = "\(message)\(detail)。正在重試，請確認 Mac 已開啟步數藍牙同步。"
        let delay = 1 << retryCount
        retryCount = min(retryCount + 1, 3)
        schedule(after: .seconds(delay)) { self.scan() }
    }

    private func schedule(after duration: Duration, action: @escaping @MainActor () -> Void) {
        nextAction?.cancel()
        nextAction = Task {
            do {
                try await Task.sleep(for: duration)
                action()
            } catch {
                return
            }
        }
    }

    private func end(_ message: String) {
        central?.stopScan()
        if let mac {
            central?.cancelPeripheralConnection(mac)
        }
        mac = nil
        central = nil
        resetTransfer()
        retryCount = 0
        active = false
        status = message
    }

    private func resetTransfer() {
        nextAction?.cancel()
        nextAction = nil
        batchCharacteristic = nil
        acknowledgementCharacteristic = nil
        availabilityCharacteristic = nil
        reading = false
        acknowledging = false
        signaled = false
    }
}
