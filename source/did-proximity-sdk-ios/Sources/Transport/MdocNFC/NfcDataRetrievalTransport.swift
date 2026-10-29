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

@_spi(MdocInternal) public final class NfcDataRetrievalTransport: DataRetrievalTransportProtocol {

    public let events: AsyncStream<TransportEvent>
    private let emit: AsyncStream<TransportEvent>.Continuation
    private let channel: Iso7816Channel
    private let chaining: EnvelopeChaining
    private let selectsApplication: Bool
    private let presenceInterval: TimeInterval
    private var presenceTask: Task<Void, Never>?
    private var finished = false

    public init(channel: Iso7816Channel,
                maxCommandDataLength: Int, maxResponseDataLength: Int,
                selectsApplication: Bool = true,
                presenceInterval: TimeInterval = 0.25) {
        self.channel = channel
        self.presenceInterval = presenceInterval
        // Never exceed the limits the peer advertised (8.3.3.1.2). The upper bound is the Table 6 maximum 65535 / 65536
        self.chaining = EnvelopeChaining(commandLimit: min(maxCommandDataLength, 65_535),
                                         responseLimit: min(maxResponseDataLength, 65_536))
        self.selectsApplication = selectsApplication
        var c: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { c = $0 }
        emit = c
    }

    public func open(_ config: TransportConfig) async throws {
        guard config.role == .mdocReader else {
            throw MdocProximityError.nfcUnavailable(reason: .vendorPolicy)
        }
        if selectsApplication {
            let response = try await channel.transceive(Apdu.selectByName(NfcAid.mdocDataRetrieval))
            guard Apdu.statusWord(response) == 0x9000 else {
                throw MdocProximityError.connectionFailed(
                    detail: "SELECT mdoc AID: SW \(String(Apdu.statusWord(response), radix: 16))")
            }
        }
        emit.yield(.ready)
        startPresenceCheck()
    }

    private func startPresenceCheck() {
        guard presenceInterval > 0, presenceTask == nil else { return }
        let interval = presenceInterval
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if !channel.isAvailable {
                    if !finished { emit.yield(.peerClosed(.remote)) }
                    return
                }
            }
        }
    }

    public func send(_ message: Data) async throws {
        let commands = try chaining.commands(for: message)
        var sent = 0
        var last = Data()
        for command in commands {
            last = try await channel.transceive(command)
            sent = min(sent + chaining.commandLimit, message.count)
            emit.yield(.progress(sent: sent, total: message.count))
        }
        let reply = try await collect(last)
        if !reply.isEmpty { emit.yield(.message(try BerTlv53.value(reply))) }
    }

    private func collect(_ first: Data) async throws -> Data {
        var accumulated = Data()
        var response = first
        while true {
            switch chaining.step(response) {
            case .done(let body):
                accumulated.append(body)
                return accumulated
            case .getResponse(let le):
                accumulated.append(response.count >= 2 ? response.prefix(response.count - 2) : Data())
                response = try await channel.transceive(Apdu.getResponse(le: le))
            case .getResponseExtended(let le):
                accumulated.append(response.count >= 2 ? response.prefix(response.count - 2) : Data())
                response = try await channel.transceive(Apdu.getResponseExtended(le: le))
            case .failed:
                throw MdocProximityError.decodeFailed(
                    detail: "NFC: SW \(String(Apdu.statusWord(response), radix: 16))")
            }
        }
    }

    public func close(_ reason: TransportCloseReason) {
        presenceTask?.cancel()
        presenceTask = nil
        finished = true
        channel.close()
        emit.finish()
    }
}
