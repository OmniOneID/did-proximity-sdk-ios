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

@_spi(MdocInternal) public struct TransportParameters {
    public let technology: TransmissionTechnology
    public let role: SessionRole
    public let l2cap: Bool
    public let serviceUUID: Data?
    public let ident: Data?
    public let l2capPSM: UInt64?
    public let maxCommandDataLength: UInt64?
    public let maxResponseDataLength: UInt64?

    public init(technology: TransmissionTechnology, role: SessionRole, l2cap: Bool = false,
                serviceUUID: Data? = nil, ident: Data? = nil, l2capPSM: UInt64? = nil,
                maxCommandDataLength: UInt64? = nil, maxResponseDataLength: UInt64? = nil) {
        self.technology = technology
        self.role = role
        self.l2cap = l2cap
        self.serviceUUID = serviceUUID
        self.ident = ident
        self.l2capPSM = l2capPSM
        self.maxCommandDataLength = maxCommandDataLength
        self.maxResponseDataLength = maxResponseDataLength
    }
}

@_spi(MdocInternal) public protocol TransportFactoryProtocol {
    var availableTechnologies: [TransmissionTechnology] { get }
    func makeTransport(_ parameters: TransportParameters) throws -> DataRetrievalTransportProtocol
}
