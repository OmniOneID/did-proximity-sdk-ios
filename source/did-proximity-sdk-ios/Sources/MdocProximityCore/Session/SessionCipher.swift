/*
 * Copyright 2026 OmniOne.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
import CryptoKit

@_spi(MdocInternal) public final class SessionCipher {

    private let sendKey: SymmetricKey
    private let recvKey: SymmetricKey
    private let sendIdentifier: Data
    private let recvIdentifier: Data

    private var sendCounter: UInt32 = 1
    private var recvCounter: UInt32 = 1

    /// mdoc reader → `00 00 00 00 00 00 00 00`, mdoc → `00 00 00 00 00 00 00 01`
    static func identifier(_ role: SessionRole) -> Data {
        role == .mdocReader ? Data(repeating: 0, count: 8) : Data(repeating: 0, count: 7) + Data([0x01])
    }

    /// `IV = identifier(8) ‖ counter(4, big-endian unsigned)`
    public static func iv(role: SessionRole, counter: UInt32) -> Data {
        identifier(role) + withUnsafeBytes(of: counter.bigEndian) { Data($0) }
    }

    public init(role: SessionRole, sharedSecret zab: Data, transcript: SessionTranscriptBytes) {
        let keys = KeyDerivation.sessionKeys(zab: zab, transcript: transcript)
        switch role {
        case .mdocReader:
            sendKey = SymmetricKey(data: keys.skReader); recvKey = SymmetricKey(data: keys.skDevice)
            sendIdentifier = Self.identifier(.mdocReader); recvIdentifier = Self.identifier(.mdoc)
        case .mdoc:
            sendKey = SymmetricKey(data: keys.skDevice); recvKey = SymmetricKey(data: keys.skReader)
            sendIdentifier = Self.identifier(.mdoc); recvIdentifier = Self.identifier(.mdocReader)
        }
    }

    public func encrypt(_ plaintext: Data) throws -> Data {
        let counter = sendCounter
        let next = try increment(counter)
        let nonce = try AES.GCM.Nonce(data: sendIdentifier + be32(counter))
        let box = try AES.GCM.seal(plaintext, using: sendKey, nonce: nonce)
        sendCounter = next
        return box.ciphertext + box.tag
    }

    public func decrypt(_ payload: Data) throws -> Data {
        try decrypt(payload, counter: recvCounter)
    }

    public func decrypt(_ payload: Data, counter: UInt32) throws -> Data {
        guard counter == recvCounter else { throw MdocProximityError.counterMismatch }
        guard payload.count > 16 else {
            throw MdocProximityError.sessionEncryptionFailed
        }
        let nonce = try AES.GCM.Nonce(data: recvIdentifier + be32(counter))
        let box = try AES.GCM.SealedBox(nonce: nonce,
                                        ciphertext: payload.prefix(payload.count - 16),
                                        tag: payload.suffix(16))
        do {
            let plain = try AES.GCM.open(box, using: recvKey)
            recvCounter = try increment(recvCounter)
            return plain
        } catch {
            throw MdocProximityError.sessionEncryptionFailed
        }
    }

    func setSendCounterForTesting(_ value: UInt32) { sendCounter = value }

    private func increment(_ c: UInt32) throws -> UInt32 {
        guard c < UInt32.max else { throw MdocProximityError.sessionEncryptionFailed }
        return c + 1
    }

    private func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
}
