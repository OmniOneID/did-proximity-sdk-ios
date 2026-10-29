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

iOS MdocTrust API
==

- Subject: MdocTrust
- Writer: 박주현
- Date: 2026-10-12
- Version: v1.0.0

| Version          | Date       | History                 |
| ---------------- | ---------- | ------------------------|
| v1.0.0           | 2026-10-12 | 최초 작성                 |


<div style="page-break-after: always;"></div>


# Table of Contents
- [개요](#개요)
- [APIs](#api-목록)
    - [1. TrustEvaluatorProtocol](#1-trustevaluatorprotocol)
        - [1.1. evaluate](#11-evaluate)
    - [2. DIDIssuerKeyResolver](#2-didissuerkeyresolver)
        - [2.1. init](#21-init)
        - [2.2. evaluate](#22-evaluate)
- [Data Models](#data-models)
    - [1. COSEHeaderSummary](#1-coseheadersummary)
    - [2. IssuerKeyResolution](#2-issuerkeyresolution)
- [Enumerators](#enumerators)
    - [1. TrustVerdict](#1-trustverdict)
    - [2. TrustPurpose](#2-trustpurpose)
    - [3. TrustSource](#3-trustsource)
- [신뢰 규칙](#신뢰-규칙)
    - [1. 신뢰 앵커는 필수다](#1-신뢰-앵커는-필수다)
    - [2. resolve 는 문서가 아니라 공개키를 돌려준다](#2-resolve-는-문서가-아니라-공개키를-돌려준다)
    - [3. 세션이 끝난 뒤의 신뢰 해석](#3-세션이-끝난-뒤의-신뢰-해석)

<br>

# 개요

리더 앱은 받은 문서마다 발급자를 검증한다(발급자 데이터 인증, ISO/IEC 18013-5 9.1.2). 검증키는 응답에 실려 오지 않는다. `issuerAuth` 에는 키를 가리키는 `kid` 만 있다. 신뢰 경로는 DID 기반이다. `kid` 는 DID URL 이고 발급자 공개키는 리더 앱이 공급한다.

| 항목 | 설명 |
|------|------|
| Import | `import MdocReader`(SPM) 또는 `import MdocProximitySDK`(XCFramework) |
| 주입 | `TrustEvaluatorProtocol` 인스턴스를 `MdocReaderSession` 에 넘긴다([MdocReaderAPI](MdocReaderAPI_ko.md) 참고) |
| 기본 구현 | [DIDIssuerKeyResolver](#2-didissuerkeyresolver) |
| 결과 | `VerifiedDocument.issuerDataAuth` 와 `verdict` 에 반영된다([DataModel](DataModel_ko.md#3-issuerdataauthresult) 참고) |

발급자 서명 검증 여부는 리더 설정 `skipIssuerAuth` 가 정한다([MdocReaderAPI](MdocReaderAPI_ko.md) 참고). 건너뛰면 신뢰 판정기를 부르지 않는다.

<br>

# API 목록

## 1. TrustEvaluatorProtocol

### Description

`리더 세션에 주입하는 발급자 신뢰 판정.`

SDK 는 필요한 COSE_Sign1 헤더 값을 [COSEHeaderSummary](#1-coseheadersummary) 로 뽑아 판정기에 넘긴다. 앱은 COSE·CBOR 원본 바이트를 다루지 않는다. 앱은 이 프로토콜을 직접 구현하거나 기본 구현 [DIDIssuerKeyResolver](#2-didissuerkeyresolver) 를 쓴다.

### Declaration

```swift
// Declaration in Swift
public protocol TrustEvaluatorProtocol: AnyObject {
    func evaluate(header: COSEHeaderSummary,
                  purpose: TrustPurpose,
                  at date: Date) async -> IssuerKeyResolution
}
```

<br>

## 1.1. evaluate

### Description

`issuerAuth 헤더에 대해 발급자 공개키와 신뢰 판정을 구한다.`

### Declaration

```swift
func evaluate(header: COSEHeaderSummary,
              purpose: TrustPurpose,
              at date: Date) async -> IssuerKeyResolution
```

### Parameters

| Name    | Type              | Description                                 | **M/O** | **Note** |
|---------|-------------------|---------------------------------------------|---------|----------|
| header  | COSEHeaderSummary | `issuerAuth` 의 헤더 값                       | M       | [COSEHeaderSummary](#1-coseheadersummary) |
| purpose | TrustPurpose      | 판정 목적                                     | M       | [TrustPurpose](#2-trustpurpose). 세션은 `.issuerDataAuthentication` 을 넘긴다 |
| date    | Date              | 판정 기준 시각                                 | M       | 앱이 세션에 넘긴 `at:` 값 |

### Returns

| Type                | Description                                       | **M/O** | **Note** |
|---------------------|---------------------------------------------------|---------|----------|
| IssuerKeyResolution | 발급자 공개키, 신뢰 판정, 판정 출처                       | M       | [IssuerKeyResolution](#2-issuerkeyresolution) |

이 메서드는 throw 하지 않는다. 해석 실패는 반환값으로 표현한다(예: `trust: .unknown`). 발급자 서명은 `publicKey` 가 있을 때만 검증된다. 키가 없으면 서명을 대조하지 못하므로 `signatureValid` 는 `false` 이고 문서의 `verdict` 는 `.invalid` 가 아니라 최대 `.unverified` 다. `.invalid` 는 대조했더니 틀린 경우다.

### Usage

```swift
final class MyTrustEvaluator: TrustEvaluatorProtocol {
    func evaluate(header: COSEHeaderSummary,
                  purpose: TrustPurpose,
                  at date: Date) async -> IssuerKeyResolution {
        guard let kid = header.kid, let key = keyStore.publicKey(forKid: kid) else {
            return .notResolved
        }
        return IssuerKeyResolution(publicKey: key, trust: .trusted, source: .did(method: "omn"))
    }
}
```

<br>

## 2. DIDIssuerKeyResolver

### Description

`TrustEvaluatorProtocol 의 기본 구현. issuerAuth 의 kid(DID URL)를 검증키로 바꾼다.`

신뢰 앵커 목록 `trustedIssuers` 는 필수다. 목록에 없는 DID 는 해석하지 않고 `.untrusted` 로 판정한다. resolver 는 목록을 저장하지 않는다. 주입받은 배열을 메모리에 들고 있을 뿐이며 바꾸는 수단도 없다. 목록을 바꾸려면 resolver 를 새로 만든다. [신뢰 규칙](#신뢰-규칙)을 참고한다.

### Declaration

```swift
// Declaration in Swift
public final class DIDIssuerKeyResolver: TrustEvaluatorProtocol {
    public init(trustedIssuers: [String],
                resolve: @escaping (_ did: String, _ versionId: String?) async throws -> Data)

    public func evaluate(header: COSEHeaderSummary,
                         purpose: TrustPurpose,
                         at date: Date) async -> IssuerKeyResolution
}
```

<br>

## 2.1. init

### Description

`신뢰 앵커 목록과 키 해석 클로저로 resolver 를 만든다.`

### Declaration

```swift
public init(trustedIssuers: [String],
            resolve: @escaping (_ did: String, _ versionId: String?) async throws -> Data)
```

### Parameters

| Name           | Type                                                   | Description                         | **M/O** | **Note** |
|----------------|--------------------------------------------------------|-------------------------------------|---------|----------|
| trustedIssuers | [String]                                               | 신뢰하는 발급자 DID(쿼리·프래그먼트 없는 DID) | M       | 빈 목록은 모든 발급자를 거부한다 |
| resolve        | (_ did: String, _ versionId: String?) async throws -> Data | DID 와 버전에 해당하는 발급자 **공개키**를 돌려준다 | M       | SEC1 uncompressed point(P-256). DID Document 가 아니다. [2. resolve 는 문서가 아니라 공개키를 돌려준다](#2-resolve-는-문서가-아니라-공개키를-돌려준다) 참고 |

`resolve` 는 `trustedIssuers` 에 있는 발급자에 대해서만 불린다. `did` 는 쿼리와 프래그먼트를 뗀 DID 이고, `versionId` 는 `kid` 의 `versionId` 쿼리 값이며 없으면 `nil` 이다.

### Returns

| Type                 | Description            | **M/O** | **Note** |
|----------------------|------------------------|---------|----------|
| DIDIssuerKeyResolver | resolver 인스턴스        | M       |          |

### Usage

```swift
let resolver = DIDIssuerKeyResolver(
    trustedIssuers: verifiedIssuerList.dids,          // DIDs from a list the app has verified
    resolve: { did, versionId in
        // Look up the stored DID Document, select the verification method that matches
        // the kid fragment, and decode it to an uncompressed P-256 point.
        try await didKeyStore.assertionKey(did: did, versionId: versionId)
    })
```

<br>

## 2.2. evaluate

### Description

`issuerAuth 의 kid 를 신뢰 앵커 목록과 대조하고 공개키를 해석한다.`

### Declaration

```swift
public func evaluate(header: COSEHeaderSummary,
                     purpose: TrustPurpose,
                     at date: Date) async -> IssuerKeyResolution
```

### Parameters

| Name    | Type              | Description                       | **M/O** | **Note** |
|---------|-------------------|-----------------------------------|---------|----------|
| header  | COSEHeaderSummary | `issuerAuth` 의 헤더 값             | M       | `kid` 만 쓴다 |
| purpose | TrustPurpose      | 판정 목적                           | M       | 이 구현은 쓰지 않는다 |
| date    | Date              | 판정 기준 시각                       | M       | 이 구현은 쓰지 않는다 |

### Returns

| 조건 | publicKey | trust | source |
|------|-----------|-------|--------|
| `kid` 가 없거나 `did:` 로 시작하지 않음 | `nil` | `.untrusted(reason: "kid is not a DID URL")` | `.none` |
| DID 가 `trustedIssuers` 에 없음(빈 목록 포함) | `nil` | `.untrusted(reason: "issuer not in trustedIssuers")` | `.did(method:)` |
| `resolve` 가 키를 돌려줌 | 그 키 | `.trusted` | `.did(method:)` |
| `resolve` 가 에러를 던짐 | `nil` | `.unknown` | `.did(method:)` |

`method` 는 DID 메서드다. 예를 들어 `did:omn:issuer` 면 `"omn"` 이다. `x5chain` 만 실린 `issuerAuth` 는 DID URL `kid` 가 없으므로 `.untrusted` 로 판정한다. 이는 실패가 아니라 판정이며, 요소 값은 그대로 앱에 전달된다.

판정 순서는 `kid` 파싱, DID 추출, `trustedIssuers` 대조, 그리고 통과했을 때만 `resolve` 호출이다. 신뢰하지 않을 발급자를 위해 외부 요청을 보내지 않는다.

### Usage

```swift
var configuration = MdocReaderConfiguration()
configuration.skipIssuerAuth = false              // the default skips issuer authentication
let session = MdocReaderSession(configuration: configuration, trust: resolver)
```

세션과 설정은 [MdocReaderAPI](MdocReaderAPI_ko.md)를 참고한다.

<br>

# Data Models

## 1. COSEHeaderSummary

### Description

`신뢰 판정에 필요한 issuerAuth COSE_Sign1 헤더 값. SDK 가 만든다.`

### Declaration

```swift
// Declaration in Swift
public struct COSEHeaderSummary: Equatable {
    public let kid: String?
    public let algorithm: Int
    public init(kid: String?, algorithm: Int)
}
```

### Property

| Name      | Type   | Description                                  | **M/O** | **Note** |
|-----------|--------|----------------------------------------------|---------|----------|
| kid       | String | 헤더 label 4(`kid`)를 UTF-8 문자열로 읽은 값       |    O    | protected 헤더를 먼저 보고 없으면 unprotected 헤더를 본다. 이 생태계에서는 DID URL 이다. 예: `did:omn:issuer?versionId=1#assert`. 없으면 `nil` |
| algorithm | Int    | protected 헤더 label 1(`alg`), COSE 알고리즘 식별자 |    M    | ES256 = `-7`. 없으면 `-7` |

생성자는 테스트와 판정기 직접 구현을 위한 것이다. 이 값은 세션이 만들며 앱이 만들 일은 드물다.

<br>

## 2. IssuerKeyResolution

### Description

`신뢰 판정 결과. 발급자 공개키, 신뢰 판정, 판정 출처.`

### Declaration

```swift
// Declaration in Swift
public struct IssuerKeyResolution {
    public let publicKey: Data?
    public let trust: TrustVerdict
    public let source: TrustSource

    public init(publicKey: Data?, trust: TrustVerdict, source: TrustSource)

    public static let notResolved: IssuerKeyResolution
}
```

### Property

| Name        | Type                | Description                                  | **M/O** | **Note** |
|-------------|---------------------|----------------------------------------------|---------|----------|
| publicKey   | Data                | `issuerAuth` 검증에 쓸 발급자 공개키              |    O    | SEC1 uncompressed point(P-256). 해석하지 못했으면 `nil` |
| trust       | TrustVerdict        | 신뢰 판정                                      |    M    | [TrustVerdict](#1-trustverdict) |
| source      | TrustSource         | 판정 출처                                      |    M    | [TrustSource](#3-trustsource) |
| notResolved | IssuerKeyResolution | 해석을 하지 않은 상태: `publicKey: nil`, `trust: .unknown`, `source: .none` |    M    | 발급자 인증을 건너뛸 때 쓰인다. 직접 구현한 판정기도 "아직 모른다"를 이 값으로 돌려줄 수 있다 |

<br>

# Enumerators

## 1. TrustVerdict

### Description

`발급자 신뢰 판정.`

### Declaration

```swift
// Declaration in Swift
public enum TrustVerdict: Equatable {
    case trusted
    case untrusted(reason: String)
    case unknown
}
```

### Property

| Name      | Type   | Description                                    | **M/O** | **Note** |
|-----------|--------|------------------------------------------------|---------|----------|
| trusted   |        | 발급자를 신뢰한다                                 |    -    |          |
| untrusted | String | 발급자를 신뢰하지 않는다. 사유를 함께 준다              |    -    | 실패가 아니라 판정이다. `unknown` 과 다르다 |
| unknown   |        | 아직 해석하지 못했다(조회 필요·실패, 또는 판정 생략)       |    -    |          |

<br>

## 2. TrustPurpose

### Description

`신뢰 판정의 목적.`

### Declaration

```swift
// Declaration in Swift
public enum TrustPurpose {
    case issuerDataAuthentication
    case mdocReaderAuthentication
}
```

### Property

| Name                     | Type | Description                                         | **M/O** | **Note** |
|--------------------------|------|-----------------------------------------------------|---------|----------|
| issuerDataAuthentication |      | 발급자 데이터 인증 (ISO/IEC 18013-5 9.1.2)             |    -    | SDK 가 넘기는 유일한 목적 |
| mdocReaderAuthentication |      | mdoc reader 인증 (ISO/IEC 18013-5 9.1.4)            |    -    | 이 버전의 SDK 는 쓰지 않는다 |

<br>

## 3. TrustSource

### Description

`신뢰 판정의 출처. 신뢰 경로는 DID 기반이며 X.509 출처는 없다.`

### Declaration

```swift
// Declaration in Swift
public enum TrustSource: Equatable {
    case did(method: String)
    case none
}
```

### Property

| Name | Type   | Description                         | **M/O** | **Note** |
|------|--------|-------------------------------------|---------|----------|
| did  | String | DID 로 판정했다. DID 메서드를 함께 준다   |    -    | 예: `"omn"` |
| none |        | 출처 없음                             |    -    | `kid` 가 DID URL 이 아니었거나 판정을 하지 않았다 |

<br>

# 신뢰 규칙

## 1. 신뢰 앵커는 필수다

`DIDIssuerKeyResolver` 는 신뢰 앵커를 요구한다. 아무 DID 나 받아들이면 DID Document 를 게시할 수 있는 누구나 신뢰받는 발급자가 된다.

| 항목 | DIDIssuerKeyResolver |
|------|----------------------|
| 앵커 | `trustedIssuers: [String]`(발급자 DID) |
| 갱신 | resolver 를 새로 만든다. 목록을 바꾸는 API 는 없다 |
| 앵커 하나가 덮는 범위 | 그 DID 하나(위임 없음) |
| 목록 증가 | 발급자 수만큼 |

**판정 규칙**

1. **목록에 없는 발급자는 `.untrusted(reason:)` 다.** `.unknown` 이 아니다. 모르는 것이 아니라 신뢰하지 않기로 한 것이다.
2. **빈 목록은 전부 거부다**(fail-closed). 목록을 채우지 않은 리더 앱이 모든 발급자를 신뢰하는 상태가 되어서는 안 된다.
3. **비교는 DID 본체로 한다.** `kid` 는 `did:omn:issuer?versionId=1#assert` 같은 DID URL 이다. 쿼리(`?versionId=`)와 프래그먼트(`#assert`)를 떼어낸 `did:omn:issuer` 를 `trustedIssuers` 와 대조한다. 그래서 키 회전에도 매칭이 깨지지 않는다.
4. **목록 확인이 조회보다 먼저 온다.** 순서는 `kid` 파싱, DID 추출, 목록 대조, 그 다음에야 `resolve` 호출이다. 신뢰하지 않을 발급자를 위해 외부 요청을 보내지 않는다.

`trustedIssuers` 는 키 목록이 아니라 DID 목록이다. 키 회전은 DID Document 안에서(`versionId`) 처리되므로 발급자가 키를 바꿔도 목록은 그대로다. 위임이 없으므로 발급자가 늘면 목록도 는다.

목록의 포맷·서명·만료·배포는 리더 앱의 책임이다. SDK 경계는 DID 배열 그 자체다. 앱은 서명과 유효기간을 검증한 목록에서 얻은 DID 만 주입해야 하며, SDK 는 이를 강제할 수 없다. 목록을 검증하지 못했거나 만료됐으면 빈 배열을 넘긴다. 그러면 규칙 2 로 모든 발급자가 거부된다.

목록을 바꾸려면 resolver 를 새로 만들어 다음 세션에 주입하거나 `MdocReaderSession.resolveTrust(for:using:at:)` 에 넘긴다. resolver 는 배열과 클로저만 가지므로 다시 만드는 비용이 없다.

<br>

## 2. resolve 는 문서가 아니라 공개키를 돌려준다

`kid` 는 검증키를 가리키는 포인터다.

```text
did:omn:issuer     <- which issuer          compared with trustedIssuers (rule 3)
?versionId=1       <- which version of its DID Document
#assert            <- which key in that version   <- the only key used to verify issuerAuth
```

검증키는 응답에 실려 오지 않으므로 따로 구해야 하고, 구하지 못하면 발급자 서명을 검증할 수 없다. 근접 거래는 오프라인 동작을 전제하므로 리더 앱은 발급자별 최신 DID Document 를 미리 배포해 두어야 한다.

`resolve` 클로저는 `(did, versionId)` 를 **공개키**로 바꾼다. 클로저 안에서 무엇을 하든 SDK 는 관여하지 않는다.

| 앱이 하는 일 | SDK 가 하는 일 |
|-------------|---------------|
| DID Document 를 어디서 얻을지 정한다: 네트워크 조회 또는 보관해 둔 사본 | 없음 |
| `kid` 의 프래그먼트에 맞는 `verificationMethod` 를 고른다 | 없음 |
| `assertionMethod` 용 키인지 확인한다 | 없음 |
| multibase 를 풀어 SEC1 uncompressed point 로 만든다 | 없음 |
| 없음 | 그 키로 `issuerAuth` COSE_Sign1 을 검증한다 |

DID Document 파싱은 SDK 안으로 들어오지 않는다. DID SDK 에 이미 있는 코드를 중복하지 않기 위해서다.

**오프라인 사용**: 문서를 미리 보관해 두면 된다. 클로저가 네트워크를 탈 필요는 없다. 권장 형태는 발급자당 **최신 DID Document 하나만** 보관하는 것이다. 버전을 누적하면 발급자가 유출된 키를 문서에서 빼도 리더가 그 키를 계속 들고 있게 되어, 오프라인에서는 폐기가 반영되지 않는다.

<br>

## 3. 세션이 끝난 뒤의 신뢰 해석

클로저가 네트워크 조회를 하면 세션 타임아웃 안에 끝나지 않을 수 있다. `MdocReaderSession.resolveTrust(for:using:at:)`([MdocReaderAPI](MdocReaderAPI_ko.md#41-resolvetrust) 참고)는 `VerifiedDocument` 의 신뢰를 판정하며 세션이 끝난 뒤에 불러도 된다.

`resolveTrust(for:using:at:)` 의 동작:

- `issuerDataAuth.trust` 가 `.unknown` 이 아니면 문서를 그대로 돌려준다.
- 그렇지 않으면 문서의 `issuerAuth` 에서 읽은 `kid` 와 알고리즘으로 판정기를 부르고, `issuerDataAuth.trust` 와 `issuerDataAuth.source` 를 바꾼 사본을 돌려준다.
- 돌려받은 키로 발급자 서명을 **다시 대조한다**. 그래서 `signatureValid` 와 `verdict` 가 바뀔 수 있다 — 요청 중 키가 없어 `.unverified` 였던 문서가 `.valid` 나 `.invalid` 가 될 수 있다. 키가 없거나 ES256 이 아닌 알고리즘·P-256 이 아닌 키면 최대 `.unverified` 로 남는다.
- 발급자 인증을 건너뛴 문서는 판정기를 부르지 않고 그대로 돌려준다.

따라서 세션 안에서 `.valid` 에 이르려면 `request(_:at:)` 중에 공개키를 얻을 수 있어야 한다. 오프라인 리더는 발급자 DID Document 를 로컬에 두어 세션 안에서 `resolve` 가 성공하도록 한다.

```swift
let response = try await session.request([ItemsRequestPresets.ageOver(18)], at: Date())
for doc in response.documents {
    var current = doc
    if case .unknown = doc.issuerDataAuth.trust {
        current = await MdocReaderSession.resolveTrust(for: doc, using: resolver, at: Date())
    }
    render(current)
}
```
