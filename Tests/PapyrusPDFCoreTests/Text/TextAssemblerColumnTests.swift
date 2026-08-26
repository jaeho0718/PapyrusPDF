import CoreGraphics
@testable import PapyrusPDFCore
import Testing

/// ``TextAssembler.orderByColumns``의 다단(2-column) 읽기 순서를 검증한다
/// (설계 `_workspace/11_architect_column-aware-text-order.md` §6·개정 1~4 TC1-TC16).
///
/// 개정 2가 제안한 "퍼센타일 경계" TC15(2단 4행)는 별도 테스트로 두지 않았다 — "2단
/// 4행"(세그먼트 8개)에서는 `percentile` 인덱스 공식이 최댓값 1개를 배제하지 못한다
/// (인덱스 공식으로 n≥12 필요, 설계 문서의 "n≤10이면 사실상 min/max"보다 더 넓은
/// 범위). TC13이 퍼센타일 트리밍이 아니라 "폭이 넓어도 클래스 폭 대비 60% 미만"인
/// 경로로 같은 관찰 가능한 결과(오른쪽 넘침이 열 흐름에 남음)를 검증한다 — 설계
/// 이슈로 오케스트레이터에 보고. 아래 TC15는 개정 3이 재사용한 번호로, 허용치 상승
/// 반복(§개정 3)을 검증하는 다른 테스트다.
///
/// 좌표계: fontSize 12 고정(1em = 12pt) — `columnGapFactor`(1.0em = 12pt)가 세그먼트
/// 분할·거터 최소 폭 임계값이고, `wideLineFraction`(0.6)·`minColumnFraction`(0.2)은 클래스
/// 폭(extent) 비율이다. 각 테스트는 이 임계값들을 넉넉히 벗어나는 좌표를 골라 결정성을
/// 확보한다 (동률·경계값은 별도 검증 없음 — `TextAssemblerTests`가 조립 자체의 동률 규칙을
/// 이미 검증한다).
struct TextAssemblerColumnTests {
  // MARK: TC1 — 2단 3행, 같은 베이스라인

  @Test func twoColumnsSameBaselineSplitIntoSeparateLines() {
    let runs = Self.twoColumnRuns(
      leftOrigin: CGPoint(x: 0, y: 700), rightOrigin: CGPoint(x: 200, y: 700), rowStep: 12,
      rightYOffset: 0
    )
    let content = TextAssembler.assemble(runs, pageIndex: 0)
    #expect(content.string == "L1\nL2\nL3\nR1\nR2\nR3")
  }

  // MARK: TC2 — 전폭 제목 + 2단

  @Test func wideTitleAboveTwoColumnsStaysFirst() {
    let title = Self.makeRun(text: "Title", origin: CGPoint(x: 0, y: 712), advanceStep: 60)
    var runs = [title]
    runs.append(
      contentsOf: Self.twoColumnRuns(
        leftOrigin: CGPoint(x: 0, y: 700), rightOrigin: CGPoint(x: 200, y: 700), rowStep: 12,
        rightYOffset: 0, rowCount: 2
      )
    )
    let content = TextAssembler.assemble(runs, pageIndex: 0)
    #expect(content.string == "Title\nL1\nL2\nR1\nR2")
  }

  // MARK: TC3 — 짧은 브리지(센터 캡션)

  @Test func shortBridgeCaptionFormsOwnLineBetweenColumnBlocks() {
    var runs = Self.twoColumnRuns(
      leftOrigin: CGPoint(x: 0, y: 700), rightOrigin: CGPoint(x: 160, y: 700), rowStep: 12,
      rightYOffset: 0, rowCount: 2, leftAdvanceStep: 70, rightAdvanceStep: 50
    )
    runs.append(Self.makeRun(text: "Caption", origin: CGPoint(x: 120, y: 676)))
    runs.append(
      contentsOf: Self.twoColumnRuns(
        leftOrigin: CGPoint(x: 0, y: 664), rightOrigin: CGPoint(x: 160, y: 664), rowStep: 12,
        rightYOffset: 0, rowCount: 2, leftAdvanceStep: 70, rightAdvanceStep: 50, rowStartIndex: 3
      )
    )
    let content = TextAssembler.assemble(runs, pageIndex: 0)
    #expect(content.string == "L1\nL2\nR1\nR2\nCaption\nL3\nL4\nR3\nR4")
  }

