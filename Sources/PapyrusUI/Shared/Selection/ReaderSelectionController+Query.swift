import CoreGraphics
import PapyrusCore

// 이 파일은 `ReaderSelectionController`의 quad·핸들·문자열 조회(displayQuads/
// handlePlacement/handleHit/selectedString/selectedStringFromCache/menuAnchorRect)를
// 담는다 — 상태·이벤트 진입·통지는 `ReaderSelectionController.swift`, 해석·재계산은
// `+Resolution.swift` 참조. 설계 §5 한도 초과 시 파일 분할 허용에 따른 분리.

extension ReaderSelectionController {
  /// 페이지의 표시 공간 선택 quad (라인 병합 적용 — 캐시 미보유·선택 밖 페이지는 빈 배열).
  /// - Parameter pageIndex: 조회할 페이지 인덱스.
  /// - Returns: 표시 공간 quad 목록.
  package func displayQuads(forPage pageIndex: Int) -> [Quad] {
    guard let selection = self.selection, selection.pageRange.contains(pageIndex),
      let geometry = self.store.geometry(forPage: pageIndex)
    else {
      return []
    }
    guard
      let range = selection.utf16Range(
        onPage: pageIndex, pageUTF16Length: geometry.content.string.utf16.count
      )
    else {
      return []
    }
    return geometry.displayQuads(forRange: range)
  }

  /// 페이지의 핸들 배치 (iOS — 그 페이지에 선택 첫/끝 quad가 있을 때만 해당 항목 non-nil).
  /// - Parameter pageIndex: 조회할 페이지 인덱스.
  /// - Returns: 핸들 배치, 이 페이지에 핸들이 없으면 `nil`.
  package func handlePlacement(forPage pageIndex: Int) -> SelectionHandlePlacement? {
    guard let selection = self.selection else {
      return nil
    }
    let quads = self.displayQuads(forPage: pageIndex)
    guard !quads.isEmpty else {
      return nil
    }
    var start: SelectionHandlePlacement.Anchor?
    var end: SelectionHandlePlacement.Anchor?
    if selection.start.pageIndex == pageIndex, let firstQuad = quads.first {
      start = Self.startAnchor(for: firstQuad)
    }
    if selection.end.pageIndex == pageIndex, let lastQuad = quads.last {
      end = Self.endAnchor(for: lastQuad)
    }
    guard start != nil || end != nil else {
      return nil
    }
    return SelectionHandlePlacement(start: start, end: end)
  }

  /// 코너 시각(표시 y) 동률 판정 허용치 (pt) — `SelectionGeometry.axisAlignEpsilon`과
  /// 동일 규모(±0.25pt)로 맞춘 결정적 폴백 기준.
  private static let cornerTieEpsilon: CGFloat = 0.25

  /// 시작 핸들의 캐럿 선분: 왼변 두 끝점 중 표시 y가 **작은**(시각적으로 위) 쪽이
  /// `knobEnd`다 — 시작 핸들의 노브는 항상 위쪽에 온다. 병합 라인 quad는 `Quad(rect:)`로
  /// 만들어져 꼭짓점 이름(`topLeft`/`bottomLeft`)이 시각과 무관하므로 y값으로 직접
  /// 판정한다 — 이름 기준 매핑은 비병합(회전) quad에서만 우연히 일치해 두 경로가
  /// 불일치했다. 동률(수평 변, ε 이내)은 `topLeft`를 knobEnd로 하는 기존 매핑을 결정적
  /// 폴백으로 둔다.
  /// - Parameter quad: 선택 첫 quad.
  /// - Returns: 시작 핸들 캐럿 선분.
  private static func startAnchor(for quad: Quad) -> SelectionHandlePlacement.Anchor {
    let top = quad.topLeft
    let bottom = quad.bottomLeft
    guard abs(top.y - bottom.y) > Self.cornerTieEpsilon else {
      return SelectionHandlePlacement.Anchor(knobEnd: top, baseEnd: bottom)
    }
    return top.y < bottom.y
      ? SelectionHandlePlacement.Anchor(knobEnd: top, baseEnd: bottom)
      : SelectionHandlePlacement.Anchor(knobEnd: bottom, baseEnd: top)
  }

