import CoreGraphics

/// 평탄화된 페이지 하나의 파싱 결과. 상속 속성이 모두 해소된 최종값이다.
package struct PageRecord: Sendable, Equatable {
  /// 페이지 객체 번호 (Kids 안 인라인 딕셔너리였으면 `nil` — 역맵에서 제외된다).
  package let objectNumber: Int?

  /// /MediaBox (상속 해소·정규화 완료). 부재 시 US Letter(612×792) 기본값.
  package let mediaBox: CGRect

  /// /CropBox (상속 해소·MediaBox와 교집합 완료). 부재·퇴화 시 mediaBox와 동일.
  package let cropBox: CGRect

  /// /Rotate 정규화 값 — 0/90/180/270 중 하나.
  package let rotationDegrees: Int

  /// /Resources (상속 해소, **미해소 원값** — 보통 `.reference` 또는 `.dictionary`).
  /// M4 텍스트 파이프라인이 소비한다. M3 공개 API로는 노출되지 않는다.
  package let resources: COSObject?

  /// /Contents 원값 (잎 노드 자신에서 포획, **미해소** — 보통 `.reference` 또는 `.array`).
  /// /Contents는 상속 속성이 아니다 (M4 텍스트 파이프라인이 소비한다).
  package let contents: COSObject?

  /// 페이지 레코드를 생성한다.
  /// - Parameters:
  ///   - objectNumber: 페이지 객체 번호 (인라인 kid면 `nil`).
  ///   - mediaBox: 상속 해소·정규화 완료된 /MediaBox.
  ///   - cropBox: 상속 해소·교집합 완료된 /CropBox.
  ///   - rotationDegrees: 정규화된 /Rotate 값 (0/90/180/270).
  ///   - resources: 상속 해소된 /Resources 원값 (미해소).
  ///   - contents: 잎 노드 자신의 /Contents 원값 (미해소).
  package init(
    objectNumber: Int?, mediaBox: CGRect, cropBox: CGRect,
    rotationDegrees: Int, resources: COSObject?, contents: COSObject? = nil
  ) {
    self.objectNumber = objectNumber
    self.mediaBox = mediaBox
    self.cropBox = cropBox
    self.rotationDegrees = rotationDegrees
    self.resources = resources
    self.contents = contents
  }
}

extension PageRecord {
  /// 회전을 반영한 표시 크기 (cropBox 기준, 90/270이면 가로·세로 교환).
  ///
  /// 공개 `PageInfo.displaySize`와 정의가 동일하다 — 렌더링·뷰어가 파서 기하를
  /// 진실 원천으로 공유하기 위한 package 접근점.
  package var displaySize: CGSize {
    PageGeometry.displaySize(
      cropBoxSize: self.cropBox.size, normalizedRotationDegrees: self.rotationDegrees
    )
  }
}
