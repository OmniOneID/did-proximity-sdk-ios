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
#endif

@_spi(MdocInternal) public final class NfcCardTransport: DataRetrievalTransportProtocol {

    public let events: AsyncStream<TransportEvent>
    private let emit: AsyncStream<TransportEvent>.Continuation
    private let emulation: NfcCardEmulationProtocol
    private var tag: Type4TagEmulator
    private let responseLimit: Int

    private enum Layer { case engagement, dataRetrieval }
    private var layer: Layer = .engagement
    private var inbound = Data()
    private var outbound = Data()
    private var queued: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private let lock = NSLock()
    private var readySignaled = false
    private var finished = false
    private var gone = false

    public init(emulation: NfcCardEmulationProtocol, handoverSelect: Data,
                maxCommandDataLength: Int, maxResponseDataLength: Int,
                mode: Type4TagEmulator.Mode = .static) {
        self.emulation = emulation
        self.tag = Type4TagEmulator(ndefMessage: handoverSelect, mode: mode)
        self.responseLimit = maxResponseDataLength
        var c: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { c = $0 }
        emit = c
    }

    public func open(_ config: TransportConfig) async throws {
        guard config.role == .mdoc else { throw MdocProximityError.unsupportedTransmissionTechnology }
        emulation.onDeactivated = { [weak self] in self?.peerGone() }
        try await emulation.start { [weak self] apdu in
            await self?.handle(apdu) ?? Data([0x6F, 0x00])
        }
    }

    public func send(_ message: Data) async throws {
        let tlv = BerTlv53.encode(message)
        guard let outcome = offer(tlv) else { throw MdocProximityError.peerDisconnected }
        outcome?.resume(returning: tlv)
        emit.yield(.progress(sent: message.count, total: message.count))
    }

    private func offer(_ tlv: Data) -> CheckedContinuation<Data?, Never>?? {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return nil }
        if let w = waiter { waiter = nil; return .some(w) }
        queued.append(tlv)
        return .some(nil)
    }

    private enum Pending {
        case ready(Data?)
        case registered
    }

    private func takeQueuedOrRegister(_ c: CheckedContinuation<Data?, Never>) -> Pending {
        lock.lock(); defer { lock.unlock() }
        if !queued.isEmpty { return .ready(queued.removeFirst()) }
        if finished { return .ready(Data()) }
        if gone { return .ready(nil) }
        waiter = c
        return .registered
    }

    public func close(_ reason: TransportCloseReason) {
        lock.lock()
        finished = true
        let w = waiter; waiter = nil
        lock.unlock()
        w?.resume(returning: Data())
        emulation.stop()
        emit.finish()
    }

    private func peerGone() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        gone = true
        let w = waiter; waiter = nil
        lock.unlock()
        w?.resume(returning: nil)
        emit.yield(.peerClosed(.remote))
    }

    // MARK: APDU

    private func handle(_ apdu: Data) async -> Data {
        guard apdu.count >= 4 else { return Data([0x67, 0x00]) }
        let cla = apdu[apdu.startIndex], ins = apdu[apdu.startIndex + 1], p1 = apdu[apdu.startIndex + 2]

        if ins == 0xA4, p1 == 0x04 {
            guard apdu.count >= 5 else { return Data([0x6A, 0x86]) }
            let lc = Int(apdu[apdu.startIndex + 4])
            guard apdu.count >= 5 + lc else { return Data([0x67, 0x00]) }
            let aid = apdu.subdata(in: (apdu.startIndex + 5)..<(apdu.startIndex + 5 + lc))
            if aid == NfcAid.ndefTagApplication {
                layer = .engagement; tag.reset()
                return Data([0x90, 0x00])
            }
            if aid == NfcAid.mdocDataRetrieval {
                layer = .dataRetrieval; inbound.removeAll()
                if !readySignaled { readySignaled = true; emit.yield(.ready) }
                return Data([0x90, 0x00])
            }
            return Data([0x6A, 0x82])
        }

        switch layer {
        case .engagement:
            return tag.handle(apdu)
        case .dataRetrieval:
            switch ins {
            case 0xC3: return await envelope(apdu, chained: cla & 0x10 != 0)
            case 0xC0: return nextChunk(le: apdu.count >= 5 ? Int(apdu[apdu.startIndex + 4]) : 0)
            default: return Data([0x6D, 0x00])
            }
        }
    }

    private func envelope(_ apdu: Data, chained: Bool) async -> Data {
        guard apdu.count >= 5 else { return Data([0x67, 0x00]) }
        let lc = Int(apdu[apdu.startIndex + 4])
        guard apdu.count >= 5 + lc else { return Data([0x67, 0x00]) }
        inbound.append(apdu.subdata(in: (apdu.startIndex + 5)..<(apdu.startIndex + 5 + lc)))
        if chained { return Data([0x90, 0x00]) }

        let raw = inbound; inbound.removeAll()
        let message: Data
        do { message = try BerTlv53.values(raw) } catch {
            emit.yield(.failed(error as? MdocProximityError ?? .decodeFailed(detail: "NFC: envelope")))
            return Data([0x6A, 0x80])
        }
        emit.yield(.message(message))

        let got: Data? = await withCheckedContinuation { c in
            if case .ready(let value) = takeQueuedOrRegister(c) { c.resume(returning: value) }
        }
        guard let got else { return Data([0x6F, 0x00]) }
        outbound = got
        let le = apdu.count > 5 + lc ? Int(apdu[apdu.startIndex + 5 + lc]) : 0
        return nextChunk(le: le)
    }

    private func nextChunk(le: Int) -> Data {
        let want = le == 0 ? 256 : le
        let n = min(want, outbound.count, responseLimit)
        let part = outbound.prefix(n)
        outbound.removeFirst(n)
        let remaining = outbound.count
        var out = Data(part)
        out.append(contentsOf: remaining == 0 ? [0x90, 0x00] : [0x61, remaining > 255 ? 0x00 : UInt8(remaining)])
        return out
    }
}
