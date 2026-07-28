import Foundation

// `PDFFixtureBuilder`의 M3 신규 스펙(페이지 트리/목차/이름 목적지/Info/XMP) 전용 기록 경로.
// 파일 분리는 순수 조직적 이유(§6)이며, `.classicTable` 전용이다(가정 7).
//
// 3단 중첩(PDFFixtureBuilder → PageTreeSpec → Node/NodeAttributes)은 설계 문서(§2.8)가
// 명시한 구조를 그대로 따른다 — SwiftLint 기본 `nesting`(최대 1단) 규칙과 충돌하므로 이
// 파일 범위에서만 규칙을 끈다.
// swiftlint:disable nesting

extension PDFFixtureBuilder {
  /// 중첩 페이지 트리 픽스처 명세.
  package struct PageTreeSpec: Sendable {
    /// 트리 노드.
    package indirect enum Node: Sendable {
      /// 중간 노드 (/Type /Pages). /Count는 잎 수로 자동 계산 기록.
      case pages(attributes: NodeAttributes, kids: [Node])
      /// 잎 노드 (/Type /Page).
      case page(attributes: NodeAttributes)
      /// Kids 배열에 원문 그대로 삽입되는 항목 — 순환("2 0 R")·댕글링("999 0 R")·
      /// 비참조("7"·"null") 병적 픽스처용. 객체를 생성하지 않는다.
      case rawKid(String)
    }

    /// 노드가 직접 보유할 속성 (전부 선택적 — 상속 픽스처는 의도적 생략으로 만든다).
    package struct NodeAttributes: Sendable {
      /// /MediaBox (없으면 미기록 — 상속 시나리오용).
      package var mediaBox: PDFRectangleSpec?
      /// /CropBox (없으면 미기록).
      package var cropBox: PDFRectangleSpec?
      /// /Rotate (없으면 미기록).
      package var rotate: Int?
      /// /Resources 원문 (예: `"<< /ProcSet [/PDF] >>"` 또는 `"20 0 R"`).
      package var resourcesRaw: String?

      /// 속성을 생성한다 (전 필드 기본 `nil`).
      /// - Parameters:
      ///   - mediaBox: /MediaBox 명세.
      ///   - cropBox: /CropBox 명세.
      ///   - rotate: /Rotate 값.
      ///   - resourcesRaw: /Resources 원문.
      package init(
        mediaBox: PDFRectangleSpec? = nil, cropBox: PDFRectangleSpec? = nil, rotate: Int? = nil,
        resourcesRaw: String? = nil
      ) {
        self.mediaBox = mediaBox
        self.cropBox = cropBox
        self.rotate = rotate
        self.resourcesRaw = resourcesRaw
      }
    }

    /// 루트 노드 (반드시 `.pages` — 아니면 precondition 실패).
    package var root: Node

    /// 트리 명세를 생성한다.
    /// - Parameter root: 루트 노드 (반드시 `.pages`).
    package init(root: Node) {
      self.root = root
    }
  }

  /// 사각형 명세 (기록 포맷은 `formatCoordinate` 재사용).
  package struct PDFRectangleSpec: Sendable {
    /// 왼쪽 X 좌표.
    package var x0: Double
    /// 아래쪽 Y 좌표.
    package var y0: Double
    /// 오른쪽 X 좌표.
    package var x1: Double
    /// 위쪽 Y 좌표.
    package var y1: Double

    /// 사각형 명세를 생성한다.
    /// - Parameters:
    ///   - x0: 왼쪽 X 좌표.
    ///   - y0: 아래쪽 Y 좌표.
    ///   - x1: 오른쪽 X 좌표.
    ///   - y1: 위쪽 Y 좌표.
    package init(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
      self.x0 = x0
      self.y0 = y0
      self.x1 = x1
      self.y1 = y1
    }
  }
}

// swiftlint:enable nesting

// MARK: - 번호 배치 + 기록 (전위 순회, 카탈로그=1, 루트 Pages=2, 이하 3부터)
//
// 명시적 스택을 쓰는 반복(비재귀) 구현이다 — 병적 픽스처(깊이 캡 테스트 등)가 재귀 호출
// 깊이만큼 네이티브 스택을 소비하는 것을 피하기 위함 (실제 파서 `buildPageTree`와 동일한
// 이유, §3.1).

