# Papyrus 아키텍처 설계

Papyrus는 macOS 15+ / iPadOS 18+ / iOS 18+ 용 Swift 패키지로, 수천 페이지급 대용량 PDF를 효율적으로 다루는 것이 목표다. PDFKit에 의존하지 않고:

1. **파싱 코어** — PDF 파일 구조(xref, 객체, 페이지 트리, 메타데이터, 목차, 페이지별 텍스트)를 순수 Swift로 직접 파싱. 지연 로딩·메모리 맵 기반으로 대용량 최적화의 제어권 확보.
2. **렌더링** — 픽셀 래스터화만 Core Graphics(`CGPDFPage` → `CGContext`)에 위임 (하이브리드 방식).
3. **뷰어** — SwiftUI 퍼사드 + 내부는 UIScrollView/NSScrollView 기반 가상화 뷰어.

**확정된 결정사항:**
- 코어 엔진: 하이브리드 (구조 파싱 = 순수 Swift, 래스터화 = CGPDFPage)
- UI: SwiftUI 퍼사드 + 네이티브 스크롤뷰 내부
- 지원 버전: iOS 18 / macOS 15 이상, Swift 6 strict concurrency
- v1 범위: 메타데이터 추출 + 페이지별 텍스트 추출 + 스크롤 전용 뷰어(세로 연속 스크롤 + 줌) + 텍스트 검색·하이라이트. 텍스트 선택/복사, 주석, 썸네일은 v1 제외 (단, 확장 가능한 구조로 설계).

## 타겟 구조

```
Papyrus (umbrella, @_exported)
 ├── PapyrusUI          ← SwiftUI + UIKit/AppKit 뷰어
 │     ├── PapyrusRendering
 │     └── PapyrusCore
 ├── PapyrusRendering   ← CGPDFDocument 풀, 타일, 캐시
 │     └── PapyrusCore
 └── PapyrusCore        ← COS 파서, xref, 페이지 트리, 메타데이터, 목차, 텍스트
```

- `Package.swift`: `platforms: [.iOS(.v18), .macOS(.v15)]` 추가, 4개 타겟 + 테스트 타겟들 + `PapyrusTestSupport`(픽스처 빌더).
- 접근 수준: COS 계층은 `package` 접근 수준으로 타겟 간 공유, 외부 공개는 `PapyrusDocument`와 값 타입들 + `PapyrusReader`/`PapyrusReaderModel`만.
- 제품(product)은 `Papyrus` 하나만 노출.

## 디렉터리 구성

```
Sources/
  PapyrusCore/
    IO/         MappedFile.swift (메모리맵 파일, Sendable)
    COS/        COSObject.swift, COSLexer.swift, COSParser.swift, ObjectID.swift
    XRef/       XRefTable.swift, XRefTableParser.swift, XRefStreamParser.swift,
                TrailerResolver.swift, RecoveryScanner.swift, ObjectStreamCache.swift
    Filters/    FlateDecode, LZW, ASCIIHex, ASCII85, RunLength, Predictor
    Security/   SecurityHandler.swift (v1: 감지만, 프로토콜 심 마련)
    Document/   PDFDocumentCore.swift (actor), PageTree.swift, PageRecord.swift
    Metadata/   InfoDictionary.swift, PDFDateParser.swift, XMPMetadata.swift
    Outline/    OutlineParser.swift, DestinationResolver.swift, NameTree.swift
    Text/       ContentStreamInterpreter.swift, FontLoader.swift, CMapParser.swift,
                Encodings.swift, GlyphList.swift(AGL 서브셋), TextAssembler.swift
    Public/     PapyrusDocument.swift, Models.swift, PapyrusError.swift, TextSearch.swift
  PapyrusRendering/
    CGDocumentPool.swift, RenderWorker.swift, TileKey.swift, TileCache.swift,
    PagePreviewCache.swift, TileRenderQueue.swift, MemoryPressure.swift,
    RenderingLimits.swift(한도 상수), RenderRequest.swift(우선순위 버퍼)
  PapyrusUI/
    Shared/     ReaderCore.swift, ReaderLayoutEngine.swift,
                PageLayerController.swift(PageLayerPool 동거),
                VisibleRangeCalculator.swift, ReaderScrollHost.swift,
                HighlightOverlay.swift(M7)
    iOS/        ReaderScrollView_iOS.swift + UIViewRepresentable
    macOS/      ReaderScrollView_macOS.swift + NSViewRepresentable
    PapyrusReader.swift, PapyrusReaderModel.swift
  Papyrus/      Papyrus.swift (@_exported)
```