  /// 끝 핸들의 캐럿 선분: 오른변 두 끝점 중 표시 y가 **큰**(시각적으로 아래) 쪽이
  /// `knobEnd`다 — 끝 핸들의 노브는 항상 아래쪽에 온다. 동률(ε 이내)은 `bottomRight`를
  /// knobEnd로 하는 기존 매핑을 결정적 폴백으로 둔다 (`startAnchor` 주석 참조).
  /// - Parameter quad: 선택 끝 quad.
  /// - Returns: 끝 핸들 캐럿 선분.
  private static func endAnchor(for quad: Quad) -> SelectionHandlePlacement.Anchor {
    let bottom = quad.bottomRight
    let top = quad.topRight
    guard abs(bottom.y - top.y) > Self.cornerTieEpsilon else {
      return SelectionHandlePlacement.Anchor(knobEnd: bottom, baseEnd: top)
    }
    return bottom.y > top.y
      ? SelectionHandlePlacement.Anchor(knobEnd: bottom, baseEnd: top)
      : SelectionHandlePlacement.Anchor(knobEnd: top, baseEnd: bottom)
  }

  /// 핸들 히트테스트 (페이지 점 + 콘텐츠 pt 환산 반경).
  /// - Parameters:
  ///   - point: 히트테스트할 페이지 점.
  ///   - radius: 콘텐츠 pt 환산 히트 반경.
  /// - Returns: 히트된 핸들, 없으면 `nil`.
  package func handleHit(at point: PagePoint, radius: CGFloat) -> SelectionHandle? {
    guard let placement = self.handlePlacement(forPage: point.pageIndex) else {
      return nil
    }
    if let start = placement.start, Self.distance(point.point, start.knobEnd) <= radius {
      return .start
    }
    if let end = placement.end, Self.distance(point.point, end.knobEnd) <= radius {
      return .end
    }
    return nil
  }

  /// 선택 문자열 (페이지 경계 `"\n"` 결합, `UILimits` 캡 절단, 선택 없으면 `nil`).
  ///
  /// 진입 시점의 선택 스냅숏으로 조립을 완주한다 — 조립 중(await 사이) 선택이 바뀌어도
  /// 결과는 "누른 시점의 선택"을 반영한다. 페이지 문자열은 캐시 우선·미스 시 프로바이더
  /// 직행(`pageString(forPage:)`)으로 얻으며, 실패한 페이지는 빈 기여로 진행한다(§5.2 규약).
  /// - Returns: 조립된 선택 문자열, 선택이 없으면 `nil`.
  package func selectedString() async -> String? {
    guard let selection = self.selection, !selection.isEmpty else {
      return nil
    }
    var pieces: [String] = []
    var totalLength = 0
    for pageIndex in selection.pageRange {
      guard totalLength < UILimits.maxSelectedTextUTF16 else {
        break
      }
      let pageString = await self.pageString(forPage: pageIndex)
      let shouldStop = Self.appendFragment(
        of: pageString, forPage: pageIndex, in: selection, pieces: &pieces,
        totalLength: &totalLength
      )
      if shouldStop {
        break
      }
    }
    return pieces.joined(separator: "\n")
  }

  /// 동기 캐시 전용 조립 — 지오메트리 캐시에 선택 범위 전 페이지가 있을 때만 성공한다.
  ///
  /// macOS 우클릭(pull) 표면처럼 `await`할 수 없는 동기 경로의 폴백 전용이다. 진실
  /// 원천은 어디까지나 `selectedString()`이며, 이 메서드는 캐시가 아직 채워지지 않은
  /// 한 페이지라도 있으면 즉시 포기하고 `nil`을 반환한다(부분 조립을 반환하지 않는다).
  /// - Returns: 조립된 선택 문자열, 선택이 없거나 캐시 미스 페이지가 있으면 `nil`.
  package func selectedStringFromCache() -> String? {
    guard let selection = self.selection, !selection.isEmpty else {
      return nil
    }
    var pieces: [String] = []
    var totalLength = 0
    for pageIndex in selection.pageRange {
      guard totalLength < UILimits.maxSelectedTextUTF16 else {
        break
      }
      guard let pageString = self.store.geometry(forPage: pageIndex)?.content.string else {
        return nil
      }
      let shouldStop = Self.appendFragment(
        of: pageString, forPage: pageIndex, in: selection, pieces: &pieces,
        totalLength: &totalLength
      )
      if shouldStop {
        break
      }
    }
    return pieces.joined(separator: "\n")
  }

