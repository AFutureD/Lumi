import Transport
import CryptoKit
import Foundation

public enum RelayCryptographyError: Error, Sendable {
    case invalidPrivateKey
    case invalidPublicKey
    case invalidSealedPayload
    case missingCiphertext
}

public struct RelayKeyPair: Codable, Hashable, Sendable {
    public let privateKey: Data
    public let publicKey: Data

    public init(privateKey: Data, publicKey: Data) {
        self.privateKey = privateKey
        self.publicKey = publicKey
    }
}

public struct RelayPreparedPayload: Sendable {
    fileprivate let plaintext: Data

    fileprivate init(plaintext: Data) {
        self.plaintext = plaintext
    }

    /// Compressed size before sealing; ChaChaPoly keeps the length, so the
    /// wire ciphertext is this plus a 16-byte tag (then Base64).
    public var byteCount: Int { plaintext.count }
}

public enum RelayCryptography {
    public static func makeKeyPair() -> RelayKeyPair {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return RelayKeyPair(
            privateKey: key.rawRepresentation,
            publicKey: key.publicKey.rawRepresentation
        )
    }

    public static func seal(
        _ payload: RemoteSessionPayload,
        hostID: HostID,
        deviceID: DeviceID,
        sequence: UInt64,
        kind: RelayFrameKind = .data,
        privateKey: Data,
        peerPublicKey: Data
    ) throws -> RelayRoutingFrame {
        try seal(
            prepare(payload),
            hostID: hostID,
            deviceID: deviceID,
            sequence: sequence,
            kind: kind,
            privateKey: privateKey,
            peerPublicKey: peerPublicKey
        )
    }

    /// Encodes and deflates the payload once; `seal` then encrypts the same
    /// bytes per device. JSON timelines deflate several-fold, which is what
    /// keeps a single-session frame inside the relay's message limit.
    public static func prepare(
        _ payload: RemoteSessionPayload
    ) throws -> RelayPreparedPayload {
        let encoded = try TransportCoding.makeEncoder().encode(payload)
        let compressed = try (encoded as NSData).compressed(using: .zlib)
        return RelayPreparedPayload(plaintext: compressed as Data)
    }

    public static func seal(
        _ payload: RelayPreparedPayload,
        hostID: HostID,
        deviceID: DeviceID,
        sequence: UInt64,
        kind: RelayFrameKind = .data,
        privateKey: Data,
        peerPublicKey: Data
    ) throws -> RelayRoutingFrame {
        let key = try symmetricKey(
            privateKey: privateKey,
            peerPublicKey: peerPublicKey,
            hostID: hostID,
            deviceID: deviceID
        )
        let sealed = try ChaChaPoly.seal(
            payload.plaintext,
            using: key,
            authenticating: routingHeader(hostID: hostID, deviceID: deviceID, sequence: sequence, kind: kind)
        )
        var ciphertext = sealed.ciphertext
        ciphertext.append(sealed.tag)
        return RelayRoutingFrame(
            hostID: hostID,
            deviceID: deviceID,
            sequence: sequence,
            kind: kind,
            nonce: sealed.nonce.withUnsafeBytes { Data($0) },
            ciphertext: ciphertext
        )
    }

