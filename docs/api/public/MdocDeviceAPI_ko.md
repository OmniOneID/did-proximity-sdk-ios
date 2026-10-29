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

iOS MdocDevice API
==

- Subject: MdocDeviceAPI
- Writer: 박주현
- Date: 2026-10-12
- Version: v1.0.0

| Version | Date       | History   |
| ------- | ---------- | --------- |
| v1.0.0  | 2026-10-12 | 최초 작성 |

<div style="page-break-after: always;"></div>

# 목차
- [APIs](#api-목록)
    - [1. MdocDeviceSession](#1-mdocdevicesession)
        - [1.1. init](#11-init)
        - [1.2. delegate](#12-delegate)
        - [1.3. state](#13-state)
        - [1.4. configuration](#14-configuration)
        - [1.5. start](#15-start)
        - [1.6. respond](#16-respond)
        - [1.7. reject](#17-reject)
        - [1.8. terminate](#18-terminate)
    - [2. MdocDeviceSessionDelegate](#2-mdocdevicesessiondelegate)
        - [2.1. didChangeState](#21-didchangestate)
        - [2.2. didReceiveRequest](#22-didreceiverequest)
        - [2.3. didProgress](#23-didprogress)
        - [2.4. mdocSessionDidFinish](#24-mdocsessiondidfinish)
        - [2.5. didFailWith](#25-didfailwith)
    - [3. NfcCardEmulationProtocol](#3-nfccardemulationprotocol)
        - [3.1. start](#31-start)
        - [3.2. onDeactivated](#32-ondeactivated)
        - [3.3. stop](#33-stop)
    - [4. Capability](#4-capability)
        - [4.1. MdocCapabilities.current](#41-mdoccapabilitiescurrent)

- [Enumerators](#enumerators)
    - [1. MdocDeviceState](#1-mdocdevicestate)
    - [2. BleAdvertiseMode](#2-bleadvertisemode)

- [Value Object](#value-object)
    - [1. MdocDeviceConfiguration](#1-mdocdeviceconfiguration)


# API 목록

이 문서의 API 는 **mdoc 앱**(홀더 앱)이 ISO/IEC 18013-5 에 따라 근접한 리더에게 mdoc 을 제시할 때
쓴다. Swift Package Manager 로는 `MdocDevice` 제품(`import MdocDevice`), XCFramework 로는
`MdocProximitySDK` 모듈(`import MdocProximitySDK`)에서 온다. 어느 쪽을 import 해도
[DataModel](DataModel_ko.md) 의 공통 타입과 에러 타입 [MdocProximityError](MdocProximityError.md) 를
함께 쓸 수 있다.

이 SDK 는 device engagement 와 암호화된 세션을 맡고 **바이트를 실어 나른다.** 문서를 읽거나
보관하지 않고, `DeviceRequest` 를 파싱하지 않으며, 동의 화면을 띄우지 않고, `DeviceResponse` 를
만들거나 서명하지 않는다. 앱은 요청 바이트를 월렛 SDK 에 넘기고, 월렛 SDK 가 만든 평문
`DeviceResponse` 를 세션에 돌려준다.

| 방향      | 값                  | 만든 쪽     | 규칙 |
| --------- | ------------------- | ----------- | ---- |
| SDK → 앱  | `deviceRequest`     | mdoc reader | 복호화된 `DeviceRequest` CBOR. SDK 는 파싱하지 않는다 |
| SDK → 앱  | `sessionTranscript` | 이 SDK      | `SessionTranscriptBytes`(`#6.24(bstr .cbor SessionTranscript)`). 월렛 SDK 에 **그대로** 넘긴다 — 디코드 후 재인코딩하면 리더의 `DeviceAuth` 검증이 깨진다 |
| 앱 → SDK  | `deviceResponse`    | 월렛 SDK    | **평문** `DeviceResponse`. SDK 가 암호화해 `SessionData` 로 보낸다 |

아래 모든 API 에 적용되는 스레딩·생명주기 규칙:

- 델리게이트 메서드는 `MdocDeviceConfiguration.callbackQueue`(기본: 메인)에서 호출된다.
- 세션의 메서드와 `terminate()` 는 어느 스레드에서 불러도 된다. 상태 변화는 세션 안에서 차례로 처리된다.
- **활성 세션은 프로세스당 하나다.** `MdocDeviceSession` 과 `MdocReaderSession` 을 합쳐 하나이며,
  BLE 광고·스캔과 NFC 카드 에뮬레이션이 프로세스 단위 자원이기 때문이다. 두 번째 `start` 는
  `invalidState` 로 실패한다.
- **세션 1개 = 트랜잭션 1개.** 세션은 다시 시작할 수 없다. 재시도는 새 세션으로 한다.
- 화면을 벗어날 때 `terminate()` 를 부른다. **종단 상태에 이른 뒤에도 마찬가지다** — 부르기
  전까지 라디오와 프로세스 세션 슬롯이 잡혀 있다.

## 1. MdocDeviceSession

mdoc 앱의 진입점.

```swift
public final class MdocDeviceSession
```

## 1.1. init

### Description
`세션을 만든다.`

설정은 세션 안으로 복사되며 이후 바꿀 수 없다. 전송체는 주입할 수 없다 — 어떤 전송 기술을
광고할지는 SDK 가 정하고 직접 세운다.

`nfcCardEmulation` 은 Apple HCE 엔타이틀먼트(`com.apple.developer.nfc.hce`)를 가진 앱을 위한
것이다. SDK 는 카드 에뮬레이션을 구현하지 않는다. 엔타이틀먼트를 가진 앱이 CoreNFC `CardSession` 을
[NfcCardEmulationProtocol](#3-nfccardemulationprotocol) 로 감싸 여기에 넘긴다. 넘기면
`start(technology: .nfcStaticHandover)` 와 `.nfcNegotiatedHandover` 를 쓸 수 있고, QR engagement 에도
NFC 가 광고된다. 넘기지 않으면 QR + BLE 로만 제시한다.

### Declaration

```swift
public convenience init(configuration: MdocDeviceConfiguration = MdocDeviceConfiguration(),
                        nfcCardEmulation: NfcCardEmulationProtocol? = nil)
```

### Parameters

| Name             | Type                      | Description                              | **M/O** | **Note** |
|------------------|---------------------------|------------------------------------------|---------|----------|
| configuration    | MdocDeviceConfiguration   | 타임아웃, BLE 모드 정책, L2CAP, 콜백 큐  | O       | 기본 `MdocDeviceConfiguration()`. [MdocDeviceConfiguration](#1-mdocdeviceconfiguration) |
| nfcCardEmulation | NfcCardEmulationProtocol? | 앱이 제공하는 카드 에뮬레이션            | O       | 기본 `nil`. [NfcCardEmulationProtocol](#3-nfccardemulationprotocol) |

### Returns

| Type              | Description            | **M/O** | **Note** |
|-------------------|------------------------|---------|----------|
| MdocDeviceSession | `idle` 상태의 새 세션  | M       |          |

### Usage

```swift
let session = MdocDeviceSession(configuration: MdocDeviceConfiguration())
session.delegate = self
```

<br>

## 1.2. delegate

### Description
`세션 콜백을 받는 객체.`

약한 참조로 보관한다. `start` 를 부르기 전에 설정한다.

### Declaration

```swift
public weak var delegate: MdocDeviceSessionDelegate?
```

### Parameters

N/A

### Returns

| Type                       | Description        | **M/O** | **Note** |
|----------------------------|--------------------|---------|----------|
| MdocDeviceSessionDelegate? | 현재 델리게이트    | O       | [MdocDeviceSessionDelegate](#2-mdocdevicesessiondelegate) |

### Usage

```swift
session.delegate = self
```

<br>

## 1.3. state

### Description
`세션의 현재 상태.`

읽기 전용이다. 모든 변경은 `mdocSession(_:didChangeState:)` 로도 알린다.

### Declaration

```swift
public private(set) var state: MdocDeviceState
```

### Parameters

N/A

### Returns

| Type            | Description  | **M/O** | **Note** |
|-----------------|--------------|---------|----------|
| MdocDeviceState | 현재 상태    | M       | [MdocDeviceState](#1-mdocdevicestate) |

### Usage

```swift
if session.state == .awaitingResponse {
    try await session.reject()
}
```

<br>

## 1.4. configuration

### Description
`세션을 만들 때 넘긴 설정.`

`init` 에 넘긴 값 그대로이며 세션이 끝날 때까지 바뀌지 않는다.

### Declaration

```swift
public let configuration: MdocDeviceConfiguration
```

### Parameters

N/A

### Returns

| Type                    | Description   | **M/O** | **Note** |
|-------------------------|---------------|---------|----------|
| MdocDeviceConfiguration | 세션의 설정   | M       | [MdocDeviceConfiguration](#1-mdocdeviceconfiguration) |

### Usage

```swift
let timeout = session.configuration.responseTimeout
```

<br>

## 1.5. start

### Description
`device engagement 를 만들고 리더를 기다리기 시작한다.`

`idle` 에서만 호출할 수 있다. 반환 시점에 세션은 `engaging` 이다 — engagement 가 노출되고
전송체가 열린 상태다. `engagementTimeout` 안에 리더가 세션을 수립하지 않으면 `failed` 로 가고
`mdocSession(_:didFailWith:)` 가 `engagementTimeout` 을 알린다.

전송 기술은 앱이 고르지 않고 SDK 가 정한다. 광고되는 집합은

- 이 SDK 가 구현한 전송 기술
- ∩ 지금 이 기기에서 쓸 수 있는 것(라디오·권한)
- 을 `MdocDeviceConfiguration.bleAdvertiseMode` 로 좁힌 것이다(BLE 에만 걸리며 좁히기만 된다).

NFC 는 `init` 에 `nfcCardEmulation` 을 넘겼을 때만 첫 항에 든다.

| technology               | 동작 |
|--------------------------|------|
| `.qr`                    | 광고하는 전송 기술 전부를 담은 `DeviceEngagement` 를 만들고 모두 연다. 리더가 붙은 쪽을 쓴다. BLE 서비스 UUID 는 트랜잭션마다 새로 만든다. 앱은 `payload.qrString` 을 QR 로 렌더링한다. NFC 가 광고되고 리더가 그것을 고르면 홀더가 기기를 리더에 대야 한다 — QR 채널로는 리더의 선택을 되돌려 받을 수 없으므로 홀더에게 알리는 것은 앱 몫이다. |
| `.nfcStaticHandover`     | `nfcCardEmulation` 이 필요하다. mdoc 이 미리 준비한 Handover Select 를 가진 NFC Type 4 Tag 로 보인다. 제안하는 캐리어는 NFC 하나이므로 data retrieval 도 같은 NFC 링크로 이어 간다. `payload.qrString` 은 `nil` 이다. |
| `.nfcNegotiatedHandover` | `nfcCardEmulation` 이 필요하다. mdoc 이 TNEP handover 서비스를 내건 Type 4 Tag 로 보인다. 리더가 Handover Request 를 써 넣으면 mdoc 은 **리더의 선호 순서에서 처음 만나는, 자신이 제공할 수 있는 캐리어** 하나로 답한다 — `bleAdvertiseMode` 가 허용하고 기기가 지원하는 BLE 모드, 또는 NFC. BLE 를 고르면 그 전송체를 그때 세운다. 제공할 수 있는 캐리어가 없으면 handover 를 거절한다. `start` 가 반환될 때 `payload.transmissions` 는 비어 있다. |

리더의 첫 메시지가 도착하면 세션은 `sessionEstablished` 를 거쳐 `awaitingResponse` 로 가고
`mdocSession(_:didReceiveRequest:sessionTranscript:)` 를 호출한다.

`start` 가 반환되기 전에 `terminate()` 가 오면 `start` 는 `CancellationError` 를 던지고 상태는
`terminated` 다. 세션 슬롯을 잡은 뒤 그 밖의 이유로 실패하면 상태는 `failed` 이고 그 세션은 다시
쓸 수 없다.

### Declaration

```swift
@discardableResult
public func start(technology: EngagementTechnology) async throws -> EngagementPayload
```

### Parameters

| Name       | Type                 | Description                    | **M/O** | **Note** |
|------------|----------------------|--------------------------------|---------|----------|
| technology | EngagementTechnology | 사용할 device engagement 채널  | M       | [EngagementTechnology](DataModel_ko.md#2-engagementtechnology) |

### Returns

| Type              | Description                                                         | **M/O** | **Note** |
|-------------------|---------------------------------------------------------------------|---------|----------|
| EngagementPayload | 노출한 engagement. `qrString` 은 `.qr` 일 때만 값이 있고, `transmissions` 는 광고한 전송 기술 목록이다 | M | [EngagementPayload](DataModel_ko.md#1-engagementpayload) |

### Throws

- `invalidState`: 세션이 `idle` 이 아니거나, 이 프로세스에 이미 활성 세션이 있음
- `nfcUnavailable(reason: .vendorPolicy)`: `nfcCardEmulation` 없이 NFC 기술을 요청함. 상태는 `idle` 그대로
- `configurationRequired(action:)` / `bleUnavailable(reason:)`: 기기의 BLE 능력(블루투스 꺼짐·권한 거부·라디오 없음) 때문에 광고할 것이 없음. [MdocCapabilities.current](#41-mdoccapabilitiescurrent) 와 같은 값
- `unsupportedTransmissionTechnology`: 능력은 되지만 `bleAdvertiseMode` 를 적용하고 나니 광고할 것이 없음
- 전송체를 열 때, 또는 `NfcCardEmulationProtocol.start(handler:)` 에서 난 에러
- `CancellationError`: `start` 가 반환되기 전에 `terminate()` 가 호출됨

[MdocProximityError](MdocProximityError.md) 참고.

### Usage

```swift
do {
    let payload = try await session.start(technology: .qr)
    qrImageView.image = renderQR(payload.qrString!)   // rendering is up to the app
} catch {
    present(error: error)
}
```

<br>

## 1.6. respond

### Description
`월렛 SDK 가 만든 DeviceResponse 를 보낸다.`

`awaitingResponse` 에서만, 세션당 1회 호출할 수 있다. **평문** `DeviceResponse` 를 넘기면 SDK 가
세션 키로 암호화해 `SessionData` 로 보낸다. SDK 는 내용을 검사하거나 요청과 대조하지 않는다.

호출하면 응답 타이머가 멈춘다. 전송 중에는 `responding`, 끝나면 `completed` 로 가고
`mdocSessionDidFinish(_:)` 가 호출된다. 큰 응답의 전송 진행률은 `mdocSession(_:didProgress:of:)`
로 온다.

### Declaration

```swift
public func respond(deviceResponse: Data) async throws
```

### Parameters

| Name           | Type | Description                        | **M/O** | **Note** |
|----------------|------|------------------------------------|---------|----------|
| deviceResponse | Data | `DeviceResponse` CBOR, **평문**    | M       | 월렛 SDK 가 만든 그대로 |

### Returns

Void

### Throws

- `invalidState`: 세션이 `awaitingResponse` 가 아니거나, 이미 응답을 보냄
- 전송 중 난 전송 에러(예: 리더가 떠났으면 `peerDisconnected`). 상태는 `failed` 가 되고, 에러는
  이 throw 로만 오며 `mdocSession(_:didFailWith:)` 는 호출되지 않는다
- `CancellationError`: 응답을 보내는 중에 `terminate()` 가 불렸다. 상태는 `terminated` 그대로이고
  `mdocSessionDidFinish(_:)` 는 호출되지 않는다

### Usage

```swift
try await session.respond(deviceResponse: response)
```

<br>

## 1.7. reject

### Description
`응답 없이 세션을 끝낸다.`

응답을 만들 수 없을 때 쓴다 — 문서 미보유, 홀더 거부, 홀더 취소. SDK 는 이를 구분하지 않는다.
`awaitingResponse` 에서만 호출할 수 있다. 리더에는 세션 종료(status 20)만 보내며, 빈
`DeviceResponse` 는 보내지 않는다. 상태는 `terminated` 로 가고 `mdocSessionDidFinish(_:)` 가
호출된다.

### Declaration

```swift
public func reject() async throws
```

### Parameters

N/A

### Returns

Void

### Throws

- `invalidState`: 세션이 `awaitingResponse` 가 아님
- 종료 메시지를 보내는 중 난 전송 에러. 상태는 `failed` 가 되고, 에러는 이 throw 로만 오며
  `mdocSession(_:didFailWith:)` 는 호출되지 않는다

### Usage

```swift
try await session.reject()
```

<br>

## 1.8. terminate

### Description
`세션을 끝내고 자원을 해제한다.`

어느 상태에서든 호출할 수 있고 예외를 던지지 않는다.

- 비종단 상태에서는 리더에 세션 종료(status 20)를 보내고, 그것이 나간 뒤 링크를 닫고,
  `terminated` 로 간다.
- 종단 상태(`completed`, `terminated`, `failed`)에서는 남은 자원만 해제한다. **상태는 바뀌지
  않는다** — `completed` 세션은 `completed` 로 남는다. `completed`·`failed` 에서 리더와 아직 세션
  종료를 주고받지 않았으면 세션 종료(status 20)를 보낸 뒤 링크를 닫는다.

어느 경우든 세션의 타이머를 멈추고 프로세스 세션 슬롯을 푼다. 제시 화면이 닫힐 때마다 부른다.

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
    session?.terminate()
}
```

<br>

## 2. MdocDeviceSessionDelegate

`MdocDeviceSession` 의 콜백. `MdocDeviceConfiguration.callbackQueue` 에서 호출된다. 모든 호출은
사건이 일어난 순서대로 그 큐에 비동기로 보낸다 — 이벤트가 메인 스레드에서 났고 큐가 메인 큐여도
그 자리에서 호출하지 않는다.

```swift
public protocol MdocDeviceSessionDelegate: AnyObject {
    func mdocSession(_ s: MdocDeviceSession, didChangeState state: MdocDeviceState)
    func mdocSession(_ s: MdocDeviceSession, didReceiveRequest deviceRequest: Data,
                     sessionTranscript: Data)
    func mdocSession(_ s: MdocDeviceSession, didProgress sent: Int, of total: Int)
    func mdocSessionDidFinish(_ s: MdocDeviceSession)
    func mdocSession(_ s: MdocDeviceSession, didFailWith error: MdocProximityError)
}

public extension MdocDeviceSessionDelegate {
    func mdocSession(_ s: MdocDeviceSession, didProgress sent: Int, of total: Int) {}
}
```

## 2.1. didChangeState

### Description
`상태가 바뀔 때마다 호출된다.`

"NFC 로 읽는 중", "블루투스로 전송 중" 같은 제시 화면 표시를 여기서 만든다.

### Declaration

```swift
func mdocSession(_ s: MdocDeviceSession, didChangeState state: MdocDeviceState)
```

### Parameters

| Name  | Type              | Description  | **M/O** | **Note** |
|-------|-------------------|--------------|---------|----------|
| s     | MdocDeviceSession | 세션         | M       |          |
| state | MdocDeviceState   | 새 상태      | M       | [MdocDeviceState](#1-mdocdevicestate) |

### Returns

Void

### Usage

```swift
func mdocSession(_ s: MdocDeviceSession, didChangeState state: MdocDeviceState) {
    statusLabel.text = "\(state)"
}
```

<br>

## 2.2. didReceiveRequest

### Description
`리더의 요청이 도착했다.`

이 SDK 의 핵심 신호다. 세션은 `awaitingResponse` 이고 응답 타이머(`responseTimeout`)가 흐르기
시작했다. **두 바이트열을 그대로** 월렛 SDK 에 넘겨 요청 매칭·동의 화면·`DeviceResponse` 조립을
하고, `respond(deviceResponse:)` 를 부른다. 응답을 만들 수 없으면 `reject()` 를 부른다. 매칭·동의·
응답 조립(생체 프롬프트 포함)이 `responseTimeout` 안에 끝나야 한다.

세션당 최대 1회 호출된다. 리더가 같은 세션에서 두 번째 요청을 보내면 SDK 가 세션 종료(status 20)를
보내고 그 요청은 전달하지 않는다. 앱의 응답을 기다리는 중이면 상태가 `terminated` 로 가고,
`completed` 뒤면 `completed` 그대로다. 리더의 위반이지 앱의 오류가 아니므로
`mdocSession(_:didFailWith:)` 는 호출되지 않는다.

### Declaration

```swift
func mdocSession(_ s: MdocDeviceSession, didReceiveRequest deviceRequest: Data,
                 sessionTranscript: Data)
```

### Parameters

| Name              | Type              | Description                          | **M/O** | **Note** |
|-------------------|-------------------|--------------------------------------|---------|----------|
| s                 | MdocDeviceSession | 세션                                 | M       |          |
| deviceRequest     | Data              | 복호화된 `DeviceRequest` CBOR        | M       | 이 SDK 는 파싱하지 않는다 |
| sessionTranscript | Data              | 이 세션의 `SessionTranscriptBytes`   | M       | `#6.24(bstr .cbor SessionTranscript)`. **재인코딩 금지** |

### Returns

Void

### Usage

```swift
func mdocSession(_ s: MdocDeviceSession,
                 didReceiveRequest deviceRequest: Data,
                 sessionTranscript: Data) {
    Task {
        do {
            // Matching, consent and DeviceResponse building happen in the wallet SDK
            let response = try await walletFlow.present(deviceRequest: deviceRequest,
                                                        sessionTranscript: sessionTranscript)
            try await s.respond(deviceResponse: response)   // plaintext; the SDK encrypts it
        } catch {
            try? await s.reject()                           // not held, declined or cancelled
        }
    }
}
```

<br>

## 2.3. didProgress

### Description
`보내는 메시지의 전송 진행률.`

메시지(주로 응답)를 보내는 동안 알린다. 초상 사진 같은 큰 element 가 든 응답은 MTU 가 작은 BLE
에서 수십 초가 걸릴 수 있다. 구현은 선택이다 — 빈 기본 구현이 있다.

### Declaration

```swift
func mdocSession(_ s: MdocDeviceSession, didProgress sent: Int, of total: Int)
```

### Parameters

| Name  | Type              | Description                      | **M/O** | **Note** |
|-------|-------------------|----------------------------------|---------|----------|
| s     | MdocDeviceSession | 세션                             | M       |          |
| sent  | Int               | 지금까지 보낸 메시지 바이트 수   | M       |          |
| total | Int               | 메시지 전체 바이트 수            | M       |          |

### Returns

Void

### Usage

```swift
func mdocSession(_ s: MdocDeviceSession, didProgress sent: Int, of total: Int) {
    progressView.progress = Float(sent) / Float(total)
}
```

<br>

## 2.4. mdocSessionDidFinish

### Description
`앱 자신의 응답으로 세션이 끝났다.`

`respond(deviceResponse:)` 가 응답을 보낸 뒤(상태 `completed`), 그리고 `reject()` 가 종료를 보낸
뒤(상태 `terminated`) 호출된다. 리더가 세션을 끝내거나 링크가 끊긴 경우에는 호출되지 않는다 —
그 경우는 `terminated` 로의 상태 변경, 또는 `mdocSession(_:didFailWith:)` 로 나타난다.

### Declaration

```swift
func mdocSessionDidFinish(_ s: MdocDeviceSession)
```

### Parameters

| Name | Type              | Description  | **M/O** | **Note** |
|------|-------------------|--------------|---------|----------|
| s    | MdocDeviceSession | 세션         | M       |          |

### Returns

Void

### Usage

```swift
func mdocSessionDidFinish(_ s: MdocDeviceSession) {
    statusLabel.text = "Done"
}
```

<br>

## 2.5. didFailWith

### Description
`세션이 실패했다.`

호출 시점에 상태는 `failed` 이며, 최대 1회 호출된다. 대표적인 에러:

- `engagementTimeout`: `engagementTimeout` 안에 리더가 세션을 수립하지 않음
- `responseTimeout`: `responseTimeout` 안에 `respond` 도 `reject` 도 호출되지 않음. 리더에는 세션
  종료(status 20)를 보낸 뒤다
- `terminatedByPeer(status:)`: 리더가 20 이 아닌 status(예: 10, 11)로 세션을 끝냄. SDK 가 링크를
  내린다. 세션 슬롯은 여전히 `terminate()` 가 푼다
- 광고한 전송체가 모두 같은 이유로 실패했을 때의 능력 에러(예:
  `configurationRequired(action: .enableBluetooth)`)
- 전송·세션 암호·디코딩 에러

리더의 정상 종료(status 20)와 링크 닫힘은 실패가 아니다 — 상태가 `terminated` 로 가고(이미
종단 상태가 아니라면) 이 메서드는 호출되지 않는다.

### Declaration

```swift
func mdocSession(_ s: MdocDeviceSession, didFailWith error: MdocProximityError)
```

### Parameters

| Name  | Type               | Description  | **M/O** | **Note** |
|-------|--------------------|--------------|---------|----------|
| s     | MdocDeviceSession  | 세션         | M       |          |
| error | MdocProximityError | 원인         | M       | [MdocProximityError](MdocProximityError.md) |

### Returns

Void

### Usage

```swift
func mdocSession(_ s: MdocDeviceSession, didFailWith error: MdocProximityError) {
    switch error {
    case .configurationRequired(.enableBluetooth): promptEnableBluetooth()
    case .engagementTimeout:                       statusLabel.text = "Timed out"
    case .terminatedByPeer:                        dismiss(animated: true)
    default:                                       present(error: error)
    }
}
```

<br>

## 3. NfcCardEmulationProtocol

mdoc 을 NFC 태그로 보이게 하는 카드 에뮬레이션. **앱이 제공한다.** iOS 전용.

SDK 는 HCE 를 구현하지 않는다. CoreNFC `CardSession`(iOS 17.4+)은
`com.apple.developer.nfc.hce` 엔타이틀먼트가 있어야 쓸 수 있고, 이 엔타이틀먼트는 SDK 가 아니라
앱에 부여된다. 그래서 경계를 APDU 하나로 잘랐다. 앱은 `CardSession` 을 감싸 명령 APDU 를
`handler` 에 넘기고 반환값을 응답 APDU 로 보내기만 하면 된다. ISO 7816 상태 머신, Type 4 Tag 파일,
ENVELOPE 체이닝, 세션 암호는 전부 SDK 가 한다.

구현체는 [init](#11-init) 으로 주입한다. `MdocCapabilities.current().mdoc.nfc` 는 주입 여부와
무관하게 `.unsupported(reason: .vendorPolicy)` 다 — 정적 조회는 주입을 알 수 없고, 주입한 앱은
자기가 주입했음을 이미 안다.

```swift
public protocol NfcCardEmulationProtocol: AnyObject {
    func start(handler: @escaping (Data) async -> Data) async throws
    var onDeactivated: (() -> Void)? { get set }
    func stop()
}
```

## 3.1. start

### Description
`카드 에뮬레이션을 켠다.`

SDK 는 `MdocDeviceSession.start` 중 NFC 전송체를 열 때 이것을 부른다. 리더가 보낸 명령 APDU 마다
`handler` 에 넘기고, 반환값을 **상태워드까지 그대로** 응답 APDU 로 보낸다. `handler` 는 응답이
생길 때까지 기다릴 수 있다 — 마지막 ENVELOPE 의 응답은 앱이 `respond(deviceResponse:)` 를 부른
뒤에야 생긴다. 그동안 링크를 유지하는 것은 OS 몫이다.

여기서 던진 에러는 `MdocDeviceSession.start` 가 그대로 던진다.

### Declaration

```swift
func start(handler: @escaping (Data) async -> Data) async throws
```

### Parameters

| Name    | Type                 | Description                                 | **M/O** | **Note** |
|---------|----------------------|---------------------------------------------|---------|----------|
| handler | (Data) async -> Data | 명령 APDU 를 받아 응답 APDU 를 돌려준다     | M       | SDK 가 제공 |

### Returns

Void

### Usage

```swift
// Inside an app class that conforms to NfcCardEmulationProtocol and holds
// `session: CardSession?` and `pump: Task<Void, Never>?` (iOS 17.4+)
func start(handler: @escaping (Data) async -> Data) async throws {
    guard CardSession.isSupported else { throw MdocProximityError.nfcUnavailable(reason: .noHardware) }
    guard await CardSession.isEligible else { throw MdocProximityError.nfcUnavailable(reason: .vendorPolicy) }
    let session = try await CardSession()                // throws without the HCE entitlement
    self.session = session
    pump = Task { [weak self] in
        do {
            for try await event in session.eventStream {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .sessionStarted:
                    try? await session.startEmulation()
                case .received(let apdu):
                    let response = await handler(apdu.payload)   // the SDK runs the protocol
                    try? await apdu.respond(response: response)
                case .readerDeselected, .sessionInvalidated:
                    onDeactivated?()
                default:
                    break
                }
            }
        } catch {
            self?.onDeactivated?()
        }
    }
}
```

<br>

## 3.2. onDeactivated

### Description
`리더가 자기장을 떠났거나 카드 세션이 무효화됐음을 SDK 에 알린다.`

SDK 가 `start(handler:)` 를 부르기 전에 이 클로저를 설정한다. 리더가 선택을 풀거나 떠났을 때,
또는 카드 세션이 끝났을 때 호출한다. SDK 는 이를 링크 닫힘으로 보고 세션을 끝낸다.

### Declaration

```swift
var onDeactivated: (() -> Void)? { get set }
```

### Parameters

N/A

### Returns

| Type          | Description             | **M/O** | **Note** |
|---------------|-------------------------|---------|----------|
| (() -> Void)? | SDK 가 설정한 클로저    | O       |          |

### Usage

```swift
var onDeactivated: (() -> Void)?

// in the CardSession event loop
case .readerDeselected, .sessionInvalidated:
    onDeactivated?()
```

<br>

## 3.3. stop

### Description
`카드 에뮬레이션을 끈다.`

SDK 가 NFC 링크를 닫을 때 부른다. `start(handler:)` 전에 불리거나 여러 번 불려도 안전해야 한다.

### Declaration

```swift
func stop()
```

### Parameters

N/A

### Returns

Void

### Usage

```swift
func stop() {
    pump?.cancel(); pump = nil
    guard let session else { return }
    self.session = nil
    Task {
        try? await session.stopEmulation(status: .success)
        session.invalidate()
    }
}
```

<br>

## 4. Capability

SDK 는 권한을 직접 요청하지 않는다. 상태만 알려 주고, 언제 요청할지는 앱이 정한다 — 시스템
프롬프트가 동의 흐름을 끊지 않게 하기 위해서다. 타입은 [DataModel](DataModel_ko.md#1-mdoccapabilities)
에 있다.

## 4.1. MdocCapabilities.current

### Description
`이 기기가 지금 쓸 수 있는 전송을 조회한다.`

mdoc 앱은 `mdoc` 멤버를 읽는다. 동기 호출이며 어떤 권한도 요청하지 않는다.

| 멤버             | mdoc 측 값 |
|------------------|------------|
| `mdoc.ble`       | `.supported`. 블루투스 권한이 거부·제한이면 `.configurationRequired(action: .grantPermission("bluetooth"))`, 블루투스가 꺼져 있으면 `.configurationRequired(action: .enableBluetooth)`, BLE 라디오가 없으면 `.unsupported(reason: .noHardware)` |
| `mdoc.nfc`       | 항상 `.unsupported(reason: .vendorPolicy)` — 카드 에뮬레이션에는 Apple HCE 엔타이틀먼트가 필요하다. [NfcCardEmulationProtocol](#3-nfccardemulationprotocol) 을 주입해도 바뀌지 않는다 |
| `mdoc.wifiAware` | 항상 `.unsupported(reason: .vendorPolicy)` |

동기이고 권한을 요청하지 않는다는 데서 한계가 둘 생긴다.

- 블루투스 권한이 **아직 결정되지 않았으면** `ble` 은 `.supported` 다. 판정하려면 OS 가 권한
  프롬프트를 띄워야 하고, 그것은 앱이 처음 `start` 를 부를 때 일어난다.
- 블루투스 전원 상태는 비동기로 온다. 권한이 허용된 뒤 처음 부른 조회는 아직 모를 수 있어
  `.supported` 로 답하고, 그 뒤 조회부터 반영한다. 조회가 이미 알았으면 `start` 가
  `configurationRequired(action: .enableBluetooth)` 를 던지고, 몰랐으면 광고한 전송체가 모두 그 이유로
  실패한 시점에 같은 값이 `mdocSession(_:didFailWith:)` 로 온다.

시스템의 "블루투스 켜기" 알림은 SDK 가 띄우지 않는다. 설정으로 안내할지, 어떻게 보일지는 앱이 정한다.

### Declaration

```swift
public static func current() -> MdocCapabilities
```

### Parameters

N/A

### Returns

| Type             | Description                                  | **M/O** | **Note** |
|------------------|----------------------------------------------|---------|----------|
| MdocCapabilities | `mdoc`·`mdocReader` 역할의 능력              | M       | [MdocCapabilities](DataModel_ko.md#1-mdoccapabilities) |

### Usage

```swift
switch MdocCapabilities.current().mdoc.ble {
case .supported:
    break
case .configurationRequired(action: .enableBluetooth):
    showEnableBluetoothGuide()
case .configurationRequired(action: .grantPermission):
    showPermissionGuide()
case .configurationRequired, .unsupported:
    showNotAvailable()
@unknown default:
    showNotAvailable()
}
```

<br>

# Enumerators
## 1. MdocDeviceState

### Description

`MdocDeviceSession 의 상태`

### Declaration

```swift
public enum MdocDeviceState: String {
    case idle, engaging, sessionEstablished, awaitingResponse, responding, completed, terminated, failed
}
```

### Property

| Value              | Description                                                   | **Note** |
| ------------------ | ------------------------------------------------------------- | -------- |
| idle               | 생성됨, 시작 전                                               | `start` 가능 |
| engaging           | engagement 노출, 리더 대기                                    | `engagementTimeout` 후 `failed` |
| sessionEstablished | 리더의 `SessionEstablishment` 를 받아 복호화함                |          |
| awaitingResponse   | 요청을 전달함, 앱의 응답 대기                                 | `respond` / `reject` 가능. `responseTimeout` 후 `failed` |
| responding         | 응답 전송 중                                                  |          |
| completed          | 응답을 보냄                                                   | 종단 |
| terminated         | `reject`, `terminate`, 리더의 종료(status 20), 링크 닫힘으로 끝남 | 종단 |
| failed             | `didFailWith` 로 알린 에러, 또는 `respond` / `reject` 가 던진 송신 실패로 끝남 | 종단 |

| 현재 상태 | 허용 호출 | 그 외 호출 |
| --------- | --------- | ---------- |
| `idle` | `start`, `terminate` | `invalidState` |
| `engaging` / `sessionEstablished` / `responding` | `terminate` | `invalidState` |
| `awaitingResponse` | `respond`, `reject`, `terminate` | `invalidState` |
| `completed` / `terminated` / `failed` | `terminate`(상태 불변) | `invalidState` |

BLE mdoc central client mode 에서는 `engaging` 중 리더의 Ident 특성을 확인한다. 일치하지 않으면 그
peripheral 을 버리고 다시 스캔한다 — 세션은 `engaging` 에 머물고 실패를 알리지 않는다.
<br>

## 2. BleAdvertiseMode

### Description

`mdoc 이 광고할 BLE 모드`

ISO/IEC 18013-5 는 mdoc 이 두 GATT 모드 중 하나만 지원해도 되게 하므로 하나만 광고해도 적합하다.
리더는 둘 다 지원해야 한다. `.both` 는 "제한하지 않는다"이지 "반드시 둘 다 광고한다"가 아니다 —
결과는 언제나 기기가 지원하는 것과 다시 교집합을 낸다.

### Declaration

```swift
public enum BleAdvertiseMode: Equatable {
    case peripheralServer
    case centralClient
    case both

    public func allows(_ technology: TransmissionTechnology) -> Bool
}
```

### Property

| Value            | Description                                          | **Note** |
| ---------------- | ---------------------------------------------------- | -------- |
| peripheralServer | mdoc peripheral server mode 만(mdoc 이 GATT server)  |          |
| centralClient    | mdoc central client mode 만(mdoc 이 GATT client)     |          |
| both             | 제한하지 않음                                        | 기본값   |

| Method     | Description | **Note** |
| ---------- | ----------- | -------- |
| allows(_:) | 이 정책이 `technology` 를 허용하는지. BLE 가 아닌 전송은 언제나 `true` | [TransmissionTechnology](DataModel_ko.md#3-transmissiontechnology) |
<br>

# Value Object

## 1. MdocDeviceConfiguration

### Description

`MdocDeviceSession 의 설정`

전송 기술 목록은 없다 — 무엇을 광고할지는 SDK 가 정한다([start](#15-start) 참고). 앱이 정하는
전송 정책은 `bleAdvertiseMode` 하나이며, 집합을 좁힐 수는 있어도 넓힐 수는 없다.

### Declaration

```swift
public struct MdocDeviceConfiguration {
    public var engagementTimeout: TimeInterval = 90
    public var responseTimeout: TimeInterval = 60
    public var bleAdvertiseMode: BleAdvertiseMode = .both
    public var l2capUpgrade: Bool = false
    public var callbackQueue: DispatchQueue = .main

    public init()
}
```

### Property

| Name              | Type             | Description                                              | **M/O** | **Note** |
| ----------------- | ---------------- | -------------------------------------------------------- | ------- | -------- |
| engagementTimeout | TimeInterval     | `engaging` 에서 리더를 기다리는 시간(초)                 | M       | 기본 90 |
| responseTimeout   | TimeInterval     | `awaitingResponse` 에서 `respond`·`reject` 를 기다리는 시간(초) | M | 기본 60. 동의 화면과 월렛 SDK 의 응답 조립(생체 프롬프트 포함)을 포함한다. 만료되면 종료를 보내고 `responseTimeout` 으로 실패한다 |
| bleAdvertiseMode  | BleAdvertiseMode | 광고할 BLE 모드                                          | M       | 기본 `.both`. 좁히기만 된다. 고른 모드를 기기가 지원하지 않아 남는 것이 없으면 `start` 가 `unsupportedTransmissionTechnology` 를 던진다. [BleAdvertiseMode](#2-bleadvertisemode) |
| l2capUpgrade      | Bool             | L2CAP 승격을 제공할지                                    | M       | 기본 `false`(GATT 만). 아래 참고 |
| callbackQueue     | DispatchQueue    | 델리게이트를 호출하는 큐                                 | M       | 기본 `.main` |

**`l2capUpgrade`** 는 광고 집합을 바꾸지 않는다 — L2CAP PSM 은 engagement 가 아니라 GATT 특성으로
주고받는다. `true` 면 mdoc peripheral server mode 에서는 mdoc 이 PSM 특성(`0000000A`)을 게시하고,
mdoc central client mode 에서는 리더의 PSM 특성(`0000000B`)을 읽어 채널을 연다. 상대가 PSM 을
내놓지 않거나 채널이 서지 않으면 같은 모드의 GATT 로 돌아간다. 기본이 꺼진 이유는 실측이다 —
21KB 응답에서 채널 수립 비용이 전송 이득을 상쇄했다.
<br>
