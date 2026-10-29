[![Swift](https://img.shields.io/badge/Swift-5-orange.svg?style=flat)](https://developer.apple.com/swift)

# iOS mdoc Proximity SDK

iOS mdoc Proximity SDK Repository에 오신 것을 환영합니다. <br>
이 Repository는 iOS에서 ISO/IEC 18013-5 device retrieval을 위한 SDK를 제공합니다. 소지자 앱(mdoc)이 mdoc을 제시하고, 검증자 앱(mdoc reader)이 이를 요청·검증합니다. engagement는 QR 또는 NFC로, 데이터 검색은 BLE 또는 NFC로 합니다.

## 폴더 구조
```
did-proximity-sdk-ios
├── CHANGELOG.md
├── CLA.md
├── CODE_OF_CONDUCT.md
├── CONTRIBUTING.md
├── dependencies-license.md
├── LICENSE
├── MAINTAINERS.md
├── Package.swift
├── README.md
├── README_ko.md
├── RELEASE-PROCESS.md
├── SECURITY.md
├── docs
│   └── api
│       ├── README.md
│       └── public
│           ├── DataModel.md
│           ├── DataModel_ko.md
│           ├── MdocDeviceAPI.md
│           ├── MdocDeviceAPI_ko.md
│           ├── MdocProximityError.md
│           ├── MdocReaderAPI.md
│           ├── MdocReaderAPI_ko.md
│           ├── MdocTrust.md
│           └── MdocTrust_ko.md
└── source
    ├── did-proximity-sdk-ios
    │   ├── MdocProximitySDK.xcodeproj
    │   ├── build_xcframework.sh
    │   ├── verify_spm_products.sh
    │   ├── verify_xcframework.sh
    │   ├── Sources
    │   │   ├── MdocProximityCore
    │   │   ├── Session
    │   │   │   ├── MdocDevice
    │   │   │   └── MdocReader
    │   │   │       └── MdocTrust
    │   │   ├── Transport
    │   │   │   ├── MdocBLE
    │   │   │   └── MdocNFC
    │   │   └── Tools
    │   │       └── VectorGen
    │   ├── Tests
    │   │   └── MdocProximityCoreTests
    │   ├── test-vectors
    │   └── Harness
    │       └── MdocProbe
    └── release
        └── did-proximity-sdk-ios-1.0.0
            └── MdocProximitySDK.xcframework
```

|  이름                    |         역할                          |
| ----------------------- | ------------------------------------ |
| source                  | SDK 소스코드 프로젝트                     |
| ┖ Sources               | SDK 소스코드                            |
| &nbsp;&nbsp;┖ MdocProximityCore | CBOR/COSE, 세션 암호화, 코덱, 검증         |
| &nbsp;&nbsp;┖ Session   | 역할별 세션 — mdoc(`MdocDevice`), mdoc reader(`MdocReader`, `MdocTrust`) |
| &nbsp;&nbsp;┖ Transport | BLE·NFC 전송                           |
| &nbsp;&nbsp;┖ Tools     | 테스트 벡터 생성기 (배포 대상 아님)           |
| ┖ Tests                 | 단위 테스트                             |
| ┖ test-vectors          | 바이트 단위 테스트 벡터 (VectorGen 으로 생성)   |
| ┖ Harness               | 실기기 테스트 앱 (배포 대상 아님)             |
| ┖ release               | 빌드된 XCFramework                     |
| docs                    | 문서                                  |
| ┖ api                   | API 가이드 문서                         |
| ┖ build_xcframework.sh  | XCFramework 빌드 스크립트                |
| ┖ verify_spm_products.sh | SPM product 를 `import` 한 줄로 쓸 수 있는지 확인 |
| ┖ verify_xcframework.sh | XCFramework 가 공개 API 만 노출하는지 확인   |
| README.md               | 프로젝트의 전체적인 개요 설명               |
| CLA.md                  | Contributor License Agreement       |
| CHANGELOG.md            | 프로젝트 버전별 변경사항                   |
| CODE_OF_CONDUCT.md      | 기여자의 행동강령                        |
| CONTRIBUTING.md         | 기여 절차 및 방법                       |
| dependencies-license.md | 프로젝트 의존성 라이브러리에 대한 라이선스     |
| MAINTAINERS.md          | 유지관리 가이드                         |
| RELEASE-PROCESS.md      | 릴리즈 절차                            |
| SECURITY.md             | 보안취약점 보고 및 보안정책                |


## S/W 사양
| 구분              | 내용                          |
|-------------------|-----------------------------|
| OS                | iOS                         |
| Language          | Swift 5                     |
| IDE               | Xcode 27.0                  |
| Compatibility     | iOS 17.0 이상                |
| Standard          | ISO/IEC 18013-5:2021 — device retrieval |
| Test Environment  | iPhone 14 (실기기)            |

## 라이브러리

라이브러리는 [release 폴더](source/release)에서 찾을 수 있습니다.

### mdoc Proximity SDK

1. 앱 프로젝트의 프레임워크 디렉토리에 `MdocProximitySDK.xcframework` 파일을 복사합니다.
2. 앱 프로젝트 의존성에 프레임워크를 추가합니다.
3. 프레임워크를 `Embed & Sign`으로 설정합니다.

XCFramework 는 두 역할을 모두 담은 모듈 하나입니다:

```swift
import MdocProximitySDK
```

### 빌드
`source/did-proximity-sdk-ios` 에서 스크립트를 실행합니다. XCFramework 는 `source/release/did-proximity-sdk-ios-<버전>/` 에 생성됩니다.

```bash
$ cd source/did-proximity-sdk-ios
$ ./build_xcframework.sh
```

## Swift Package 적용 방법

패키지는 역할마다 product 를 하나씩 제공합니다. 앱은 자기 역할의 product 하나만 추가하면 됩니다. 공용 모듈은 의존성으로 함께 들어오고, `import` 도 한 줄이면 됩니다.

| Product      | 앱                            | Import              |
|--------------|------------------------------|---------------------|
| `MdocDevice` | mdoc 앱 (소지자)               | `import MdocDevice` |
| `MdocReader` | mdoc reader 앱 (검증자)        | `import MdocReader` |

1. **Xcode → Project → Package Dependencies** 를 엽니다.
2. **“+”** 버튼을 누릅니다.
3. SDK 의 Swift Package URL 을 입력합니다:
    ```text
    https://github.com/OmniOneID/did-proximity-sdk-ios.git
    ```
4. **Version ≥ 1.0.0** 을 선택합니다.
5. 앱 역할에 맞는 product 를 타깃에 추가합니다.

## 앱 설정

| 키 | 역할 | 필요한 경우 |
|-----|------|----------|
| `NSBluetoothAlwaysUsageDescription` (Info.plist) | mdoc, mdoc reader | BLE |
| `NSCameraUsageDescription` (Info.plist) | mdoc reader | QR 스캔 (앱이 수행) |
| `NFCReaderUsageDescription` (Info.plist) | mdoc reader | NFC |
| `com.apple.developer.nfc.readersession.iso7816.select-identifiers` (Info.plist) | mdoc reader | NFC — `D2760000850101` 먼저, 그다음 `A0000002480400` |
| `com.apple.developer.nfc.readersession.formats = [TAG]` (Entitlements) | mdoc reader | NFC |

`select-identifiers` 는 순서가 중요합니다. `A0000002480400` 이 앞에 오면 리더가 engagement 를 건너뜁니다. 항목이 없거나 순서가 뒤집혀 있으면 `MdocCapabilities.current()` 가 `configurationRequired(.addEntitlement(...))` 로 알려 줍니다.

mdoc 측 NFC engagement(iOS 카드 에뮬레이션)에 필요한 엔타이틀먼트는 이 SDK 가 가질 수 없으므로 앱이 주입합니다. [MdocDevice API](docs/api/public/MdocDeviceAPI_ko.md) 를 참조하세요.

## API 참조

| 구분                | API 문서 링크                                                  |
|--------------------|---------------------------------------------------------------|
| MdocDevice         | [mdoc API](docs/api/public/MdocDeviceAPI_ko.md)               |
| MdocReader         | [mdoc reader API](docs/api/public/MdocReaderAPI_ko.md)        |
| MdocTrust          | [신뢰 API](docs/api/public/MdocTrust_ko.md)                    |
| DataModel          | [데이터 모델](docs/api/public/DataModel_ko.md)                  |
| MdocProximityError | [오류](docs/api/public/MdocProximityError.md)                  |


## 수정내역

Change Log에는 버전별 변경 사항과 업데이트가 자세히 기록되어 있습니다. 다음에서 확인할 수 있습니다:
- [Change Log](./CHANGELOG.md)


## 데모 영상
OpenDID 시스템의 실제 동작을 보여주는 데모 영상은 [Demo Repository](https://github.com/OmniOneID/did-demo-server) 에서 확인하실 수 있습니다. <br>
사용자 등록, VC 발급, VP 제출 등 주요 기능들을 영상으로 확인하실 수 있습니다.


## 기여

Contributing 및 pull request 제출 절차에 대한 자세한 내용은 [CONTRIBUTING.md](CONTRIBUTING.md)와 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) 를 참조하세요.


## 라이선스
[Apache 2.0](LICENSE)
