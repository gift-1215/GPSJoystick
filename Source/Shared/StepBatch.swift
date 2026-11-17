import CryptoKit
import Foundation

enum StepBluetooth {
    static let batchID = "63933C2E-E1F5-491C-93D9-2E6370B19D02"
    static let acknowledgementID = "63933C2E-E1F5-491C-93D9-2E6370B19D03"
    static let availableID = "63933C2E-E1F5-491C-93D9-2E6370B19D04"
}

struct StepPairing: Equatable {
    private static let prefix = "GPSJoystickSteps:"
    let secret: Data

    init() {
        secret = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
    }

    init?(secret: Data) {
        guard secret.count == 16 else { return nil }
        self.secret = secret
    }

    init?(code: String) {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = text.hasPrefix(Self.prefix) ? String(text.dropFirst(Self.prefix.count)) : text
        guard let secret = Data(base64Encoded: payload) else { return nil }
        self.init(secret: secret)
    }

    var code: String { secret.base64EncodedString() }
    var qrValue: String { Self.prefix + code }

    var serviceID: UUID {
        let bytes = derive("service").withUnsafeBytes { Array($0) }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    func seal(_ batch: StepBatch?) throws -> Data {
        let data = try JSONEncoder().encode(batch)
        let box = try AES.GCM.seal(data, using: derive("batch"))
        guard let combined = box.combined else { throw CryptoKitError.incorrectParameterSize }
        return combined
    }

    func open(_ data: Data) throws -> StepBatch? {
        let box = try AES.GCM.SealedBox(combined: data)
        return try JSONDecoder().decode(StepBatch?.self, from: AES.GCM.open(box, using: derive("batch")))
    }

    func acknowledgement(for encryptedBatch: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: encryptedBatch, using: derive("ack")).prefix(16))
    }

    func verifies(_ acknowledgement: Data, for encryptedBatch: Data) -> Bool {
        let expected = self.acknowledgement(for: encryptedBatch)
        guard acknowledgement.count == expected.count else { return false }
        return zip(acknowledgement, expected).reduce(UInt8.zero) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func derive(_ purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            info: Data("GPSJoystickSteps/v1/\(purpose)".utf8),
            outputByteCount: 16
        )
    }
}

struct StepBatch: Codable, Equatable {
    let id: UUID
    let start: Date
    let end: Date
    let count: Int

    var isValid: Bool {
        (1...10_000).contains(count) && start < end
            && (end.timeIntervalSince(start) <= 60)
    }

    var adjustedForClockGap: StepBatch {
        guard !(0 < end.timeIntervalSince(start) && end.timeIntervalSince(start) <= 60) else { return self }
        // Older versions could include idle time. Keep the batch ID, step count and end time.
        return StepBatch(id: id, start: end.addingTimeInterval(-10), end: end, count: count)
    }
}