  // MARK: TC4 — 단일 열 + 우측 수식 번호 (거터 없음 폴백 또는 좁은 열 흡수)

  @Test func narrowEquationNumberColumnStaysOnSameLine() {
    let body = Self.makeRun(text: "Alpha beta gamma delta", origin: CGPoint(x: 0, y: 700))
    let eq = Self.makeRun(text: "eq", origin: CGPoint(x: 0, y: 688))
    let equationNumber = Self.makeRun(text: "(1)", origin: CGPoint(x: 376, y: 688))
    let next = Self.makeRun(text: "Next", origin: CGPoint(x: 0, y: 676))
    let content = TextAssembler.assemble([body, eq, equationNumber, next], pageIndex: 0)
    #expect(content.string == "Alpha beta gamma delta\neq (1)\nNext")
  }

  // MARK: TC5 — 같은 열 안 큰 간격은 개행 아님

  @Test func largeGapWithinSingleColumnStaysOnOneLine() {
    // rowA/rowC(폭90, x=0..90)는 전폭(90≥0.6×extent116)이라 커버리지에서 빠져, AB~CD
    // 사이(x=16..100)가 tolerance 0에서 즉시 거터로 잡힌다 — 하지만 그 거터의 양쪽 열
    // (AB만·CD만, 폭 각 16)이 minColumnFraction(0.2×116=23.2) 미달이라
    // mergingNarrowColumns가 거터를 병합해 없애고, 최종 거터 0개 → 전 라인 y 순서
    // 재결합(개정 2)으로 귀결된다.
    let rowA = Self.makeRun(text: "AA", origin: CGPoint(x: 0, y: 700), advanceStep: 45)
    let left = Self.makeRun(text: "AB", origin: CGPoint(x: 0, y: 688))
    let right = Self.makeRun(text: "CD", origin: CGPoint(x: 100, y: 688))
    let rowC = Self.makeRun(text: "CC", origin: CGPoint(x: 0, y: 676), advanceStep: 45)
    let content = TextAssembler.assemble([rowA, left, right, rowC], pageIndex: 0)
    #expect(content.string == "AA\nAB CD\nCC")
    #expect(content.string.filter { $0 == "\n" }.count == 2)
  }

  // MARK: TC6 — runs 오름차순 계약 (TC1 배치 재사용)

  @Test func outputRunsStayAscendingAcrossColumns() {
    let runs = Self.twoColumnRuns(
      leftOrigin: CGPoint(x: 0, y: 700), rightOrigin: CGPoint(x: 200, y: 700), rowStep: 12,
      rightYOffset: 0
    )
    let content = TextAssembler.assemble(runs, pageIndex: 0)
    for index in 1..<content.runs.count {
      #expect(content.runs[index - 1].range.lowerBound < content.runs[index].range.lowerBound)
    }
  }

  // MARK: TC7 — 퇴화 입력: 전진량 0 / 라인 1개 / 빈 입력

  @Test func degenerateInputsDoNotCrashAndKeepOrder() {
    let zeroAdvance = Self.makeRun(text: "AB", origin: .zero, advanceStep: 0)
    #expect(TextAssembler.assemble([zeroAdvance], pageIndex: 0).string == "AB")

    let single = Self.makeRun(text: "Solo", origin: CGPoint(x: 0, y: 700))
    #expect(TextAssembler.assemble([single], pageIndex: 0).string == "Solo")

    #expect(TextAssembler.assemble([], pageIndex: 0).string.isEmpty)
  }

