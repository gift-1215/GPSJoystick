import Combine
import CoreBluetooth
import Foundation

@MainActor
final class StepBroadcaster: NSObject, ObservableObject, @preconcurrency CBPeripheralManagerDelegate {
    enum TestStepStatus: Equatable {
        case queued(UUID)
        case acknowledged
    }

    static let testStepCount = 2_000

    @Published private(set) var enabled = false
    @Published private(set) var status = "藍牙同步已關閉"
    @Published private(set) var pendingSteps = 0
    @Published private(set) var storageError: String?
    @Published private(set) var pairing: StepPairing?
    @Published private(set) var testStepStatus: TestStepStatus?

    private let file = URL.applicationSupportDirectory
        .appending(path: "GPSJoystick/step-outbox.json")
    private let pairingFile = URL.applicationSupportDirectory
        .appending(path: "GPSJoystick/step-pairing-key")
    private var outbox: StepOutbox?
    private var unsaved: [StepBatch] = []
    private var manager: CBPeripheralManager?
    private var characteristic: CBMutableCharacteristic?
    private var availability: CBMutableCharacteristic?
    private var notificationPending = false
    private var notificationSequence: UInt32 = 0
    private var notificationRetry: Task<Void, Never>?
    private var subscribers: [UUID: CBCentral] = [:]
    private struct BatchRead {
        let data: Data
        let batch: StepBatch?
    }
    private var reads: [UUID: BatchRead] = [:]
    private let batchID = CBUUID(string: StepBluetooth.batchID)
    private let acknowledgementID = CBUUID(string: StepBluetooth.acknowledgementID)
    private let availableID = CBUUID(string: StepBluetooth.availableID)

    override init() {
        super.init()
        persist()
    }

    func enqueue(_ batch: StepBatch) {
        unsaved.append(batch)
        persist()
        notifyAvailability()
    }

    func enqueueTestSteps() {
        let now = Date()
        let batch = StepBatch(id: UUID(), start: now.addingTimeInterval(-1), end: now, count: Self.testStepCount)
        testStepStatus = .queued(batch.id)
        enqueue(batch)
    }

