import CoreGraphics
import PapyrusCore
import PapyrusRendering
import QuartzCore

/// 페이지 하나의 레이어 서브트리 (아래→위: 배경/프리뷰 → 스테일 타일 → 현재 타일 → 오버레이).
///
/// 레이어 좌표계 = 페이지 표시 공간 (좌상단 원점, pt — 가정 9). 렌더 산출물의
/// `pointRect`를 그대로 frame으로 쓴다. 모든 레이어 변경은 `CATransaction`
/// 암시 애니메이션 비활성 하에 수행한다 (스크롤 중 페이드 아티팩트 방지).
@MainActor
package final class PageLayerController {
  /// 구버킷으로 강등된 타일 레이어 하나 (완전 포함 판정·나이순 제거를 위한 부가 정보).
  private struct StaleTileLayer {
    /// 강등된 레이어.
    let layer: CALayer
    /// 강등 시점의 프레임 (완전 포함 판정용).
    let frame: CGRect
    /// 강등 순번 (오래된 순 제거용, 단조 증가).
    let sequence: Int
  }

  /// 루트 컨테이너 (frame = 콘텐츠 공간의 페이지 프레임, 배경 흰색 —
  /// 아무 렌더도 없을 때의 플레이스홀더이자 렌더 실패 페이지의 최종 표시).
  package let containerLayer: CALayer

  /// M7+ 확장 심: 타일 위 오버레이 슬롯 (v1에서는 빈 레이어 — 검색 하이라이트가
  /// 여기에 CAShapeLayer를 얹는다. 구조 변경 없는 확장점, ARCHITECTURE 130행).
  package let overlayLayer: CALayer

  /// 현재 담당 페이지 (풀에 있으면 nil).
  package private(set) var pageIndex: Int?

  /// 현재 표시 중인 타일 버킷.
  package private(set) var currentBucket: ScaleBucket?

  /// 최하단 프리뷰 레이어 (contentsGravity = .resize로 페이지 크기에 맞춤).
  private let previewLayer: CALayer

  /// 현재 버킷의 타일 레이어 (키 → 레이어).
  private var currentTileLayers: [TileKey: CALayer] = [:]

  /// 구버킷으로 강등된 타일 레이어들 (§4.5 스테일 제거 규칙 대상).
  private var staleTileLayers: [StaleTileLayer] = []

  /// 다음에 부여할 스테일 강등 순번.
  private var nextStaleSequence = 0

  /// 지연 생성 하이라이트 오버레이 (검색 미사용 페이지는 비용 0).
  private var highlightOverlay: HighlightOverlay?

  /// 지연 생성 선택 오버레이 (선택 미사용 페이지는 비용 0).
  private var selectionOverlay: SelectionOverlay?

  /// 지연 생성 지속 하이라이트 오버레이 (하이라이트 미사용 페이지는 비용 0).
  private var persistentHighlightOverlay: PersistentHighlightOverlay?

  /// 컨트롤러를 만든다.
  package init() {
    let containerLayer = CALayer()
    let previewLayer = CALayer()
    let overlayLayer = CALayer()
    previewLayer.contentsGravity = .resize
    containerLayer.backgroundColor = CGColor(gray: 1, alpha: 1)
    containerLayer.addSublayer(previewLayer)
    containerLayer.addSublayer(overlayLayer)
    self.containerLayer = containerLayer
    self.previewLayer = previewLayer
    self.overlayLayer = overlayLayer
  }

  /// 페이지에 배정한다 (재사용 진입점). 프리뷰·타일은 비운 상태로 시작한다.
  /// - Parameters:
  ///   - pageIndex: 배정할 페이지 인덱스.
  ///   - frame: 콘텐츠 공간의 페이지 프레임.
  package func configure(pageIndex: Int, frame: CGRect) {
    self.pageIndex = pageIndex
    Self.withoutImplicitAnimation {
      self.containerLayer.frame = frame
      self.previewLayer.frame = CGRect(origin: .zero, size: frame.size)
      // M7이 이 슬롯에 오버레이를 얹을 때 프레임을 별도로 챙기지 않아도 되도록 페이지
      // 크기에 맞춰 둔다 (v1은 빈 레이어라 무해, 확장 시 실수 방지 — 리뷰 nit 반영).
      self.overlayLayer.frame = CGRect(origin: .zero, size: frame.size)
    }
  }

  /// 프리뷰를 표시한다 (최하단, contentsGravity = .resize로 페이지 크기에 맞춤).
  /// - Parameter preview: 표시할 렌더 프리뷰.
  package func setPreview(_ preview: RenderedPreview) {
    Self.withoutImplicitAnimation {
      self.previewLayer.contents = preview.image
    }
  }

  /// 타일을 표시한다. `tile.key.scaleBucket != currentBucket`이면 무시한다
  /// (늦게 도착한 구버킷 결과 방어). 새 타일 frame에 완전히 덮이는 스테일
  /// 레이어는 즉시 제거한다 (§4.5).
  /// - Parameter tile: 표시할 렌더 타일.
  package func setTile(_ tile: RenderedTile) {
    guard tile.key.scaleBucket == self.currentBucket else {
      return
    }
    let layer = self.currentTileLayers[tile.key] ?? {
      let newLayer = CALayer()
      self.containerLayer.insertSublayer(newLayer, below: self.overlayLayer)
      self.currentTileLayers[tile.key] = newLayer
      return newLayer
    }()
    Self.withoutImplicitAnimation {
      layer.frame = tile.pointRect
      layer.contents = tile.image
    }
    self.removeStaleLayers(fullyContainedIn: tile.pointRect)
  }

  /// 버킷 전환: 현재 타일들을 스테일 그룹으로 강등하고 새 버킷을 현재로 삼는다.
  /// 스테일 초과분(`maxStaleTileLayers`)은 오래된 순으로 제거.
  /// - Parameter bucket: 새로 활성화할 스케일 버킷.
  package func activateBucket(_ bucket: ScaleBucket) {
    guard bucket != self.currentBucket else {
      return
    }
    for layer in self.currentTileLayers.values {
      self.staleTileLayers.append(
        StaleTileLayer(layer: layer, frame: layer.frame, sequence: self.nextStaleSequence)
      )
      self.nextStaleSequence += 1
    }
    self.currentTileLayers.removeAll()
    self.currentBucket = bucket
    self.enforceStaleCap()
  }

  /// 현재 버킷 타일이 `keys`를 전부 갖췄을 때 호출 — 스테일 전량 제거 (§4.5).
  package func removeStaleTiles() {
    guard !self.staleTileLayers.isEmpty else {
      return
    }
    Self.withoutImplicitAnimation {
      for stale in self.staleTileLayers {
        stale.layer.removeFromSuperlayer()
      }
    }
    self.staleTileLayers.removeAll()
  }

  /// 현재 버킷에서 이미 레이어로 보유한 타일 키 집합 (중복 요청 방지용 조회).
  /// - Parameter key: 조회할 타일 키.
  /// - Returns: 현재 버킷에 이미 표시되어 있으면 `true`.
  package func hasTile(for key: TileKey) -> Bool {
    self.currentTileLayers[key] != nil
  }

  /// 검색 하이라이트를 표시한다 (없던 오버레이는 이때 지연 생성한다).
  /// - Parameters:
  ///   - highlights: 이 페이지의 표시 공간 매치들.
  ///   - currentOrdinal: 현재 매치의 페이지 내 순번 (이 페이지에 없으면 `nil`).
  package func setSearchHighlights(_ highlights: PageSearchHighlights, currentOrdinal: Int?) {
    let overlay = self.highlightOverlay ?? {
      let created = HighlightOverlay(parent: self.overlayLayer)
      self.highlightOverlay = created
      return created
    }()
    overlay.apply(highlights, currentOrdinal: currentOrdinal)
  }

  /// 검색 하이라이트를 지운다 (오버레이 미생성이면 no-op).
  package func clearSearchHighlights() {
    self.highlightOverlay?.clear()
  }

  /// 선택 quad·핸들을 표시한다 (없던 오버레이는 지연 생성. `quads` 비고 `handles` `nil`이면
  /// ``clearSelection()``과 동일하다).
  /// - Parameters:
  ///   - quads: 표시할 표시 공간 quad 목록.
  ///   - handles: 핸들 배치 (macOS는 항상 `nil`).
  ///   - handleScale: 1/zoom (핸들 치수 화면 고정).
  package func setSelection(
    _ quads: [Quad], handles: SelectionHandlePlacement?, handleScale: CGFloat
  ) {
    let overlay = self.selectionOverlay ?? {
      let created = SelectionOverlay(parent: self.overlayLayer)
      self.selectionOverlay = created
      return created
    }()
    overlay.apply(quads: quads, handles: handles, handleScale: handleScale)
  }

  /// 선택 표시를 지운다 (오버레이 미생성이면 no-op).
  package func clearSelection() {
    self.selectionOverlay?.clear()
  }

  /// 지속 하이라이트 그룹을 표시한다 (없던 오버레이는 지연 생성 — 빈 배열이면
  /// ``clearPersistentHighlights()``와 동일).
  /// - Parameter groups: 표시할 지속 하이라이트 그룹.
  package func setPersistentHighlights(_ groups: [PersistentHighlightGroup]) {
    let overlay = self.persistentHighlightOverlay ?? {
      let created = PersistentHighlightOverlay(parent: self.overlayLayer)
      self.persistentHighlightOverlay = created
      return created
    }()
    overlay.apply(groups)
  }

  /// 지속 하이라이트를 지운다 (오버레이 미생성이면 no-op).
  package func clearPersistentHighlights() {
    self.persistentHighlightOverlay?.clear()
  }

  /// 버킷 전환 시 오버레이(지속 하이라이트+검색+선택) 선명도를 일괄 갱신한다
  /// (미생성 오버레이는 no-op).
  /// - Parameters:
  ///   - screenScale: 화면 배율(픽셀 밀도).
  ///   - bucketScale: 현재 스케일 버킷 배율.
  package func updateOverlayContentsScale(screenScale: CGFloat, bucketScale: CGFloat) {
    self.persistentHighlightOverlay?.updateContentsScale(
      screenScale: screenScale, bucketScale: bucketScale
    )
    self.highlightOverlay?.updateContentsScale(screenScale: screenScale, bucketScale: bucketScale)
    self.selectionOverlay?.updateContentsScale(screenScale: screenScale, bucketScale: bucketScale)
  }

  /// 풀 반환 준비: 전 레이어 contents 해제·서브레이어 정리·pageIndex nil.
  package func prepareForReuse() {
    Self.withoutImplicitAnimation {
      self.previewLayer.contents = nil
      for layer in self.currentTileLayers.values {
        layer.removeFromSuperlayer()
      }
      for stale in self.staleTileLayers {
        stale.layer.removeFromSuperlayer()
      }
    }
    self.currentTileLayers.removeAll()
    self.staleTileLayers.removeAll()
    self.pageIndex = nil
    self.currentBucket = nil
    // 재활용 풀 경유 시 이전 페이지 하이라이트·선택 잔류 방지 (필수 불변식).
    self.clearSearchHighlights()
    self.clearSelection()
    self.clearPersistentHighlights()
  }

  /// 새 타일 frame에 완전히 포함되는 스테일 레이어를 제거한다 (§4.5 규칙 1, 여유 ε).
  /// - Parameter rect: 새로 표시된 타일의 페이지 표시 공간 사각형.
  private func removeStaleLayers(fullyContainedIn rect: CGRect) {
    let epsilon: CGFloat = 0.5
    let expanded = rect.insetBy(dx: -epsilon, dy: -epsilon)
    let covered = self.staleTileLayers.filter { expanded.contains($0.frame) }
    guard !covered.isEmpty else {
      return
    }
    Self.withoutImplicitAnimation {
      for stale in covered {
        stale.layer.removeFromSuperlayer()
      }
    }
    self.staleTileLayers.removeAll { candidate in
      covered.contains { $0.layer === candidate.layer }
    }
  }

  /// 스테일 수가 `maxStaleTileLayers`를 넘으면 오래된 순으로 제거한다 (§4.5 규칙 3).
  private func enforceStaleCap() {
    guard self.staleTileLayers.count > ReaderLayoutMetrics.maxStaleTileLayers else {
      return
    }
    self.staleTileLayers.sort { $0.sequence < $1.sequence }
    let excess = self.staleTileLayers.count - ReaderLayoutMetrics.maxStaleTileLayers
    let toRemove = self.staleTileLayers.prefix(excess)
    Self.withoutImplicitAnimation {
      for stale in toRemove {
        stale.layer.removeFromSuperlayer()
      }
    }
    self.staleTileLayers.removeFirst(excess)
  }

  /// 암시 애니메이션을 비활성화한 채로 레이어 변경을 수행한다 (스크롤 중 페이드 방지).
  /// - Parameter body: 레이어 변경 클로저.
  private static func withoutImplicitAnimation(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
  }
}

