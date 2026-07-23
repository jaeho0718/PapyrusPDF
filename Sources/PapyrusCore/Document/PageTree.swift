import CoreGraphics

/// 페이지 트리 평탄화의 최종 산출물. 생성 이후 불변.
package struct PageTreeSnapshot: Sendable {
  /// 문서 순서(전위 순회의 잎 순서)대로의 페이지 레코드.
  package let records: [PageRecord]

  /// 객체 번호 → 페이지 인덱스 역맵 (목차 목적지 해소에 사용).
  package let pageIndexByObjectNumber: [Int: Int]

  /// 페이지 수 (== `records.count` — /Count 주장값이 아니라 실측이다).
  package var pageCount: Int {
    self.records.count
  }

  /// 스냅숏을 생성한다.
  /// - Parameters:
  ///   - records: 문서 순서대로의 페이지 레코드.
  ///   - pageIndexByObjectNumber: 객체 번호 → 페이지 인덱스 역맵.
  package init(records: [PageRecord], pageIndexByObjectNumber: [Int: Int]) {
    self.records = records
    self.pageIndexByObjectNumber = pageIndexByObjectNumber
  }
}

/// 페이지 트리 순회 중 하향 전파되는 상속 속성 묶음 + 정규화 헬퍼.
/// 순수 값 타입 — 알고리즘은 페이지 트리 평탄화(`buildPageTree`)가 소유한다.
package struct PageInheritedAttributes: Sendable, Equatable {
  /// 상속된 /MediaBox (미설정이면 `nil`).
  package var mediaBox: CGRect?

  /// 상속된 /CropBox (미설정이면 `nil`).
  package var cropBox: CGRect?

  /// 상속된 /Rotate 정규화 값 (미설정이면 `nil`).
  package var rotationDegrees: Int?

  /// 상속된 /Resources 원값 (미설정이면 `nil`).
  package var resources: COSObject?

  /// 전 필드 미설정 상태로 생성한다 (루트 노드 진입 시 사용).
  package init() {
    self.mediaBox = nil
    self.cropBox = nil
    self.rotationDegrees = nil
    self.resources = nil
  }

  /// 노드 자신의 속성값(이미 해소된 직접값)으로 덮어쓴 사본을 만든다 (자식이 이긴다).
  /// - Parameters:
  ///   - mediaBox: 노드 자신의 /MediaBox (없으면 `nil` — 상속값 유지).
  ///   - cropBox: 노드 자신의 /CropBox (없으면 `nil` — 상속값 유지).
  ///   - rotationDegrees: 노드 자신의 /Rotate (없으면 `nil` — 상속값 유지).
  ///   - resources: 노드 자신의 /Resources (없으면 `nil` — 상속값 유지).
  /// - Returns: 덮어쓴 사본.
  package func overriding(
    mediaBox: CGRect?, cropBox: CGRect?, rotationDegrees: Int?, resources: COSObject?
  ) -> PageInheritedAttributes {
    var copy = self
    if let mediaBox {
      copy.mediaBox = mediaBox
    }
    if let cropBox {
      copy.cropBox = cropBox
    }
    if let rotationDegrees {
      copy.rotationDegrees = rotationDegrees
    }
    if let resources {
      copy.resources = resources
    }
    return copy
  }
}

/// 페이지 기하 정규화 유틸 (순수 함수 모음).
package enum PageGeometry {
  /// MediaBox 부재 시의 기본값 — US Letter (0, 0, 612, 792).
  /// 스펙에 기본값은 없으나 주요 구현(Adobe/PDFBox)의 관례를 따른다.
  package static let defaultMediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)

  /// COS 배열 `[x0 y0 x1 y1]`을 정규화된 CGRect로 만든다 (모서리 순서 뒤집힘 허용).
  /// 원소 4개 미만·비숫자·비유한값·퇴화(면적 0)면 `nil`.
  /// - Parameter elements: COS 배열 원소 (사전 해소된 값이어야 한다).
  /// - Returns: 정규화된 사각형, 또는 실패 시 `nil`.
  package static func rectangle(from elements: [COSObject]) -> CGRect? {
    guard elements.count >= 4,
      let x0 = elements[0].realValue, x0.isFinite,
      let y0 = elements[1].realValue, y0.isFinite,
      let x1 = elements[2].realValue, x1.isFinite,
      let y1 = elements[3].realValue, y1.isFinite
    else {
      return nil
    }
    let rect = CGRect(
      x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)
    )
    guard rect.width > 0, rect.height > 0 else {
      return nil
    }
    return rect
  }

  /// /Rotate 값을 0/90/180/270으로 정규화한다. 음수는 모듈러 보정, 90의 배수가
  /// 아니면 0 (관용). 예: -90 → 270, 450 → 90, 45 → 0.
  /// - Parameter raw: 원본 /Rotate 정수값 (부재면 `nil`).
  /// - Returns: 정규화된 회전 값 (0/90/180/270).
  package static func normalizedRotation(_ raw: Int?) -> Int {
    guard let raw, raw % 90 == 0 else {
      return 0
    }
    let remainder = raw % 360
    return remainder < 0 ? remainder + 360 : remainder
  }
}
