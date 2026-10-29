---
puppeteer:
    pdf:
        format: A4
        displayHeaderFooter: true
        landscape: false
        scale: 0.8
        margin:
            top: 1.2cm
            right: 1cm
            bottom: 1cm
            left: 1cm
    image:
        quality: 100
        fullPage: false
---

iOS MdocProximity DataModel
==

- Subject: DataModel
- Writer: 박주현
- Date: 2026-10-12
- Version: v1.0.0

| Version          | Date       | History                 |
| ---------------- | ---------- | ------------------------|
| v1.0.0           | 2026-10-12 | 최초 작성                 |


<div style="page-break-after: always;"></div>


# Table of Contents
- [개요](#개요)
- [식별자](#식별자)
    - [1. Type Aliases](#1-type-aliases)
    - [2. MdocDocTypes](#2-mdocdoctypes)
- [Data Element 값](#data-element-값)
    - [1. MdocValue](#1-mdocvalue)
- [Engagement 와 전송](#engagement-와-전송)
    - [1. EngagementPayload](#1-engagementpayload)
    - [2. EngagementTechnology](#2-engagementtechnology)
    - [3. TransmissionTechnology](#3-transmissiontechnology)
    - [4. BleMode](#4-blemode)
- [검증 결과](#검증-결과)
    - [1. VerifiedResponse](#1-verifiedresponse)
    - [2. VerifiedDocument](#2-verifieddocument)
    - [3. IssuerDataAuthResult](#3-issuerdataauthresult)
    - [4. ValidityCheck](#4-validitycheck)
    - [5. MdocAuthResult](#5-mdocauthresult)
    - [6. DigestCheckResult](#6-digestcheckresult)
    - [7. VerificationVerdict](#7-verificationverdict)
    - [8. ElementProvenance](#8-elementprovenance)
    - [9. DocumentWarning](#9-documentwarning)
    - [10. 검증 결과 해석](#10-검증-결과-해석)
        - [10.1. 요소의 출처](#101-요소의-출처)
        - [10.2. 네임스페이스 범위](#102-네임스페이스-범위)
        - [10.3. 모르는 요소](#103-모르는-요소)
        - [10.4. 보관 범위와 intentToRetain](#104-보관-범위와-intenttoretain)
        - [10.5. 부분 응답과 notReturned](#105-부분-응답과-notreturned)
- [Capability](#capability)
    - [1. MdocCapabilities](#1-mdoccapabilities)
    - [2. RoleCapabilities](#2-rolecapabilities)
    - [3. TransportCapability](#3-transportcapability)
    - [4. Capability 해석](#4-capability-해석)
        - [4.1. unsupported 와 configurationRequired](#41-unsupported-와-configurationrequired)
        - [4.2. iOS 의 NFC](#42-ios-의-nfc)
        - [4.3. Bluetooth 조회의 한계](#43-bluetooth-조회의-한계)

<br>

# 개요

이 문서는 ISO/IEC 18013-5 근접 제출 SDK 가 공통으로 쓰는 공개 값 타입을 설명한다.

| Distribution | Import | Note |
|--------------|--------|------|
| Swift Package product `MdocDevice` | `import MdocDevice` | mdoc(홀더) 앱. 이 문서의 타입을 함께 내보낸다 |
| Swift Package product `MdocReader` | `import MdocReader` | mdoc reader 앱. 이 문서의 타입과 [MdocTrust](MdocTrust_ko.md) 를 함께 내보낸다 |
| XCFramework | `import MdocProximitySDK` | 모든 공개 타입을 담은 단일 모듈 |

관련 문서

| Document | Content |
|----------|---------|
| [MdocDeviceAPI](MdocDeviceAPI_ko.md) | `MdocDeviceSession` 과 그 설정·상태·콜백 |
| [MdocReaderAPI](MdocReaderAPI_ko.md) | `MdocReaderSession`, 리더 설정, 요청 구성, 콜백 |
| [MdocTrust](MdocTrust_ko.md) | 리더 앱이 쓰는 발급자 신뢰 판정 |
| [MdocProximityError](MdocProximityError.md) | `MdocProximityError`, `CapabilityReason`, `RequiredAction` |

**mdoc 문서는 이 SDK 의 타입이 아니다.** mdoc 측에서 어느 문서를 제시할지, 어떤 data element 를 공개할지는 이 SDK 의 API 에 나타나지 않는다. 문서 보관·매칭·홀더 동의는 월렛 SDK 와 앱의 일이다. 이 SDK 는 앱에 요청 바이트를 건네고 응답 바이트를 받는다. 그래서 문서 참조 타입도, 저장소 식별자를 감싼 핸들도 없다.

이 문서의 값은 SDK 가 만든다. 공개 생성자가 없는 타입은 앱이 직접 만드는 용도가 아니다.

<br>

# 식별자

## 1. Type Aliases

### Description

`API 전반에서 쓰는 식별자. 모두 String 이다.`

### Declaration

```swift
// Declaration in Swift
public typealias DocType               = String   // "org.iso.18013.5.1.mDL"
public typealias NameSpace             = String   // "org.iso.18013.5.1"
public typealias DataElementIdentifier = String   // "family_name"
```

### Property

| Name                  | Type   | Description                     | **M/O** | **Note** |
|-----------------------|--------|---------------------------------|---------|----------|
| DocType               | String | 문서 타입                         |    M    | 형식 제한 없음 |
| NameSpace             | String | data element 네임스페이스          |    M    | 형식 제한 없음 |
| DataElementIdentifier | String | 네임스페이스 안의 data element 식별자 |    M    |          |

<br>

## 2. MdocDocTypes

### Description

`mDL 전용 편의 상수.`

프로토콜은 문서 타입과 네임스페이스를 제한하지 않는다. 이 상수는 mDL 문서 타입을 위한 것일 뿐이다. 다른 문서 타입은 식별자를 직접 쓴다. [10.2. 네임스페이스 범위](#102-네임스페이스-범위)를 참고한다.

### Declaration

```swift
// Declaration in Swift
public enum MdocDocTypes {
    public static let mDL          = "org.iso.18013.5.1.mDL"
    public static let mDLNameSpace = "org.iso.18013.5.1"
}
```

### Property

| Name         | Type   | Description         | **M/O** | **Note** |
|--------------|--------|---------------------|---------|----------|
| mDL          | String | mDL 문서 타입         |    M    | `org.iso.18013.5.1.mDL` |
| mDLNameSpace | String | mDL 네임스페이스       |    M    | `org.iso.18013.5.1` |

<br>

# Data Element 값

## 1. MdocValue

### Description

`data element 의 값. CBOR 값을 태그를 케이스로 보존해 표현한다.`

태그가 붙은 값은 별도 케이스로 온다. `full-date`(tag 1004)와 date-time(tag 0)은 글자가 비슷해도 `.fullDate` 와 `.dateTime` 으로 갈린다. 날짜 값은 **원문 문자열 그대로** 준다. SDK 는 날짜를 파싱하지 않으며, 파싱과 로캘·시간대 해석은 앱이 한다.

값은 패턴 매칭으로 꺼낸다(`if case .integer(let n) = value`). 접근자는 `asText` 와 `asBoolean` 둘만 둔다. 표시용 포맷 API 는 제공하지 않는다.

### Declaration

```swift
// Declaration in Swift
public enum MdocValue: Equatable {
    case text(String)
    case integer(Int64)
    case boolean(Bool)
    case bytes(Data)
    case fullDate(String)      // tag 1004
    case dateTime(String)      // tag 0
    case array([MdocValue])
    case map([String: MdocValue])
    case null
    case unsupported

    public var asBoolean: Bool? { get }
    public var asText: String? { get }
}
```

### Property

| Name        | Type                  | Description                                     | **M/O** | **Note** |
|-------------|-----------------------|-------------------------------------------------|---------|----------|
| text        | String                | 문자열                                           |    -    |          |
| integer     | Int64                 | 정수                                             |    -    | `Int64` 범위를 넘는 정수는 `.unsupported` |
| boolean     | Bool                  | 불리언                                           |    -    | 예: `age_over_18` |
| bytes       | Data                  | 바이트 문자열                                     |    -    | 예: `portrait` |
| fullDate    | String                | `full-date`(tag 1004), 원문 그대로                 |    -    | 예: `"1990-01-02"` |
| dateTime    | String                | date-time(tag 0), 원문 그대로                      |    -    | 예: `"2026-01-01T00:00:00Z"` |
| array       | [MdocValue]           | 배열                                             |    -    | 예: `driving_privileges` |
| map         | [String: MdocValue]   | 문자열 키 맵                                      |    -    |          |
| null        |                       | CBOR null                                       |    -    | CBOR undefined 는 `.null` 이 아니라 `.unsupported` 로 온다 |
| unsupported |                       | 이 SDK 가 표현하지 못하는 값                        |    -    | 아래 설명 참고 |
| asBoolean   | Bool                  | `.boolean` 이면 그 값, 아니면 `nil`                 |    O    |          |
| asText      | String                | `.text` 이면 그 값, 아니면 `nil`                    |    O    |          |

**`unsupported`** 는 틀린 값을 주지 않기 위해 있다. 아래 값은 변환하지 않고 `.unsupported` 로 보낸다.

| 받은 값 | 이유 |
|---------|------|
| 0·1004 외의 태그 (또는 문자열을 감싸지 않은 tag 0·1004) | 태그를 떼면 의미가 달라진다 (예: bignum 이 `.bytes` 로 보인다) |
| 문자열이 아닌 키를 가진 맵 | 그 쌍을 버리면 값이 없었던 것처럼 보인다 |
| `Int64` 범위를 넘는 정수 | 표현할 수 없다 |
| 부동소수점(16·32·64비트), `undefined`, 그 밖의 simple value | 표현할 케이스가 없다. `undefined` 를 `.null` 로 바꾸지 않는다 — 다른 값이다 |

값의 원본 CBOR 바이트는 노출하지 않는다.

### Usage

```swift
let ns = MdocDocTypes.mDLNameSpace
if case .fullDate(let text)? = doc.issuerSignedElements[ns]?["birth_date"] {
    showBirthDate(text)              // "1990-01-02", unparsed
}
let isAdult = doc.issuerSignedElements[ns]?["age_over_18"]?.asBoolean == true
```

<br>

# Engagement 와 전송

## 1. EngagementPayload

### Description

`Device engagement. mdoc 앱이 QR 로 보여주거나 리더 앱이 스캔해 얻는 값.`

내부의 `DeviceEngagementBytes` 와 `Handover` 원본 바이트는 노출하지 않는다. `SessionTranscript` 구성에만 쓰이며, 바꾸면 검증이 깨진다.

### Declaration

```swift
// Declaration in Swift
public struct EngagementPayload {
    public let qrString: String?
    public let technology: EngagementTechnology
    public let transmissions: [TransmissionTechnology]

    public static func parse(qrString: String) throws -> EngagementPayload
}
```

### Property

| Name          | Type                     | Description                                            | **M/O** | **Note** |
|---------------|--------------------------|--------------------------------------------------------|---------|----------|
| qrString      | String                   | `"mdoc:" + base64url(DeviceEngagement)`                |    O    | QR engagement 일 때만 값이 있다 |
| technology    | EngagementTechnology     | 무엇으로 engagement 했는가                                |    M    | [EngagementTechnology](#2-engagementtechnology) |
| transmissions | [TransmissionTechnology] | 상대가 광고한 data retrieval 전송 기술                     |    M    | [TransmissionTechnology](#3-transmissiontechnology). NFC engagement 이면 Handover Select 의 캐리어 |

### Method

| Name             | Description                                        | **Note** |
|------------------|----------------------------------------------------|----------|
| parse(qrString:) | 스캔한 QR 문자열을 `EngagementPayload` 로 해석한다       | `mdoc:` 으로 시작하지 않거나 base64url 이 올바르지 않으면 `MdocProximityError.malformedEngagement`. 렌더링과 카메라는 앱 몫이다 |

`transmissions` 에서 BLE 는 GATT 모드만 나온다. 상대가 L2CAP PSM 을 실었는지는 이 값에 없다. L2CAP 은 고른 모드 위에서 SDK 가 협상한다. 상대가 BLE method 하나에 두 모드를 함께 광고하면 두 모드가 모두 나온다. Wi-Fi Aware 는 iOS 가 쓸 수 없어도 광고됐으면 목록에 나온다([4.1](#41-unsupported-와-configurationrequired) 참고).

### Usage

```swift
let payload = try EngagementPayload.parse(qrString: scannedText)
```

<br>

## 2. EngagementTechnology

### Description

`Device engagement 전송 기술 (ISO/IEC 18013-5 8.2.2).`

data retrieval 전송 기술과는 다른 축이다. engagement 채널이 세션 트랜스크립트의 `Handover` 를 정한다.

### Declaration

```swift
// Declaration in Swift
public enum EngagementTechnology: Equatable {
    case qr
    case nfcStaticHandover
    case nfcNegotiatedHandover

    public var isNFC: Bool { get }
}
```

### Property

| Name                  | Type | Description                                   | **M/O** | **Note** |
|-----------------------|------|-----------------------------------------------|---------|----------|
| qr                    |      | QR 코드 engagement                             |    -    |          |
| nfcStaticHandover     |      | NFC static handover                           |    -    |          |
| nfcNegotiatedHandover |      | NFC negotiated handover(TNEP). 리더가 Handover Request 를 쓰고 mdoc 이 캐리어 하나를 골라 Handover Select 로 답한다 |    -    |          |
| isNFC                 | Bool | NFC 케이스 둘이면 `true`                        |    M    |          |

<br>

## 3. TransmissionTechnology

### Description

`Data retrieval 전송 기술 (ISO/IEC 18013-5 8.3.3).`

### Declaration

```swift
// Declaration in Swift
public enum TransmissionTechnology: Equatable {
    case ble(BleMode)
    case nfc
    case wifiAware
}
```

### Property

| Name      | Type    | Description                        | **M/O** | **Note** |
|-----------|---------|------------------------------------|---------|----------|
| ble       | BleMode | 지정한 GATT 모드의 BLE               |    -    | [BleMode](#4-blemode) |
| nfc       |         | NFC                                |    -    |          |
| wifiAware |         | Wi-Fi Aware                        |    -    | iOS 에서는 쓸 수 없다. 능력 조회가 `.unsupported(reason: .vendorPolicy)` 를 내고, Wi-Fi Aware 만 광고한 상대에는 연결할 수 없다(`wifiAwareUnavailable(reason: .vendorPolicy)`) |

iOS 에도 이 케이스가 있는 것은 리더가 상대의 광고를 읽고 왜 쓸 수 없는지를 능력 조회·에러와 같은 어휘로 말하기 위해서다.

<br>

## 4. BleMode

### Description

`BLE GATT 모드 (ISO/IEC 18013-5 8.3.3.1.1).`

L2CAP 은 모드가 아니다. 상대가 PSM 을 노출할 때 같은 연결 설정·서비스를 쓰며 GATT 모드 위에서 협상되는 승격이다. 양쪽의 `l2capUpgrade` 설정으로 켠다([MdocDeviceAPI](MdocDeviceAPI_ko.md), [MdocReaderAPI](MdocReaderAPI_ko.md) 참고). L2CAP 이 성립하지 않으면 SDK 가 같은 모드의 GATT 로 복귀한다.

### Declaration

```swift
// Declaration in Swift
public enum BleMode: Equatable {
    case peripheralServer, centralClient
}
```

### Property

| Name             | Type | Description                                         | **M/O** | **Note** |
|------------------|------|-----------------------------------------------------|---------|----------|
| peripheralServer |      | mdoc peripheral server 모드. mdoc 이 GATT server     |    -    |          |
| centralClient    |      | mdoc central client 모드. mdoc reader 가 GATT server |    -    |          |

<br>

# 검증 결과

리더 앱은 `MdocReaderSession.request(_:at:)` 에서 이 타입들을 받는다([MdocReaderAPI](MdocReaderAPI_ko.md) 참고). 검증은 boolean 하나로 뭉개지 않는다. 항목별 판정을 따로 노출하고 [verdict](#7-verificationverdict) 가 이를 요약한다.

## 1. VerifiedResponse

### Description

`검증된 DeviceResponse.`

### Declaration

```swift
// Declaration in Swift
public struct VerifiedResponse {
    public let documents: [VerifiedDocument]
    public let documentErrors: [DocType: Int64]
    public let status: UInt64
}
```

### Property

| Name           | Type               | Description                                  | **M/O** | **Note** |
|----------------|--------------------|----------------------------------------------|---------|----------|
| documents      | [VerifiedDocument] | 받은 문서                                      |    M    | [VerifiedDocument](#2-verifieddocument). `status` 가 0 이어도 빌 수 있다. [10.5](#105-부분-응답과-notreturned) 참고 |
| documentErrors | [DocType: Int64]   | 문서 타입별 문서 단위 오류                         |    M    | `ErrorCode` 는 부호 있는 정수다 |
| status         | UInt64             | `DeviceResponse.status`                      |    M    | 0 이 아니면 문서가 하나도 오지 않는다 |

`documents` 는 옵셔널이 아니다. 문서가 없는 응답은 빈 배열로 온다.

<br>

## 2. VerifiedDocument

### Description

`검증된 문서 하나. 항목별 검증 결과를 따로 노출한다.`

### Declaration

```swift
// Declaration in Swift
public struct VerifiedDocument {
    public let docType: DocType

    public let issuerSignedElements: [NameSpace: [DataElementIdentifier: MdocValue]]
    public let deviceSignedElements: [NameSpace: [DataElementIdentifier: MdocValue]]
    public var allElements: [NameSpace: [DataElementIdentifier: MdocValue]] { get }

    public let issuerDataAuth: IssuerDataAuthResult
    public let mdocAuth: MdocAuthResult
    public let digests: DigestCheckResult?
    public let warnings: [DocumentWarning]

    public let notReturned: [NameSpace: [DataElementIdentifier]]
    public let elementErrors: [NameSpace: [DataElementIdentifier: Int64]]

    public var verdict: VerificationVerdict { get }
    public var retainable: [NameSpace: [DataElementIdentifier]] { get }

    public func provenance(_ nameSpace: NameSpace,
                           _ id: DataElementIdentifier) -> ElementProvenance?
    public func retainableElements(requiringValidDigest: Bool = true)
        -> [NameSpace: [DataElementIdentifier: MdocValue]]
}
```

### Property

| Name                 | Type                                              | Description                                         | **M/O** | **Note** |
|----------------------|---------------------------------------------------|-----------------------------------------------------|---------|----------|
| docType              | DocType                                           | 문서 타입                                             |    M    |          |
| issuerSignedElements | [NameSpace: [DataElementIdentifier: MdocValue]]   | `IssuerSigned` 로 온 요소. MSO 다이제스트를 거쳐 발급자 서명이 보증한다 |    M    | 신원·자격 판단에는 이것만 쓴다. [10.1](#101-요소의-출처) 참고 |
| deviceSignedElements | [NameSpace: [DataElementIdentifier: MdocValue]]   | `DeviceSigned` 로 온 요소. mdoc authentication 만 보증한다 |    M    | **발급자가 보증하지 않는다** |
| allElements          | [NameSpace: [DataElementIdentifier: MdocValue]]   | 위 둘을 합친 편의 뷰                                     |    M    | 같은 식별자가 양쪽에 있으면 발급자 쪽 값이 남는다 |
| issuerDataAuth       | IssuerDataAuthResult                              | 발급자 데이터 인증 결과                                   |    M    | [IssuerDataAuthResult](#3-issuerdataauthresult) |
| mdocAuth             | MdocAuthResult                                    | mdoc authentication 결과                             |    M    | [MdocAuthResult](#5-mdocauthresult) |
| digests              | DigestCheckResult                                 | 다이제스트 대조 결과                                     |    O    | [DigestCheckResult](#6-digestcheckresult). MSO 를 얻지 못하면 `nil`, 즉 대조하지 못한 것이다 |
| warnings             | [DocumentWarning]                                 | 응답에 대한 관찰. 오류가 아니다                             |    M    | [DocumentWarning](#9-documentwarning). 네임스페이스, 식별자 순으로 정렬 |
| notReturned          | [NameSpace: [DataElementIdentifier]]              | 요청했으나 오지 않은 요소                                  |    M    | 요청 ∖ 응답으로 계산한다. [10.5](#105-부분-응답과-notreturned) 참고 |
| elementErrors        | [NameSpace: [DataElementIdentifier: Int64]]       | mdoc 이 보낸 요소 단위 `ErrorCode`                       |    M    | 참고 값. 사유는 담기지 않는다 |
| verdict              | VerificationVerdict                               | 검증 결과 요약                                          |    M    | [VerificationVerdict](#7-verificationverdict). 요청 충족 여부는 포함하지 않는다 |
| retainable           | [NameSpace: [DataElementIdentifier]]              | 이 요청에서 `intentToRetain = true` 로 요청한 식별자          |    M    | 식별자만 주고 값은 주지 않는다. [10.4](#104-보관-범위와-intenttoretain) 참고 |

### Method

| Name                                     | Description                                         | **Note** |
|------------------------------------------|-----------------------------------------------------|----------|
| provenance(_:_:)                         | 요소가 누구 서명으로 보증되는지 돌려준다                     | [ElementProvenance](#8-elementprovenance). 발급자 서명 요소에 있으면 `.issuerSigned`, 기기 서명 요소에만 있으면 `.deviceSigned`, 없으면 `nil` |
| retainableElements(requiringValidDigest:) | 리더 앱이 보관해도 되는 값만 돌려준다                        | [10.4](#104-보관-범위와-intenttoretain) 참고 |

### Usage

```swift
let response = try await session.request([ItemsRequestPresets.ageOver(18)], at: Date())
for doc in response.documents {
    guard doc.verdict == .valid else { continue }
    let ns = MdocDocTypes.mDLNameSpace
    let ageOK = doc.issuerSignedElements[ns]?["age_over_18"]?.asBoolean == true
}
```

<br>

## 3. IssuerDataAuthResult

### Description

`발급자 데이터 인증 결과 (ISO/IEC 18013-5 9.1.2). 암호 검증과 신뢰 판정을 합친 값.`

### Declaration

```swift
// Declaration in Swift
public struct IssuerDataAuthResult {
    public let signatureValid: Bool
    public let verificationSkipped: Bool
    public let trust: TrustVerdict
    public let source: TrustSource
    public let docTypeChecked: Bool
    public let docTypeMatches: Bool
    public let validity: ValidityCheck?
}
```

### Property

| Name                | Type          | Description                                            | **M/O** | **Note** |
|---------------------|---------------|--------------------------------------------------------|---------|----------|
| signatureValid      | Bool          | 발급자 공개키로 `issuerAuth` 서명을 검증했는가                 |    M    | 검증을 건너뛰었거나, 서명을 대조하지 못했거나(공개키를 얻지 못함 — `trust` 가 `.unknown`·`.untrusted` — 또는 ES256 이 아닌 알고리즘, P-256 이 아닌 키), 대조했더니 틀렸으면 `false`. 마지막 경우만 `verdict` 가 `.invalid` 이고, 나머지는 최대 `.unverified` 다 |
| verificationSkipped | Bool          | 발급자 서명 검증을 건너뛰었는가                               |    M    | 리더 설정 `skipIssuerAuth` 가 `true` 면 `true`. "확인하지 않았다"와 "확인했더니 틀렸다"를 구분한다 |
| trust               | TrustVerdict  | 발급자 신뢰 판정                                          |    M    | [TrustVerdict](MdocTrust_ko.md#1-trustverdict) |
| source              | TrustSource   | 신뢰 판정의 출처                                          |    M    | [TrustSource](MdocTrust_ko.md#3-trustsource) |
| docTypeChecked      | Bool          | MSO 를 읽어 `docType` 을 비교했는가                         |    M    | `false` 면 `docTypeMatches` 는 의미 없는 값이다 |
| docTypeMatches      | Bool          | MSO 의 `docType` 이 문서의 `docType` 과 같은가               |    M    | `docTypeChecked` 가 `false` 면 항상 `false` |
| validity            | ValidityCheck | MSO 유효기간 정보와 그 판정                                  |    O    | [ValidityCheck](#4-validitycheck). MSO 를 얻지 못하면 `nil` |

MSO 를 얻지 못하면(`issuerAuth` 에 payload 가 없거나 `MobileSecurityObjectBytes` 를 파싱하지 못한 경우) `validity` 와 `digests` 는 `nil` 이고 `signatureValid` 와 `docTypeChecked` 는 `false` 다. 두 원인은 구분하지 않는다.

검증을 건너뛰면 발급자 키를 해석하지 않고 조회도 하지 않는다. 이때 `trust` 는 `.unknown`, `source` 는 `.none` 이다. MSO 파싱, `docType` 비교, 유효기간 판정, 다이제스트 대조, mdoc authentication 은 그대로 한다.

<br>

## 4. ValidityCheck

### Description

`MSO 의 ValidityInfo (ISO/IEC 18013-5 9.1.2.4) 와 그 판정.`

판정 기준 시각은 앱이 요청에 넘긴 `at:` 값이며 여기에 다시 담지 않는다. `expectedUpdate` 는 포함하지 않는다.

### Declaration

```swift
// Declaration in Swift
public struct ValidityCheck: Equatable {
    public let signed: Date
    public let validFrom: Date
    public let validUntil: Date
    public let isCurrentlyValid: Bool
}
```

### Property

| Name             | Type | Description                                           | **M/O** | **Note** |
|------------------|------|-------------------------------------------------------|---------|----------|
| signed           | Date | MSO 서명 시각                                           |    M    |          |
| validFrom        | Date | 유효 시작                                               |    M    |          |
| validUntil       | Date | 유효 종료                                               |    M    |          |
| isCurrentlyValid | Bool | `signed <= at && validFrom <= at && at <= validUntil` |    M    | `at` 은 요청에 넘긴 시각. `signed` 가 `at` 보다 늦어도 실패다 |

<br>

## 5. MdocAuthResult

### Description

`mdoc authentication 결과 (ISO/IEC 18013-5 9.1.3).`

### Declaration

```swift
// Declaration in Swift
public struct MdocAuthResult: Equatable {
    public enum Method: Equatable { case ecdsa, mac }
    public let method: Method
    public let valid: Bool
    public let boundToIssuerDeviceKey: Bool
}
```

### Property

| Name                   | Type   | Description                                         | **M/O** | **Note** |
|------------------------|--------|-----------------------------------------------------|---------|----------|
| method                 | Method | mdoc 이 쓴 `DeviceAuth` 방식                          |    M    | `.ecdsa`(deviceSignature) 또는 `.mac`(deviceMac) |
| valid                  | Bool   | mdoc authentication 성공 여부                         |    M    |          |
| boundToIssuerDeviceKey | Bool   | MSO 의 `deviceKey` 로 검증했는가                        |    M    | `false` 면 발급자가 서명한 기기 키와의 바인딩이 끊긴 것이다 |

<br>

## 6. DigestCheckResult

### Description

`IssuerSigned 항목을 MSO valueDigests 와 요소 단위로 대조한 결과.`

받은 `IssuerSignedItem` 은 의미를 알든 모르든 전부 대조한다. 조회는 (네임스페이스, digestID) 쌍으로 한다. 알고리즘은 MSO 의 `digestAlgorithm`(`SHA-256`, `SHA-384`, `SHA-512`)을 따르며, 그 밖의 알고리즘이면 모든 항목이 불일치다. 기기 서명 요소는 다이제스트가 없어 여기에 나오지 않는다.

### Declaration

```swift
// Declaration in Swift
public struct DigestCheckResult: Equatable {
    public let matches: [NameSpace: [DataElementIdentifier: Bool]]
    public var allMatch: Bool { get }
}
```

### Property

| Name     | Type                                        | Description                                  | **M/O** | **Note** |
|----------|---------------------------------------------|----------------------------------------------|---------|----------|
| matches  | [NameSpace: [DataElementIdentifier: Bool]]  | 받은 발급자 서명 요소별 다이제스트 일치 여부          |    M    | `false` 인 요소의 값은 신뢰할 수 없다 |
| allMatch | Bool                                        | 받은 요소가 전부 일치했는가                       |    M    | 대조할 요소가 없으면 `true`. 대조하지 못했으면 `VerifiedDocument.digests` 자체가 `nil` 이다 |

**표시 규칙**: `digests?.matches[ns]?[id] == true` 가 아닌 발급자 서명 요소는 값을 표시하지 않는다. `false`(불일치)와 `nil`(대조 못 함) 모두 발급자가 보증하지 않은 값이다. SDK 는 그런 값을 지우지 않고 판정만 준다.

<br>

## 7. VerificationVerdict

### Description

`문서 검증 결과의 요약.`

### Declaration

```swift
// Declaration in Swift
public enum VerificationVerdict: Equatable {
    case valid
    case invalid
    case unverified
}
```

### Property

| Name       | Type | Description                                      | **M/O** | **Note** |
|------------|------|--------------------------------------------------|---------|----------|
| valid      |      | 모든 검사를 통과했고 발급자를 신뢰한다                  |    -    |          |
| invalid    |      | 검사 중 하나가 실패했다                             |    -    |          |
| unverified |      | 실패한 검사는 없으나 발급자 서명을 대조하지 못했거나 발급자를 신뢰한다고 판정할 수 없다 |    -    |          |

`VerifiedDocument.verdict` 는 다른 필드로부터 다음과 같이 계산된다.

| 조건 | verdict |
|------|---------|
| `issuerDataAuth.verificationSkipped == true` 이고 `docTypeMatches`, `digests?.allMatch == true`, `mdocAuth.valid`, `validity?.isCurrentlyValid == true` 가 모두 성립 | `.unverified` |
| `issuerDataAuth.verificationSkipped == true` 이고 위 중 하나라도 실패 | `.invalid` |
| 건너뛰지 않았고 `signatureValid`, `docTypeMatches`, `digests?.allMatch == true`, `mdocAuth.valid`, `validity?.isCurrentlyValid == true` 가 모두 성립하며 `trust == .trusted` | `.valid` |
| 건너뛰지 않았고 위 검사가 모두 성립하나 `trust` 가 `.trusted` 가 아님 | `.unverified` |
| 건너뛰지 않았고 발급자 서명을 대조하지 못했으며(공개키 없음, ES256 이 아닌 알고리즘, P-256 이 아닌 키) `docTypeMatches`, `digests?.allMatch == true`, `mdocAuth.valid`, `validity?.isCurrentlyValid == true` 가 모두 성립 | `.unverified` |
| 건너뛰지 않았고 발급자 서명을 대조했더니 틀렸거나, 그 밖의 검사 중 하나라도 실패 | `.invalid` |

- 발급자 서명 검증을 건너뛰면 `verdict` 는 결코 `.valid` 가 되지 않는다. `deviceKey` 가 응답 안에 오므로 발급자 서명 없이는 그 키가 누구 것인지 말할 수 없고, mdoc authentication 통과도 신원을 보증하지 않는다.
- `signatureValid` 는 요청 중 신뢰 판정기가 발급자 공개키를 돌려줘야 성립한다. [DIDIssuerKeyResolver](MdocTrust_ko.md#2-didissuerkeyresolver) 는 신뢰 앵커 목록에 있고 키 해석에 성공한 발급자에만 키를 돌려준다. 따라서 목록 밖의 발급자나 키를 해석하지 못한 발급자는 `.invalid` 가 아니라 `.unverified` 다 — 서명을 대조하지 못한 것이다. `.invalid` 는 대조했더니 틀린 경우다. 나중에 `resolveTrust(for:using:at:)` 가 키를 얻으면 서명을 다시 대조한다([MdocReaderAPI](MdocReaderAPI_ko.md#41-resolvetrust)).
- `verdict` 는 요청 충족 여부를 포함하지 않는다. [10.5](#105-부분-응답과-notreturned) 참고.

<br>

## 8. ElementProvenance

### Description

`요소 값이 누구 서명으로 보증되는가.`

### Declaration

```swift
// Declaration in Swift
public enum ElementProvenance: Equatable {
    case issuerSigned
    case deviceSigned
}
```

### Property

| Name         | Type | Description                                      | **M/O** | **Note** |
|--------------|------|--------------------------------------------------|---------|----------|
| issuerSigned |      | 발급자 서명과 MSO 다이제스트로 보증된다                 |    -    |          |
| deviceSigned |      | mdoc authentication 으로만 보증된다. 발급자가 보증하지 않는다 |    -    |          |

<br>

## 9. DocumentWarning

### Description

`응답에 대한 관찰. 오류가 아닌 경고다. unrequestedElement 는 비적합 판정이 아니고, unauthorizedDeviceSignedElement 는 mdoc 쪽 위반(18013-5 9.1.3.4)을 그 요소만 빼서 알린다.`

### Declaration

```swift
// Declaration in Swift
public enum DocumentWarning: Equatable {
    case unrequestedElement(NameSpace, DataElementIdentifier)
    case unauthorizedDeviceSignedElement(NameSpace, DataElementIdentifier)
}
```

### Property

| Name               | Type                              | Description                                | **M/O** | **Note** |
|--------------------|-----------------------------------|--------------------------------------------|---------|----------|
| unrequestedElement | (NameSpace, DataElementIdentifier) | 요청하지 않았는데 응답에 들어온 요소              |    -    | 표준이 금지하지 않는다. `intentToRetain` 플래그가 없으므로 보관할 수 없으며 `retainable` 과 `retainableElements(requiringValidDigest:)` 에 포함되지 않는다 |
| unauthorizedDeviceSignedElement | (NameSpace, DataElementIdentifier) | MSO `keyAuthorizations` 가 `deviceKey` 에 허가하지 않은 deviceSigned 요소 (ISO/IEC 18013-5 9.1.3.4) |    -    | 값은 `deviceSignedElements` 에서 빠지고, 요청했다면 `notReturned` 에도 든다. 문서의 나머지 판정은 그대로다 |

네임스페이스는 판정하지 않는다. 어떤 네임스페이스가 왔는지는 `issuerSignedElements` 와 `deviceSignedElements` 의 키로 알 수 있다.

<br>

## 10. 검증 결과 해석

## 10.1. 요소의 출처

ISO/IEC 18013-5 7.2 는 mDL 이 돌려주는 Table 5 요소는 `IssuerSignedItems` 로 돌려줘야 하고, 도메스틱 data element 는 `IssuerSignedItems` 와 `DeviceSignedItems` 어느 쪽으로든 돌려줄 수 있다고 정한다. 모든 요소가 발급자 서명으로 보증되는 것은 아니다.

| 출처 | 보증하는 것 | 무엇으로 |
|------|------------|---------|
| `issuerSignedElements` | 발급자가 그 값을 발급했음 | MSO `valueDigests` 와 `IssuerAuth` 서명 |
| `deviceSignedElements` | 그 기기가 그 값을 보냈음 | mdoc authentication(`DeviceAuth`) 뿐 |

`deviceSignedElements` 는 발급자가 보증하지 않으며 다이제스트 대조 대상도 아니다. 신원 판단의 근거로 쓰면 안 된다. 그래서 API 는 둘을 기본으로 합쳐 주지 않는다. `allElements` 는 편의로 제공하지만, 신뢰 판단이 걸린 코드는 `issuerSignedElements` 를 직접 쓰거나 `provenance(_:_:)` 로 확인한다. `deviceSignedElements` 를 표시할 때는 발급자가 보증하지 않은 값임이 드러나야 한다.

```swift
// Use only issuer-signed elements for identity and entitlement decisions
let ns = MdocDocTypes.mDLNameSpace
let ageOK = doc.issuerSignedElements[ns]?["age_over_18"]?.asBoolean == true

// For supplementary display, check the provenance first
if doc.provenance(ns, "domestic_note") == .deviceSigned { showAsUnverifiedNote() }
```

<br>

## 10.2. 네임스페이스 범위

프로토콜은 네임스페이스와 문서 타입을 제한하지 않는다(ISO/IEC 18013-5 8.3.1). 한 문서가 여러 네임스페이스의 요소를 담을 수 있고, 역도메인 형식은 요구가 아니라 권고다. 7.1 의 제한은 어떤 네임스페이스를 쓸 수 있느냐가 아니라 `org.iso.18013.5.1` 네임스페이스 안에 무엇을 넣을 수 있느냐에 걸린다. 도메스틱 네임스페이스는 발급 기관이 정한다(7.2.8).

| 항목 | SDK 동작 |
|------|----------|
| 네임스페이스 | 제한하지 않는다. 모르는 네임스페이스도 똑같이 다루며 경고를 내지 않는다 |
| `MdocDocTypes` | mDL 전용 편의 상수일 뿐이다. 다른 문서 타입은 식별자를 직접 쓴다 |
| 모르는 요소의 값 | 표현할 수 있으면 `MdocValue`, 아니면 `.unsupported`. 조용히 다른 값이 되지 않는다 |
| `org.iso.18013.5.1` 안의 모르는 식별자 | 판정하지 않는다. 값은 보존하고 검증은 정상 수행한다. 경고를 내지 않는다 |

이 SDK 는 mDL 전용이 아니라 mdoc 일반을 대상으로 한다.

<br>

## 10.3. 모르는 요소

ISO/IEC 18013-5 9.3.1 3단계는 돌려받은 **모든** `IssuerSignedItem` 의 다이제스트를 검증하도록 요구한다. 그래서 SDK 는 의미를 알든 모르든 모든 요소를 검증하고, 그 다음에 해석할 수 있는 것만 해석한다.

```text
Step 1, verification:   compare the digest of every IssuerSignedItem, known or not.
Step 2, interpretation: interpret known values; keep the rest as values (MdocValue / .unsupported).
```

모르는 요소를 버리면 1단계가 불완전해지고, 오류로 처리하면 도메스틱 요소를 실은 정상 mDL 을 거부하게 된다. [10.4](#104-보관-범위와-intenttoretain) 의 보관 규칙은 모르는 요소에도 그대로 적용된다.

<br>

## 10.4. 보관 범위와 intentToRetain

ISO/IEC 18013-5 8.3.2.1.2.1 은 mdoc verifier 가 요청에서 `IntentToRetain` 을 `true` 로 둔 data element 를 제외하고는 mdoc 에서 받은 어떤 데이터도(다이제스트·서명·파생 데이터 포함) 보관해서는 안 된다고 정한다. 보관이란 실시간 트랜잭션 수행에 필요한 기간보다 오래 저장하는 것이다.

1. 보관하지 않는 것이 원칙이고 `true` 가 예외다. 요청하지 않은 요소에도 금지가 적용된다.
2. `true` 는 상한이지 의무가 아니다. 앱은 그 값을 버려도 된다.
3. 금지 대상은 값만이 아니다. `DeviceResponse` 원문 바이트, MSO 다이제스트, `IssuerAuth`·`DeviceAuth` 서명, 응답에서 파생한 값(예: `birth_date` 로 계산한 나이), 트랜잭션을 넘겨 유지되는 메모리 캐시가 모두 해당한다.
4. 프로토콜은 이를 강제하지 못하지만, 다른 데이터를 보관하는 리더는 ISO/IEC 18013-5 에 적합하지 않다.

| 항목 | SDK 동작 |
|------|----------|
| 응답 원문 로깅 | 하지 않으며 켜는 옵션도 없다 |
| 내부 버퍼 | 세션과 함께 해제한다 |
| 보관 경로 | `retainableElements(requiringValidDigest:)` 하나뿐이다. `allElements` 를 그대로 저장하면 규칙 위반이다 |
| 파생 값 | 만들지 않는다. `age_over_NN` 은 받은 그대로 주며 `birth_date` 로 계산하지 않는다 |

`retainableElements(requiringValidDigest:)` 는 `intentToRetain = true` 로 요청한 요소만 돌려준다.

| requiringValidDigest | 결과 |
|----------------------|------|
| `true`(기본) | 다이제스트가 일치한 요소만(`digests?.matches[ns]?[id] == true`). 기기 서명 요소는 다이제스트가 없어 빠진다. `digests` 가 `nil` 이면 빈 결과 |
| `false` | 다이제스트가 일치하지 않은 요소와 기기 서명 요소도 포함한다. `retainable` 범위는 그대로 지켜진다 |

```swift
// The reader app stores only this result
let toStore = doc.retainableElements()
try repository.save(docType: doc.docType, elements: toStore)
```

<br>

## 10.5. 부분 응답과 notReturned

요청한 것이 다 오지 않아도 오류가 아니다. 무엇을 내줄지는 mdoc 이 정하며, 표준은 무엇이 빠졌는지 알릴 의무를 두지 않는다.

1. **`elementErrors` 는 참고 값이다.** `errors` 필드는 선택이고, 유일한 `ErrorCode` 값(0, data not returned)은 사유를 담지 않는다. 그래서 `notReturned` 는 응답이 아니라 요청에서 계산한다.

    ```text
    Document level: requested docTypes minus returned docTypes  -> visible through documentErrors / missing documents
    Element level:  notReturned = elements requested for that document minus (issuer-signed ∪ device-signed)
    ```

    `errors` 가 오든 안 오든 `notReturned` 는 같다. 값이 실제로 온 요소는 `errors` 에 함께 실려 있어도 온 것으로 본다. 문서가 통째로 오지 않으면 그 문서의 `VerifiedDocument` 가 없다.

2. **`verdict` 는 충족 판정이 아니다.** `notReturned` 가 비어 있지 않아도 `verdict` 는 `.valid` 일 수 있다. 검증(서명·다이제스트)과 충족(필요한 요소가 왔는가)은 다른 축이며, 충족 판정은 리더 앱이 한다.

    ```swift
    let ns = MdocDocTypes.mDLNameSpace
    guard doc.verdict == .valid else { return .reject }          // verification, decided by the SDK
    guard doc.issuerSignedElements[ns]?["age_over_18"]?.asBoolean == true else {
        return .insufficient                                     // satisfaction, decided by the app
    }
    // A portrait left in doc.notReturned does not matter for this use case
    ```

3. **문서가 하나도 없어도 `status` 는 0 일 수 있다.** mdoc 이 요청한 문서 타입을 갖고 있지 않으면 `status` 0 과 `documentErrors` 만으로 응답할 수 있다. 세션은 정상 완료된 것이다. mdoc 이 대신 status 20 으로 세션을 끝낼 수도 있으며, 그때는 `MdocProximityError.terminatedByPeer(status: 20)` 으로 온다. 표준은 두 경로를 모두 허용하므로 리더 앱은 양쪽을 다 다뤄야 한다.

    ```swift
    let response = try await session.request([ItemsRequestPresets.ageOver(18)], at: Date())
    if response.documents.isEmpty {
        // status 0 + documentErrors: not held, or not released by the holder. No reason is given
        showNoDocument(Array(response.documentErrors.keys))
    }
    ```

    status 10(general error)도 사유를 주지 않는다. `documents` 가 비었다는 사실만으로 원인을 단정하지 않는다.

<br>

# Capability

SDK 는 권한을 요청하지 않는다. 상태만 알려 주며, 권한 요청 시점은 앱이 정한다.

## 1. MdocCapabilities

### Description

`역할별·전송 기술별 기기 능력.`

### Declaration

```swift
// Declaration in Swift
public struct MdocCapabilities: Equatable {
    public let mdoc: RoleCapabilities
    public let mdocReader: RoleCapabilities

    public static func current() -> MdocCapabilities
}
```

### Property

| Name       | Type             | Description                       | **M/O** | **Note** |
|------------|------------------|-----------------------------------|---------|----------|
| mdoc       | RoleCapabilities | mdoc(홀더) 역할의 능력               |    M    | [RoleCapabilities](#2-rolecapabilities) |
| mdocReader | RoleCapabilities | mdoc reader 역할의 능력             |    M    | [RoleCapabilities](#2-rolecapabilities) |

### Method

| Name      | Description                                    | **Note** |
|-----------|------------------------------------------------|----------|
| current() | 현재 능력을 런타임에 조회한다                        | 동기 호출. 권한을 요청하지 않는다. [4.3](#43-bluetooth-조회의-한계) 참고 |

### Usage

```swift
let caps = MdocCapabilities.current()
if case .configurationRequired(let action) = caps.mdocReader.ble {
    guideUser(action)
}
```

<br>

## 2. RoleCapabilities

### Description

`한 역할에서 전송 기술별 능력.`

### Declaration

```swift
// Declaration in Swift
public struct RoleCapabilities: Equatable {
    public let ble: TransportCapability
    public let nfc: TransportCapability
    public let wifiAware: TransportCapability
}
```

### Property

| Name      | Type                | Description         | **M/O** | **Note** |
|-----------|---------------------|---------------------|---------|----------|
| ble       | TransportCapability | BLE                 |    M    | [TransportCapability](#3-transportcapability). 두 역할이 같은 라디오·권한을 쓴다 |
| nfc       | TransportCapability | NFC                 |    M    | 두 역할이 서로 다른 값을 낸다. [4.2](#42-ios-의-nfc) 참고 |
| wifiAware | TransportCapability | Wi-Fi Aware         |    M    | iOS 에서는 항상 `.unsupported(reason: .vendorPolicy)` |

<br>

## 3. TransportCapability

### Description

`전송 기술 하나의 능력. 사실만 알려 주며 판단은 앱이 한다.`

### Declaration

```swift
// Declaration in Swift
public enum TransportCapability: Equatable {
    case supported
    case unsupported(reason: CapabilityReason)
    case configurationRequired(action: RequiredAction)
}
```

### Property

| Name                  | Type             | Description                                  | **M/O** | **Note** |
|-----------------------|------------------|----------------------------------------------|---------|----------|
| supported             |                  | 쓸 수 있다                                     |    -    |          |
| unsupported           | CapabilityReason | 쓸 수 없고 앱이 고칠 수 없다                       |    -    | [CapabilityReason](MdocProximityError.md#capabilityreason) |
| configurationRequired | RequiredAction   | 지금은 쓸 수 없으나 앱이나 사용자가 고칠 수 있다          |    -    | [RequiredAction](MdocProximityError.md#requiredaction) |

`CapabilityReason` 과 `RequiredAction` 은 `MdocProximityError.bleUnavailable` / `nfcUnavailable` / `wifiAwareUnavailable` 과 `configurationRequired` 가 싣는 값과 같다.

<br>

## 4. Capability 해석

## 4.1. unsupported 와 configurationRequired

기준은 하나, 앱이 고칠 수 있는가다. `unsupported` 는 앱이 고칠 수 없고 `configurationRequired` 는 고칠 수 있다.

| 값 | iOS 사례 | 앱이 할 일 |
|----|---------|-----------|
| `unsupported(.noHardware)` | NFC 리더 라디오가 없는 기기(예: iPad), 또는 Bluetooth 미지원 | 대안 전송 안내 |
| `unsupported(.vendorPolicy)` | mdoc NFC(카드 에뮬레이션), 두 역할의 Wi-Fi Aware | 대안(QR + BLE) 안내 |
| `configurationRequired(.enableBluetooth)` | 사용자가 Bluetooth 를 껐다 | 설정 유도 |
| `configurationRequired(.grantPermission("bluetooth"))` | Bluetooth 권한 거부·제한 | 권한 허용 유도 |
| `configurationRequired(.addEntitlement(...))` | 필요한 `select-identifiers` 등록이 없는 mdoc reader NFC | 개발자에게 통합 설정 안내 |

`.vendorPolicy` 와 `.osVersion` 을 혼동하지 않는다. 앞은 OS 버전이 올라가도 달라지지 않는 정책·API 표면의 문제이고, 뒤는 기기나 OS 가 바뀌면 달라지는 것이다. `.vendorPolicy` 는 "영구 불가"를 뜻하지 않으며 현재의 사실만 말한다.

<br>

## 4.2. iOS 의 NFC

`mdoc.nfc` 와 `mdocReader.nfc` 는 서로 다른 값을 내며, 하나로 묶어 판단하면 안 된다.

```swift
let caps = MdocCapabilities.current()

caps.mdoc.nfc        // Always .unsupported(reason: .vendorPolicy)
                     // Even when an authorized app injects card emulation into an mdoc session,
                     // this static query does not know about it and the value does not change.

caps.mdocReader.nfc  // No NFC reader radio                       -> .unsupported(reason: .noHardware)
                     // select-identifiers registered correctly   -> .supported
                     // Missing, or in the wrong order            -> .configurationRequired(action:
                     //     .addEntitlement("com.apple.developer.nfc.readersession.iso7816.select-identifiers"))
```

리더 NFC 판정은 앱 `Info.plist` 의 `com.apple.developer.nfc.readersession.iso7816.select-identifiers` 를 읽는다. 목록은 `D2760000850101`(NDEF Tag Application)로 시작해야 하고 `A0000002480400`(mdoc data retrieval)을 포함해야 한다. 순서가 중요하다. 시스템은 목록 순서대로 SELECT 를 시도하고 처음 성공한 곳에서 멈춘다.

엔타이틀먼트는 SDK 가 아니라 통합 앱이 갖는다. 리더 NFC 를 켜지 않은 앱도 링크·심사·실행이 정상이며 QR + BLE 로 동작한다. `.addEntitlement` 는 차단이 아니라 안내다.

<br>

## 4.3. Bluetooth 조회의 한계

`current()` 는 동기이고 권한을 요청하지 않는다. 그래서 다음 한계가 있다.

- Bluetooth 권한이 **아직 결정되지 않았으면** `.supported` 로 답한다. 판정하려면 Bluetooth 매니저를 만들어야 하는데 그 순간 OS 가 권한 프롬프트를 띄우며, 그 시점은 앱이 정한다(첫 `start()` 또는 `connect()`). 거부·제한은 매니저 없이 읽히므로 바로 `.configurationRequired(action: .grantPermission("bluetooth"))` 로 답한다.
- Bluetooth **전원 상태는 비동기로 온다**. 권한이 허용된 뒤 처음 부른 조회는 상태를 아직 모를 수 있어 `.supported` 로 답하고, 그 뒤 조회부터 꺼짐을 `.configurationRequired(action: .enableBluetooth)` 로 반영한다. 모르는 상태를 "쓸 수 없음"으로 바꾸지 않는다. 조회가 상태를 몰랐다면 같은 값이 나중에 세션 에러로 온다. 어느 경우든 앱이 보는 값은 같다.
- iOS 의 "Bluetooth 켜기" 시스템 알림은 SDK 가 띄우지 않는다. 꺼짐은 위 값으로만 알리며, 사용자를 안내할지와 그 방식은 앱이 정한다. Bluetooth 를 처음 쓸 때 OS 가 띄우는 권한 프롬프트는 이와 별개이며 SDK 가 막을 수 없다.
