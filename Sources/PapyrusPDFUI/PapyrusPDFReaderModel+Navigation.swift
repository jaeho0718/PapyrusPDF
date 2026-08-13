import CoreGraphics
import PapyrusPDFCore

/// 연결 전에 접수된 탐색 명령 (연결 직후 1회 재생 — §4.1).
enum PendingReaderCommand {
  /// 보류된 `goToPage` 호출.
  case goToPage(index: Int, animated: Bool)
  /// 보류된 `restore` 호출.
  case restore(ReaderPosition)
}

/// 연결·부착 전에 접수된 줌 명령 (탐색 슬롯과 별도 — 서로를 밀어내지 않는다).
enum PendingZoomCommand {
  /// 보류된 `setZoom` 호출.
  case setZoom(scale: CGFloat, animated: Bool)
  /// 보류된 `fitWidth` 호출.
  case fitWidth(animated: Bool)
}

/// 이동·줌 공개 API(`goToPage`/`restore`/`setZoom`/`fitWidth`) + 보류 슬롯 재생 내부 로직.
///
/// `PapyrusPDFReaderModel.swift`의 몸통과 파일만 분리한 확장이다 (파일 길이 한도 —
/// `PapyrusPDFReaderModel+Highlights` 전례와 동일 패턴). 게이트는 "코어 연결 ∧ 호스트
/// 부착"이다(이슈 #19) — `core.isHostAttached`가 그 조건을 읽는다.
extension PapyrusPDFReaderModel {
  /// 페이지 상단으로 이동합니다 (범위 밖은 클램프).
  ///
  /// 페이지 번호 입력창이나 커스텀 목차 UI에서 사용자가 특정 페이지를 선택했을 때
  /// 호출합니다. `PapyrusPDFReader`가 아직 화면에 붙지 않은 상태에서 호출해도
  /// 안전합니다 — 요청이 보류됐다가 뷰어가 화면에 붙는 즉시(애니메이션 없이) 자동으로
  /// 재생됩니다.
  /// - Parameters:
  ///   - index: 이동할 페이지 인덱스입니다.
  ///   - animated: 애니메이션 여부입니다.
  public func goToPage(_ index: Int, animated: Bool = true) {
    guard let core, core.isHostAttached else {
      self.pendingCommand = .goToPage(index: index, animated: animated)
      return
    }
    core.goToPage(index, animated: animated)
  }

  /// 목차 목적지로 이동합니다 (`OutlineDestination.pageIndex` — 현재는 페이지 단위 목적지입니다).
  ///
  /// `document.outline`에서 얻은 항목을 사용자가 목차 사이드바에서 선택했을 때 그
  /// `destination`을 그대로 넘기면 됩니다.
  /// - Parameters:
  ///   - destination: 이동할 목차 목적지입니다.
  ///   - animated: 애니메이션 여부입니다.
  public func go(to destination: OutlineDestination, animated: Bool = true) {
    self.goToPage(destination.pageIndex, animated: animated)
  }

  /// 현재 위치 스냅숏입니다 (적재 전 nil).
  ///
  /// 화면이 사라지거나 앱이 백그라운드로 전환되는 시점에 호출해 `Codable`인 반환값을
  /// 영구 저장소(예: `UserDefaults`)에 저장해 두면, 다음에 같은 문서를 열 때
  /// ``restore(_:)``로 이어 볼 수 있습니다.
  /// - Returns: 현재 위치 스냅숏, 미연결이면 `nil`입니다.
  public func capturePosition() -> ReaderPosition? {
    self.core?.capturePosition()
  }

  /// 위치를 복원합니다 (적재 전 호출 시 보류 후 부착 직후 적용).
  ///
  /// 이전에 ``capturePosition()``으로 저장해 둔 위치를 다시 불러올 때 사용합니다.
  /// 모델을 만든 직후, `PapyrusPDFReader`가 화면에 붙기 전에 호출해도 안전합니다 —
  /// 뷰어가 화면에 붙는 즉시(애니메이션 없이) 자동으로 적용됩니다.
  /// - Parameter position: 복원할 위치 스냅숏입니다.
  public func restore(_ position: ReaderPosition) {
    guard let core, core.isHostAttached else {
      self.pendingCommand = .restore(position)
      return
    }
    core.restore(position, animated: true)
  }

  /// 줌 배율을 설정합니다 (현재 뷰포트 상단 위치는 유지됩니다).
  ///
  /// 배율은 그 시점 유효 범위 ``zoomRange``로 클램프됩니다 — `0`을 전달하면 하한
  /// (fit-width)이 됩니다. 뷰어가 화면에 붙기 전에 호출해도 안전합니다 — 보류됐다가
  /// 표시 준비가 끝나는 즉시(애니메이션 없이) 적용됩니다.
  /// - Parameters:
  ///   - scale: 목표 줌 배율입니다.
  ///   - animated: 애니메이션 여부입니다.
  public func setZoom(_ scale: CGFloat, animated: Bool = true) {
    guard let core, core.isHostAttached else {
      self.pendingZoom = .setZoom(scale: scale, animated: animated)
      return
    }
    core.setZoom(scale, animated: animated)
  }

  /// 페이지 폭을 뷰포트 폭에 맞춥니다 (현재 뷰포트 상단 위치는 유지됩니다).
  ///
  /// 호출 시점이 아니라 **적용 시점**의 뷰포트 폭 기준입니다 — 회전·리사이즈 직후에
  /// 호출해도 새 폭에 맞습니다. 뷰어가 화면에 붙기 전에 호출해도 안전합니다.
  /// - Parameter animated: 애니메이션 여부입니다.
  public func fitWidth(animated: Bool = true) {
    guard let core, core.isHostAttached else {
      self.pendingZoom = .fitWidth(animated: animated)
      return
    }
    core.fitWidth(animated: animated)
  }

  /// 연결 전 접수된 이동·줌 명령을 재생 순서(이동 → 줌)로 1회 재생한다
  /// (`ReaderCore.onHostAttached` 배선 전용 — `attach(core:)`가 호출한다).
  func replayNavigationCommands() {
    self.replayPendingCommand()
    self.replayPendingZoom()
  }

  /// 연결 전 접수된 탐색 명령을 1회 재생한다. 코어를 직접 `animated: false`로
  /// 호출한다 — 재생 시점엔 뷰어가 화면에 없었으므로 사용자가 애니메이션 출발점을
  /// 본 적이 없다(가정 1).
  private func replayPendingCommand() {
    guard let command = self.pendingCommand, let core else {
      return
    }
    self.pendingCommand = nil
    switch command {
    case let .goToPage(index, _):
      core.goToPage(index, animated: false)
    case let .restore(position):
      core.restore(position, animated: false)
    }
  }

  /// 연결 전 접수된 줌 명령을 1회 재생한다. 코어를 직접 `animated: false`로
  /// 호출한다(가정 1).
  private func replayPendingZoom() {
    guard let pending = self.pendingZoom, let core else {
      return
    }
    self.pendingZoom = nil
    switch pending {
    case let .setZoom(scale, _):
      core.setZoom(scale, animated: false)
    case .fitWidth:
      core.fitWidth(animated: false)
    }
  }
}
