import Foundation

/// XMP 패킷에서 추출한 속성 (병합 전 중간값 — Info의 보충용).
package struct XMPProperties: Sendable, Equatable {
  /// `dc:title` (rdf:Alt 첫 항목).
  package var title: String?
  /// `dc:creator` (rdf:Seq 첫 항목).
  package var author: String?
  /// `dc:description` (rdf:Alt 첫 항목).
  package var subject: String?
  /// `pdf:Keywords`.
  package var keywords: String?
  /// `xmp:CreatorTool`.
  package var creator: String?
  /// `pdf:Producer`.
  package var producer: String?
  /// `xmp:CreateDate` (ISO 8601).
  package var creationDate: Date?
  /// `xmp:ModifyDate` (ISO 8601).
  package var modificationDate: Date?

  /// 전 필드 `nil`로 생성한다.
  package init() {
    self.title = nil
    self.author = nil
    self.subject = nil
    self.keywords = nil
    self.creator = nil
    self.producer = nil
    self.creationDate = nil
    self.modificationDate = nil
  }

  /// 전 필드가 `nil`인가 (파서가 아무것도 채집하지 못했을 때).
  fileprivate var isEmpty: Bool {
    self.title == nil && self.author == nil && self.subject == nil && self.keywords == nil
      && self.creator == nil && self.producer == nil && self.creationDate == nil
      && self.modificationDate == nil
  }
}

/// /Root /Metadata 스트림의 XMP(XML) 파서. Foundation `XMLParser` 기반.
///
/// 무관용 실패 허용 (가정 1): 어떤 실패도 `nil`로 끝난다 — 에러·경고 없음.
/// 원소 텍스트 형과 rdf:Description 애트리뷰트 축약형을 모두 수용한다.
package enum XMPMetadataParser {
  /// XMP 바이트를 파싱한다. `CoreLimits.maxXMPMetadataBytes` 초과 입력은 즉시 `nil`.
  /// - Parameter data: XMP 패킷 바이트 (스트림 필터 적용 후).
  /// - Returns: 채집된 속성. 전 필드 미채집이거나 크기 초과·파싱 실패로 아무것도
  ///   얻지 못했으면 `nil`.
  package static func parse(_ data: Data) -> XMPProperties? {
    guard data.count <= CoreLimits.maxXMPMetadataBytes else {
      return nil
    }
    let delegate = XMPParsingDelegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    // XMLParser 에러(비정형 XML)는 그 시점까지 채집분을 그대로 쓴다 — 전체 폐기 아님.
    _ = parser.parse()
    return delegate.properties.isEmpty ? nil : delegate.properties
  }
}

/// XMP 채집 상태를 들고 다니는 delegate. 함수 로컬 사용(격리 문제 없음).
private final class XMPParsingDelegate: NSObject, XMLParserDelegate {
  /// 지금까지 채집된 속성.
  var properties = XMPProperties()

  /// `dc:title`/`dc:creator`/`dc:description`처럼 rdf:Alt(-류) 컨테이너 아래 첫 rdf:li만
  /// 채집해야 하는 필드.
  private enum AltField {
    case title
    case author
    case subject
  }

  /// 직접 텍스트 값을 갖는 단순 필드.
  private enum SimpleField {
    case keywords
    case producer
    case creatorTool
    case createDate
    case modifyDate
  }

  /// 현재 활성 Alt 필드 (rdf:Alt 컨테이너 진입 스코프 동안 유지).
  private var activeAltField: AltField?
  /// 활성 Alt 필드의 첫 rdf:li를 이미 채집했는가 (이후 li는 무시).
  private var altFieldCaptured = false
  /// 지금 열려 있는 rdf:li가 활성 Alt 필드의 "첫 rdf:li"인가.
  private var inFirstLi = false
  /// 현재 활성 단순 필드.
  private var activeSimpleField: SimpleField?
  /// 현재 요소의 누적 텍스트 (요소 시작 시 초기화).
  private var currentText = ""

