import CoreGraphics
import Foundation

/// Form XObject 하나의 사전 해소 입력. resources가 재귀 중첩된다 (깊이 캡 16, 순환은
/// 방문 객체번호 집합으로 절단 — 절단 지점은 빈 리소스).
package struct FormXObjectInput: Sendable {
  /// 디코딩 완료된 콘텐츠.
  package var content: Data
  /// `/Matrix` (기본 항등).
  package var matrix: CGAffineTransform
  /// 폼 자신의 `/Resources` (재귀 해소 완료).
  package var resources: ResolvedResources

  /// Form XObject 입력을 생성한다.
  /// - Parameters:
  ///   - content: 디코딩 완료된 콘텐츠.
  ///   - matrix: `/Matrix` (기본 항등).
  ///   - resources: 폼 자신의 `/Resources` (재귀 해소 완료).
  package init(content: Data, matrix: CGAffineTransform, resources: ResolvedResources) {
    self.content = content
    self.matrix = matrix
    self.resources = resources
  }
}

/// `/Resources`에서 텍스트 추출에 필요한 부분만 사전 해소한 테이블.
package struct ResolvedResources: Sendable {
  /// `/Font` 리소스 이름 → 로딩 완료 폰트 (로딩 실패는 fallbackFont로 대체 — 키 유지).
  package var fonts: [COSName: LoadedFont]
  /// `/XObject` 중 `/Subtype /Form`만 (이미지 XObject는 미포함 — `Do`가 이름 미발견 시 무시).
  package var formXObjects: [COSName: FormXObjectInput]

  /// 해소된 리소스 테이블을 생성한다.
  /// - Parameters:
  ///   - fonts: `/Font` 리소스 이름 → 로딩 완료 폰트.
  ///   - formXObjects: `/XObject` 중 Form만.
  package init(
    fonts: [COSName: LoadedFont] = [:], formXObjects: [COSName: FormXObjectInput] = [:]
  ) {
    self.fonts = fonts
    self.formXObjects = formXObjects
  }
}

/// 액터가 사전 해소를 끝낸, 페이지 하나의 추출 입력 (전부 값 — Sendable).
package struct PageExtractionInput: Sendable {
  /// 디코딩·연결 준비가 끝난 콘텐츠 세그먼트들 (해석 시 공백 1바이트 삽입 개념으로 연결).
  package var contentSegments: [Data]
  /// 페이지 `/Resources` 해소 결과.
  package var resources: ResolvedResources
  /// 페이지 인덱스 (결과 스냅숏에 각인).
  package var pageIndex: Int

  /// 페이지 추출 입력을 생성한다.
  /// - Parameters:
  ///   - contentSegments: 디코딩·연결 준비가 끝난 콘텐츠 세그먼트들.
  ///   - resources: 페이지 `/Resources` 해소 결과.
  ///   - pageIndex: 페이지 인덱스.
  package init(contentSegments: [Data], resources: ResolvedResources, pageIndex: Int) {
    self.contentSegments = contentSegments
    self.resources = resources
    self.pageIndex = pageIndex
  }
}
