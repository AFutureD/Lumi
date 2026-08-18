import AgentStatusTransport
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

    public static func prepare(
        _ payload: RemoteSessionPayload
    ) throws -> RelayPreparedPayload {
        RelayPreparedPayload(
            plaintext: try TransportCoding.makeEncoder().encode(payload)
        )
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
        let sealed = try ChaChaPoly.seal(payload.plaintext, using: key)
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
        let plaintext = try ChaChaPoly.open(box, using: key)
        return try TransportCoding.makeDecoder().decode(RemoteSessionPayload.self, from: plaintext)
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
        let context = Data("Agent Status Relay/v1/\(hostID.rawValue)/\(deviceID.rawValue)".utf8)
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("Agent Status Relay/v1".utf8),
            sharedInfo: context,
            outputByteCount: 32
        )
    }
}
