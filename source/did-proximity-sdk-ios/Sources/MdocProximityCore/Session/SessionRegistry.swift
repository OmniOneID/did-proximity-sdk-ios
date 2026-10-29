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

@_spi(MdocInternal) public enum SessionRegistry {
    private static let lock = NSLock()
    private static var active: (who: String, token: UInt64)? = nil
    private static var nextToken: UInt64 = 0

    public struct Claim: Equatable, Sendable {
        fileprivate let token: UInt64
    }

    @discardableResult
    public static func claim(_ who: String) throws -> Claim {
        lock.lock(); defer { lock.unlock() }
        if let active {
            throw MdocProximityError.invalidState(current: "active session: \(active.who)",
                                                  attempted: who)
        }
        nextToken &+= 1
        active = (who, nextToken)
        return Claim(token: nextToken)
    }

    public static func release(_ claim: Claim) {
        lock.lock(); defer { lock.unlock() }
        if active?.token == claim.token { active = nil }
    }

    public static func release() {
        lock.lock(); defer { lock.unlock() }
        active = nil
    }

    public static var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active != nil
    }
}
