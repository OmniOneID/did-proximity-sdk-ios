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

@_spi(MdocInternal) public final class LoopbackTransport: DataRetrievalTransportProtocol {

    public let events: AsyncStream<TransportEvent>
    private let emit: AsyncStream<TransportEvent>.Continuation
    private weak var peer: LoopbackTransport?

    public init() {
        var c: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { c = $0 }
        emit = c
    }

    public static func pair() -> (LoopbackTransport, LoopbackTransport) {
        let a = LoopbackTransport(), b = LoopbackTransport()
        a.peer = b; b.peer = a
        return (a, b)
    }

    public func open(_ config: TransportConfig) async throws {
        emit.yield(.ready)
    }

    public func send(_ message: Data) async throws {
        guard let peer else { throw MdocProximityError.peerDisconnected }
        emit.yield(.progress(sent: message.count, total: message.count))
        peer.emit.yield(.message(message))
    }

    public func close(_ reason: TransportCloseReason) {
        peer?.emit.yield(.peerClosed(.remote))
        emit.finish()
    }

    public func nextMessage() async -> Data? {
        for await e in events { if case .message(let d) = e { return d } }
        return nil
    }
}
