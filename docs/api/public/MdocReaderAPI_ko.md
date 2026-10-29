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

iOS MdocReader API
==

- Subject: MdocReaderAPI
- Writer: 박주현
- Date: 2026-10-12
- Version: v1.0.0

| Version | Date       | History   |
| -------- | ---------- | --------- |
| v1.0.0   | 2026-10-12 | 최초 작성 |

<div style="page-break-after: always;"></div>

# 목차
- [APIs](#api-목록)
    - [1. MdocReaderSession](#1-mdocreadersession)
        - [1.1. init](#11-init)
        - [1.2. delegate](#12-delegate)
        - [1.3. state](#13-state)
        - [1.4. configuration](#14-configuration)
    - [2. Engagement](#2-engagement)
        - [2.1. connect](#21-connect)
        - [2.2. connectViaNFC](#22-connectvianfc)
    - [3. Request](#3-request)
        - [3.1. request](#31-request)
        - [3.2. terminate](#32-terminate)
    - [4. Trust Resolution](#4-trust-resolution)
        - [4.1. resolveTrust](#41-resolvetrust)
    - [5. Request Construction](#5-request-construction)
        - [5.1. ItemsRequestSpec.init](#51-itemsrequestspecinit)
        - [5.2. jsonData](#52-jsondata)
        - [5.3. from](#53-from)
        - [5.4. ItemsRequestPresets.ageOver](#54-itemsrequestpresetsageover)
        - [5.5. ItemsRequestPresets.identity](#55-itemsrequestpresetsidentity)
        - [5.6. ItemsRequestPresets.drivingPrivileges](#56-itemsrequestpresetsdrivingprivileges)
    - [6. Callback](#6-callback)
        - [6.1. didChangeState](#61-didchangestate)
        - [6.2. readerSessionDidConnect](#62-readersessiondidconnect)
        - [6.3. didProgress](#63-didprogress)
        - [6.4. didFailWith](#64-didfailwith)
    - [7. Capability](#7-capability)
        - [7.1. MdocCapabilities.current](#71-mdoccapabilitiescurrent)

- [Enumerators](#enumerators)
    - [1. MdocReaderState](#1-mdocreaderstate)
    - [2. TransmissionKind](#2-transmissionkind)
    - [3. BleModePreference](#3-blemodepreference)

- [Value Object](#value-object)
    - [1. MdocReaderConfiguration](#1-mdocreaderconfiguration)
    - [2. ItemsRequestSpec](#2-itemsrequestspec)
        - [2.1. Request Profile Format](#21-request-profile-format)
    - [3. MdocDocTypes](#3-mdocdoctypes)

- [Usage](#usage)
    - [1. Verification Flow](#1-verification-flow)
    - [2. NFC Tap and BLE Handover](#2-nfc-tap-and-ble-handover)
    - [3. Integration Settings](#3-integration-settings)
    - [4. Usage Rules](#4-usage-rules)


# API 목록

리더 측 진입점은 `MdocReaderSession` 이다. 요청 생성부터 응답 검증까지 전부 SDK 안에서
수행되며, 앱이 넣는 것은 engagement(QR 또는 NFC 탭), 요청, 유효기간 판정에 쓸 시각, 신뢰
평가기뿐이다.

Swift Package Manager 로 `MdocReader` 제품을 추가해 `import MdocReader` 하거나,
XCFramework 를 포함해 `import MdocProximitySDK` 한다. 공통 타입과 신뢰 타입도 같은
import 로 쓸 수 있다.

다른 문서에 정의된 타입:

- 공통 타입·검증 결과 타입 (`EngagementPayload`, `VerifiedResponse`, `VerifiedDocument`, `MdocCapabilities` 등): [DataModel.md](DataModel_ko.md)
- 신뢰 설정 (`TrustEvaluatorProtocol`, `DIDIssuerKeyResolver`, 신뢰 앵커): [MdocTrust.md](MdocTrust_ko.md)
- 오류 (`MdocProximityError`): [MdocProximityError.md](MdocProximityError.md)

## 1. MdocReaderSession

## 1.1. init

### Description
`리더 세션을 생성한다.`

세션 1개는 트랜잭션 1개다. 종료된 세션은 다시 쓸 수 없고, 재시도는 새 세션으로 한다.
세션을 생성하는 것만으로는 아무것도 점유하지 않는다 — 프로세스당 하나뿐인 활성 세션 자리는
`connect(to:)` / `connectViaNFC()` 가 잡는다.

전송 방식은 앱이 고르거나 주입하지 않는다. 연결 시점에 설정, mdoc 이 광고한 것, 이 기기가
쓸 수 있는 것으로 SDK 가 고른다 ([connect](#21-connect) 참고).

### Declaration

```swift
public convenience init(configuration: MdocReaderConfiguration = MdocReaderConfiguration(),
                        trust: TrustEvaluatorProtocol)
```

### Parameters

| Name          | Type                    | Description                          | **M/O** | **Note** |
|---------------|-------------------------|--------------------------------------|---------|----------|
| configuration | MdocReaderConfiguration | 세션 설정                            | O       | [MdocReaderConfiguration](#1-mdocreaderconfiguration). 기본값 `MdocReaderConfiguration()` |
| trust         | TrustEvaluatorProtocol  | 발급자 공개키를 해석하고 신뢰를 판정 | M       | [MdocTrust.md](MdocTrust_ko.md). `skipIssuerAuth` 가 `true` 면 호출되지 않는다 |

### Returns

| Type              | Description             | **M/O** | **Note** |
|-------------------|-------------------------|---------|----------|
| MdocReaderSession | `idle` 상태의 세션      | M       |          |

### Usage

```swift
let trust = DIDIssuerKeyResolver(trustedIssuers: trustedIssuerDIDs) { did, versionId in
    try await issuerKeyStore.publicKey(did: did, versionId: versionId)
}
var config = MdocReaderConfiguration()
config.skipIssuerAuth = false

let session = MdocReaderSession(configuration: config, trust: trust)
```

<br>

## 1.2. delegate

### Description
`상태 변화·연결·진행률·유휴 중 링크 실패를 받는다.`

약한 참조로 보관한다. 모든 콜백은 `configuration.callbackQueue`(기본 메인)에서 호출된다.
상태 변화를 놓치지 않도록 `connect(to:)` / `connectViaNFC()` 를 부르기 전에 설정한다.

### Declaration

```swift
public weak var delegate: MdocReaderSessionDelegate?
```

### Parameters

N/A

### Returns

| Type                       | Description       | **M/O** | **Note** |
|----------------------------|-------------------|---------|----------|
| MdocReaderSessionDelegate? | 현재 델리게이트   | O       | [6. Callback](#6-callback) |

### Usage

```swift
session.delegate = self
```

<br>

## 1.3. state

### Description
`현재 세션 상태.`

| 현재 상태 | 허용 호출 | 그 외 호출 시 |
| --- | --- | --- |
| `idle` | `connect(to:)`, `connectViaNFC()` | `invalidState` |
| `connecting` | `terminate()` | `invalidState` |
| `connected` | `request(_:at:)`, `terminate()` | `invalidState` |
| `awaitingResponse` | `terminate()` | `invalidState` |
| `verifying` | `terminate()` | `invalidState` |
| `completed` / `terminated` / `failed` | `terminate()` (상태는 바뀌지 않는다) | `invalidState` |

전이 규칙:

- `connecting` → `connected`: 링크가 서고 세션 키가 만들어지면.
- `connecting` → `failed`: `connectTimeout` 안에 링크가 준비되지 않거나 그 밖의 연결 오류가
  나면. 취소(사용자가 NFC 시트를 닫음, 호출한 `Task` 의 취소, `terminate()` 호출)는 대신
  `terminated` 로 끝난다.
- `connected` → `awaitingResponse`: `request(_:at:)` 가 요청을 보내면.
- `awaitingResponse` → `verifying`: 응답이 도착하면. 검증 전에 세션 종료 메시지(status 20)를
  보내고 링크를 닫는다.
- `awaitingResponse` → `failed`: `responseTimeout` 이 지나거나 mdoc 이 세션을 끝내면(상태 코드
  10·11·20 만 보냄). 뒤의 경우 SDK 가 링크를 내린다.
- `verifying` → `completed`: 검증이 끝나면. 검증에 실패한 문서가 있어도 세션은 실패하지
  않는다 — 결과는 반환되는 [VerifiedResponse](DataModel_ko.md#1-verifiedresponse) 안에 담긴다.
- `connected` → `failed`: 연결 뒤 요청 전, 세션이 대기하는 동안 링크가 끊기면. 이 경우는
  `readerSession(_:didFailWith:)` 로 알린다.
- 비종단 상태 → `terminated`: `terminate()` 호출 시. `terminate()` 뒤에는 링크 오류나 끝나는
  검증이 상태를 바꾸지 않는다.

### Declaration

```swift
public private(set) var state: MdocReaderState
```

### Parameters

N/A

### Returns

| Type            | Description   | **M/O** | **Note** |
|-----------------|---------------|---------|----------|
| MdocReaderState | 현재 상태     | M       | [MdocReaderState](#1-mdocreaderstate) |

### Usage

```swift
if session.state == .connected {
    // the request can be sent
}
```

<br>

## 1.4. configuration

### Description
`생성 때 넘긴 설정.`

`MdocReaderConfiguration` 은 값 타입이다. 세션을 만든 뒤 복사본을 바꿔도 세션에는 영향이 없다.

### Declaration

```swift
public let configuration: MdocReaderConfiguration
```

### Parameters

N/A

### Returns

| Type                    | Description        | **M/O** | **Note** |
|-------------------------|--------------------|---------|----------|
| MdocReaderConfiguration | 이 세션의 설정     | M       | [MdocReaderConfiguration](#1-mdocreaderconfiguration) |

### Usage

```swift
let timeout = session.configuration.responseTimeout
```

<br>

## 2. Engagement

## 2.1. connect

### Description
`QR 코드로 얻은 engagement 의 mdoc 에 연결한다.`

전송 방식은 세 집합의 교집합에서 `transmissionPriority` 순서로 고른다.

```text
candidates = configuration.transmissionPriority   (app policy: order and allow-list)
           ∩ what the mdoc advertised in the engagement
           ∩ what this device can use now          (radio, permission, entitlement)
```

- BLE 로 정해지면 GATT 모드는 mdoc 이 광고한 모드 중에서 `blePreferredMode` 를 따른다.
  서비스 UUID 없이 광고된 모드는 건너뛴다.
- L2CAP 은 `l2capUpgrade` 가 `true` 일 때만 쓴다. 채널을 세우지 못하면 같은 모드의 GATT 로
  계속한다.
- QR engagement 에서 NFC 가 선택되면 여기서 시스템 NFC 시트가 뜨고 사용자가 mdoc 을 탭한다.

리더의 임시키(`EReaderKey`)는 트랜잭션마다 SDK 가 만들고 개인키는 세션 밖으로 나가지 않는다.
키 합의를 위해 앱이 넣을 것은 없다.

성공하면 상태가 `connected` 가 되고 `readerSessionDidConnect(_:)` 가 호출된다. throw 하면
상태는 `failed`(취소면 `terminated`)가 되고 프로세스 자리는 풀린다. `invalidState` 오류는
세션을 건드리지 않는다.

### Declaration

```swift
public func connect(to engagement: EngagementPayload) async throws
```

### Parameters

| Name       | Type              | Description                      | **M/O** | **Note** |
|------------|-------------------|----------------------------------|---------|----------|
| engagement | EngagementPayload | mdoc 에서 스캔한 engagement      | M       | [EngagementPayload](DataModel_ko.md#1-engagementpayload). `EngagementPayload.parse(qrString:)` 로 얻는다 |

### Returns

Void

### Throws

- `invalidState(current:attempted:)`: 상태가 `idle` 이 아니거나, 이 프로세스에 다른 세션이 활성 상태다
- `configurationRequired(action:)` / `bleUnavailable(reason:)` / `nfcUnavailable(reason:)`: 설정이 허용하고 mdoc 이 광고한 전송을 이 기기가 쓸 수 없어 후보가 비었다 — [MdocCapabilities.current](#71-mdoccapabilitiescurrent) 가 보고하는 값과 같다
- `unsupportedTransmissionTechnology`: 그 밖의 이유로 후보가 비었다 (설정과 광고가 겹치지 않거나, 광고된 BLE 모드에 서비스 UUID 가 없다)
- `connectionFailed(detail:)`: 링크를 세우지 못했거나 `connectTimeout` 안에 준비되지 않았다
- `CancellationError`: 호출한 `Task` 가 취소되었거나 사용자가 NFC 시트를 닫았다. 상태는 `terminated` 가 된다

[MdocProximityError.md](MdocProximityError.md) 참고.

### Usage

```swift
let engagement = try EngagementPayload.parse(qrString: scannedString)
try await session.connect(to: engagement)
```

<br>

## 2.2. connectViaNFC

### Description
`NFC 탭으로 engagement 를 읽고 같은 호출 안에서 연결까지 한다.`

읽기와 연결이 한 호출인 이유는 링크 연속성이다. 전송 선택이 NFC 를 고르면 engagement 를 읽은
ISO-DEP 링크를 데이터 검색에 그대로 이어 쓴다. 읽기를 별도 호출로 떼면 그 사이에 NFC 세션이
닫힌다.

SDK 가 시스템 NFC 시트를 띄우고 탭을 기다린다. mdoc 이 아닌 태그는 오류가 아니다 — 무시하고
시트는 다음 탭을 계속 기다린다. static / negotiated handover 중 어느 쪽을 쓸지는 태그가 정한다.

- Static handover: 태그에서 engagement 를 읽는다. `technology` 는 `.nfcStaticHandover` 다.
- Negotiated handover: 리더가 지원하는 캐리어를 `transmissionPriority` 순서로 담은 Handover
  Request 를 써 넣고(BLE — 역할은 `blePreferredMode` 를 따른다 — 와 NFC), mdoc 이 하나를
  고른다. `technology` 는 `.nfcNegotiatedHandover` 다.

engagement 를 읽은 뒤의 전송 선택은 [connect](#21-connect) 와 똑같다. NFC 가 선택되면 탭한
링크를 유지하고, 아니면 링크를 놓고 선택된 전송(예: BLE)으로 이어 간다.

사용자가 NFC 시트를 닫는 것은 오류가 아니다. 호출은 `CancellationError` 를 던지고 상태는
`terminate()` 와 같은 `terminated` 가 된다. 앱은 오류 안내 없이 이전 화면으로 돌아가면 된다.

NFC 시트에는 iOS 가 정한 약 60초 제한이 있고 SDK 는 바꿀 수 없다. NFC 교환은 짧게 끝나야
한다 — 제한을 넘기면(예: 소지자 동의 대기) 세션은 `connectionFailed(detail:)` 로 끝난다.

### Declaration

```swift
@discardableResult
public func connectViaNFC() async throws -> EngagementPayload
```

### Parameters

N/A

### Returns

| Type              | Description                  | **M/O** | **Note** |
|-------------------|------------------------------|---------|----------|
| EngagementPayload | 태그에서 읽은 engagement     | M       | [EngagementPayload](DataModel_ko.md#1-engagementpayload). `technology` 는 `.nfcStaticHandover` 또는 `.nfcNegotiatedHandover` |

### Throws

- `invalidState(current:attempted:)`: 상태가 `idle` 이 아니거나, 이 프로세스에 다른 세션이 활성 상태다
- `nfcUnavailable(reason:)`: 이 기기는 NFC 태그를 읽을 수 없다 (`.noHardware`)
- `CancellationError`: 사용자가 NFC 시트를 닫았거나, 호출한 `Task` 가 취소되었거나, 탭 전에 `terminate()` 가 호출되었다. 상태는 `terminated` 가 된다
- `connectionFailed(detail:)`: NFC 시트가 다른 이유로 끝났거나(시스템 제한 시간 초과 — Description 참고, 엔타이틀먼트 누락, 시스템 자원 부족), negotiated handover 에서 공통 캐리어를 찾지 못했다
- `peerDisconnected`: 읽는 도중 태그가 멀어졌다
- 전송을 고르고 여는 동안 나는 [connect](#21-connect) 의 오류 전부

[MdocProximityError.md](MdocProximityError.md) 참고.

### Usage

```swift
do {
    let engagement = try await session.connectViaNFC()
    showConnected(engagement.technology)
} catch is CancellationError {
    // the user closed the NFC sheet — not an error
} catch {
    present(error: error)
}
```

<br>

## 3. Request

## 3.1. request

### Description
`요청을 보내고 로컬 검증까지 끝난 응답을 돌려준다.`

**세션당 1회**, `connected` 상태에서만 허용된다. `specs` 의 각 원소가 `DeviceRequest` 의
`DocRequest` 하나가 되므로 문서 여러 건을 한 번에 요청할 수 있다. 같은 `docType` 은 두 번 담을
수 없다 — 응답을 요청에 되짚을 수 없기 때문이다.

요청 포맷 오류(빈 배열, `docType` 중복)는 아무것도 보내기 전에 걸린다. `validationFailed` 를
던지고 상태는 `connected` 그대로이며 1회 기회도 소비되지 않으므로, 앱은 입력을 고쳐 다시
부를 수 있다. `invalidState` 도 같다.

요청을 보낸 뒤의 흐름:

1. 상태가 `awaitingResponse` 가 되고, `responseTimeout`(사용자 동의·전송 시간 포함)까지
   응답을 기다린다.
2. 응답이 오면 세션 종료 메시지(status 20)를 보내고 링크를 닫는다. 검증에는 링크가 필요 없다.
3. 상태가 `verifying` 이 되고 문서마다 검증한다: 발급자 서명(`skipIssuerAuth` 가 아니면),
   `docType`, 유효기간, 값 다이제스트, 기기 인증. `skipIssuerAuth == false` 면 여기서 문서마다
   신뢰 평가기를 호출한다. 링크를 닫은 뒤이며 이 단계에는 타임아웃이 없다.
4. 상태가 `completed` 가 되고 결과를 돌려준다.

검증에 실패한 문서는 오류가 아니다 — 그 결과는 반환값에 담긴다. 문서가 0건인 응답도 정상
완료다: `documents` 는 빈 배열이고 요청한 `docType` 이 `documentErrors` 에 들어 있다.

요청을 보낸 뒤 던지는 오류는 전부 상태를 `failed` 로 만들고, `readerSession(_:didFailWith:)` 로
다시 오지 않는다. 기다리는 동안 `terminate()` 가 호출되었으면 상태는 `terminated` 로 남는다.

### Declaration

```swift
public func request(_ specs: [ItemsRequestSpec], at now: Date) async throws -> VerifiedResponse
```

### Parameters

| Name  | Type               | Description                            | **M/O** | **Note** |
|-------|--------------------|----------------------------------------|---------|----------|
| specs | [ItemsRequestSpec] | 요청할 문서와 요소                     | M       | [ItemsRequestSpec](#2-itemsrequestspec). 비어 있지 않고 `docType` 중복이 없어야 한다 |
| at    | Date               | `validityInfo` 판정에 쓸 시각          | M       | SDK 는 시계를 읽지 않는다. 이 시각을 믿을 수 있는지는 앱이 판단한다 |

### Returns

| Type             | Description                           | **M/O** | **Note** |
|------------------|---------------------------------------|---------|----------|
| VerifiedResponse | 문서와 문서별 로컬 검증 결과          | M       | [VerifiedResponse](DataModel_ko.md#1-verifiedresponse) |

### Throws

상태 불변:

- `invalidState(current:attempted:)`: 상태가 `connected` 가 아니거나, 이 세션에서 이미 요청했다
- `validationFailed(detail:)`: `specs` 가 비었거나 같은 `docType` 이 두 번 있다

상태가 `failed` 가 됨:

- `responseTimeout`: `responseTimeout` 안에 응답이 오지 않았다
- `terminatedByPeer(status:)`: mdoc 이 응답 대신 세션을 끝냈다. status 20 은 세션 종료다 — 홀더의 거부와 문서 미보유가 모두 이 경로로 오며 둘을 구분할 수 없다. 10·11 은 mdoc 쪽 세션 암호·CBOR 오류다. SDK 가 링크를 내린다
- `peerDisconnected`: 응답을 기다리는 동안 링크가 끊기거나 실패했다
- `sessionEncryptionFailed`, `counterMismatch`: 응답을 복호화하지 못했다
- `decodeFailed(detail:)`, `validationFailed(detail:)`: 응답을 디코딩하지 못했다 (예: 한 네임스페이스에 같은 `elementIdentifier` 가 둘)
- `connectionFailed(detail:)`·`peerDisconnected` 같은 전송 오류: 요청을 보내지 못했다

[MdocProximityError.md](MdocProximityError.md) 참고.

### Usage

```swift
let response = try await session.request([ItemsRequestPresets.ageOver(18)], at: Date())
for document in response.documents {
    render(document)
}
```

<br>

## 3.2. terminate

### Description
`세션을 끝내고 자원을 해제한다.`

- 비종단 상태: 링크가 있으면 세션 종료 메시지(status 20)를 보내고 링크를 닫은 뒤 상태를
  `terminated` 로 바꾼다. `connecting` 에서는 기다리던 `connect(to:)` / `connectViaNFC()` 가
  `CancellationError` 를 던지고, 그 뒤 링크가 서도 `connected` 로 가지 않는다. NFC 탭 전이면
  NFC 시트도 내린다. `awaitingResponse`·`verifying` 에서는 기다리던 `request(_:at:)` 가
  `CancellationError` 를 던지고, 검증 중이던 응답은 버린다.
- 종단 상태(`completed`, `terminated`, `failed`): 링크와 프로세스 자리를 해제하고 상태는 바꾸지
  않는다. `failed` 에서 링크가 살아 있으면(예: `responseTimeout` 뒤) 세션 종료 메시지(status 20)를
  보낸 뒤 링크를 닫는다.

`completed`·`failed` 뒤를 포함해 언제나 호출한다. 프로세스 자리는 `terminate()`(또는 실패한
`connect`)만 푼다. 부르지 않으면 다음 세션의 `connect(to:)` / `connectViaNFC()` 가
`invalidState` 를 던진다. 여러 번 불러도 무해하고 다른 세션에 영향을 주지 않는다.

### Declaration

```swift
public func terminate()
```

### Parameters

N/A

### Returns

Void

### Usage

```swift
override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    session.terminate()
}
```

<br>

## 4. Trust Resolution

## 4.1. resolveTrust

### Description
`발급자 신뢰가 아직 unknown 인 문서에 대해 신뢰 평가기에 다시 묻는다.`

static 함수다. 세션 상태와 무관하며, 세션이 끝났거나 해제된 뒤에도 호출할 수 있다. 문서가
`issuerDataAuth.trust == .unknown` 으로 왔을 때 — 예를 들어 `request(_:at:)` 중에 평가기가
발급자 키에 닿지 못했을 때 — 세션 밖에서 나중에 해석을 다시 시도하는 데 쓴다.

- `issuerDataAuth.trust` 가 `.unknown` 이 아니면 문서를 그대로 돌려주고 평가기를 부르지 않는다.
- 그 밖에는 문서의 `issuerAuth` 헤더에서 읽은 `kid` 와 알고리즘으로 평가기를 호출하고(목적
  `.issuerDataAuthentication`), `issuerDataAuth.trust` 와 `issuerDataAuth.source` 를 바꾼
  사본을 돌려준다.
- 평가기가 돌려준 키로 발급자 서명을 **다시 대조한다**. 그래서 `signatureValid` 와 `verdict` 가
  함께 바뀔 수 있다 — `.unverified` 로 왔던 문서가 `.valid` 나 `.invalid` 가 될 수 있다. 키가
  없거나 SDK 가 지원하지 않는 알고리즘·곡선이면 대조하지 못해 최대 `.unverified` 로 남는다.
  `verificationSkipped`, `validity`, `digests`, `mdocAuth` 는 `request(_:at:)` 가 계산한 값
  그대로다.
- 발급자 검증을 건너뛴 문서(`skipIssuerAuth == true`)는 평가기를 부르지 않고 그대로 돌려준다.
  서명을 보지 않은 문서가 `.trusted` 가 되면 안 된다.

### Declaration

```swift
public static func resolveTrust(for document: VerifiedDocument,
                                using trust: TrustEvaluatorProtocol,
                                at now: Date) async -> VerifiedDocument
```

### Parameters

| Name     | Type                   | Description                        | **M/O** | **Note** |
|----------|------------------------|------------------------------------|---------|----------|
| document | VerifiedDocument       | `request(_:at:)` 가 돌려준 문서    | M       | [VerifiedDocument](DataModel_ko.md#2-verifieddocument) |
| trust    | TrustEvaluatorProtocol | 물어볼 평가기                      | M       | [MdocTrust.md](MdocTrust_ko.md) |
| at       | Date                   | 평가기에 넘길 시각                 | M       |          |

### Returns

| Type             | Description                                          | **M/O** | **Note** |
|------------------|------------------------------------------------------|---------|----------|
| VerifiedDocument | `trust`·`source`·`signatureValid`·`verdict` 를 갱신한 문서, 또는 원래 문서 | M       | [VerifiedDocument](DataModel_ko.md#2-verifieddocument) |

### Usage

```swift
render(document)                                    // draw first
if case .unknown = document.issuerDataAuth.trust {
    let resolved = await MdocReaderSession.resolveTrust(for: document, using: trust, at: Date())
    updateTrustBadge(resolved.issuerDataAuth.trust)
}
```

<br>

## 5. Request Construction

## 5.1. ItemsRequestSpec.init

### Description
`요청할 문서 한 건 — docType 과 네임스페이스별 요청 요소 — 을 만든다.`

`items` 는 네임스페이스 → 요소 식별자 → `intentToRetain` 이다. `intentToRetain` 은 리더가
트랜잭션 뒤에도 보관할 요소에만 `true` 로 둔다 — 홀더에게 그 선언이 보인다. SDK 는 무엇을
요청하는지 판단하지 않는다. 검증 주체가 무엇을 요청해도 되는지는 배포처 정책이다.

### Declaration

```swift
public init(docType: DocType, items: [NameSpace: [DataElementIdentifier: Bool]])
```

### Parameters

| Name    | Type                                       | Description                                   | **M/O** | **Note** |
|---------|--------------------------------------------|-----------------------------------------------|---------|----------|
| docType | DocType                                    | 요청할 문서 유형                              | M       | `String`. 예: [MdocDocTypes.mDL](#3-mdocdoctypes) |
| items   | [NameSpace: [DataElementIdentifier: Bool]] | 네임스페이스 → (요소 식별자 → `intentToRetain`) | M     | `NameSpace`·`DataElementIdentifier` 는 `String` |

### Returns

| Type             | Description      | **M/O** | **Note** |
|------------------|------------------|---------|----------|
| ItemsRequestSpec | 요청 항목        | M       | [ItemsRequestSpec](#2-itemsrequestspec) |

### Usage

```swift
let spec = ItemsRequestSpec(docType: MdocDocTypes.mDL, items: [
    MdocDocTypes.mDLNameSpace: [
        "family_name": false,
        "given_name": false,
        "document_number": true      // the reader keeps this one
    ]
])
```

<br>

## 5.2. jsonData

### Description
`요청 항목을 요청 프로파일로 직렬화한다.`

SDK 는 요청 프로파일을 저장하지 않고 포맷만 정한다. 어디에 둘지(파일·설정·서버 배포), 누가
승인할지는 리더 앱이 정한다. 출력은 키를 정렬한 들여쓰기 없는 JSON 이라, 같은 프로파일은 언제나
같은 바이트가 되어 해시로 비교하거나 서명해 배포할 수 있다.
[Request Profile Format](#21-request-profile-format) 참고.

### Declaration

```swift
func jsonData() throws -> Data
```

### Parameters

N/A

### Returns

| Type | Description                       | **M/O** | **Note** |
|------|-----------------------------------|---------|----------|
| Data | 요청 프로파일의 UTF-8 JSON        | M       | [Request Profile Format](#21-request-profile-format) |

### Usage

```swift
let profile = try ItemsRequestPresets.identity.jsonData()
try profile.write(to: profileURL)
```

<br>

## 5.3. from

### Description
`요청 프로파일에서 요청 항목을 복원한다.`

모르는 최상위 키는 무시한다. 모르는 `version` 이나 포맷과 맞지 않는 구조는 거절한다.

### Declaration

```swift
static func from(jsonData: Data) throws -> ItemsRequestSpec
```

### Parameters

| Name     | Type | Description      | **M/O** | **Note** |
|----------|------|------------------|---------|----------|
| jsonData | Data | 요청 프로파일    | M       | [Request Profile Format](#21-request-profile-format) |

### Returns

| Type             | Description      | **M/O** | **Note** |
|------------------|------------------|---------|----------|
| ItemsRequestSpec | 요청 항목        | M       | [ItemsRequestSpec](#2-itemsrequestspec) |

### Throws

- `decodeFailed(detail:)`: JSON 구조가 맞지 않거나 `version` 이 `1` 이 아니다

### Usage

```swift
let saved = try ItemsRequestSpec.from(jsonData: Data(contentsOf: profileURL))
let response = try await session.request([saved], at: Date())
```

<br>

## 5.4. ItemsRequestPresets.ageOver

### Description
`성인 인증 프리셋: mDL 의 age_over_NN.`

`org.iso.18013.5.1.mDL` 의 `org.iso.18013.5.1` 네임스페이스에서 `age_over_<age>` 를
`intentToRetain = false` 로 요청한다. `portrait` 는 기본으로 요청하지 않는다 — mDL 에서 가장 큰
요소이고 생체 정보이기 때문이다. 얼굴 대조가 필요한 검증 주체는 명시적으로 요청한다.

### Declaration

```swift
public static func ageOver(_ age: Int, includePortrait: Bool = false) -> ItemsRequestSpec
```

### Parameters

| Name            | Type | Description                 | **M/O** | **Note** |
|-----------------|------|-----------------------------|---------|----------|
| age             | Int  | 기준 나이                   | M       | `age_over_<age>` 에 그대로 들어간다. 두 자리 값을 넘긴다 (예: `18`, `21`) |
| includePortrait | Bool | `portrait` 도 요청할지      | O       | 기본값 `false` |

### Returns

| Type             | Description      | **M/O** | **Note** |
|------------------|------------------|---------|----------|
| ItemsRequestSpec | 요청 항목        | M       | [ItemsRequestSpec](#2-itemsrequestspec) |

### Usage

```swift
let response = try await session.request([ItemsRequestPresets.ageOver(18)], at: Date())
let withFace = ItemsRequestPresets.ageOver(19, includePortrait: true)
```

<br>

## 5.5. ItemsRequestPresets.identity

### Description
`신원 확인 프리셋: mDL 의 이름·생년월일·초상.`

`family_name`, `given_name`, `birth_date`, `portrait` 를 모두 `intentToRetain = false` 로
요청한다.

### Declaration

```swift
public static var identity: ItemsRequestSpec { get }
```

### Parameters

N/A

### Returns

| Type             | Description      | **M/O** | **Note** |
|------------------|------------------|---------|----------|
| ItemsRequestSpec | 요청 항목        | M       | [ItemsRequestSpec](#2-itemsrequestspec) |

### Usage

```swift
let response = try await session.request([ItemsRequestPresets.identity], at: Date())
```

<br>

## 5.6. ItemsRequestPresets.drivingPrivileges

### Description
`운전 자격 확인 프리셋: mDL 의 문서번호·만료일·운전 자격.`

`document_number`, `expiry_date`, `driving_privileges` 를 모두 `intentToRetain = false` 로
요청한다.

### Declaration

```swift
public static var drivingPrivileges: ItemsRequestSpec { get }
```

### Parameters

N/A

### Returns

| Type             | Description      | **M/O** | **Note** |
|------------------|------------------|---------|----------|
| ItemsRequestSpec | 요청 항목        | M       | [ItemsRequestSpec](#2-itemsrequestspec) |

### Usage

```swift
let response = try await session.request([ItemsRequestPresets.drivingPrivileges], at: Date())
```

<br>

## 6. Callback

앱은 `MdocReaderSessionDelegate` 를 구현해 [delegate](#12-delegate) 에 설정한다. 모든 메서드는
`configuration.callbackQueue` 에서, 사건이 일어난 순서대로 비동기로 호출된다 — 메인 스레드에서 났어도
그 자리에서 호출하지 않는다. 세션의 메서드와 `terminate()` 는 어느 스레드에서 불러도 된다.

`request(_:at:)` 가 결과를 직접 돌려주므로 응답 전용 콜백은 없다. 오류는 사건 하나당 정확히
한 경로로만 온다.

| 언제 | 어디로 | 예 |
| --- | --- | --- |
| `connect(to:)` · `connectViaNFC()` · `request(_:at:)` **안** | 그 호출의 **throw** | 연결 타임아웃, `terminatedByPeer(status: 20)`, 응답 대기 중 링크 끊김(`peerDisconnected`) |
| **`connected` 로 대기하는 동안** (연결 뒤, 요청 전) | **`readerSession(_:didFailWith:)`** | 홀더가 멀어지거나 앱을 닫음 → `peerDisconnected`, 전송 오류 |

앱은 `catch` 와 `didFailWith` 양쪽을 같은 화면 상태로 보내면 된다. 한 사건이 두 번 오는 일은
없다.

```swift
public protocol MdocReaderSessionDelegate: AnyObject {
    func readerSession(_ s: MdocReaderSession, didChangeState state: MdocReaderState)
    func readerSessionDidConnect(_ s: MdocReaderSession)
    func readerSession(_ s: MdocReaderSession, didProgress received: Int, of total: Int)
    func readerSession(_ s: MdocReaderSession, didFailWith error: MdocProximityError)
}

public extension MdocReaderSessionDelegate {
    func readerSession(_ s: MdocReaderSession, didProgress received: Int, of total: Int) {}
}
```

## 6.1. didChangeState

### Description
`상태가 바뀔 때마다 호출된다.`

### Declaration

```swift
func readerSession(_ s: MdocReaderSession, didChangeState state: MdocReaderState)
```

### Parameters

| Name  | Type              | Description   | **M/O** | **Note** |
|-------|-------------------|---------------|---------|----------|
| s     | MdocReaderSession | 세션          | M       |          |
| state | MdocReaderState   | 새 상태       | M       | [MdocReaderState](#1-mdocreaderstate) |

### Returns

Void

### Usage

```swift
func readerSession(_ s: MdocReaderSession, didChangeState state: MdocReaderState) {
    statusLabel.text = state.rawValue
}
```

<br>

## 6.2. readerSessionDidConnect

### Description
`connect(to:) 또는 connectViaNFC() 가 세션을 수립했을 때 호출된다.`

### Declaration

```swift
func readerSessionDidConnect(_ s: MdocReaderSession)
```

### Parameters

| Name | Type              | Description | **M/O** | **Note** |
|------|-------------------|-------------|---------|----------|
| s    | MdocReaderSession | 세션        | M       |          |

### Returns

Void

### Usage

```swift
func readerSessionDidConnect(_ s: MdocReaderSession) {
    showWaitingForHolder()
}
```

<br>

## 6.3. didProgress

### Description
`응답 수신 진행률을 알린다.`

선택 구현이다 — 빈 기본 구현이 제공된다.

### Declaration

```swift
func readerSession(_ s: MdocReaderSession, didProgress received: Int, of total: Int)
```

### Parameters

| Name     | Type              | Description            | **M/O** | **Note** |
|----------|-------------------|------------------------|---------|----------|
| s        | MdocReaderSession | 세션                   | M       |          |
| received | Int               | 지금까지 받은 바이트   | M       |          |
| total    | Int               | 전체 예상 바이트       | M       |          |

### Returns

Void

### Usage

```swift
func readerSession(_ s: MdocReaderSession, didProgress received: Int, of total: Int) {
    progressView.progress = Float(received) / Float(max(total, 1))
}
```

<br>

## 6.4. didFailWith

### Description
`세션이 connected 로 대기하는 동안 링크가 실패했을 때만 호출된다.`

오류를 받을 호출이 진행 중이지 않은 경우다 — `connect` 가 돌아온 뒤 `request` 를 부르기 전에
홀더가 멀어지거나 앱을 닫은 경우. 상태는 `failed` 가 된다. `connect(to:)`,
`connectViaNFC()`, `request(_:at:)` 안의 실패는 그 호출이 throw 하고 여기로 오지 않는다.

BLE 링크 상실은 시스템이 즉시 알린다. NFC 는 SDK 가 태그 존재를 주기적으로(0.25초마다)
확인하므로 그 주기만큼 늦게 알려질 수 있다.

### Declaration

```swift
func readerSession(_ s: MdocReaderSession, didFailWith error: MdocProximityError)
```

### Parameters

| Name  | Type               | Description | **M/O** | **Note** |
|-------|--------------------|-------------|---------|----------|
| s     | MdocReaderSession  | 세션        | M       |          |
| error | MdocProximityError | 실패 원인   | M       | 대개 `peerDisconnected`. [MdocProximityError.md](MdocProximityError.md) |

### Returns

Void

### Usage

```swift
func readerSession(_ s: MdocReaderSession, didFailWith error: MdocProximityError) {
    showDisconnected()
    s.terminate()
}
```

<br>

## 7. Capability

## 7.1. MdocCapabilities.current

### Description
`이 기기가 리더로서 쓸 수 있는 전송을 권한 요청 없이 알려준다.`

SDK 는 권한을 요청하지 않고 시스템의 "Bluetooth 켜기" 알림도 띄우지 않는다. 현재 상태만
알려주며, 사용자에게 언제 물을지는 앱이 정한다. 흐름을 시작하기 전에 받아 둔다 — 세션 도중에
권한 프롬프트가 뜨면 BLE 연결이 끊길 수 있다. 리더는 `mdocReader` 멤버를 본다.

| 멤버 | 값 | 의미 | 앱이 할 일 |
| --- | --- | --- | --- |
| `ble` | `.supported` | Bluetooth 사용 가능, 또는 아직 모름 | — |
| `ble` | `.configurationRequired(.grantPermission("bluetooth"))` | Bluetooth 권한 거부·제한 | 설정으로 안내 |
| `ble` | `.configurationRequired(.enableBluetooth)` | Bluetooth 꺼짐 | 설정으로 안내 |
| `ble` | `.unsupported(.noHardware)` | Bluetooth LE 없음 | 다른 전송 안내 |
| `nfc` | `.supported` | NFC 읽기 가능, AID 등록 정상 | — |
| `nfc` | `.configurationRequired(.addEntitlement("com.apple.developer.nfc.readersession.iso7816.select-identifiers"))` | `select-identifiers` 등록 누락 또는 순서 틀림 | 통합 설정 수정 ([Integration Settings](#3-integration-settings)) |
| `nfc` | `.unsupported(.noHardware)` | 이 기기는 NFC 태그를 읽을 수 없음 | QR + BLE 사용 |
| `wifiAware` | `.unsupported(.vendorPolicy)` | iOS 에서는 항상 | — |

조회의 한계 — 조회는 동기이고 프롬프트를 띄우지 않는다.

- Bluetooth 권한이 아직 결정되지 않았으면 `ble` 은 `.supported` 다. 시스템 프롬프트는 앱이 첫
  세션을 열 때 뜬다.
- Bluetooth 전원 상태는 비동기로 온다. 권한 허용 뒤 첫 조회는 아직 `.supported` 일 수 있고, 그
  뒤 조회부터 실제 상태를 반영한다. 조회가 아직 몰랐다면 `connect(to:)` 가 같은 값을 던진다.

이 값은 기기가 전송을 막을 때 `connect(to:)` / `connectViaNFC()` 가 던지는 오류
(`configurationRequired(action:)`, `bleUnavailable(reason:)`, `nfcUnavailable(reason:)`)와 같다.
NFC 엔타이틀먼트 누락은 차단이 아니라 안내다 — NFC 리더 기능이 없는 앱도 빌드·심사·실행이
정상이고 QR + BLE 로 동작한다.

### Declaration

```swift
public static func current() -> MdocCapabilities
```

### Parameters

N/A

### Returns

| Type             | Description             | **M/O** | **Note** |
|------------------|-------------------------|---------|----------|
| MdocCapabilities | 두 역할의 능력          | M       | [MdocCapabilities](DataModel_ko.md#1-mdoccapabilities). 리더는 `mdocReader` 를 쓴다 |

### Usage

```swift
let reader = MdocCapabilities.current().mdocReader
switch reader.ble {
case .supported:
    break
case .configurationRequired(let action):
    guideToSettings(action)
case .unsupported:
    hideBleOption()
@unknown default:
    hideBleOption()
}
nfcButton.isHidden = reader.nfc != .supported
```

<br>

# Enumerators
## 1. MdocReaderState

### Description

`리더 세션의 상태.`

### Declaration

```swift
public enum MdocReaderState: String {
    case idle, connecting, connected, awaitingResponse, verifying, completed, terminated, failed
}
```

### Property

| Value            | Description                                             | **Note** |
| ---------------- | ------------------------------------------------------- | -------- |
| idle             | 생성됨, 아직 연결 전                                    |          |
| connecting       | 전송 선택·링크 수립 중 (NFC 시트 포함)                  | `connectTimeout` 후 `failed` |
| connected        | 세션 키 생성 완료, `request(_:at:)` 가능                |          |
| awaitingResponse | 요청을 보냄, 응답 대기 중                               | `responseTimeout` 후 `failed` |
| verifying        | 응답 수신·링크 종료, 문서 검증 중                       |          |
| completed        | 검증 완료, 결과 반환                                    | 종단 |
| terminated       | `terminate()` 또는 취소로 종료                          | 종단 |
| failed           | 오류로 종료                                             | 종단 |
<br>

## 2. TransmissionKind

### Description

`전송 기술의 종류. 리더의 전송 정책에 쓴다.`

종류만 나열한다. BLE 모드는 `blePreferredMode`, L2CAP 은 `l2capUpgrade` 가 정한다.

### Declaration

```swift
public enum TransmissionKind: Equatable {
    case ble
    case nfc
    case wifiAware
}
```

### Property

| Value     | Description            | **Note** |
| --------- | ---------------------- | -------- |
| ble       | Bluetooth Low Energy   |          |
| nfc       | NFC                    |          |
| wifiAware | Wi-Fi Aware            | iOS 에서는 쓸 수 없어 선택되지 않는다 |
<br>

## 3. BleModePreference

### Description

`mdoc 이 두 GATT 모드를 다 광고했을 때 리더가 고를 모드.`

허용 목록이 아니라 선호다. mdoc 이 한 모드만 광고하면 이 값과 무관하게 그 모드를 쓴다. 어느
쪽이든 ISO/IEC 18013-5 에 적합하며, 표준은 `central` 을 권고한다.

### Declaration

```swift
public enum BleModePreference: Equatable {
    case central
    case peripheral
}
```

### Property

| Value      | Description                                                         | **Note** |
| ---------- | ------------------------------------------------------------------- | -------- |
| central    | mdoc central client mode — mdoc 이 central, 리더가 GATT server      |          |
| peripheral | mdoc peripheral server mode — mdoc 이 GATT server, 리더가 central   | 기본값 |
<br>

# Value Object

## 1. MdocReaderConfiguration

### Description

`리더 세션 설정.`

세션은 트랜잭션 하나이므로 진입점마다 다른 설정을 써도 된다 (예: QR 스캔용과 NFC 탭용).

### Declaration

```swift
public struct MdocReaderConfiguration {
    public var transmissionPriority: [TransmissionKind] = [.ble, .nfc, .wifiAware]
    public var blePreferredMode: BleModePreference = .peripheral
    public var skipIssuerAuth: Bool = true
    public var l2capUpgrade: Bool = false
    public var connectTimeout: TimeInterval = 30
    public var responseTimeout: TimeInterval = 120
    public var callbackQueue: DispatchQueue = .main
    public init()
}
```

### Property

| Name                 | Type               | Description | **M/O** | **Note** |
| -------------------- | ------------------ | ----------- | ------- | -------- |
| transmissionPriority | [TransmissionKind] | 전송 종류의 순서**이자** 허용 목록. 뺀 종류는 mdoc 이 광고해도 고르지 않는다 | M | 기본값 `[.ble, .nfc, .wifiAware]`. [TransmissionKind](#2-transmissionkind). engagement 채널과 무관하다 — 탭한 NFC 링크로 데이터까지 받으려면 그 세션에서 `[.nfc, .ble]` 로 둔다 |
| blePreferredMode     | BleModePreference  | mdoc 이 두 GATT 모드를 다 광고했을 때 고를 모드 | M | 기본값 `.peripheral`. [BleModePreference](#3-blemodepreference) |
| skipIssuerAuth       | Bool               | 발급자 서명(`issuerAuth`) 검증을 건너뛸지 | M | 기본값 **`true`** — 아래 참고 |
| l2capUpgrade         | Bool               | 가능하면 BLE L2CAP 채널을 쓸지 | M | 기본값 `false` — GATT 만 쓴다. 아래 참고 |
| connectTimeout       | TimeInterval       | `connecting` 에서 링크가 준비되기까지 허용하는 초 | M | 기본값 `30` |
| responseTimeout      | TimeInterval       | `awaitingResponse` 에서 허용하는 초. 사용자 동의·전송 시간 포함 | M | 기본값 `120` |
| callbackQueue        | DispatchQueue      | 델리게이트 메서드를 호출하는 큐 | M | 기본값 `.main` |

**`skipIssuerAuth`** 의 기본값은 `true` 다 — SDK 는 기본적으로 발급자를 **검증하지 않는다.**
`true` 인 동안에는 발급자 공개키를 해석하지 않고(신뢰 평가기를 부르지 않으므로 조회도 나가지
않는다) 발급자 서명도 확인하지 않는다. MSO 파싱, `docType`, 유효기간, 다이제스트 대조, 기기
인증은 그대로 한다. 이 모드에서 문서의 `verdict` 는 최대 `.unverified` 이며 `.valid` 가 되지
않는다 — 기기 키가 응답 안에 실려 오므로, 발급자 서명 없이는 그 키가 누구 것인지 말할 수 없다.
운영 환경에서는 `false` 로 둔다.

**`l2capUpgrade`**: `true` 면 mdoc peripheral server mode 에서는 리더가 mdoc 의 L2CAP PSM
특성을 읽어 채널을 열고, mdoc central client mode 에서는 자기 PSM 특성을 게시해 mdoc 이 열게
한다. mdoc 이 engagement 에 PSM 을 실어 왔으면 GATT 왕복 없이 바로 채널을 연다 — 이것도 이 값이
`true` 일 때만이다. PSM 이 없거나 채널을 세우지 못하면 같은 모드의 GATT 로 계속한다.
<br>

## 2. ItemsRequestSpec

### Description

`요청할 문서 한 건: docType 과 요청 요소, 요소별 intentToRetain.`

`request(_:at:)` 에 배열로 넘기며 원소마다 `DocRequest` 하나가 된다. 문서 여러 건을 한 번에
요청할 수 있지만 같은 `docType` 을 두 번 담을 수는 없다. 응답에는 같은 `docType` 문서가 여러 건
올 수 있으며(홀더가 둘을 제시할 수 있다), 각각 따로 검증되고 보고된다.

### Declaration

```swift
public struct ItemsRequestSpec: Equatable {
    public let docType: DocType
    public let items: [NameSpace: [DataElementIdentifier: Bool]]

    public init(docType: DocType, items: [NameSpace: [DataElementIdentifier: Bool]])
    func jsonData() throws -> Data
    static func from(jsonData: Data) throws -> ItemsRequestSpec
}
```

### Property

| Name    | Type                                       | Description                                     | **M/O** | **Note** |
| ------- | ------------------------------------------ | ----------------------------------------------- | ------- | -------- |
| docType | DocType                                    | 요청할 문서 유형                                | M       | `String` |
| items   | [NameSpace: [DataElementIdentifier: Bool]] | 네임스페이스 → (요소 식별자 → `intentToRetain`) | M       | `true` 는 리더가 그 요소를 보관한다는 선언이다 |
<br>

## 2.1. Request Profile Format

### Description

`jsonData() 가 만들고 from(jsonData:) 가 읽는 JSON 포맷.`

이 JSON 은 SDK 자체의 저장 포맷이며 ISO/IEC 18013-5 구조가 아니다. mdoc 에 실제로 전송되는
것은 SDK 가 만드는 CBOR `ItemsRequest` 다.

```json
{
  "version": 1,
  "docType": "org.iso.18013.5.1.mDL",
  "items": {
    "org.iso.18013.5.1": {
      "age_over_18": false,
      "portrait": false
    }
  }
}
```

### Property

| Name    | Type                              | Description                       | **M/O** | **Note** |
| ------- | --------------------------------- | --------------------------------- | ------- | -------- |
| version | Int                               | 이 JSON 포맷의 버전               | M       | 항상 `1`. `DeviceRequest.version` 과 무관하다 |
| docType | String                            | `ItemsRequestSpec.docType`        | M       |          |
| items   | Object (String → String → Bool)   | `ItemsRequestSpec.items`          | M       |          |

직렬화 규칙:

- 키는 사전순, 들여쓰기 없음, `/` 는 이스케이프하지 않는다. 같은 프로파일은 언제나 같은
  바이트가 된다.
- 읽을 때 모르는 최상위 키는 무시하고, 모르는 `version` 은 `decodeFailed` 로 거절한다.
<br>

## 3. MdocDocTypes

### Description

`ISO/IEC 18013-5 가 정의한 mDL 의 상수.`

프로토콜은 `docType` 이나 네임스페이스를 제한하지 않는다. 이 값들은 mDL 용 편의 상수다.

### Declaration

```swift
public enum MdocDocTypes {
    public static let mDL          = "org.iso.18013.5.1.mDL"
    public static let mDLNameSpace = "org.iso.18013.5.1"
}
```

### Property

| Name         | Type   | Description          | **M/O** | **Note** |
| ------------ | ------ | -------------------- | ------- | -------- |
| mDL          | String | mDL `docType`        | M       | `org.iso.18013.5.1.mDL` |
| mDLNameSpace | String | mDL 네임스페이스     | M       | `org.iso.18013.5.1` |
<br>

# Usage

## 1. Verification Flow

| 순서 | 부르는 것 | 지킬 것 |
| --- | --- | --- |
| 1 | 신뢰 평가기 생성 (`DIDIssuerKeyResolver(trustedIssuers:resolve:)`) | `trustedIssuers` 가 비어 있으면 모든 발급자를 거부한다. [MdocTrust.md](MdocTrust_ko.md) 참고 |
| 2 | QR: `EngagementPayload.parse(qrString:)` → `connect(to:)` · NFC: `connectViaNFC()` | NFC 는 읽기와 연결이 한 호출이다 (링크 연속성) |
| 3 | `request(_:at:)` | 세션당 1회. `docType` 중복 금지. `at` 은 앱이 믿는 시각이다 — SDK 는 시계를 읽지 않는다 |
| 4 | 결과 해석 | `verdict` 는 SDK 의 검증 결과이고, 응답이 업무 규칙을 충족하는지는 앱이 판단한다. 빠진 요소는 `notReturned` 에 있다. 문서 0건도 정상 완료다 |
| 5 | 저장이 필요하면 `retainableElements()` | `allElements` 를 저장하면 보관 규칙 위반이다 ([DataModel.md](DataModel_ko.md#2-verifieddocument)) |
| 6 | `trust` 가 `.unknown` 이면 `resolveTrust(for:using:at:)` | 세션이 끝난 뒤 호출해도 된다 |
| 7 | `terminate()` | `completed`·`failed` 뒤에도 항상 |

`terminatedByPeer(status: 20)` 은 사유를 싣지 않는다 — 거부, 문서 미보유, 단순 끊김이 모두 이
경로로 온다.

```swift
func verifyAge() async {
    let trust = DIDIssuerKeyResolver(trustedIssuers: trustedIssuerDIDs) { did, versionId in
        try await issuerKeyStore.publicKey(did: did, versionId: versionId)
    }
    var config = MdocReaderConfiguration()
    config.skipIssuerAuth = false

    let session = MdocReaderSession(configuration: config, trust: trust)
    session.delegate = self
    defer { session.terminate() }

    do {
        let engagement = try EngagementPayload.parse(qrString: scannedString)
        try await session.connect(to: engagement)

        let response = try await session.request([ItemsRequestPresets.ageOver(18)], at: Date())
        guard let doc = response.documents.first else { showNoDocument(); return }

        // Use only issuer-signed values whose digest matched
        let ns = MdocDocTypes.mDLNameSpace
        let ageOK = doc.digests?.matches[ns]?["age_over_18"] == true
                 && doc.issuerSignedElements[ns]?["age_over_18"]?.asBoolean == true

        render(ageOK: ageOK, verdict: doc.verdict, trust: doc.issuerDataAuth.trust)

        if case .unknown = doc.issuerDataAuth.trust {
            let resolved = await MdocReaderSession.resolveTrust(for: doc, using: trust, at: Date())
            updateTrustBadge(resolved.issuerDataAuth.trust)
        }
    } catch is CancellationError {
        return
    } catch {
        present(error: error)
    }
}
```

<br>

## 2. NFC Tap and BLE Handover

전송 선택은 두 진입점이 같고, engagement 를 어디서 얻는지만 다르다. 기본
`transmissionPriority`(`[.ble, .nfc, .wifiAware]`)에서는 탭 뒤 mdoc 이 BLE 를 광고하면 BLE 로
넘어가고(큰 응답에 유리), NFC 만 광고하면 탭한 링크로 이어 간다.

```swift
// NFC: reading and connecting are one call, to keep the link
let engagement = try await session.connectViaNFC()
let response = try await session.request([ItemsRequestPresets.identity], at: Date())
```

탭한 NFC 링크로 항상 데이터를 받으려면 **그 세션의** 설정에서 NFC 를 앞에 둔다. QR 스캔용
세션은 기본값을 그대로 써도 된다.

```swift
var nfcConfig = MdocReaderConfiguration()
nfcConfig.transmissionPriority = [.nfc, .ble]
let nfcSession = MdocReaderSession(configuration: nfcConfig, trust: trust)
let engagement = try await nfcSession.connectViaNFC()
```

<br>

## 3. Integration Settings

SDK 는 엔타이틀먼트를 갖지 않는다. 통합하는 앱이 선언한다.

```text
Info.plist
  NSBluetoothAlwaysUsageDescription       (BLE)
  NSCameraUsageDescription                (QR scanning, done by the app)
  NFCReaderUsageDescription               (NFC)
  com.apple.developer.nfc.readersession.iso7816.select-identifiers   (array, order matters)
      [0] D2760000850101   (NFC Forum NDEF Tag Application — engagement)
      [1] A0000002480400   (mdoc data retrieval)
Entitlements
  com.apple.developer.nfc.readersession.formats = [TAG]
```

- AID 를 **둘 다** 등록한다. `D2760000850101` 만 있으면 engagement 는 읽히지만 NFC 데이터
  검색이 실패한다.
- `D2760000850101` 이 **앞**에 와야 한다. 시스템은 AID 를 순서대로 시도하므로 데이터 검색 AID
  가 앞에 오면 engagement 를 건너뛴다.
- `MdocCapabilities.current().mdocReader.nfc` 가 두 규칙을 확인한다.

<br>

## 4. Usage Rules

1. **세션은 1회용이다.** 재시도는 새 세션으로 한다. 세션 키가 engagement 에 묶여 있다.
2. **`terminate()` 를 반드시 호출한다.** 화면을 벗어날 때(`viewWillDisappear`), 그리고
   `completed`·`failed` 뒤에도 부른다. 그러지 않으면 다음 세션이 연결하지 못한다.
3. **권한은 앱이 요청한다.** `MdocCapabilities.current()` 로 확인하고 흐름을 시작하기 전에
   받아 둔다.
4. **판단은 `issuerSignedElements` 로 한다.** `allElements` 는 표시 편의용이고,
   `deviceSignedElements` 는 발급자가 보증하지 않는 값이다.
5. **`retainableElements()` 로만 저장한다.** `allElements` 를 저장하면 `intentToRetain` 이
   `false` 인 값까지 보관하게 되며, ISO/IEC 18013-5 가 허용하지 않는다.
6. **파생 값도 보관 대상이다.** `birth_date` 로 계산한 나이를 저장하는 것은 `birth_date` 를
   저장하는 것과 같다.
7. **로그에 요소 값·다이제스트·서명을 남기지 않는다.** SDK 도 남기지 않으며 응답 원문 로깅
   옵션을 제공하지 않는다.
8. **트랜잭션 뒤에 응답 데이터를 메모리에 들고 있지 않는다.** 트랜잭션에 필요한 기간을 넘는
   캐시도 보관이다.
9. **발급자 검증을 건너뛴 결과는 미검증으로 다룬다.** `skipIssuerAuth == true`(기본값)에서는
   어떤 문서도 `.valid` 가 되지 않는다.

