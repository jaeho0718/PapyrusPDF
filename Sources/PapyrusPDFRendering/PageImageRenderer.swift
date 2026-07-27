import CoreGraphics
import PapyrusPDFCore

/// OCR 등 외부 처리를 위해 페이지 전체를 이미지로 렌더하는 렌더러입니다.
///
/// 산출 이미지는 뷰어가 그리는 것과 같은 표시 공간 래스터입니다 — 좌상단이 원점이고
/// y축이 아래로 향하며, 페이지 회전이 반영된 정립(upright) 방향으로, 크기는
/// `PageInfo.displaySize`에 `scale`을 곱한 픽셀입니다. 이 이미지 위의 정규화 좌표는
/// y축만 뒤집으면 `PageInfo.pageQuad(normalizedDisplayRect:)`에 바로 전달할 수 있습니다.
///
/// 인스턴스 하나가 렌더용 문서 자원 한 벌을 소유하고 렌더를 직렬화합니다 — OCR
/// 프로바이더가 인스턴스를 보유하고 재사용하세요. 여러 페이지를 병렬로 렌더하려면
/// 인스턴스를 여러 개 만듭니다 (각각 문서 자원을 따로 가집니다).
public struct PageImageRenderer: Sendable {
  /// 기본 렌더 배율입니다 (표시 크기 pt당 3픽셀 ≈ 216DPI — 일반 본문 OCR에 충분합니다).
  public static let defaultScale: CGFloat = 3

  /// 렌더 대상 문서입니다.
  private let document: PapyrusPDFDocument

  /// 래스터화를 직렬화하는 내부 워커입니다 (문서당 CGPDFDocument 한 벌 지연 생성).
  private let worker: RenderWorker

  /// 문서의 페이지 이미지 렌더러를 만듭니다. 이 시점에는 렌더 자원을 만들지 않습니다
  /// (첫 렌더 시 지연 생성).
  /// - Parameter document: 렌더할 문서입니다 (열린 상태).
  public init(document: PapyrusPDFDocument) {
    self.document = document
    self.worker = RenderWorker(documentData: document.core.sourceBytes, pixelScale: 1)
  }

  /// 페이지 하나를 표시 공간 이미지로 렌더합니다.
  ///
  /// 배율이 유한한 양수가 아니면 기본값으로 교정되고, 산출 픽셀 크기는 내부 최장변
  /// 상한에서 자동으로 줄어듭니다 — 어떤 배율 입력도 실패나 과도한 메모리를 만들지
  /// 않습니다. 이미지는 캐시되지 않습니다 — 반환 즉시 호출자 소유입니다.
  /// - Parameters:
  ///   - pageIndex: 렌더할 페이지 인덱스입니다 (0 기반).
  ///   - scale: 표시 크기(pt)당 픽셀 수입니다 (기본 ``defaultScale``).
  /// - Returns: 표시 공간 래스터 이미지입니다.
  /// - Throws: ``RenderError`` — 페이지가 없으면 ``RenderError/pageUnavailable(pageIndex:)``,
  ///   렌더 백엔드가 문서를 해석하지 못하면 ``RenderError/documentUnavailable``,
  ///   비트맵 생성 실패는 ``RenderError/imageCreationFailed``, 태스크 취소는
  ///   ``RenderError/cancelled``입니다.
  public func image(
    forPage pageIndex: Int, scale: CGFloat = PageImageRenderer.defaultScale
  ) async throws(RenderError) -> CGImage {
    let info: PageInfo
    do {
      info = try await self.document.page(at: pageIndex)
    } catch {
      throw Self.mapDocumentError(error, pageIndex: pageIndex)
    }
    let rendered = try await self.worker.renderPageImage(
      pageIndex: pageIndex, pageSize: info.displaySize, scale: scale
    )
    return rendered.image
  }

  /// `PapyrusPDFDocument.page(at:)`의 ``PapyrusPDFError``를 단일 ``RenderError`` 도메인으로
  /// 사상한다 (§7.0-5).
  /// - Parameters:
  ///   - error: 사상할 문서 에러.
  ///   - pageIndex: 요청한 페이지 인덱스 (`pageUnavailable`의 진단값으로 쓰인다).
  /// - Returns: 사상된 렌더 에러.
  private static func mapDocumentError(_ error: PapyrusPDFError, pageIndex: Int) -> RenderError {
    switch error {
    case .pageOutOfRange:
      return .pageUnavailable(pageIndex: pageIndex)
    case .cancelled:
      return .cancelled
    default:
      return .documentUnavailable
    }
  }
}
