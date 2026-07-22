import Foundation

/// 메모리맵 기반 읽기 전용 바이트 소스.
///
/// 파일을 `.alwaysMapped`로 열어 전체를 메모리에 올리지 않고 오프셋 기반
/// 랜덤 액세스를 제공한다. 테스트·인메모리 파싱용으로 `Data` 직접 입력도 받는다.
/// 인덱스는 항상 0 기반이다 (`Data` 슬라이스 입력은 init에서 재배치).
///
/// - Note: 매핑 중 외부에서 파일이 절단되면 SIGBUS가 발생할 수 있다. 이는 mmap
///   고유의 한계로, 다른 메모리맵 기반 PDF 리더(예: PDFKit)와 동일하게 수용한다.
package struct MappedFile: Sendable {
  /// 매핑되거나 복사된 원본 바이트. 항상 0 기반 인덱스를 갖는다.
  private let data: Data

  /// 전체 바이트 수.
  package var count: Int {
    self.data.count
  }

  /// 파일을 메모리맵으로 연다.
  /// - Parameter url: 열려는 파일의 위치.
  /// - Throws: 열기 실패 시 ``MappedFileError/openFailed(path:reason:)``.
  package init(url: URL) throws(MappedFileError) {
    do {
      self.data = try Data(contentsOf: url, options: [.alwaysMapped])
    } catch {
      throw MappedFileError.openFailed(path: url.path, reason: error.localizedDescription)
    }
  }

  /// 인메모리 바이트로 생성한다 (mmap 없음).
  ///
  /// `data.startIndex != 0`인 슬라이스는 1회 복사로 0 기반으로 재배치한다.
  /// - Parameter data: 원본 바이트.
  package init(data: Data) {
    if data.startIndex == 0 {
      self.data = data
    } else {
      self.data = Data(data)
    }
  }

  /// 경계 검사된 단일 바이트 접근. 범위 밖이면 `nil`.
  /// - Parameter offset: 0 기반 바이트 오프셋.
  /// - Returns: 해당 위치의 바이트, 범위를 벗어나면 `nil`.
  package func byte(at offset: Int) -> UInt8? {
    guard offset >= 0, offset < self.data.count else {
      return nil
    }
    return self.data[self.data.startIndex + offset]
  }

  /// 경계 검사된 구간 추출. 범위가 유효하지 않으면 `nil`.
  ///
  /// 반환 `Data`는 0 기반으로 재배치된 복사본이다 (스트림 페이로드 추출용).
  /// - Parameter range: 0 기반 바이트 구간.
  /// - Returns: 구간에 해당하는 바이트 복사본. 빈 구간이면 빈 `Data`, 범위가
  ///   유효하지 않으면 `nil`.
  package func bytes(in range: Range<Int>) -> Data? {
    guard range.lowerBound >= 0, range.upperBound <= self.data.count else {
      return nil
    }
    let base = self.data.startIndex
    let lower = base + range.lowerBound
    let upper = base + range.upperBound
    return Data(self.data[lower..<upper])
  }

  /// 전체 버퍼에 대한 무복사 접근 (M2 RecoveryScanner의 전역 스캔용 탈출구).
  ///
  /// - Warning: 포인터는 클로저 밖으로 탈출시켜서는 안 된다.
  /// - Parameter body: 원본 바이트 버퍼를 전달받는 클로저.
  /// - Returns: `body`의 반환값.
  package func withUnsafeBytes<R>(
    _ body: (UnsafeRawBufferPointer) throws -> R
  ) rethrows -> R {
    try self.data.withUnsafeBytes(body)
  }
}