/// 번호 배치가 끝난 노드 하나의 기록용 평탄 표현.
struct PlannedPageTreeNode {
  /// 이 노드의 객체 번호.
  let number: Int
  /// 부모 객체 번호 (루트면 `nil` — 실파일 관례상 루트 Pages는 /Parent를 기록하지 않는다).
  let parentNumber: Int?
  /// 중간 노드(/Pages) 여부 (`false`면 잎(/Page)).
  let isPages: Bool
  /// 노드가 직접 보유한 속성.
  let attributes: PDFFixtureBuilder.PageTreeSpec.NodeAttributes
  /// `.pages` 전용 — `/Kids` 배열 원소 텍스트(공백 결합, 이미 조립 완료).
  let kidsText: String
  /// `.pages` 전용 — 객체를 갖는 직계 kid들의 번호(`.rawKid`는 제외). `/Count`에 쓸
  /// 서브트리 잎 총수를 반복(비재귀) 후위 집계로 구하기 위한 재료다 (PDF 32000-1:2008
  /// §7.7.3.2 정합 — 직계 kid 수가 아니다, r1 §2.8).
  let childNumbers: [Int]
}

extension PDFFixtureBuilder {
  /// 번호가 배치된(또는 원문 그대로인) kid 하나.
  private enum NumberedKid {
    /// 객체를 생성하는 kid (번호 배치 완료).
    case object(node: PageTreeSpec.Node, number: Int)
    /// 원문 그대로 삽입되는 병적 kid (객체 없음).
    case raw(text: String)
  }

  /// kid 목록에 좌→우 순서로 번호를 배치한다 (`.rawKid`는 번호 없이 원문만 보존).
  private static func numberDirectKids(
    _ kids: [PageTreeSpec.Node], next: inout Int
  ) -> [NumberedKid] {
    kids.map { kid in
      if case let .rawKid(text) = kid {
        return .raw(text: text)
      }
      let number = next
      next += 1
      return .object(node: kid, number: number)
    }
  }

  /// kid 하나의 `/Kids` 배열 원소 텍스트 (참조 또는 원문 그대로).
  private static func kidReferenceText(_ kid: NumberedKid) -> String {
    switch kid {
    case let .object(_, number):
      return "\(number) 0 R"
    case let .raw(text):
      return text
    }
  }

  /// 루트를 포함한 전체 페이지 트리에 반복 전위 순회로 번호를 배치하고, 기록용 평탄
  /// 계획 + 문서 순서 잎 객체 번호 목록을 만든다. 명시적 스택 DFS — 재귀 없음.
  /// - Parameters:
  ///   - rootAttributes: 루트(Pages, 번호 2) 자신의 속성.
  ///   - rootKids: 루트의 직계 kid 목록.
  ///   - next: 다음에 배치할 객체 번호 (3부터 시작, 갱신되어 반환됨).
  /// - Returns: 기록용 평탄 계획(문서에 기록될 순서)과 문서 순서 페이지 객체 번호 목록.
  static func planPageTree(
    rootAttributes: PageTreeSpec.NodeAttributes, rootKids: [PageTreeSpec.Node], next: inout Int
  ) -> (plan: [PlannedPageTreeNode], pageObjectNumbers: [Int]) {
    var plan: [PlannedPageTreeNode] = []
    var pageObjectNumbers: [Int] = []

    let numberedRootKids = Self.numberDirectKids(rootKids, next: &next)
    plan.append(PlannedPageTreeNode(
      number: 2, parentNumber: nil, isPages: true, attributes: rootAttributes,
      kidsText: numberedRootKids.map(Self.kidReferenceText).joined(separator: " "),
      childNumbers: Self.objectNumbers(of: numberedRootKids)
    ))

    struct WorkItem {
      let node: PageTreeSpec.Node
      let number: Int
      let parentNumber: Int
    }
    var stack: [WorkItem] = numberedRootKids.reversed().compactMap { kid in
      guard case let .object(node, number) = kid else {
        return nil
      }
      return WorkItem(node: node, number: number, parentNumber: 2)
    }

    while let item = stack.popLast() {
      switch item.node {
      case let .page(attributes):
        pageObjectNumbers.append(item.number)
        plan.append(PlannedPageTreeNode(
          number: item.number, parentNumber: item.parentNumber, isPages: false,
          attributes: attributes, kidsText: "", childNumbers: []
        ))
      case let .pages(attributes, kids):
        let numberedKids = Self.numberDirectKids(kids, next: &next)
        plan.append(PlannedPageTreeNode(
          number: item.number, parentNumber: item.parentNumber, isPages: true,
          attributes: attributes,
          kidsText: numberedKids.map(Self.kidReferenceText).joined(separator: " "),
          childNumbers: Self.objectNumbers(of: numberedKids)
        ))
        for kid in numberedKids.reversed() {
          if case let .object(node, number) = kid {
            stack.append(WorkItem(node: node, number: number, parentNumber: item.number))
          }
        }
      case .rawKid:
        break // NumberedKid.object는 .rawKid를 절대 감싸지 않는다 (도달 불가).
      }
    }

    return (plan, pageObjectNumbers)
  }

