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

@_spi(MdocInternal) public enum EngagementCodec {

    public static func decode(_ data: Data) throws -> DeviceEngagement {
        let node = try CborDecoder.decodeNode(data)
        guard case .map = node.value else {
            throw MdocProximityError.validationFailed(detail: "DeviceEngagement: not a map")
        }
        guard let version = node.value(for: UInt64(0))?.value.asText else {
            throw MdocProximityError.validationFailed(detail: "DeviceEngagement: missing version")
        }
        guard let security = node.value(for: UInt64(1)), case .array = security.value,
              security.children.count == 2 else {
            throw MdocProximityError.validationFailed(detail: "DeviceEngagement: bad Security")
        }
        let suite: Int64
        switch security.children[0].value {
        case .unsigned(let n) where Int64(exactly: n) != nil: suite = Int64(n)
        case .negative(let n) where Int64(exactly: n) != nil: suite = -1 - Int64(n)
        default: throw MdocProximityError.validationFailed(detail: "DeviceEngagement: bad cipher suite")
        }

        var methods: [DeviceRetrievalMethod] = []
        if let m = node.value(for: UInt64(2)), case .array(let items) = m.value {
            for item in items {
                guard case .array(let f) = item, f.count >= 3,
                      let t = f[0].asUInt, let v = f[1].asUInt else { continue }
                methods.append(DeviceRetrievalMethod(type: t, version: v, options: f[2]))
            }
        }

        var unknown: [UInt64] = []
        for (k, _) in node.pairs {
            if case .unsigned(let n) = k.value, n > 4 { unknown.append(n) }
        }

        return DeviceEngagement(
            version: version,
            cipherSuiteIdentifier: suite,
            eDeviceKeyBytes: OpaqueCBOR(security.children[1], in: data),
            retrievalMethods: methods,
            unknownKeys: unknown,
            raw: OpaqueCBOR(node, in: data))
    }
}

@_spi(MdocInternal) public extension EngagementCodec {
    static func encode(cipherSuite: Int64 = 1,
                       eDeviceKeyBytes: OpaqueCBOR,
                       retrievalMethods: [DeviceRetrievalMethod]) throws -> Data {
        var pairs: [CborPair] = [
            CborPair(.unsigned(0), .text("1.0")),
            CborPair(.unsigned(1), .array([.unsigned(UInt64(cipherSuite)),
                                           try CborDecoder.decode(eDeviceKeyBytes.raw)]))
        ]
        if !retrievalMethods.isEmpty {
            pairs.append(CborPair(.unsigned(2), .array(retrievalMethods.map {
                .array([.unsigned($0.type), .unsigned($0.version), $0.options])
            })))
        }
        return CborEncoder.encode(.map(pairs))
    }
}