  // MARK: TC8 — 회전 클래스에서도 같은 결과

  @Test func rotatedClassProducesSameOrderAsHorizontal() {
    let direction = CGVector(dx: 0, dy: 1)
    var runs: [RawGlyphRun] = []
    for row in 0..<3 {
      let rowX = CGFloat(row) * 12
      runs.append(
        Self.makeRun(
          text: "L\(row + 1)", origin: CGPoint(x: rowX, y: 0), direction: direction,
          advanceStep: 50
        )
      )
      runs.append(
        Self.makeRun(
          text: "R\(row + 1)", origin: CGPoint(x: rowX, y: 200), direction: direction,
          advanceStep: 50
        )
      )
    }
    let content = TextAssembler.assemble(runs, pageIndex: 0)
    #expect(content.string == "L1\nL2\nL3\nR1\nR2\nR3")
  }

  // MARK: TC9 — 베이스라인이 3.7pt 어긋난 2단(실측 버그 재현)

  @Test func slightlyMisalignedBaselinesStillSplitIntoColumns() {
    let runs = Self.twoColumnRuns(
      leftOrigin: CGPoint(x: 0, y: 700), rightOrigin: CGPoint(x: 200, y: 700), rowStep: 12,
      rightYOffset: 3.7
    )
    let content = TextAssembler.assemble(runs, pageIndex: 0)
    #expect(content.string == "L1\nL2\nL3\nR1\nR2\nR3")
  }

  // MARK: TC10 — 넘친 행(참고문헌 URL 등)은 밴드를 가르지 않는다 (개정 2 §6, 넘침)

  @Test func overflowingRowStaysInColumnFlowWithoutSplittingBand() {
    // L/R 2단 4행(extent=300, TC1과 같은 배치) 중 L2가 클래스 폭의 60%를 넘는 184pt까지
    // 넘쳐 전폭(커버리지 제외)이지만, 왼쪽 가장자리(x=0)에서 시작하고 오른쪽 여백
    // (maxEnd300−anchor36=264)에 184가 못 미쳐(차 116>36) 넘침(overrun)으로 분류돼
    // 열0 흐름에 남는다. R2(x=200)와는 16pt 간격(>12pt)을 둬 세그먼트가 합쳐지지 않게
    // 한다.
    let overflowText = String(repeating: "L", count: 23) // 23×8=184pt.
    let l1 = Self.makeRun(text: "L1", origin: CGPoint(x: 0, y: 700), advanceStep: 50)
    let r1 = Self.makeRun(text: "R1", origin: CGPoint(x: 200, y: 700), advanceStep: 50)
    let l2 = Self.makeRun(text: overflowText, origin: CGPoint(x: 0, y: 688))
    let r2 = Self.makeRun(text: "R2", origin: CGPoint(x: 200, y: 688), advanceStep: 50)
    let l3 = Self.makeRun(text: "L3", origin: CGPoint(x: 0, y: 676), advanceStep: 50)
    let r3 = Self.makeRun(text: "R3", origin: CGPoint(x: 200, y: 676), advanceStep: 50)
    let l4 = Self.makeRun(text: "L4", origin: CGPoint(x: 0, y: 664), advanceStep: 50)
    let r4 = Self.makeRun(text: "R4", origin: CGPoint(x: 200, y: 664), advanceStep: 50)
    let content = TextAssembler.assemble([l1, r1, l2, r2, l3, r3, l4, r4], pageIndex: 0)
    #expect(content.string == "L1\n\(overflowText)\nL3\nL4\nR1\nR2\nR3\nR4")
  }

  // MARK: TC11 — 희소 열(오른쪽 열이 2행뿐)도 tolerance 0 첫 패스로 분리된다 (개정 1 §b)

