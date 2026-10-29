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

@_spi(MdocInternal) public struct DeviceEngagement {
    public let version: String
    public let cipherSuiteIdentifier: Int64
    public let eDeviceKeyBytes: OpaqueCBOR
    public let retrievalMethods: [DeviceRetrievalMethod]
    public let unknownKeys: [UInt64]
    public let raw: OpaqueCBOR
}

@_spi(MdocInternal) public struct DeviceRetrievalMethod {
    public let type: UInt64
    public let version: UInt64
    public let options: CborValue  // BleOptions / NfcOptions / WifiOptions / any(RFU)

    public init(type: UInt64, version: UInt64, options: CborValue) {
        self.type = type; self.version = version; self.options = options
    }
}

@_spi(MdocInternal) public struct BleOptions {
    public let peripheralServerMode: Bool     // 0
    public let centralClientMode: Bool        // 1
    public let peripheralServerUUID: Data?    // 10
    public let centralClientUUID: Data?       // 11
    public let deviceAddress: Data?
    public let l2capPSM: UInt64?

    public init?(_ v: CborValue) {
        guard case .bool(let p) = v.member(0) ?? .null,
              case .bool(let c) = v.member(1) ?? .null else { return nil }
        peripheralServerMode = p
        centralClientMode = c
        peripheralServerUUID = v.member(10)?.asBytes
        centralClientUUID = v.member(11)?.asBytes
        deviceAddress = v.member(20)?.asBytes
        l2capPSM = v.member(21)?.asUInt
    }
}

@_spi(MdocInternal) public struct WifiOptions: Equatable {
    public let passphrase: String?
    public let operatingClass: UInt64?      // 1
    public let channelNumber: UInt64?       // 2
    public let supportedBands: Data?

    public init(passphrase: String? = nil, operatingClass: UInt64? = nil,
                channelNumber: UInt64? = nil, supportedBands: Data?) {
        self.passphrase = passphrase; self.operatingClass = operatingClass
        self.channelNumber = channelNumber; self.supportedBands = supportedBands
    }

    public init?(_ v: CborValue) {
        guard case .map = v else { return nil }
        passphrase = v.member(0)?.asText
        operatingClass = v.member(1)?.asUInt
        channelNumber = v.member(2)?.asUInt
        supportedBands = v.member(3)?.asBytes
    }

    public var cbor: CborValue {
        var pairs: [CborPair] = []
        if let operatingClass { pairs.append(CborPair(.unsigned(1), .unsigned(operatingClass))) }
        if let channelNumber { pairs.append(CborPair(.unsigned(2), .unsigned(channelNumber))) }
        pairs.append(CborPair(.unsigned(3), .bytes(supportedBands ?? Data())))
        return .map(pairs)
    }
}

@_spi(MdocInternal) public struct NfcOptions {
    public let maxCommandDataLength: UInt64   // 0
    public let maxResponseDataLength: UInt64  // 1
    public init?(_ v: CborValue) {
        guard let c = v.member(0)?.asUInt, let r = v.member(1)?.asUInt else { return nil }
        maxCommandDataLength = c; maxResponseDataLength = r
    }
}