  /// 페이지 문자열 하나를 조각 배열에 반영한다 (경계 구간 추출 + 캡 절단) — `selectedString()`·
  /// `selectedStringFromCache()`가 공유하는 조립 단계 (캡·경계 스냅 규칙 중복 금지).
  /// - Parameters:
  ///   - pageString: 반영할 페이지 문자열.
  ///   - pageIndex: 그 페이지 인덱스.
  ///   - selection: 대상 선택.
  ///   - pieces: 누적 조각 배열 (반영 후 갱신).
  ///   - totalLength: 누적 UTF-16 길이 (반영 후 갱신).
  /// - Returns: 캡 절단으로 조립을 끝내야 하면 `true`.
  private static func appendFragment(
    of pageString: String, forPage pageIndex: Int, in selection: TextSelection,
    pieces: inout [String], totalLength: inout Int
  ) -> Bool {
    guard
      let utf16Range = selection.utf16Range(
        onPage: pageIndex, pageUTF16Length: pageString.utf16.count
      )
    else {
      pieces.append("")
      return false
    }
    let fragment = Self.substring(of: pageString, utf16Range: utf16Range)
    let remaining = UILimits.maxSelectedTextUTF16 - totalLength
    guard fragment.utf16.count <= remaining else {
      pieces.append(Self.snapToCharacterLimit(fragment, utf16Limit: remaining))
      return true
    }
    pieces.append(fragment)
    totalLength += fragment.utf16.count
    return false
  }

  /// 메뉴 앵커 rect (해당 페이지 quad 합집합 boundingRect — 코어가 콘텐츠 공간으로 변환).
  /// - Parameter pageIndex: 조회할 페이지 인덱스.
  /// - Returns: 합집합 사각형, 그 페이지에 quad가 없으면 `nil`.
  package func menuAnchorRect(forPage pageIndex: Int) -> CGRect? {
    let quads = self.displayQuads(forPage: pageIndex)
    guard let first = quads.first else {
      return nil
    }
    return quads.dropFirst().reduce(first.boundingRect) { $0.union($1.boundingRect) }
  }

  /// 페이지 문자열을 얻는다 (캐시 우선, 미스면 스토어의 프로바이더 직행 경로).
  /// - Parameter pageIndex: 조회할 페이지 인덱스.
  /// - Returns: 페이지 문자열 (실패 시 빈 문자열).
  private func pageString(forPage pageIndex: Int) async -> String {
    if let cached = self.store.geometry(forPage: pageIndex)?.content.string {
      return cached
    }
    return await self.store.pageString(forPage: pageIndex)
  }

  /// UTF-16 구간을 문자열 조각으로 변환한다 (경계 밖·정렬 실패는 빈 문자열).
  /// - Parameters:
  ///   - string: 원본 문자열.
  ///   - utf16Range: UTF-16 코드유닛 구간.
  /// - Returns: 변환된 조각.
  private static func substring(of string: String, utf16Range: Range<Int>) -> String {
    let utf16View = string.utf16
    guard
      let lower = utf16View.index(
        utf16View.startIndex, offsetBy: utf16Range.lowerBound, limitedBy: utf16View.endIndex
      ),
      let upper = utf16View.index(
        utf16View.startIndex, offsetBy: utf16Range.upperBound, limitedBy: utf16View.endIndex
      ),
      let lowerIndex = String.Index(lower, within: string),
      let upperIndex = String.Index(upper, within: string)
    else {
      return ""
    }
    return String(string[lowerIndex..<upperIndex])
  }

  /// 조각을 `utf16Limit` 안쪽 Character 경계로 스냅해 절단한다 (복사 총량 캡 절단 규칙).
  /// - Parameters:
  ///   - fragment: 절단할 조각.
  ///   - utf16Limit: 남은 UTF-16 코드유닛 한도.
  /// - Returns: 절단된 조각.
  private static func snapToCharacterLimit(_ fragment: String, utf16Limit: Int) -> String {
    guard utf16Limit > 0 else {
      return ""
    }
    let snapped = TextBoundary.snapToCharacterBoundary(utf16Limit, in: fragment)
    return Self.substring(of: fragment, utf16Range: 0..<snapped)
  }

  /// 두 점의 유클리드 거리.
  /// - Parameters:
  ///   - lhs: 첫 번째 점.
  ///   - rhs: 두 번째 점.
  /// - Returns: 두 점 사이 거리.
  private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    let dx = lhs.x - rhs.x
    let dy = lhs.y - rhs.y
    return (dx * dx + dy * dy).squareRoot()
  }
}
