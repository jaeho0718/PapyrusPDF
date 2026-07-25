import CoreGraphics
import Foundation
import PapyrusCore
import PapyrusRendering
import PapyrusTestSupport
import PapyrusUI
import QuartzCore
import Testing

/// `PapyrusUITests` 전용 최소 조립 헬퍼 (실제 CG 렌더 없이 비용 있는
/// `RenderedTile`/`RenderedPreview`를 조립하고, 픽스처로부터 `ReaderCore`를 만든다).
enum UITestSupport {
  /// `size` × `size` 픽셀의 단색 비트맵 이미지를 만든다 (테스트 값 조립용).
  static func makeImage(size: Int = 4) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo =
      CGImageAlphaInfo.noneSkipFirst.rawValue | CGImageByteOrderInfo.order32Host.rawValue
    guard
      let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: bitmapInfo
      ), let image = context.makeImage()
    else {
      preconditionFailure("test-only bitmap creation must succeed")
    }
    return image
  }

  /// 지정한 타일 하나를 만든다 (레이어 배치 검증용 — `pointRect`가 핵심 입력).
  static func makeTile(
    pageIndex: Int = 0, scaleBucket: ScaleBucket = ScaleBucket(exponent: 0),
    col: Int = 0, row: Int = 0,
    pointRect: CGRect = CGRect(x: 0, y: 0, width: 512, height: 512), cost: Int = 1
  ) -> RenderedTile {
    let key = TileKey(pageIndex: pageIndex, scaleBucket: scaleBucket, col: col, row: row)
    return RenderedTile(key: key, image: self.makeImage(), pointRect: pointRect, cost: cost)
  }

  /// 지정한 프리뷰 하나를 만든다.
  static func makePreview(pageIndex: Int = 0, cost: Int = 1) -> RenderedPreview {
    RenderedPreview(pageIndex: pageIndex, image: self.makeImage(), cost: cost)
  }

  /// 지정한 페이지 수·크기의 균일 문서로 `ReaderCore`를 조립한다 (메모리 압박 모니터는 끈다).
  @MainActor
  static func makeReaderCore(
    pageCount: Int, pageWidth: Double = 200, pageHeight: Double = 200,
    workerCount: Int = 2, pixelScale: CGFloat = 1
  ) async throws -> ReaderCore {
    let fixture = PDFFixtureBuilder(
      pageCount: pageCount, pageWidth: pageWidth, pageHeight: pageHeight
    ).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let pageSizes = try await document.pageTree().records.map(\.displaySize)
    let layout = ReaderLayoutEngine(pageSizes: pageSizes)
    let configuration = RenderConfiguration(
      workerCount: workerCount, pixelScale: pixelScale, installsMemoryPressureMonitor: false
    )
    let queue = TileRenderQueue(
      documentData: document.sourceBytes, pageSizes: pageSizes, configuration: configuration
    )
    return ReaderCore(layout: layout, renderQueue: queue)
  }

  /// 지정한 페이지 수·크기의 균일 문서로, 선택 컨트롤러를 주입한 `ReaderCore`를 조립한다
  /// (선택 통합 테스트 전용 — `ReaderCoreSelectionTests`).
  @MainActor
  static func makeReaderCore(
    pageCount: Int, pageWidth: Double = 200, pageHeight: Double = 200,
    workerCount: Int = 2, pixelScale: CGFloat = 1, selectionController: ReaderSelectionController
  ) async throws -> ReaderCore {
    let fixture = PDFFixtureBuilder(
      pageCount: pageCount, pageWidth: pageWidth, pageHeight: pageHeight
    ).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let pageSizes = try await document.pageTree().records.map(\.displaySize)
    let layout = ReaderLayoutEngine(pageSizes: pageSizes)
    let configuration = RenderConfiguration(
      workerCount: workerCount, pixelScale: pixelScale, installsMemoryPressureMonitor: false
    )
    let queue = TileRenderQueue(
      documentData: document.sourceBytes, pageSizes: pageSizes, configuration: configuration
    )
    return ReaderCore(
      layout: layout, renderQueue: queue, pixelScale: pixelScale,
      selectionController: selectionController
    )
  }

  /// 파서(레이아웃)가 실제 CGPDFDocument보다 페이지가 많다고 보는 손상 문서를
  /// 시뮬레이션한다 — `realPageCount` 뒤의 `phantomPageCount`장은 레이아웃·`pageSizes`에는
  /// 존재하지만 실제 CG 문서에는 없어, 그 페이지 요청은 항상 `RenderError.pageUnavailable`로
  /// 실패한다 (§5.2 B1 회귀 테스트 전용 — 영구 실패 래치 검증).
  /// - Parameters:
  ///   - realPageCount: 실제 CGPDFDocument에 존재하는 페이지 수.
  ///   - phantomPageCount: 레이아웃에만 존재하는(CG에는 없는) 뒤쪽 페이지 수.
  ///   - pageWidth: 페이지 폭.
  ///   - pageHeight: 페이지 높이.
  ///   - workerCount: 워커 수.
  /// - Returns: 조립된 코어 (뒤쪽 `phantomPageCount`장이 영구 실패 대상).
  @MainActor
  static func makeReaderCoreWithPagesBeyondDocument(
    realPageCount: Int, phantomPageCount: Int,
    pageWidth: Double = 300, pageHeight: Double = 300, workerCount: Int = 1
  ) async throws -> ReaderCore {
    let fixture = PDFFixtureBuilder(
      pageCount: realPageCount, pageWidth: pageWidth, pageHeight: pageHeight
    ).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let realSizes = try await document.pageTree().records.map(\.displaySize)
    let phantomSize = CGSize(width: pageWidth, height: pageHeight)
    let pageSizes = realSizes + Array(repeating: phantomSize, count: phantomPageCount)
    let layout = ReaderLayoutEngine(pageSizes: pageSizes)
    let configuration = RenderConfiguration(
      workerCount: workerCount, pixelScale: 1, installsMemoryPressureMonitor: false
    )
    let queue = TileRenderQueue(
      documentData: document.sourceBytes, pageSizes: pageSizes, configuration: configuration
    )
    return ReaderCore(layout: layout, renderQueue: queue)
  }

  /// 조건이 참이 될 때까지 짧게 폴링한다 (타이밍 단정 아님 — M5 관례 승계).
  @MainActor
  static func waitUntil(
    timeoutSeconds: Double = 5, _ condition: () async -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
    while !(await condition()) {
      if ContinuousClock.now > deadline {
        Issue.record("polling condition did not settle within timeout")
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  /// 큐 통계가 연속 두 번 동일해질 때까지 폴링한다 (진행 중이던 배경 작업의 정착 대기 —
  /// 무작업 비교 단정 전 잔여 작업으로 인한 요행 실패 방지).
  @MainActor
  static func settle(_ queue: TileRenderQueue, timeoutSeconds: Double = 5) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
    var previous = await queue.statistics()
    while true {
      try await Task.sleep(for: .milliseconds(5))
      let current = await queue.statistics()
      if current == previous {
        return
      }
      previous = current
      if ContinuousClock.now > deadline {
        Issue.record("queue statistics did not settle within timeout")
        return
      }
    }
  }
}

/// `MockScrollHost.scrollTo`가 기록하는 호출 인자 하나 (튜플 대신 명명 타입 — large_tuple 회피).
struct ScrollToCall: Equatable {
  /// 목표 콘텐츠 공간 Y 좌표.
  let contentY: CGFloat
  /// 목표 줌 배율 (nil이면 유지).
  let zoomScale: CGFloat?
  /// 애니메이션 여부.
  let animated: Bool
}

/// 고정 `[Int: PageTextContent]` + throw 지정 페이지로 응답하는 결정적 텍스트 프로바이더
/// (선택 스토어/컨트롤러 테스트 전용).
struct DictionaryTextProvider: PageTextProvider {
  /// 페이지별 콘텐츠.
  let contents: [Int: PageTextContent]

  /// 요청 시 항상 throw할 페이지 집합.
  var throwingPages: Set<Int> = []

  /// 지정 콘텐츠를 반환한다 (throw 지정 페이지·미보유 페이지는 실패).
  func textContent(forPage pageIndex: Int) async throws -> PageTextContent {
    guard !self.throwingPages.contains(pageIndex) else {
      throw PapyrusError.damagedDocument
    }
    guard let content = self.contents[pageIndex] else {
      throw PapyrusError.damagedDocument
    }
    return content
  }
}

/// 페이지별 `CheckedContinuation` 게이트로 도착 시점을 테스트가 수동 제어하는 프로바이더
/// (잠정 클램프→재계산의 결정적 재현. `Task.sleep` 없이 도착 타이밍을 정확히 고정한다).
final class GatedTextProvider: PageTextProvider, @unchecked Sendable {
  /// 페이지별 콘텐츠 (게이트 해제 시 반환할 값).
  private let contents: [Int: PageTextContent]

  /// 페이지별 대기 중 continuation.
  private let lock = NSLock()
  private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
  private var openedPages: Set<Int> = []

  /// 게이트가 걸린 프로바이더를 만든다.
  /// - Parameter contents: 페이지별 콘텐츠 (게이트 해제 시 반환할 값).
  init(contents: [Int: PageTextContent]) {
    self.contents = contents
  }

  /// 지정 페이지의 게이트를 연다 (대기 중 요청·이후 요청 모두 즉시 통과).
  /// - Parameter pageIndex: 게이트를 열 페이지 인덱스.
  func open(_ pageIndex: Int) {
    self.lock.lock()
    self.openedPages.insert(pageIndex)
    let pending = self.waiters.removeValue(forKey: pageIndex) ?? []
    self.lock.unlock()
    for continuation in pending {
      continuation.resume()
    }
  }

  /// 페이지 콘텐츠를 반환한다 (게이트가 열릴 때까지 대기).
  func textContent(forPage pageIndex: Int) async throws -> PageTextContent {
    await self.waitForGate(pageIndex)
    guard let content = self.contents[pageIndex] else {
      throw PapyrusError.damagedDocument
    }
    return content
  }

  /// 게이트가 열릴 때까지 정지한다 (이미 열려 있으면 즉시 반환).
  private func waitForGate(_ pageIndex: Int) async {
    await withCheckedContinuation { continuation in
      self.lock.lock()
      if self.openedPages.contains(pageIndex) {
        self.lock.unlock()
        continuation.resume()
        return
      }
      self.waiters[pageIndex, default: []].append(continuation)
      self.lock.unlock()
    }
  }
}

/// 테스트용 목 스크롤 호스트 — `visibleContentRect`/`zoomScale` 직접 설정, `scrollTo` 호출 기록.
@MainActor
final class MockScrollHost: ReaderScrollHost {
  /// 페이지 컨테이너 레이어들이 붙는 루트.
  let contentLayer = CALayer()

  /// 화면 뷰포트 크기 (pt) — 테스트가 직접 설정.
  var viewportSize = CGSize(width: 400, height: 800)

  /// 현재 줌 배율 — `scrollTo` 호출 시 갱신된다.
  var zoomScale: CGFloat = 1

  /// 뷰포트의 콘텐츠 공간 가시 사각형 — 테스트가 스크롤을 시뮬레이션할 때 직접 설정.
  var visibleContentRect = CGRect.zero

  /// `setContentSize(_:)`로 마지막 설정된 크기.
  var contentSize = CGSize.zero

  /// `setZoomLimits(minimum:maximum:)`로 마지막 설정된 한계.
  var zoomLimits: (minimum: CGFloat, maximum: CGFloat)?

  /// `scrollTo` 호출 기록 (순서대로).
  var scrollToCalls: [ScrollToCall] = []

  /// `presentSelectionMenu` 호출 기록 (순서대로) — 항목·앵커 사각형.
  var presentedMenus: [(items: [ResolvedMenuItem], contentRect: CGRect)] = []

  /// `dismissSelectionMenu` 호출 횟수.
  var dismissCount = 0

  /// 콘텐츠 크기(줌 1 기준)를 설정한다.
  func setContentSize(_ size: CGSize) {
    self.contentSize = size
  }

  /// 줌 한계를 설정한다.
  func setZoomLimits(minimum: CGFloat, maximum: CGFloat) {
    self.zoomLimits = (minimum, maximum)
  }

  /// 스크롤·줌 호출을 기록하고 줌 배율을 갱신한다.
  func scrollTo(contentY: CGFloat, zoomScale: CGFloat?, animated: Bool) {
    self.scrollToCalls.append(
      ScrollToCall(contentY: contentY, zoomScale: zoomScale, animated: animated)
    )
    if let zoomScale {
      self.zoomScale = zoomScale
    }
  }
}

/// `MockScrollHost`의 ``ReaderMenuPresenting`` 채택 — iOS push 표면 테스트용 (§6-4).
extension MockScrollHost: ReaderMenuPresenting {
  /// 호출을 `presentedMenus`에 기록한다.
  /// - Parameters:
  ///   - items: 표시할 메뉴 항목.
  ///   - contentRect: 앵커 사각형 (콘텐츠 공간).
  func presentSelectionMenu(_ items: [ResolvedMenuItem], around contentRect: CGRect) {
    self.presentedMenus.append((items, contentRect))
  }

  /// 호출 횟수를 `dismissCount`에 기록한다.
  func dismissSelectionMenu() {
    self.dismissCount += 1
  }
}
