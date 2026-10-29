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

extension CborNode {
    func value(for key: String) -> CborNode? {
        guard case .map = value else { return nil }
        for i in stride(from: 0, to: children.count - 1, by: 2) where children[i].value == .text(key) {
            return children[i + 1]
        }
        return nil
    }
    func value(for key: UInt64) -> CborNode? {
        guard case .map = value else { return nil }
        for i in stride(from: 0, to: children.count - 1, by: 2) where children[i].value == .unsigned(key) {
            return children[i + 1]
        }
        return nil
    }
    var pairs: [(CborNode, CborNode)] {
        guard case .map = value else { return [] }
        return stride(from: 0, to: children.count - 1, by: 2).map { (children[$0], children[$0 + 1]) }
    }
    func require(_ key: String, _ what: String) throws -> CborNode {
        guard let n = value(for: key) else {
            throw MdocProximityError.validationFailed(detail: "\(what): missing \"\(key)\"")
        }
        return n
    }
}