  @Test func sparseRightColumnStillSeparatesFromLeftColumn() {
    var runs: [RawGlyphRun] = []
    for row in 0..<12 {
      let y = 700 - CGFloat(row) * 12
      runs.append(
        Self.makeRun(text: "L\(row + 1)", origin: CGPoint(x: 0, y: y), advanceStep: 50)
      )
    }
    runs.append(Self.makeRun(text: "R1", origin: CGPoint(x: 200, y: 700), advanceStep: 50))
    runs.append(Self.makeRun(text: "R2", origin: CGPoint(x: 200, y: 688), advanceStep: 50))
    let content = TextAssembler.assemble(runs, pageIndex: 0)
    let expectedLeft = (1...12).map { "L\($0)" }.joined(separator: "\n")
    #expect(content.string == "\(expectedLeft)\nR1\nR2")
  }

  // MARK: TC12 — 들여쓴 전폭 제목은 여전히 밴드 구분 (개정 2 §6, 구분선)

  @Test func indentedWideTitleStillSplitsBand() {
    // columnMinStart[0](=L의 최소 start 0) + anchor(edgeAnchorFactor(3.0)×fontSize12=36)
    // 보다 오른쪽(x=40)에서 시작 — 넘침(overrun)의 "시작점" 조건이 아예 성립하지 않아
    // (오른쪽 여백에 닿든 안 닿든) 구분선으로 남는다.
    let title = Self.makeRun(text: "Title", origin: CGPoint(x: 40, y: 712), advanceStep: 52)
    var runs = [title]
    runs.append(
      contentsOf: Self.twoColumnRuns(
        leftOrigin: CGPoint(x: 0, y: 700), rightOrigin: CGPoint(x: 200, y: 700), rowStep: 12,
        rightYOffset: 0, rowCount: 2
      )
    )
    let content = TextAssembler.assemble(runs, pageIndex: 0)
    #expect(content.string == "Title\nL1\nL2\nR1\nR2")
  }

  // MARK: TC13 — 오른쪽 넘침(우측 열의 URL형 run)도 열 흐름에 남는다 (개정 2 §6, 넘침)

  @Test func rightOverflowStaysInColumnFlow() {
    // R2가 R1/R3/R4(x=200..300)보다 훨씬 오른쪽(x=200..450)까지 넘친다 — R2 자신이
    // extent(=450)를 정의하지만 폭(250)이 wideLineFraction(0.6×450=270) 미달이라
    // "전폭"이 아니고, 거터(100..200)도 가로지르지 않아(시작이 거터 끝과 같음) 그냥
    // 일반 세그먼트로 열1에 남는다 — 오른쪽 넘침이 열 흐름을 깨지 않음을 확인한다.
    let l1 = Self.makeRun(text: "L1", origin: CGPoint(x: 0, y: 700), advanceStep: 50)
    let r1 = Self.makeRun(text: "R1", origin: CGPoint(x: 200, y: 700), advanceStep: 50)
    let l2 = Self.makeRun(text: "L2", origin: CGPoint(x: 0, y: 688), advanceStep: 50)
    let r2 = Self.makeRun(text: "R2", origin: CGPoint(x: 200, y: 688), advanceStep: 125)
    let l3 = Self.makeRun(text: "L3", origin: CGPoint(x: 0, y: 676), advanceStep: 50)
    let r3 = Self.makeRun(text: "R3", origin: CGPoint(x: 200, y: 676), advanceStep: 50)
    let l4 = Self.makeRun(text: "L4", origin: CGPoint(x: 0, y: 664), advanceStep: 50)
    let r4 = Self.makeRun(text: "R4", origin: CGPoint(x: 200, y: 664), advanceStep: 50)
    let content = TextAssembler.assemble([l1, r1, l2, r2, l3, r3, l4, r4], pageIndex: 0)
    #expect(content.string == "L1\nL2\nL3\nL4\nR1\nR2\nR3\nR4")
  }

  // MARK: TC14 — 양쪽 정렬 전폭 캡션 3행 — 짧은 마지막 행은 아래 밴드 열 0에 합류

