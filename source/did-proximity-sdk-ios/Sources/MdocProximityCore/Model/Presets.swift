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

public enum MdocDocTypes {
    public static let mDL          = "org.iso.18013.5.1.mDL"
    public static let mDLNameSpace = "org.iso.18013.5.1"
}

public enum ItemsRequestPresets {
    public static func ageOver(_ age: Int, includePortrait: Bool = false) -> ItemsRequestSpec {
        var items: [DataElementIdentifier: Bool] = ["age_over_\(age)": false]
        if includePortrait { items["portrait"] = false }
        return ItemsRequestSpec(docType: MdocDocTypes.mDL, items: [MdocDocTypes.mDLNameSpace: items])
    }

    public static var identity: ItemsRequestSpec {
        ItemsRequestSpec(docType: MdocDocTypes.mDL, items: [MdocDocTypes.mDLNameSpace: [
            "family_name": false, "given_name": false, "birth_date": false, "portrait": false]])
    }

    public static var drivingPrivileges: ItemsRequestSpec {
        ItemsRequestSpec(docType: MdocDocTypes.mDL, items: [MdocDocTypes.mDLNameSpace: [
            "document_number": false, "expiry_date": false, "driving_privileges": false]])
    }
}

public extension ItemsRequestSpec {
    func jsonData() throws -> Data {
        let obj: [String: Any] = ["version": 1, "docType": docType,
                                  "items": items.mapValues { $0.mapValues { $0 } }]
        return try JSONSerialization.data(withJSONObject: obj,
                                          options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func from(jsonData: Data) throws -> ItemsRequestSpec {
        guard let o = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let docType = o["docType"] as? String, let raw = o["items"] as? [String: [String: Bool]] else {
            throw MdocProximityError.decodeFailed(detail: "ItemsRequestSpec JSON: bad structure")
        }
        guard (o["version"] as? Int) == 1 else {
            throw MdocProximityError.decodeFailed(detail: "ItemsRequestSpec JSON: unknown version")
        }
        return ItemsRequestSpec(docType: docType, items: raw)
    }
}
