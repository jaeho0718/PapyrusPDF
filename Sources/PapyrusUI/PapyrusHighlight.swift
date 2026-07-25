import CoreGraphics
import Foundation
import PapyrusCore

/// 하이라이트 색입니다 (sRGB 성분, 0...1 — `Codable` 직렬화 친화).
///
/// 성분은 저장 시 검증하지 않고 그대로 보존합니다 — 앱 데이터의 왕복 충실도를
/// 우선합니다. 렌더 시점에 0...1로 클램프되며, 유한하지 않은 성분은 0으로
/// 취급됩니다.
public struct HighlightColor: Sendable, Hashable, Codable {
  /// 빨강 성분입니다 (0...1).
  public var red: Double
  /// 초록 성분입니다 (0...1).
  public var green: Double
  /// 파랑 성분입니다 (0...1).
  public var blue: Double
  /// 불투명도입니다 (0...1 — 지속 하이라이트는 반투명 채움을 전제합니다).
  public var alpha: Double

  /// 색을 생성합니다.
  /// - Parameters:
  ///   - red: 빨강 성분입니다 (0...1).
  ///   - green: 초록 성분입니다 (0...1).
  ///   - blue: 파랑 성분입니다 (0...1).
  ///   - alpha: 불투명도입니다 (0...1).
  public init(red: Double, green: Double, blue: Double, alpha: Double) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  /// 노랑 프리셋입니다 (채움 전용 — 밑줄·취소선 스타일은 제공하지 않습니다).
  public static let yellow = HighlightColor(red: 1, green: 0.9, blue: 0.2, alpha: 0.4)
  /// 초록 프리셋입니다.
  public static let green = HighlightColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 0.4)
  /// 파랑 프리셋입니다.
  public static let blue = HighlightColor(red: 0.35, green: 0.65, blue: 1, alpha: 0.4)
  /// 분홍 프리셋입니다.
  public static let pink = HighlightColor(red: 1, green: 0.45, blue: 0.65, alpha: 0.4)
  /// 주황 프리셋입니다.
  public static let orange = HighlightColor(red: 1, green: 0.6, blue: 0.2, alpha: 0.4)
}

extension HighlightColor {
  /// 렌더용 CGColor (성분 클램프 + 비유한 → 0). 같은 모듈의 오버레이 전용.
  package var cgColor: CGColor {
    CGColor(
      srgbRed: Self.clamped(self.red), green: Self.clamped(self.green),
      blue: Self.clamped(self.blue), alpha: Self.clamped(self.alpha)
    )
  }

  /// 성분 하나를 렌더 안전한 0...1로 만든다 (비유한은 0).
  private static func clamped(_ component: Double) -> CGFloat {
    guard component.isFinite else {
      return 0
    }
    return CGFloat(min(max(component, 0), 1))
  }
}

/// 지속 하이라이트 하나입니다 (영속화는 앱 책임 — `Codable` 왕복을 보장합니다).
///
/// JSON 형식(자동 합성): `{"id": "...", "pageIndex": 3, "quads": [...],
/// "color": {"red": 1, ...}, "range": [10, 24]}` — `range`는 없으면 생략됩니다.
public struct Highlight: Identifiable, Sendable, Equatable, Codable {
  /// 식별자입니다 (기본 UUID 문자열 — 앱 저장소 키로 그대로 사용 가능합니다).
  /// 같은 id를 다시 등록하면 기존 항목이 대체됩니다.
  public let id: String
  /// 페이지 인덱스입니다 (0 기반).
  public let pageIndex: Int
  /// 하이라이트 quad들입니다 (PDF 페이지 공간 — 라인당 1개가 관례이나 강제하지
  /// 않습니다).
  public let quads: [Quad]
  /// 색입니다.
  public let color: HighlightColor
  /// 대응하는 페이지 문자열 UTF-16 구간입니다 (``PapyrusReaderModel/makeHighlights(from:color:)``가
  /// 채웁니다 — 앱의 역참조용이며 렌더링에는 쓰이지 않습니다).
  public let range: Range<Int>?

  /// 하이라이트를 생성합니다.
  /// - Parameters:
  ///   - id: 식별자입니다 (기본 UUID 문자열).
  ///   - pageIndex: 페이지 인덱스입니다 (0 기반).
  ///   - quads: 하이라이트 quad들입니다 (PDF 페이지 공간).
  ///   - color: 색입니다.
  ///   - range: 대응하는 페이지 문자열 UTF-16 구간입니다 (기본 `nil`).
  public init(
    id: String = UUID().uuidString, pageIndex: Int, quads: [Quad],
    color: HighlightColor, range: Range<Int>? = nil
  ) {
    self.id = id
    self.pageIndex = pageIndex
    self.quads = quads
    self.color = color
    self.range = range
  }
}