  @Test func justifiedWideCaptionBlockSplitsSurroundingColumns() {
    // 2단 2행 블록 사이에 전폭 캡션 3행 — Cap1·Cap2는 양쪽 여백(0..300)에 닿아 구분선,
    // Cap3(0..120, 40%)는 전폭도 브리지도 아닌 일반 세그먼트라 열0 중심 배정으로
    // 아래 블록의 열0 첫 행이 된다(§6 라티오네일 예시와 동일 순서).
    var runs = Self.twoColumnRuns(
      leftOrigin: CGPoint(x: 0, y: 700), rightOrigin: CGPoint(x: 200, y: 700), rowStep: 12,
      rightYOffset: 0, rowCount: 2
    )
    runs.append(Self.makeRun(text: "Cap1", origin: CGPoint(x: 0, y: 676), advanceStep: 75))
    runs.append(Self.makeRun(text: "Cap2", origin: CGPoint(x: 0, y: 664), advanceStep: 75))
    runs.append(Self.makeRun(text: "Cap3", origin: CGPoint(x: 0, y: 652), advanceStep: 30))
    runs.append(
      contentsOf: Self.twoColumnRuns(
        leftOrigin: CGPoint(x: 0, y: 640), rightOrigin: CGPoint(x: 200, y: 640), rowStep: 12,
        rightYOffset: 0, rowCount: 2, rowStartIndex: 3
      )
    )
    let content = TextAssembler.assemble(runs, pageIndex: 0)
    #expect(content.string == "L1\nL2\nR1\nR2\nCap1\nCap2\nCap3\nL3\nL4\nR3\nR4")
  }

  // MARK: TC15 — 브리지가 라인 수/10보다 많아도 허용치 상승 반복으로 분리된다 (개정 3)

  @Test func toleranceEscalationSeparatesWhenBridgeLinesExceedLineCountHeuristic() {
    // 2단 6행(L·R 각 6, extent=300) 위에 센터 브리지 3행 — 브리지(x=85..215, 폭130)는
    // 전폭 미달(130<0.6×300=180)이라 커버리지에 남아 L(0..100)~R(200..300) 사이를 완전히
    // 메운다(peak=9,cap=4) — tolerance 0~2에서는 거터가 안 닫히고 4에서 닫힌다. 브리지
    // 시작(85)은 columnMinStart[0]+anchor(0+36)보다 오른쪽이라 넘침이 아닌 구분선이다.
    var runs: [RawGlyphRun] = []
    runs.append(Self.makeRun(text: "B1", origin: CGPoint(x: 85, y: 724), advanceStep: 65))
    runs.append(Self.makeRun(text: "B2", origin: CGPoint(x: 85, y: 712), advanceStep: 65))
    runs.append(Self.makeRun(text: "B3", origin: CGPoint(x: 85, y: 700), advanceStep: 65))
    for row in 0..<6 {
      let y = 688 - CGFloat(row) * 12
      runs.append(
        Self.makeRun(text: "L\(row + 1)", origin: CGPoint(x: 0, y: y), advanceStep: 50)
      )
      runs.append(
        Self.makeRun(text: "R\(row + 1)", origin: CGPoint(x: 200, y: y), advanceStep: 50)
      )
    }
    let content = TextAssembler.assemble(runs, pageIndex: 0)
    let expectedLeft = (1...6).map { "L\($0)" }.joined(separator: "\n")
    let expectedRight = (1...6).map { "R\($0)" }.joined(separator: "\n")
    #expect(content.string == "B1\nB2\nB3\n\(expectedLeft)\n\(expectedRight)")
  }

  // MARK: TC16 — 폭 붕괴 입력은 y 순서 유지 (개정 4, 폭 건전성 게이트)