    public static func open(
        _ frame: RelayRoutingFrame,
        privateKey: Data,
        peerPublicKey: Data
    ) throws -> RemoteSessionPayload {
        guard let deviceID = frame.deviceID,
              let nonceData = frame.nonce,
              let combinedCiphertext = frame.ciphertext else {
            throw RelayCryptographyError.missingCiphertext
        }
        guard combinedCiphertext.count >= 16 else {
            throw RelayCryptographyError.invalidSealedPayload
        }
        let key = try symmetricKey(
            privateKey: privateKey,
            peerPublicKey: peerPublicKey,
            hostID: frame.hostID,
            deviceID: deviceID
        )
        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let ciphertext = combinedCiphertext.dropLast(16)
        let tag = combinedCiphertext.suffix(16)
        let box = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )
        let plaintext = try ChaChaPoly.open(
            box,
            using: key,
            authenticating: routingHeader(hostID: frame.hostID, deviceID: deviceID, sequence: frame.sequence, kind: frame.kind)
        )
        let inflated = try (plaintext as NSData).decompressed(using: .zlib)
        return try TransportCoding.makeDecoder().decode(RemoteSessionPayload.self, from: inflated as Data)
    }

    /// The routing header as additional authenticated data: the Relay (or
    /// anyone on the path) can still read these fields, but cannot change
    /// them, swap a frame's direction, or replay a sealed body under another
    /// sequence without the tag failing.
    static func routingHeader(hostID: HostID, deviceID: DeviceID, sequence: UInt64, kind: RelayFrameKind) -> Data {
        Data("Lumi Relay/v1/frame/\(hostID.rawValue)/\(deviceID.rawValue)/\(sequence)/\(kind.rawValue)".utf8)
    }

    // MARK: - Pairing (code + Numeric Comparison)

    /// A fresh 32-byte nonce for one pairing session (`hostNonce`).
    public static func makePairingNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }

    /// The Mac's commitment, published to the Relay before any iPhone shows
    /// up: `SHA256("Lumi Relay/pair-commit/v1" ‖ hostPub ‖ nonce)`.
    /// The nonce is revealed only after the daemon has the device's key, so
    /// nobody in the middle can pick a key to match a known SAS.
    public static func pairingCommitment(hostPublicKey: Data, hostNonce: Data) -> Data {
        var message = Data("Lumi Relay/pair-commit/v1".utf8)
        message.append(hostPublicKey)
        message.append(hostNonce)
        return Data(SHA256.hash(data: message))
    }

    /// Constant-time check of a revealed (key, nonce) against the commitment
    /// the iPhone got at claim time.
    public static func verifyPairingCommitment(_ commit: Data, hostPublicKey: Data, hostNonce: Data) -> Bool {
        let expected = pairingCommitment(hostPublicKey: hostPublicKey, hostNonce: hostNonce)
        guard expected.count == commit.count else { return false }
        var difference: UInt8 = 0
        for (lhs, rhs) in zip(expected, commit) { difference |= lhs ^ rhs }
        return difference == 0
    }

    /// The six-digit Numeric Comparison string both ends show:
    /// first four bytes of `SHA256("Lumi Relay/pair-sas/v1" ‖ hostID ‖
    /// deviceID ‖ hostPub ‖ devicePub ‖ nonce)` big-endian, mod 1 000 000,
    /// zero-padded. Display it as `XXX XXX`.
    public static func pairingSAS(
        hostID: HostID,
        deviceID: DeviceID,
        hostPublicKey: Data,
        devicePublicKey: Data,
        hostNonce: Data
    ) -> String {
        var message = Data("Lumi Relay/pair-sas/v1".utf8)
        message.append(Data(hostID.rawValue.utf8))
        message.append(Data(deviceID.rawValue.utf8))
        message.append(hostPublicKey)
        message.append(devicePublicKey)
        message.append(hostNonce)
        let digest = Array(SHA256.hash(data: message))
        let value = (UInt32(digest[0]) << 24) | (UInt32(digest[1]) << 16) | (UInt32(digest[2]) << 8) | UInt32(digest[3])
        return String(format: "%06d", Int(value % 1_000_000))
    }

    private static func symmetricKey(
        privateKey: Data,
        peerPublicKey: Data,
        hostID: HostID,
        deviceID: DeviceID
    ) throws -> SymmetricKey {
        let local: Curve25519.KeyAgreement.PrivateKey
        let peer: Curve25519.KeyAgreement.PublicKey
        do {
            local = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        } catch {
            throw RelayCryptographyError.invalidPrivateKey
        }
        do {
            peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        } catch {
            throw RelayCryptographyError.invalidPublicKey
        }
        let secret = try local.sharedSecretFromKeyAgreement(with: peer)
        let context = Data("Lumi Relay/v1/\(hostID.rawValue)/\(deviceID.rawValue)".utf8)
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("Lumi Relay/v1".utf8),
            sharedInfo: context,
            outputByteCount: 32
        )
    }
}
