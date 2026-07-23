# PapyrusDemo

Papyrus (`PapyrusUI`/`PapyrusReader`) 뷰어를 실제로 실행·프로파일링하기 위한 데모 앱입니다.
파일 열기, 목차 탐색, 5,000페이지 합성 문서 생성 기능을 제공합니다.

이 프로젝트는 메인 `Papyrus` 스위프트 패키지(`../..`)와는 별도의 Xcode 프로젝트입니다.
`swift build`/`swift test` 대상이 아니므로 패키지 CI에 영향을 주지 않습니다.

## 요구 사항

- Xcode 16 이상 (iOS 18 / macOS 15 SDK)
- 로컬 패키지 참조: `../..` (제품 `Papyrus`)

## 프로젝트 구성 및 빌드

`PapyrusDemo.xcodeproj`는 [XcodeGen](https://github.com/yonaskolb/XcodeGen)으로 `project.yml`에서
생성되었습니다. 프로젝트 파일을 직접 커밋해 두었으므로 XcodeGen 없이 바로 열어 빌드할 수
있습니다. 소스 파일을 추가/삭제하는 등 구조를 바꾼 경우에만 재생성하세요.

```sh
# (선택) 구조 변경 후 프로젝트 재생성
brew install xcodegen   # 최초 1회
cd Examples/PapyrusDemo
xcodegen generate
```

XcodeGen은 플랫폼별 타겟(`PapyrusDemo_iOS`, `PapyrusDemo_macOS`)을 생성합니다 — 이 XcodeGen
버전은 단일 타겟에 여러 destination을 부여하는 "멀티플랫폼 앱" 스펙을 지원하지 않아 택한
실용적 대안입니다(두 타겟이 `PapyrusDemo/` 소스를 그대로 공유합니다). 설계 문서가 말하는
"멀티플랫폼 앱 타겟 1개"라는 의도(공유 코드 100%, 플랫폼별 코드 0줄)는 동일하게
성립합니다 — 소스는 정확히 한 벌뿐입니다.

### 커맨드라인 빌드

```sh
cd Examples/PapyrusDemo
xcodebuild -project PapyrusDemo.xcodeproj -scheme PapyrusDemo_macOS \
  -destination 'platform=macOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO

xcodebuild -project PapyrusDemo.xcodeproj -scheme PapyrusDemo_iOS \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

### Xcode에서 실행

1. `PapyrusDemo.xcodeproj`를 연다.
2. 서명은 "Automatic"(개인 팀)으로 되어 있다 — 실기기 실행 시 본인 Apple ID 팀을 선택한다.
3. 스킴을 `PapyrusDemo_macOS`(Mac) 또는 `PapyrusDemo_iOS`(시뮬레이터/기기)로 선택 후 실행(⌘R).

## 소스 파일

| 파일 | 역할 |
|---|---|
| `PapyrusDemoApp.swift` | `@main` 앱 진입점, `WindowGroup` |
| `ContentView.swift` | `NavigationSplitView`: 사이드바(목차) + 디테일(리더), 열기/생성 툴바 |
| `DocumentLoader.swift` | `@Observable`: `fileImporter` URL/합성 바이트 → `PapyrusDocument.open`, 경고·에러 상태 |
| `OutlineSidebar.swift` | `OutlineItem` 트리 → `List`, 탭 시 `model.go(to:)` |
| `ReaderToolbar.swift` | 페이지 표시("n / N")·페이지 이동 입력·줌 ±·위치 저장/복원(UserDefaults의 `ReaderPosition` JSON) |
| `SyntheticPDF.swift` | `CGContext(consumer:mediaBox:_:)` 기반 N페이지 생성기 — 페이지 번호 대형 텍스트 + 100pt 격자(타일 경계 눈검증 겸용) |

`SyntheticPDF`는 `PapyrusTestSupport`(제품 비노출 타겟)를 쓰지 않습니다 — CG의 PDF 그리기
API에 위임하는 수십 줄짜리 생성기라 데모 앱 자체에 둡니다(M6 설계 가정 10).

## 완료 기준 검증 절차 (M6 설계 §7.3)

1. 앱 실행 → 툴바의 **"Generate 5,000-Page Document"** → 문서가 열릴 때까지 대기.
2. **Instruments**로 프로파일링 (Xcode → Product → Profile, 또는 `xcrun xctrace record`):
   - **iOS 실기기**: Time Profiler + Hitches 템플릿. 문서 상단↔하단 왕복 플링 스크롤을
     반복하며 측정. **목표**: 히치율 < 5ms/s, 메인 스레드에서 뷰어 코드가 소비하는 시간이
     프레임당 < 1ms (설계 §4.7 예산표 대조 — 렌더·디코딩은 전부 워커 액터이므로 메인
     스레드에는 나타나지 않아야 한다).
   - **macOS**: Animation FPS 계측기(또는 Core Animation FPS)로 동일한 왕복 스크롤 측정.
3. **Allocations** 계측기: 스크롤 내내 타일+프리뷰 상주 메모리가 M5 예산
   (`min(256MB, 물리 메모리/8)` + 프리뷰 예산) 내로 유지되는지 확인.
4. 목표 미달 시 (난제 3 절차): 프로파일 결과로 병목 특정 → 상수(프리페치 반경·풀 캡·뷰포트
   양자화 노브, `Sources/PapyrusUI/Shared/ReaderLayoutEngine.swift`의
   `ReaderLayoutMetrics`) 조정. 구조 변경이 필요해지면 `_workspace` 설계 문서를 개정한다
   (이 튜닝은 설계가 아니라 Instruments 실측의 소관 — M6 설계 §7.3).

## 수동 검증 체크리스트 (양 플랫폼, M6 설계 §7.4)

- [ ] macOS: 페이지 순서가 위→아래, 타일 이미지 상하가 정상(뒤집히지 않음) — 가정 9, 최우선 확인 항목.
- [ ] 핀치(iOS)/트랙패드 매그니피케이션(macOS) 중 즉시 확대(흐릿) → 손을 떼면 선명하게
      전환되고, 그 사이 공백 프레임이 없다.
- [ ] 빠른 플링 스크롤 중 프리뷰가 항상 타일보다 먼저 차오른다(visiblePreview 최우선).
- [ ] 목차(사이드바) 탭 → 해당 페이지 상단으로 이동한다.
- [ ] **위치 저장** → 앱 재시작 → **위치 복원** → 같은 내용 위치로 돌아온다.
- [ ] 창 크기 조절(macOS)/기기 회전(iOS) 시 같은 내용 위치가 유지된다.
- [ ] 손상된 PDF(파일 일부를 무작위 바이트로 조작한 뒤 열기)에서: 흰 페이지가 표시되고,
      스크롤은 정상 동작하며, 크래시가 없다.