/// 유휴 컨트롤러 재활용 풀 (캡 = recyclePoolCapacity, 가정 4).
@MainActor
package final class PageLayerPool {
  /// 유휴 컨트롤러 스택.
  private var idle: [PageLayerController] = []

  /// 보관 상한.
  private let capacity: Int

  /// 풀을 만든다.
  /// - Parameter capacity: 유휴 보관 상한 (기본 `ReaderLayoutMetrics.recyclePoolCapacity`).
  package init(capacity: Int = ReaderLayoutMetrics.recyclePoolCapacity) {
    self.capacity = capacity
  }

  /// 유휴 컨트롤러를 꺼내거나 새로 만든다.
  /// - Returns: 사용 준비된 컨트롤러.
  package func acquire() -> PageLayerController {
    self.idle.popLast() ?? PageLayerController()
  }

  /// 반환한다 (`prepareForReuse` 호출 포함). 캡 초과분은 버린다 (레이어 해제).
  /// - Parameter controller: 반환할 컨트롤러.
  package func release(_ controller: PageLayerController) {
    controller.prepareForReuse()
    guard self.idle.count < self.capacity else {
      return
    }
    self.idle.append(controller)
  }

  /// 보관 중 수 (테스트 관찰용).
  package var idleCount: Int {
    self.idle.count
  }
}
