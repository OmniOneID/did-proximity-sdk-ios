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

@_spi(MdocInternal) public struct SessionEstablishment {
    public let eReaderKeyBytes: OpaqueCBOR
    public let data: Data
    public init(eReaderKeyBytes: OpaqueCBOR, data: Data) {
        self.eReaderKeyBytes = eReaderKeyBytes; self.data = data
    }
}

@_spi(MdocInternal) public struct SessionData {
    public let data: Data?
    public let status: UInt64?
    public init(data: Data? = nil, status: UInt64? = nil) {
        self.data = data; self.status = status
    }
    public static let terminate = SessionData(status: 20)
}

@_spi(MdocInternal) public enum SessionRole {
    case mdoc
    case mdocReader
}