    func persist() {
        do {
            if outbox == nil {
                outbox = try StepOutbox(file: file)
            }
            while let batch = unsaved.first {
                try outbox?.append(batch)
                unsaved.removeFirst()
            }
            storageError = nil
        } catch {
            storageError = "無法儲存模擬步數。請確認磁碟空間與資料夾權限。"
        }
        updatePendingSteps()
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if value {
            persist()
            do {
                pairing = try loadPairing()
            } catch {
                enabled = false
                status = "無法讀取或儲存步數配對碼。"
                return
            }
            status = "正在啟動藍牙…"
            manager = CBPeripheralManager(delegate: self, queue: nil, options: [
                CBPeripheralManagerOptionShowPowerAlertKey: false
            ])
        } else {
            manager?.stopAdvertising()
            manager?.removeAllServices()
            manager = nil
            characteristic = nil
            availability = nil
            subscribers.removeAll()
            cancelNotificationRetry()
            reads.removeAll()
            pairing = nil
            status = "藍牙同步已關閉"
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        characteristic = nil
        availability = nil
        subscribers.removeAll()
        cancelNotificationRetry()
        reads.removeAll()
        switch peripheral.state {
        case .poweredOn:
            guard let pairing else { return }
            let batch = CBMutableCharacteristic(
                type: batchID, properties: .read, value: nil,
                permissions: .readable
            )
            let ack = CBMutableCharacteristic(
                type: acknowledgementID, properties: .write, value: nil,
                permissions: .writeable
            )
            let available = CBMutableCharacteristic(
                type: availableID, properties: .indicate, value: nil, permissions: []
            )
            let service = CBMutableService(type: CBUUID(nsuuid: pairing.serviceID), primary: true)
            service.characteristics = [batch, ack, available]
            characteristic = batch
            availability = available
            peripheral.add(service)
        case .poweredOff:
            status = "請開啟 Mac 藍牙"
        case .unauthorized:
            status = "請在系統設定允許 GPS 搖桿使用藍牙"
        case .unsupported:
            status = "這台 Mac 無法使用低功耗藍牙"
        default:
            status = "正在等待藍牙…"
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard peripheral === manager else { return }
        guard error == nil else {
            status = "無法啟動藍牙服務，請重新開啟步數同步"
            return
        }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [service.uuid]
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard peripheral === manager else { return }
        status = error == nil ? "等待 iPhone 配套 App 接收" : "無法廣播藍牙服務，請重新開啟步數同步"
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard peripheral === manager, request.characteristic.uuid == characteristic?.uuid, let pairing else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        let central = request.central.identifier
        if request.offset == 0 {
            let batch = outbox?.batches.first?.adjustedForClockGap
            guard let data = try? pairing.seal(batch) else {
                peripheral.respond(to: request, withResult: .unlikelyError)
                return
            }
            reads[central] = BatchRead(data: data, batch: batch)
        }
        guard let read = reads[central], request.offset <= read.data.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = Data(read.data.dropFirst(request.offset))
        peripheral.respond(to: request, withResult: .success)
        status = read.batch == nil ? "iPhone 已連線，等待模擬步數" : "iPhone 已讀取步數，等待寫入確認"
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let request = requests.first else { return }
        guard peripheral === manager, requests.count == 1, request.offset == 0,
              request.characteristic.uuid == acknowledgementID, let data = request.value else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        guard let pairing, let read = reads[request.central.identifier], let batch = read.batch,
              pairing.verifies(data, for: read.data) else {
            peripheral.respond(to: request, withResult: .insufficientAuthorization)
            return
        }
        do {
            try outbox?.acknowledge(batch.id)
            updatePendingSteps()
            if testStepStatus == .queued(batch.id) {
                testStepStatus = .acknowledged
            }
            if outbox?.batches.isEmpty == true {
                cancelNotificationRetry()
            }
            status = "iPhone 已確認寫入步數"
            peripheral.respond(to: request, withResult: .success)
        } catch {
            storageError = "無法更新步數同步佇列。重新連線可再試一次。"
            peripheral.respond(to: request, withResult: .unlikelyError)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard peripheral === manager, characteristic.uuid == availableID else { return }
        subscribers[central.identifier] = central
        status = "iPhone 已連線"
        notifyAvailability()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard peripheral === manager, characteristic.uuid == availableID else { return }
        subscribers.removeValue(forKey: central.identifier)
        reads.removeValue(forKey: central.identifier)
        if subscribers.isEmpty {
            cancelNotificationRetry()
            status = "等待 iPhone 配套 App 接收"
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard peripheral === manager, notificationPending else { return }
        notifyAvailability()
    }

    private func notifyAvailability() {
        guard let manager, manager.state == .poweredOn, let availability, !subscribers.isEmpty,
              outbox?.batches.isEmpty == false else {
            cancelNotificationRetry()
            return
        }
        notificationSequence &+= 1
        let signal = withUnsafeBytes(of: notificationSequence.bigEndian) { Data($0) }
        notificationPending = !manager.updateValue(signal, for: availability, onSubscribedCentrals: Array(subscribers.values))
        if notificationRetry == nil {
            // Retry if the phone missed the wake-up and no receipt cleared the queue.
            notificationRetry = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.notificationRetry = nil
                self.notifyAvailability()
            }
        }
    }

    private func cancelNotificationRetry() {
        notificationPending = false
        notificationRetry?.cancel()
        notificationRetry = nil
    }

    private func updatePendingSteps() {
        pendingSteps = (outbox?.batches.reduce(0) { $0 + $1.count } ?? 0)
            + unsaved.reduce(0) { $0 + $1.count }
    }

    private func loadPairing() throws -> StepPairing {
        do {
            let secret = try Data(contentsOf: pairingFile)
            guard let pairing = StepPairing(secret: secret) else { throw CocoaError(.fileReadCorruptFile) }
            return pairing
        } catch CocoaError.fileReadNoSuchFile {
            let pairing = StepPairing()
            let files = FileManager.default
            try files.createDirectory(at: pairingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard files.createFile(atPath: pairingFile.path, contents: pairing.secret,
                                   attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return pairing
        }
    }
}
