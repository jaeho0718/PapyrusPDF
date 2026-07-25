# OCR 텍스트 연결하기

스캔 PDF처럼 내장 텍스트가 없는 문서에 OCR 결과를 연결해, 드래그 선택·복사·검색이
그 위에서 동작하게 만드는 방법입니다.

## 개요

Papyrus는 OCR을 직접 수행하지 않습니다. 대신 `PageTextProvider`를 구현해
`PapyrusReader(document:model:textProvider:)`에 주입하면, 뷰어의 드래그 선택·복사·검색이
내장 텍스트 추출 대신 그 공급원이 내놓는 텍스트 위에서 동작합니다.

```swift
PapyrusReader(document: document, model: model, textProvider: OCRTextProvider(document: document))
```

문서에 내장 텍스트가 이미 있어도 공급원을 지정하면 그 문서의 텍스트는 전부 가려지고
공급원의 결과로 완전히 대체됩니다 — 두 출처를 병합하는 기능은 없습니다. 텍스트 페이지는
내장 추출을, 스캔 페이지만 OCR을 쓰고 싶다면 아래 "혼합 문서 레시피"를 참고하세요.

## 좌표 계약

OCR 엔진은 보통 페이지를 이미지로 렌더한 뒤 그 이미지 위의 정규화 좌표로 결과를
내놓습니다. `PageTextProvider`가 최종적으로 공급해야 하는 좌표는 그것과 다른 세
번째 좌표계입니다 — 셋을 표로 비교합니다.

| 좌표계 | y축 방향 | 원점 | 값의 범위 |
|---|---|---|---|
| PDF 페이지 공간 (`TextRun`의 `quad`가 속한 계) | 위 | 좌하단 | 포인트(pt), cropBox 기준 |
| 표시 공간 (뷰어 화면 배치) | 아래 | 좌상단 | 포인트(pt), `displaySize` 기준 |
| Vision 정규화 공간 (`VNRecognizedTextObservation.boundingBox`) | 위 | 좌하단 | 0...1 |

`PageTextProvider`가 반환하는 `TextRun`의 `quad`는 항상 **PDF 페이지 공간**이어야
합니다. Vision류 엔진의 정규화 좌표는 y축 방향이 표시 공간과 반대이므로, 페이지
공간으로 옮기기 전에 먼저 표시 공간 기준으로 뒤집어야 합니다.

```
y' = 1 - y - height   (x·폭·높이는 그대로)
```

뒤집은 표시 공간 정규화 rect를 `pageQuad(normalizedDisplayRect:)`에 넘기면 PDF 페이지
공간 quad를 얻습니다. 문자 단위 위치 정보가 없는 OCR 결과는 `TextRun.uniform(range:quad:)`으로
균등 전진 run을 만들면 됩니다 — 글자 경계 정밀도만 낮아질 뿐, 선택·검색 하이라이트는
정상 동작합니다.

```swift
// observation: VNRecognizedTextObservation, pageInfo: 대상 페이지의 PageInfo,
// text: observation.topCandidates(1).first?.string.
let visionBox = observation.boundingBox
let displayRect = CGRect(
  x: visionBox.minX, y: 1 - visionBox.minY - visionBox.height,
  width: visionBox.width, height: visionBox.height
)
let quad = pageInfo.pageQuad(normalizedDisplayRect: displayRect)
let run = TextRun.uniform(range: existingLength..<(existingLength + text.utf16.count), quad: quad)
```

한 페이지의 모든 관측치를 이렇게 run으로 만들고, 그 사이를 공백이나 개행으로 이어
붙인 문자열과 함께 `PageTextContent(pageIndex:string:runs:)`로 조립하면 그 페이지의
반환값이 완성됩니다.

## 프로바이더 구현 예제

검색 워밍업과 선택 프리페치는 여러 페이지를 **동시에** 요청할 수 있으므로, 내부에
캐시를 둔다면 actor로 격리하는 것을 권장합니다.

```swift
actor OCRTextProvider: PageTextProvider {
  private let document: PapyrusDocument
  private var cache: [Int: PageTextContent] = [:]

  init(document: PapyrusDocument) {
    self.document = document
  }

  func textContent(forPage pageIndex: Int) async throws -> PageTextContent {
    if let cached = cache[pageIndex] {
      return cached
    }
    try Task.checkCancellation()
    let pageInfo = try await document.page(at: pageIndex)
    let image = try await renderPageImage(pageInfo)   // 앱이 준비하는 페이지 래스터.
    let observations = try await recognizeText(in: image)
    let content = assemble(pageIndex: pageIndex, pageInfo: pageInfo, observations: observations)
    cache[pageIndex] = content
    return content
  }
}
```

페이지 래스터 확보는 앱의 책임입니다 — Papyrus는 페이지 이미지를 얻는 공개 API를
제공하지 않습니다. `displaySize` 비율의 이미지라면 어떤 렌더 수단을 쓰든 상관없습니다.
OCR 엔진 호출은 시간이 걸릴 수 있으므로 `Task.checkCancellation()`으로 협조적 취소를
지원하는 것을 권장합니다 — 검색 취소나 화면 이탈 시 불필요한 작업을 빨리 놓아줍니다.

### 혼합 문서 레시피

일부 페이지에만 내장 텍스트가 없는 문서라면, 프로바이더 안에서 페이지별로 분기해
내장 텍스트가 있는 페이지는 그대로 위임하면 됩니다.

```swift
func textContent(forPage pageIndex: Int) async throws -> PageTextContent {
  let embedded = try await document.text(forPage: pageIndex)
  guard embedded.runs.isEmpty else {
    return embedded   // 이미 텍스트가 있는 페이지는 내장 추출을 그대로 씁니다.
  }
  return try await ocrContent(forPage: pageIndex)   // 스캔 페이지만 OCR을 실행합니다.
}
```

## 주입과 수명

공급원은 문서가 적재되는 시점에 한 번만 포착됩니다. 같은 `PapyrusReader`가 같은
문서를 표시한 채로 `textProvider` 인자만 바꿔도 반영되지 않습니다 — 교체하려면
문서 자체를 바꾸거나, 뷰에 새 `id(_:)`를 부여해 다시 만들어야 합니다. 선택·복사·검색은
전부 이 한 번 포착된 인스턴스를 공유하므로, 프로바이더 안의 캐시는 한 벌만 두면
충분합니다.

## 입력 위생

`PageTextProvider`가 반환한 값은 소비되기 전에 검사를 거칩니다 — 범위를 벗어난
`TextRun`은 클램프되거나 폐기되고, 비유한(NaN·∞) 좌표를 가진 run은 폐기되며, 문자열
길이와 run 수에는 상한이 있습니다. 계약을 벗어난 값이 뷰어를 멈추게 하거나 죽이지는
않지만, 계약을 지킬 때만 정확한 선택·검색 결과를 보장합니다.
