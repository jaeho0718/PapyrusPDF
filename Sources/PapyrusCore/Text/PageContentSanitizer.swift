import CoreGraphics
import Foundation

/// 프로바이더 입력 위생 (핵심 불변식의 외부 입력 확장 — 크래시/무한루프/메모리 폭주 방지).
package enum PageContentSanitizer {
  /// 콘텐츠를 검증하고 필요 시 교정본을 반환한다.
  ///
  /// 깨끗한 입력(내장 추출 결과의 정상 경로)은 1패스 검사만 하고 **원본을 그대로**
  /// 반환한다 — 복사·정렬 비용 0. 교정 규칙은 결정적이며 판정 순서는 다음과 같다:
  /// 1. 문자열이 ``CoreLimits/maxProviderStringUTF16``을 넘으면 문자 경계로 절단한다.
  /// 2. quad 좌표에 비유한 값이 있는 run은 폐기한다.
  /// 3. `range`가 문자열 길이를 벗어나면 클램프하고, 줄어든 만큼 advances를 함께 절단한다
  ///    (빈 구간이 되면 run을 폐기한다).
  /// 4. `advances.count != range.count`이거나 advance에 비유한·음수가 있으면 균등
  ///    advance로 교체한다 (quad는 유효하므로 폐기 대신 정밀도만 낮춘다).
  /// 5. 살아남은 run의 `range.count` 누적이 ``CoreLimits/maxGlyphsPerPage``를 넘으면
  ///    그 시점 이후 run을 전부 폐기한다.
  /// 6. `range.lowerBound`가 오름차순이 아니면 `(lowerBound, upperBound, 원래 인덱스)`
  ///    3중 키로 정렬한다 (겹침 run의 동률은 upperBound, 그마저 같으면 원래 인덱스로 결정).
  /// 7. `pageIndex`가 `expectedPageIndex`와 다르면 재기입한다.
  ///
  /// run 간 `range` 겹침은 폐기하지 않는다 (OCR 소스에서 발생 가능 — 교차 탐색·히트테스트
  /// 모두 겹침에서 안전하다. 이진 탐색은 `lowerBound` 단조만 요구한다).
  /// - Parameters:
  ///   - content: 검사할 콘텐츠.
  ///   - expectedPageIndex: 요청한 페이지 인덱스 (결과의 `pageIndex`가 이 값과 일치해야 한다).
  /// - Returns: 위생 검사를 통과한 콘텐츠 (깨끗한 입력은 원본과 동일한 값).
  package static func sanitize(
    _ content: PageTextContent, expectedPageIndex: Int
  ) -> PageTextContent {
    if Self.isClean(content, expectedPageIndex: expectedPageIndex) {
      return content
    }
    return Self.correct(content, expectedPageIndex: expectedPageIndex)
  }

  /// 교정이 전혀 필요 없는지 1패스로 검사한다 (할당 없음 — fast path 전용).
  /// - Parameters:
  ///   - content: 검사할 콘텐츠.
  ///   - expectedPageIndex: 요청한 페이지 인덱스.
  /// - Returns: 규칙 1~7 전부를 이미 만족하면 `true`.
  private static func isClean(_ content: PageTextContent, expectedPageIndex: Int) -> Bool {
    guard content.pageIndex == expectedPageIndex else {
      return false
    }
    let stringUTF16Count = content.string.utf16.count
    guard stringUTF16Count <= CoreLimits.maxProviderStringUTF16 else {
      return false
    }
    var previousLowerBound = Int.min
    var glyphCount = 0
    for run in content.runs {
      guard run.range.lowerBound >= 0, run.range.upperBound <= stringUTF16Count,
        run.range.lowerBound < run.range.upperBound
      else {
        return false
      }
      guard run.range.lowerBound >= previousLowerBound else {
        return false
      }
      guard Self.hasFiniteQuad(run.quad) else {
        return false
      }
      guard run.advances.count == run.range.count,
        run.advances.allSatisfy({ $0.isFinite && $0 >= 0 })
      else {
        return false
      }
      glyphCount += run.range.count
      guard glyphCount <= CoreLimits.maxGlyphsPerPage else {
        return false
      }
      previousLowerBound = run.range.lowerBound
    }
    return true
  }

  /// 규칙 1~7을 순서대로 적용해 교정본을 만든다 (더러운 입력 경로).
  /// - Parameters:
  ///   - content: 교정할 콘텐츠.
  ///   - expectedPageIndex: 결과에 각인할 페이지 인덱스.
  /// - Returns: 교정된 콘텐츠.
  private static func correct(
    _ content: PageTextContent, expectedPageIndex: Int
  ) -> PageTextContent {
    let (string, _) = Self.truncateStringIfNeeded(content.string)
    let stringUTF16Count = string.utf16.count

    var corrected: [TextRun] = []
    corrected.reserveCapacity(content.runs.count)
    var glyphCount = 0
    var needsSort = false
    var previousLowerBound = Int.min

    for run in content.runs {
      guard Self.hasFiniteQuad(run.quad) else {
        continue
      }
      guard let clamped = Self.clampRange(of: run, toStringLength: stringUTF16Count) else {
        continue
      }
      let fixed = Self.fixAdvancesIfNeeded(clamped)
      guard glyphCount + fixed.range.count <= CoreLimits.maxGlyphsPerPage else {
        break
      }
      glyphCount += fixed.range.count
      if fixed.range.lowerBound < previousLowerBound {
        needsSort = true
      }
      previousLowerBound = fixed.range.lowerBound
      corrected.append(fixed)
    }

    if needsSort {
      // (lowerBound, upperBound, 원래 인덱스) 3중 키 — 설계 §1.7 규칙 6. Swift `sort`는
      // 불안정이므로 lowerBound가 같은 겹침 run도 upperBound로, 그마저 같으면 원래
      // 인덱스로 순서를 결정해 결정성을 보장한다.
      corrected = corrected.enumerated()
        .sorted {
          if $0.element.range.lowerBound != $1.element.range.lowerBound {
            return $0.element.range.lowerBound < $1.element.range.lowerBound
          }
          if $0.element.range.upperBound != $1.element.range.upperBound {
            return $0.element.range.upperBound < $1.element.range.upperBound
          }
          return $0.offset < $1.offset
        }
        .map(\.element)
    }

    return PageTextContent(pageIndex: expectedPageIndex, string: string, runs: corrected)
  }

  /// 문자열이 상한을 넘으면 문자 경계 안쪽으로 절단한다.
  /// - Parameter string: 원본 문자열.
  /// - Returns: 절단 여부와 결과 문자열.
  private static func truncateStringIfNeeded(_ string: String) -> (String, Bool) {
    guard string.utf16.count > CoreLimits.maxProviderStringUTF16 else {
      return (string, false)
    }
    let utf16View = string.utf16
    let cutIndex = utf16View.index(
      utf16View.startIndex, offsetBy: CoreLimits.maxProviderStringUTF16
    )
    var snapped = cutIndex
    while snapped > utf16View.startIndex, String.Index(snapped, within: string) == nil {
      snapped = utf16View.index(before: snapped)
    }
    guard let boundary = String.Index(snapped, within: string) else {
      return ("", true)
    }
    return (String(string[string.startIndex..<boundary]), true)
  }

  /// run의 `range`를 문자열 길이 안으로 클램프하고, 줄어든 만큼 advances를 함께 자른다.
  /// - Parameters:
  ///   - run: 검사할 run.
  ///   - length: 절단 후 문자열의 UTF-16 길이.
  /// - Returns: 클램프된 run, 결과 구간이 비면 `nil` (run 폐기).
  private static func clampRange(of run: TextRun, toStringLength length: Int) -> TextRun? {
    let lower = min(max(run.range.lowerBound, 0), length)
    let upper = min(max(run.range.upperBound, lower), length)
    guard lower < upper else {
      return nil
    }
    guard lower != run.range.lowerBound || upper != run.range.upperBound else {
      return run
    }
    let lowerDelta = lower - run.range.lowerBound
    let newCount = upper - lower
    guard lowerDelta >= 0, lowerDelta + newCount <= run.advances.count else {
      // 원본 advances가 range.count와 이미 어긋난 병적 입력 — 절단 없이 규칙 4(균등 교체)로 넘긴다.
      return TextRun(
        range: lower..<upper, quad: run.quad, advances: run.advances, isInvisible: run.isInvisible
      )
    }
    let slicedAdvances = Array(run.advances[lowerDelta..<(lowerDelta + newCount)])
    return TextRun(
      range: lower..<upper, quad: run.quad, advances: slicedAdvances, isInvisible: run.isInvisible
    )
  }

  /// quad의 16개 성분이 전부 유한한지 검사한다.
  /// - Parameter quad: 검사할 quad.
  /// - Returns: 전부 유한하면 `true`.
  private static func hasFiniteQuad(_ quad: Quad) -> Bool {
    let points = [quad.bottomLeft, quad.bottomRight, quad.topRight, quad.topLeft]
    return points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
  }

  /// advances 개수·값이 유효하지 않으면 균등 advance로 교체한다.
  /// - Parameter run: 검사할 run.
  /// - Returns: advances가 유효하면 원본, 아니면 균등 advance로 교체한 run.
  private static func fixAdvancesIfNeeded(_ run: TextRun) -> TextRun {
    let isValid = run.advances.count == run.range.count
      && run.advances.allSatisfy { $0.isFinite && $0 >= 0 }
    guard !isValid else {
      return run
    }
    return TextRun.uniform(range: run.range, quad: run.quad, isInvisible: run.isInvisible)
  }
}