## 파싱 코어 설계 (PapyrusCore)

### 파일 접근
- `MappedFile`: `Data(contentsOf:options:[.alwaysMapped])` 래핑, 오프셋 기반 랜덤 액세스. 전체 파일을 절대 메모리에 올리지 않음. `Data` 직접 입력도 지원(테스트용).
- 열기: 마지막 1KB 역방향 스캔으로 `startxref` 탐색, `%PDF-x.y` 헤더 검증(스펙 허용대로 앞 1KB 정크 허용).

### COS 객체 모델
- `enum COSObject` (null/bool/int/real/string/name/array/dict/stream/reference, indirect case 활용).
- `COSStream`은 바이트가 아닌 **위치**(`fileRange` 또는 ObjStm 페이로드)를 보유 — 디코딩은 온디맨드 + 바이트 예산 LRU 캐시.
- `COSLexer`: 전체 토큰화 없이 커서 기반 바이트 렉서. 문자열 이스케이프, EOL 변형(CR/LF/CRLF), 주석, 중첩 깊이 캡(512) 처리. `12 0 R` 참조는 2토큰 lookahead로 판별.

### XRef — 현실 세계 대응 매트릭스
1. 클래식 xref 테이블 (19/21바이트 비정상 행 허용)
2. xref 스트림 (PDF 1.5+, /W /Index, Flate+PNG predictor 필수)
3. 하이브리드 파일 (/XRefStm)
4. 증분 업데이트 (/Prev 체인, 최신 우선 병합, 순환 가드)
5. 객체 스트림 (/Type /ObjStm) — 컨테이너 단위 압축해제 LRU 캐시 (~16MB 예산). 최신 대용량 PDF 성능의 핵심.
6. **복구 폴백** (`RecoveryScanner`): xref 검증 실패 시 `N G obj` 패턴 선형 스캔으로 테이블 재구성. 실패 대신 `openWarnings`로 보고.

### 스트림 필터
- v1 구현: FlateDecode(Compression 프레임워크, zlib 헤더 스킵), PNG/TIFF Predictor, ASCIIHex, ASCII85, RunLength, LZW.
- 이미지 필터(DCT/JPX/JBIG2/CCITT)는 디코딩 안 함 — 이미지는 렌더링 시 CG가 처리.

### 암호화
- **v1: 감지 후 `PapyrusError.encryptedDocument`로 명확히 실패.** 단 `SecurityHandler` 프로토콜 심을 지금 만들어 모든 문자열/스트림이 핸들러를 경유하게 함 → 이후 표준 핸들러(RC4/AES) 추가 시 다른 계층 무수정.

### 페이지 트리
- **한 번에 평탄화** (첫 접근 시): 반복 순회 + 순환 가드, 상속 속성(/MediaBox, /Rotate, /Resources) 해소하여 `[PageRecord]` 구축. 5,000페이지 ≈ 수십 ms, ~500KB. O(1) 페이지 접근 + `ObjectID → pageIndex` 역맵(목차 해소에 필요) + 뷰어 레이아웃 즉시 계산 가능.

### 메타데이터 / 목차
- /Info 딕셔너리 (PDFDocEncoding/UTF-16BE/UTF-8 텍스트 문자열 디코딩) + PDF 날짜 파서(`D:YYYYMMDD...`, 필드 대부분 선택적, 관용적 파싱) + XMP 폴백(/Root /Metadata, XMLParser). 병합: Info 우선, XMP 보충.
- 목차: /Outlines를 /First·/Next 반복 순회(순환 가드, 5만 항목 캡). 목적지 해소: 명시적 /Dest 배열 → 이름 목적지(/Dests 딕셔너리, /Names/Dests **네임 트리는 지연 탐색**) → /A GoTo 액션. 페이지 참조는 역맵으로 인덱스 변환.

### 텍스트 추출 ← 최대 난제, v1 컷 명확화
목표: **ToUnicode CMap 또는 표준 인코딩을 가진 ~90% 문서에서 올바른 유니코드 + 검색 하이라이트에 충분한 run 단위 quad**.

