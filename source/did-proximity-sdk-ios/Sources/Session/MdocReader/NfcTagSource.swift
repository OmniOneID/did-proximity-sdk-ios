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
#if canImport(MdocProximityCore)
@_spi(MdocInternal) import MdocProximityCore
@_spi(MdocInternal) import MdocNFC
#endif

@_spi(MdocInternal) public protocol NfcTagSource {
    func openChannel() async throws -> Iso7816Channel
    func cancel()
}

extension NfcTagSource {
    public func cancel() {}
}

@_spi(MdocInternal) public struct UnavailableNfcTagSource: NfcTagSource {
    public init() {}
    public func openChannel() async throws -> Iso7816Channel {
        throw MdocProximityError.nfcUnavailable(reason: .noHardware)
    }
}

@_spi(MdocInternal) public enum NfcSessionInvalidation {
    public static let errorDomain = "NFCError"
    /// `NFCReaderError.readerSessionInvalidationErrorUserCanceled`
    public static let userCanceledCode = 200

    public static func error(domain: String, code: Int, description: String) -> Error {
        if domain == errorDomain, code == userCanceledCode { return CancellationError() }
        return MdocProximityError.connectionFailed(detail: "NFC session: \(description)")
    }
}

@_spi(MdocInternal) public enum NfcTransceiveFailure {
    /// `readerTransceiveErrorTagConnectionLost` · `RetryExceeded` · `SessionInvalidated` · `TagNotConnected`
    public static let linkLostCodes: Set<Int> = [100, 101, 103, 104]

    public static func error(domain: String, code: Int, description: String) -> MdocProximityError {
        if domain == NfcSessionInvalidation.errorDomain, linkLostCodes.contains(code) { return .peerDisconnected }
        return .connectionFailed(detail: "NFC transceive: \(description)")
    }
}

#if canImport(CoreNFC)
import CoreNFC

@_spi(MdocInternal) public final class CoreNfcTagSource: NSObject, NfcTagSource, NFCTagReaderSessionDelegate {

    private var session: NFCTagReaderSession?
    private var waiter: CheckedContinuation<Iso7816Channel, Error>?
    private var cancelled = false
    private let lock = NSLock()
    @_spi(MdocInternal) public var onTagSeen: ((String) -> Void)?

    public override init() { super.init() }

    public func openChannel() async throws -> Iso7816Channel {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                guard NFCTagReaderSession.readingAvailable else {
                    return c.resume(throwing: MdocProximityError.nfcUnavailable(reason: .noHardware))
                }
                guard let s = NFCTagReaderSession(pollingOption: [.iso14443],
                                                  delegate: self, queue: nil) else {
                    return c.resume(throwing: MdocProximityError.nfcUnavailable(reason: .noHardware))
                }
                lock.lock()
                if cancelled {
                    cancelled = false; lock.unlock()
                    return c.resume(throwing: CancellationError())
                }
                waiter = c
                session = s
                lock.unlock()
                s.begin()
            }
        } onCancel: {
            cancel()
        }
    }

    public func cancel() {
        lock.lock()
        let s = session
        let w = waiter
        waiter = nil
        if w == nil, s == nil { cancelled = true }
        session = nil
        lock.unlock()
        w?.resume(throwing: CancellationError())
        s?.invalidate()
    }

    public func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    public func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        let ns = error as NSError
        resume(.failure(NfcSessionInvalidation.error(domain: ns.domain, code: ns.code, description: "\(error)")),
               from: session)
    }

    public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first, case .iso7816(let iso) = tag else {
            let kind: String
            switch tags.first {
            case .miFare: kind = "MIFARE"
            case .feliCa: kind = "FeliCa"
            case .iso15693: kind = "ISO15693"
            default: kind = "unknown"
            }
            onTagSeen?("non-ISO7816 tag — \(kind)")
            return session.restartPolling()
        }
        onTagSeen?("ISO7816 tag — AID selected by the system: "
                   + iso.initialSelectedAID)
        session.connect(to: tag) { [weak self] error in
            guard error == nil else { return session.restartPolling() }
            self?.resume(.success(CoreNfcChannel(tag: iso, session: session)), from: session)
        }
    }

    private func resume(_ result: Result<Iso7816Channel, Error>, from origin: NFCTagReaderSession) {
        lock.lock()
        guard let waiter, origin === session else { lock.unlock(); return }
        self.waiter = nil
        if case .success = result {} else { session = nil }
        lock.unlock()
        waiter.resume(with: result)
    }
}

final class CoreNfcChannel: Iso7816Channel {
    private let tag: NFCISO7816Tag
    private let session: NFCTagReaderSession

    init(tag: NFCISO7816Tag, session: NFCTagReaderSession) {
        self.tag = tag; self.session = session
    }

    func transceive(_ apdu: Data) async throws -> Data {
        guard let command = NFCISO7816APDU(data: apdu) else {
            throw MdocProximityError.decodeFailed(detail: "NFC: malformed APDU")
        }
        do {
            let (data, sw1, sw2) = try await tag.sendCommand(apdu: command)
            return data + Data([sw1, sw2])
        } catch let error as MdocProximityError {
            throw error
        } catch {
            let ns = error as NSError
            throw NfcTransceiveFailure.error(domain: ns.domain, code: ns.code, description: "\(error)")
        }
    }

    var isAvailable: Bool { tag.isAvailable }

    func close() { session.invalidate() }
}
#endif

@_spi(MdocInternal) public enum DefaultNfcTagSource {
    public static func make() -> NfcTagSource {
        #if canImport(CoreNFC)
        return CoreNfcTagSource()
        #else
        return UnavailableNfcTagSource()
        #endif
    }
}
