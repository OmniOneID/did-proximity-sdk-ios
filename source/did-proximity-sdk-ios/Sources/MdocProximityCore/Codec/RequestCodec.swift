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

@_spi(MdocInternal) public enum RequestCodec {

    public static func encode(_ request: DeviceRequest) throws -> Data {
        guard !request.docRequests.isEmpty else {
            throw MdocProximityError.validationFailed(detail: "docRequests must not be empty")
        }
        var seen = Set<DocType>()
        for spec in request.docRequests where !seen.insert(spec.docType).inserted {
            throw MdocProximityError.validationFailed(
                detail: "duplicate docType \"\(spec.docType)\"")
        }

        let docRequests: [CborValue] = request.docRequests.map { spec in
            let itemsRequest = CborValue.map([
                CborPair(.text("docType"), .text(spec.docType)),
                CborPair(.text("nameSpaces"), .map(spec.items.map { ns, elems in
                    CborPair(.text(ns), .map(elems.map { CborPair(.text($0.key), .bool($0.value)) }))
                }))
            ])
            // ItemsRequestBytes = #6.24(bstr .cbor ItemsRequest)
            let inner = CborEncoder.encode(itemsRequest)
            return .map([CborPair(.text("itemsRequest"), .tagged(24, .bytes(inner)))])
        }

        return CborEncoder.encode(.map([
            CborPair(.text("version"), .text(request.version)),
            CborPair(.text("docRequests"), .array(docRequests))
        ]))
    }
}
