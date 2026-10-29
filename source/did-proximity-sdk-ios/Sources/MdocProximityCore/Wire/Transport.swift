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

@_spi(MdocInternal) public protocol DataRetrievalTransportProtocol: AnyObject {
    var events: AsyncStream<TransportEvent> { get }
    func open(_ config: TransportConfig) async throws
    func send(_ message: Data) async throws
    func close(_ reason: TransportCloseReason)
}

@_spi(MdocInternal) public struct TransportConfig {
    public let role: SessionRole
    public init(role: SessionRole) { self.role = role }
}

@_spi(MdocInternal) public enum TransportEvent {
    case ready
    case message(Data)
    case progress(sent: Int, total: Int)
    case downgradedToGatt(reason: String)
    case peerClosed(TransportCloseReason)
    case failed(MdocProximityError)
}

@_spi(MdocInternal) public enum TransportCloseReason {
    case normal
    case remote
    case protocolError
    case timeout
}

@_spi(MdocInternal) public struct EngagementArtifacts {
    public let handoverSelectBytes: Data?
    public let handoverRequestBytes: Data?
    public var carriers: [TransmissionTechnology] = []
    public var nfcMaxCommandDataLength: UInt64?
    public var nfcMaxResponseDataLength: UInt64?
    public var bleServiceUUID: Data?
    public init(handoverSelectBytes: Data?, handoverRequestBytes: Data?) {
        self.handoverSelectBytes = handoverSelectBytes
        self.handoverRequestBytes = handoverRequestBytes
    }
}
