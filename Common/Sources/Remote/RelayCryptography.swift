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

/// The keys a channel's frames are sealed with, one per direction. A channel
/// has two kinds:
/// - the handshake key, derived from the two long-term keys fixed at
///   pairing. It seals only the two payloads that open a channel session
///   (`sync_index` and `channel_opened`), which carry no session content;
/// - a channel session's key, derived from those long-term keys and two
///   one-time keys. It seals everything else and exists only in memory.
public struct RelayChannelKey: Sendable {
    /// Seals `data` frames (host → device).
    fileprivate let toDevice: SymmetricKey
    /// Seals `request` frames (device → host).
    fileprivate let toHost: SymmetricKey

    /// 64 bytes of key material: the host → device key, then the device → host key.
    fileprivate init(material: SymmetricKey) {
        let bytes = material.withUnsafeBytes { Data($0) }
        toDevice = SymmetricKey(data: bytes.prefix(32))
        toHost = SymmetricKey(data: bytes.suffix(32))
    }

    fileprivate func key(for kind: RelayFrameKind) -> SymmetricKey {
        kind == .request ? toHost : toDevice
    }
}

/// One end's one-time X25519 key for a channel session. It lives in memory
/// until the session's key is derived, then is dropped — which is what keeps
/// a session's frames sealed after a long-term key leaks.
public struct RelayEphemeralKey: Sendable {
    fileprivate let privateKey: Data

    public init() {
        privateKey = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }

    /// Tests: a fixed key for golden vectors.
    public init(privateKey: Data) {
        self.privateKey = privateKey
    }

    public var publicKey: Data {
        get throws {
            do {
                return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.rawRepresentation
            } catch {
                throw RelayCryptographyError.invalidPrivateKey
            }
        }
    }
}

/// Which end of the channel is deriving a session key.
public enum RelayChannelEnd: Sendable {
    case host
    case device
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
        key: RelayChannelKey
    ) throws -> RelayRoutingFrame {
        try seal(
            prepare(payload),
            hostID: hostID,
            deviceID: deviceID,
            sequence: sequence,
            kind: kind,
            key: key
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
        key: RelayChannelKey
    ) throws -> RelayRoutingFrame {
        let sealed = try ChaChaPoly.seal(
            payload.plaintext,
            using: key.key(for: kind),
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

    /// Authenticates and opens a frame. A frame that was not sealed with
    /// `key` for exactly this routing header throws — callers treat that as
    /// "not ours" and change no state.
    public static func open(
        _ frame: RelayRoutingFrame,
        key: RelayChannelKey
    ) throws -> RemoteSessionPayload {
        guard let deviceID = frame.deviceID,
              let nonceData = frame.nonce,
              let combinedCiphertext = frame.ciphertext else {
            throw RelayCryptographyError.missingCiphertext
        }
        guard combinedCiphertext.count >= 16 else {
            throw RelayCryptographyError.invalidSealedPayload
        }
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
            using: key.key(for: frame.kind),
            authenticating: routingHeader(hostID: frame.hostID, deviceID: deviceID, sequence: frame.sequence, kind: frame.kind)
        )
        let inflated = try (plaintext as NSData).decompressed(using: .zlib)
        return try TransportCoding.makeDecoder().decode(RemoteSessionPayload.self, from: inflated as Data)
    }

    /// The routing header as additional authenticated data: the Relay (or
    /// anyone on the path) can still read these fields, but cannot change
    /// them, swap a frame's direction, or replay a sealed body under another
    /// sequence without the tag failing. Each direction also has its own
    /// key, so a frame cannot be turned around either.
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

    // MARK: - Channel keys

    /// The handshake key of one Mac ↔ iPhone channel: X25519 between the two
    /// long-term keys fixed at pairing, through HKDF-SHA256 with the
    /// channel's IDs as context. Both ends derive the same key; it never
    /// changes while the pairing stands, so it seals nothing but the
    /// opening of channel sessions.
    public static func handshakeKey(
        privateKey: Data,
        peerPublicKey: Data,
        hostID: HostID,
        deviceID: DeviceID
    ) throws -> RelayChannelKey {
        let secret = try sharedSecret(privateKey: privateKey, publicKey: peerPublicKey)
        return RelayChannelKey(material: secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("Lumi Relay/v2/handshake".utf8),
            sharedInfo: Data("\(hostID.rawValue)/\(deviceID.rawValue)".utf8),
            outputByteCount: 64
        ))
    }

    /// The key of one channel session, from four X25519 results — both
    /// long-term keys with each other, each end's long-term key with the
    /// other's one-time key, and the two one-time keys with each other —
    /// through one HKDF-SHA256 bound to the channel's IDs and both one-time
    /// public keys (iPhone's first).
    ///
    /// The long-term keys are what authenticate the session: only the two
    /// paired ends arrive at the same key, and a leaked long-term key of one
    /// end is not enough to pose as the other. The one-time keys are what
    /// make it fresh: a frame recorded in any other session does not open,
    /// and once both one-time private keys are gone, no long-term key
    /// recovers this one.
    public static func sessionKey(
        as end: RelayChannelEnd,
        ephemeral: RelayEphemeralKey,
        peerEphemeralPublicKey: Data,
        privateKey: Data,
        peerPublicKey: Data,
        hostID: HostID,
        deviceID: DeviceID
    ) throws -> RelayChannelKey {
        let longTerm = try sharedSecret(privateKey: privateKey, publicKey: peerPublicKey)
        let ownLongTermWithPeerOneTime = try sharedSecret(privateKey: privateKey, publicKey: peerEphemeralPublicKey)
        let ownOneTimeWithPeerLongTerm = try sharedSecret(privateKey: ephemeral.privateKey, publicKey: peerPublicKey)
        let oneTime = try sharedSecret(privateKey: ephemeral.privateKey, publicKey: peerEphemeralPublicKey)
        let ownEphemeralPublicKey = try ephemeral.publicKey

        // Both ends must feed the same bytes in the same order: the mixed
        // results go host-long-term first, and the one-time public keys
        // iPhone first.
        var material = Data()
        var context = Data("\(hostID.rawValue)/\(deviceID.rawValue)".utf8)
        context.append(0)
        material.append(bytes(of: longTerm))
        switch end {
        case .host:
            material.append(bytes(of: ownLongTermWithPeerOneTime))
            material.append(bytes(of: ownOneTimeWithPeerLongTerm))
            context.append(peerEphemeralPublicKey)
            context.append(ownEphemeralPublicKey)
        case .device:
            material.append(bytes(of: ownOneTimeWithPeerLongTerm))
            material.append(bytes(of: ownLongTermWithPeerOneTime))
            context.append(ownEphemeralPublicKey)
            context.append(peerEphemeralPublicKey)
        }
        material.append(bytes(of: oneTime))
        return RelayChannelKey(material: HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material),
            salt: Data("Lumi Relay/v2/session".utf8),
            info: context,
            outputByteCount: 64
        ))
    }

    private static func sharedSecret(privateKey: Data, publicKey: Data) throws -> SharedSecret {
        let local: Curve25519.KeyAgreement.PrivateKey
        let peer: Curve25519.KeyAgreement.PublicKey
        do {
            local = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        } catch {
            throw RelayCryptographyError.invalidPrivateKey
        }
        do {
            peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        } catch {
            throw RelayCryptographyError.invalidPublicKey
        }
        return try local.sharedSecretFromKeyAgreement(with: peer)
    }

    private static func bytes(of secret: SharedSecret) -> Data {
        secret.withUnsafeBytes { Data($0) }
    }
}