파이프라인 (페이지당):
1. /Contents 해소(배열이면 연결) + /Resources/Font → `LoadedFont` 테이블 (폰트는 객체 ID 기준 문서 전역 캐시).
2. 폰트 로딩: **ToUnicode 최우선** → 단순 폰트는 기본 인코딩(+/Differences) + AGL 서브셋 테이블 → Type0/CID는 Identity-H/V + 임베디드 CMap만 지원. 사전정의 CJK CMap(UniJIS 등)은 v1 제외 — 위치는 유지한 채 U+FFFD run으로 표시(하이라이트는 동작).
3. `ContentStreamInterpreter`: 그래픽 상태(q/Q/cm) + 텍스트 상태(BT/ET, Tf, Td/TD/Tm/T*, Tc/Tw/Tz/TL/Ts) + 표시 연산자(Tj/TJ/'/") 해석. Form XObject 재귀(깊이 캡 16). Tr 3(투명 텍스트, OCR 레이어)는 포함하되 `isInvisible` 태그.
4. 지오메트리: run별 원점 + advance 배열 + ascent/descent 박스 → PDF 페이지 공간 quad. 문자별 rect 저장 대신 run + advances로 파생.
5. `TextAssembler`: 베이스라인 정렬 → 간격 휴리스틱으로 공백/줄바꿈 삽입 → `PageTextContent`(페이지 문자열 + run들).

캐싱: 페이지별 결과를 바이트 예산 LRU에. 추출은 순수 함수 → TaskGroup 병렬화 (검색 워밍업 경로).

### 동시성 모델
- `actor PDFDocumentCore`: 맵 파일, xref, 객체 LRU, ObjStm 캐시, 폰트 캐시, 페이지 인덱스, 텍스트 캐시 소유. 모든 객체 해소가 여기로 수렴.
- 공개 `PapyrusDocument`는 Sendable 클래스로 액터 래핑, getter는 async, 반환값은 전부 Sendable 스냅샷 값 타입.
- CPU 무거운 작업(inflate, 콘텐츠 해석, 복구 스캔)은 액터가 넘겨준 데이터로 nonisolated 실행 — 액터 비블로킹. 페이지별 in-flight `Task` 딕셔너리로 중복 요청 dedupe.
- **CGPDFDocument는 Sendable 아님** → `RenderWorker` 액터 N개(각자 독립 CGPDFDocument 소유, N = min(4, 코어 수)) 풀로 병렬 타일 렌더링. CG 객체는 액터 밖으로 절대 안 나가고 `CGImage`(불변, 스레드 안전)만 반환.

## 렌더링 파이프라인 (PapyrusRendering)

- **CATiledLayer 대신 커스텀 타일링** — CATiledLayer는 동기 draw 콜백이라 액터 기반 비동기 렌더링과 충돌하고, 줌 페이드 아티팩트 + 캐시 제어 불가. 커스텀: 페이지당 프리뷰 레이어(전체 페이지 저해상도) 아래 + 512pt 타일 레이어들 위.
- `TileKey`(pageIndex, scaleBucket, col, row). 줌 스케일은 √2 버킷으로 스냅 — 핀치 중엔 레이어 transform 확대(즉시·흐릿), 제스처 종료 시 재타일링.
- `TileCache`: 바이트 비용 LRU, 예산 min(256MB, 물리메모리/8). `PagePreviewCache` 별도(작고 많이 유지 — 빠른 스크롤 체감의 핵심). Mutex(Synchronization) 기반 Sendable.
- `TileRenderQueue`(actor): 우선순위 4등급(visiblePreview > visibleTile > prefetchTile > prefetchPreview — 보이는 페이지의 공백 방지가 최우선, 프리뷰 렌더는 타일보다 저렴), in-flight dedupe, 가시 범위 이탈 시 Task 취소.
- 프리페치: 프리뷰는 visible ±3페이지, 타일은 visible ±0.5 뷰포트.
- 메모리 압박: `DispatchSource.makeMemoryPressureSource` — warning 시 예산 반감, critical 시 타일 전량 퍼지.

## 뷰어 (PapyrusUI)

- **플랫폼 공유 전략**: CALayer 수준까지 공유(~85%) — `ReaderCore`(@MainActor, 레이아웃·재활용·타일 요청·하이라이트), `ReaderLayoutEngine`, `PageLayerController`. 플랫폼별은 스크롤 호스트만 (`ReaderScrollHost` 프로토콜: viewportBounds, zoomScale, contentLayer, setContentSize, scrollTo).
- macOS는 `isFlipped = true` NSView로 좌표계를 iOS와 통일 — 플랫폼 분기 대부분 제거.
- **레이아웃 엔진**: 파서의 PageRecord에서 페이지 크기 획득(CGPDFDocument 불필요 → 열자마자 레이아웃 완성). 누적 Y 오프셋 배열 1회 계산(5,000페이지 = 40KB), 프레임 조회 O(1), 오프셋→페이지 이진 탐색 O(log n).
- **가상화**: visibleRange ±2페이지만 `PageLayerController` 실체화, 재활용 풀(캡 ~8). 이탈 시 풀 반환 + 타일 요청 취소.
- 탐색: goToPage / 목차 목적지 이동 / `ReaderPosition`(pageIndex + 페이지 내 정규화 오프셋 + zoom, Codable) 저장·복원.
- M5/M6 경계 계약: 가시 캐시 조회는 동기(nonisolated Mutex 캐시), 미스는 visible 등급 async 페치, 프리페치·폐기는 `updateViewport` 위임.
- **검색**: `PapyrusDocument.search()` → `AsyncThrowingStream<SearchResult>` (병렬 텍스트 워밍업, 페이지 순서대로 방출). 매칭은 Foundation `range(of:options:[.caseInsensitive,.diacriticInsensitive])` 반복 — 폴딩 길이 변화로 인한 오프셋 매핑 버그 회피. 결과 quad는 run + advances에서 보간. 뷰어는 페이지당 `CAShapeLayer` 하나로 전체 quad 패스 오버레이, 현재 매치는 강조 레이어, next/prev 시 스크롤 이동.
- SwiftUI 퍼사드: `PapyrusReader(document:model:)` + `@Observable PapyrusReaderModel`(currentPageIndex, visiblePageRange, zoomScale, searchState, goToPage, search, next/previousMatch, position 저장·복원).
- 확장 대비(설계만): 텍스트 선택 = TextRun quad 히트테스트 레이어 추가, 주석 = 오버레이 레이어 종 추가, 썸네일 = RenderWorker 프리뷰 재사용 — 구조 변경 불필요.

## 공개 API 요약

```swift
public final class PapyrusDocument: Sendable {
    static func open(url: URL) async throws(PapyrusError) -> PapyrusDocument
    static func open(data: Data) async throws(PapyrusError) -> PapyrusDocument
    var openWarnings: [OpenWarning] { get }
    var pageCount: Int { get async throws(PapyrusError) }
    var metadata: DocumentMetadata { get async throws(PapyrusError) }
    var outline: [OutlineItem] { get async throws(PapyrusError) }
    func page(at index: Int) async throws(PapyrusError) -> PageInfo
    func text(forPage index: Int) async throws(PapyrusError) -> PageTextContent
    func search(_ query: String, options: SearchOptions) -> AsyncThrowingStream<SearchResult, Error>
}
// 값 타입: DocumentMetadata, PageInfo(mediaBox/cropBox/rotation/displaySize),
//         OutlineItem(title/destination/children), PageTextContent(string/runs),
//         TextRun(range/quad/advances/isInvisible), Quad, SearchResult(pageIndex/range/quads/snippet)
// enum PapyrusError: notAPDF, damagedDocument, encryptedDocument, pageOutOfRange,
//                    unsupportedFilter, cancelled ...

// M6 공개 표면 (PapyrusUI):
public struct PapyrusReader: View {
    init(document: PapyrusDocument, model: PapyrusReaderModel)
}
@MainActor @Observable
public final class PapyrusReaderModel {
    var loadState: ReaderLoadState { get }   // loading / ready / failed(PapyrusError)
    var pageCount: Int { get }
    var currentPageIndex: Int { get }
    var visiblePageRange: Range<Int> { get }
    var zoomScale: CGFloat { get }
    func goToPage(_ index: Int, animated: Bool = true)
    func go(to destination: OutlineDestination, animated: Bool = true)
    func capturePosition() -> ReaderPosition?
    func restore(_ position: ReaderPosition)
}
// 값 타입: ReaderPosition(pageIndex/normalizedOffset/zoomScale, Codable),
//         ReaderLoadState(loading/ready/failed)
```

## 테스트 전략 (Swift Testing)

- **`PapyrusTestSupport`의 `PDFFixtureBuilder`가 핵심**: 코드로 최소 PDF를 생성하는 소형 PDF 라이터. 모든 xref 변형(.classicTable/.xrefStream/.objectStreams/.hybrid), 증분 업데이트, 의도적 손상 모드를 재현 가능 — 바이너리 블롭 관리 불필요. 실제 소형 PDF 5~10개를 리소스로 보충.
- 유닛: 렉서 골든 테스트(`@Test(arguments:)` 파라미터화), 필터 라운드트립, xref 매트릭스, 날짜 파서, ToUnicode/커닝 공백 삽입 등 텍스트 추출 검증, 네임 트리 조회.
- 렌더링: 스모크 수준(타일 CGImage 비-nil + 크기 + 픽셀 프로브). 픽셀 퍼펙트 스냅샷은 v1 보류(OS 버전별 CG 출력 편차).
- 뷰어: `ReaderLayoutEngine`은 순수 수학이라 집중 테스트(`Tests/PapyrusUITests` — PapyrusRenderingTests 전례를 따르는 별도 타겟). 스크롤 동작은 데모 앱에서 수동 검증.
- 성능: 픽스처 빌더로 5,000페이지 합성 PDF 생성 → 열기+pageCount < 250ms, warm `page(at:)` < 1ms 등을 `ContinuousClock` 수동 측정 + `#expect` 판정으로 게이트 (env 플래그 뒤에). `.timeLimit` trait은 최소 단위가 분이라 ms 게이트에 쓸 수 없고, 행(hang) 가드로만 사용.
- `Examples/PapyrusDemo` 앱 (별도 Xcode 프로젝트) — Instruments로 스크롤/메모리 프로파일링.

## 구현 마일스톤

| 단계 | 내용 | 완료 기준 |
|---|---|---|
| M0 | 타겟 재구성 + FixtureBuilder v0 | `swift test` 통과 |
| M1 | MappedFile, 렉서/파서, COS 모델, Flate+predictor+ASCII 필터 | 골든 테스트 통과 |
| M2 | XRef 전 변형 + ObjStm + 복구 스캐너 + `PDFDocumentCore` 액터 + 암호화 감지 | 모든 픽스처 변형 열기 성공 |
| M3 | 페이지 트리 + 메타데이터 + 목차 → **공개 API 1차 출시** (텍스트 제외) | 5,000페이지 성능 게이트 통과 |
| M4 | 텍스트 추출 (인터프리터 + 폰트/CMap + 어셈블러 + quad) + LZW | 픽스처 텍스트 일치 |
| M5 | 렌더링 파이프라인 (M4와 병렬 가능, M2만 필요) | 타일 스모크 + 메모리 상한 확인 |
| M6 | 뷰어 (레이아웃, 가상화, iOS/macOS 호스트, 줌, SwiftUI 퍼사드) + 데모 앱 | 5,000페이지 60fps 스크롤 |
| M7 | 검색 + 하이라이트 + 매치 탐색 | 검색 픽스처 검증 |
| M8 | 하드닝 (손상 파일 퍼징 — 크래시/행 금지), DocC, README | 코퍼스 통과 |

임계 경로: M1 → M2 → M3 → M6. M4/M5는 병렬 가능.

## 난제 플래그 (정직한 리스크)

1. **폰트/CMap (M4)** — 가장 깊은 구덩이. v1 컷(ToUnicode 우선, Identity-H만, CJK 사전정의 CMap 제외)을 반드시 지킬 것. 예상 기간 ≈ M1+M2 합.
2. **XRef 엣지 케이스 (M2)** — 실파일은 스펙을 어김. "경고하되 실패하지 않는" 복구 자세 + 픽스처 빌더로 대응, M8에서 코퍼스 기반 보강.
3. **스크롤 성능 튜닝 (M6)** — 마지막 20%는 설계가 아닌 Instruments 작업.
4. **검색 범위 매핑** — 폴딩 길이 변화 문제는 Foundation `range(of:)` 루프로 회피 (약간의 성능 비용 수용).

## 검증 방법

1. 각 마일스톤마다 `swift test` (macOS + iOS 시뮬레이터 목적지).
2. M3 이후: 실제 대용량 PDF(논문·기술서적 등)로 메타데이터/목차/페이지 수 수동 대조.
3. M6 이후: `Examples/PapyrusDemo`에서 5,000페이지 문서 스크롤 — Instruments(Time Profiler, Allocations)로 60fps + 메모리 상한 확인.
4. M7 이후: 데모 앱에서 검색 → 하이라이트 → next/prev 이동 시각 확인.