  /// 번호가 배치된 kid 목록에서 객체를 갖는 것들의 번호만 뽑는다 (`.rawKid`는 제외).
  private static func objectNumbers(of kids: [NumberedKid]) -> [Int] {
    kids.compactMap { kid in
      guard case let .object(_, number) = kid else {
        return nil
      }
      return number
    }
  }

  /// 서브트리 잎(페이지) 총수를 노드별로 집계한다 — 파서 본체(`buildPageTree`)와 동일하게
  /// **반복(비재귀)** 후위 집계로 구한다 (r1 §2.8). 전위 순서로 쌓인 `plan`을 역순으로
  /// 훑으면, 어떤 노드의 모든 자손은 그 노드보다 배열에서 앞서 나온다는 전위 순회의
  /// 성질에 의해 자식의 집계값이 부모보다 먼저 확정된다 — 재귀 호출 없이 단일 역순
  /// 패스로 정확한 서브트리 총수를 얻는다.
  /// - Parameter plan: `planPageTree`가 만든 전위 순서 평탄 계획.
  /// - Returns: 객체 번호 → 서브트리 잎 총수 (잎 노드는 1).
  static func subtreeLeafCounts(for plan: [PlannedPageTreeNode]) -> [Int: Int] {
    var totals: [Int: Int] = [:]
    for planned in plan.reversed() {
      if planned.isPages {
        totals[planned.number] = planned.childNumbers.reduce(0) { partial, childNumber in
          partial + (totals[childNumber] ?? 0)
        }
      } else {
        totals[planned.number] = 1
      }
    }
    return totals
  }
}

// MARK: - 기록

extension PDFFixtureBuilder {
  /// 사각형 명세를 COS 배열 원문으로 포맷한다.
  static func rectangleText(_ rect: PDFRectangleSpec) -> String {
    let parts = [rect.x0, rect.y0, rect.x1, rect.y1].map(Self.formatCoordinate)
    return "[\(parts.joined(separator: " "))]"
  }

  /// 노드 속성을 딕셔너리 엔트리 문자열 목록으로 변환한다.
  static func attributeEntries(_ attributes: PageTreeSpec.NodeAttributes) -> [String] {
    var parts: [String] = []
    if let mediaBox = attributes.mediaBox {
      parts.append("/MediaBox \(Self.rectangleText(mediaBox))")
    }
    if let cropBox = attributes.cropBox {
      parts.append("/CropBox \(Self.rectangleText(cropBox))")
    }
    if let rotate = attributes.rotate {
      parts.append("/Rotate \(rotate)")
    }
    if let resourcesRaw = attributes.resourcesRaw {
      parts.append("/Resources \(resourcesRaw)")
    }
    return parts
  }

  /// 번호 배치된 평탄 계획을 기록한다 (반복 for 루프 — 재귀 없음). `/Count`는
  /// `subtreeLeafCounts(for:)`가 미리 집계한 서브트리 잎 총수를 쓴다 (r1 §2.8).
  static func writePageTreePlan(
    _ plan: [PlannedPageTreeNode], into writer: inout PDFByteWriter,
    objectOffsets: inout [Int: Int]
  ) {
    let leafCounts = Self.subtreeLeafCounts(for: plan)
    for planned in plan {
      var parts = [planned.isPages ? "/Type /Pages" : "/Type /Page"]
      if let parentNumber = planned.parentNumber {
        parts.append("/Parent \(parentNumber) 0 R")
      }
      if planned.isPages {
        parts.append("/Kids [\(planned.kidsText)]")
        parts.append("/Count \(leafCounts[planned.number] ?? 0)")
      }
      parts.append(contentsOf: Self.attributeEntries(planned.attributes))
      objectOffsets[planned.number] = writer.offset
      writer.writeLine("\(planned.number) 0 obj")
      writer.writeLine("<< \(parts.joined(separator: " ")) >>")
      writer.writeLine("endobj")
    }
  }
}

// M3 전체 조립(buildM3Fixture 등)은 `PDFFixtureBuilderM3Assembly.swift`로 분리되었다
// (파일 길이 제한, §6).
