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

@_spi(MdocInternal) public enum SessionCodec {

    public static func encodeEstablishment(eReaderKeyBytes: OpaqueCBOR, data: Data) throws -> Data {
        CborEncoder.encode(.map([
            CborPair(.text("eReaderKey"), try CborDecoder.decode(eReaderKeyBytes.raw)),
            CborPair(.text("data"), .bytes(data))
        ]))
    }

    public static func decodeEstablishment(_ bytes: Data) throws -> SessionEstablishment {
        let node = try CborDecoder.decodeNode(bytes)
        guard let keyNode = node.value(for: "eReaderKey"),
              let data = node.value(for: "data")?.value.asBytes else {
            throw MdocProximityError.validationFailed(detail: "SessionEstablishment: missing field")
        }
        return SessionEstablishment(eReaderKeyBytes: OpaqueCBOR(keyNode, in: bytes), data: data)
    }

    public static func encodeData(_ s: SessionData) -> Data {
        var pairs: [CborPair] = []
        if let d = s.data { pairs.append(CborPair(.text("data"), .bytes(d))) }
        if let st = s.status { pairs.append(CborPair(.text("status"), .unsigned(st))) }
        return CborEncoder.encode(.map(pairs))
    }

    public static func decodeData(_ bytes: Data) throws -> SessionData {
        let v = try CborDecoder.decode(bytes)
        guard case .map = v else {
            throw MdocProximityError.validationFailed(detail: "SessionData: not a map")
        }
        return SessionData(data: v.member("data")?.asBytes, status: v.member("status")?.asUInt)
    }
}