  /// 요소 이름 → Alt 필드 매핑 (분기 대신 조회로 복잡도를 낮춘다).
  private static let altFieldsByElementName: [String: AltField] = [
    "dc:title": .title, "dc:creator": .author, "dc:description": .subject
  ]

  /// 요소 이름 → 단순 필드 매핑.
  private static let simpleFieldsByElementName: [String: SimpleField] = [
    "pdf:Keywords": .keywords, "pdf:Producer": .producer, "xmp:CreatorTool": .creatorTool,
    "xmp:CreateDate": .createDate, "xmp:ModifyDate": .modifyDate
  ]

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
  ) {
    self.currentText = ""
    if let altField = Self.altFieldsByElementName[elementName] {
      self.activeAltField = altField
      self.altFieldCaptured = false
      return
    }
    if let simpleField = Self.simpleFieldsByElementName[elementName] {
      self.activeSimpleField = simpleField
      return
    }
    switch elementName {
    case "rdf:li":
      if self.activeAltField != nil, !self.altFieldCaptured {
        self.inFirstLi = true
      }
    case "rdf:Description":
      self.captureAttributeFallbacks(attributeDict)
    default:
      break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    self.currentText += string
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    defer {
      self.currentText = ""
    }
    switch elementName {
    case "rdf:li":
      if self.inFirstLi, let altField = self.activeAltField {
        self.assign(altField: altField, text: self.trimmedText())
        self.altFieldCaptured = true
      }
      self.inFirstLi = false
    case "dc:title", "dc:creator", "dc:description":
      self.activeAltField = nil
      self.altFieldCaptured = false
    case "pdf:Keywords", "pdf:Producer", "xmp:CreatorTool", "xmp:CreateDate", "xmp:ModifyDate":
      if let field = self.activeSimpleField {
        self.assign(simpleField: field, text: self.trimmedText())
      }
      self.activeSimpleField = nil
    default:
      break
    }
  }

  /// XML 파싱 에러는 무시한다 — 그 시점까지 채집분을 그대로 쓴다 (가정 1).
  func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {}

  private func trimmedText() -> String {
    self.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func assign(altField: AltField, text: String) {
    switch altField {
    case .title:
      self.properties.title = text
    case .author:
      self.properties.author = text
    case .subject:
      self.properties.subject = text
    }
  }

  private func assign(simpleField: SimpleField, text: String) {
    switch simpleField {
    case .keywords:
      self.properties.keywords = text
    case .producer:
      self.properties.producer = text
    case .creatorTool:
      self.properties.creator = text
    case .createDate:
      self.properties.creationDate = Self.parseISODate(text)
    case .modifyDate:
      self.properties.modificationDate = Self.parseISODate(text)
    }
  }

  /// `rdf:Description`의 동명 애트리뷰트 축약형을 채집한다 (요소형이 뒤이어 나오면 덮어써
  /// 요소형이 이긴다 — 단일 순방향 파싱에서 문서 순서가 이를 자연히 보장한다).
  private func captureAttributeFallbacks(_ attributes: [String: String]) {
    if let value = attributes["dc:title"] {
      self.properties.title = value
    }
    if let value = attributes["dc:creator"] {
      self.properties.author = value
    }
    if let value = attributes["dc:description"] {
      self.properties.subject = value
    }
    if let value = attributes["pdf:Keywords"] {
      self.properties.keywords = value
    }
    if let value = attributes["pdf:Producer"] {
      self.properties.producer = value
    }
    if let value = attributes["xmp:CreatorTool"] {
      self.properties.creator = value
    }
    if let value = attributes["xmp:CreateDate"] {
      self.properties.creationDate = Self.parseISODate(value)
    }
    if let value = attributes["xmp:ModifyDate"] {
      self.properties.modificationDate = Self.parseISODate(value)
    }
  }

  /// ISO 8601 날짜를 소수초 유무 두 구성으로 순차 시도한다.
  private static func parseISODate(_ text: String) -> Date? {
    let withFractionalSeconds = ISO8601DateFormatter()
    withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractionalSeconds.date(from: text) {
      return date
    }
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    return standard.date(from: text)
  }
}