  @Test func brokenAdvanceWidthsSkipColumnOrderingAndKeepYOrder() {
    // TC1과 같은 배치(2단 3행)지만 advanceStep을 origin 간격(50)의 5%(2.5)로 줄인다 —
    // 라인별 fill(run 폭 합/스팬)이 advanceSanityFraction(0.5)에 크게 못 미쳐 폭 추출이
    // 깨진 것으로 보고 `orderByColumns`가 입력 라인을 그대로 반환해야 한다.
    let brokenRuns = Self.twoColumnRuns(
      leftOrigin: CGPoint(x: 0, y: 700), rightOrigin: CGPoint(x: 200, y: 700), rowStep: 12,
      rightYOffset: 0, leftAdvanceStep: 2.5, rightAdvanceStep: 2.5
    )
    var lines: [[TextAssembler.RunEntry]] = []
    for index in stride(from: 0, to: brokenRuns.count, by: 2) {
      let left = TextAssembler.RunEntry(originalIndex: index, run: brokenRuns[index])
      let right = TextAssembler.RunEntry(originalIndex: index + 1, run: brokenRuns[index + 1])
      lines.append([left, right])
    }
    let ordered = TextAssembler.orderByColumns(lines)
    #expect(ordered.count == lines.count)
    for (orderedLine, originalLine) in zip(ordered, lines) {
      let orderedIndices = orderedLine.map { $0.originalIndex }
      let originalIndices = originalLine.map { $0.originalIndex }
      #expect(orderedIndices == originalIndices)
    }

    // 정상 advanceStep(TC1)은 여전히 열 분리.
    let normalRuns = Self.twoColumnRuns(
      leftOrigin: CGPoint(x: 0, y: 700), rightOrigin: CGPoint(x: 200, y: 700), rowStep: 12,
      rightYOffset: 0
    )
    let normalContent = TextAssembler.assemble(normalRuns, pageIndex: 0)
    #expect(normalContent.string == "L1\nL2\nL3\nR1\nR2\nR3")
  }
}

// MARK: - 테스트 헬퍼

extension TextAssemblerColumnTests {
  /// 좌/우 2단 run들을 3행(기본) 만든다 — "L1".."Ln"(좌), "R1".."Rn"(우), y는 행마다
  /// `rowStep`씩 감소(위→아래), 우측 열은 `rightYOffset`만큼 y를 더한다(베이스라인 어긋남
  /// 재현용).
  static func twoColumnRuns(
    leftOrigin: CGPoint, rightOrigin: CGPoint, rowStep: CGFloat, rightYOffset: CGFloat,
    rowCount: Int = 3, leftAdvanceStep: CGFloat = 50, rightAdvanceStep: CGFloat = 50,
    rowStartIndex: Int = 1
  ) -> [RawGlyphRun] {
    var runs: [RawGlyphRun] = []
    for row in 0..<rowCount {
      let index = rowStartIndex + row
      let dy = CGFloat(row) * rowStep
      runs.append(
        Self.makeRun(
          text: "L\(index)", origin: CGPoint(x: leftOrigin.x, y: leftOrigin.y - dy),
          advanceStep: leftAdvanceStep
        )
      )
      runs.append(
        Self.makeRun(
          text: "R\(index)",
          origin: CGPoint(x: rightOrigin.x, y: rightOrigin.y - dy + rightYOffset),
          advanceStep: rightAdvanceStep
        )
      )
    }
    return runs
  }

  /// 단순 원시 run을 만든다 (`TextAssemblerTests.makeRun`과 동일 스타일, fontSize 12 고정).
  static func makeRun(
    text: String, origin: CGPoint, direction: CGVector = CGVector(dx: 1, dy: 0),
    advanceStep: CGFloat = 8
  ) -> RawGlyphRun {
    let units = Array(text.utf16)
    let advances = Array(repeating: advanceStep, count: units.count)
    let degenerateQuad = Quad(
      bottomLeft: origin, bottomRight: origin, topRight: origin, topLeft: origin
    )
    return RawGlyphRun(
      utf16: units, advances: advances, quad: degenerateQuad, origin: origin,
      baselineDirection: direction, effectiveFontSize: 12, isInvisible: false, isVertical: false
    )
  }
}
