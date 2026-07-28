import Foundation

extension PDFDocumentCore {
  /// 문서 메타데이터를 반환한다. 첫 호출 시 Info → XMP 순으로 수집·병합하고 영구 메모이즈.
  ///
  /// /Info 부재·해소 실패·XMP 실패는 전부 관용 — 해당 필드만 `nil`이 된다.
  /// - Throws: 실질적으로 던지지 않는 구조이나, 시그니처는 액터 해소 경로와 정합하게
  ///   untyped `throws`로 둔다 (M2 가정 2).
  /// - Returns: 병합 완료된 문서 메타데이터.
  package func documentMetadata() async throws -> DocumentMetadata {
    if let task = self.metadataTask {
      return try await task.value
    }
    let task = Task { try await self.buildMetadata() }
    self.metadataTask = task
    return try await task.value
  }
}

// MARK: - 수집·병합 (§3.2)

extension PDFDocumentCore {
  /// 표준 8키 중 값 참조 해소가 필요한 키 목록.
  private static let infoStringKeys: [COSName] = [
    .title, .author, .subject, .keywords, .creator, .producer, .creationDate, .modDate
  ]

  /// /Info → XMP 순으로 수집하고, Info 우선·XMP 보충으로 병합한다.
  private func buildMetadata() async throws -> DocumentMetadata {
    self.metadataBuildCount += 1

    let info = await self.collectInfoProperties()
    let xmp = await self.collectXMPProperties()
    let pdfVersion = await self.resolvedPDFVersionText()

    return DocumentMetadata(
      title: info.title ?? xmp?.title,
      author: info.author ?? xmp?.author,
      subject: info.subject ?? xmp?.subject,
      keywords: info.keywords ?? xmp?.keywords,
      creator: info.creator ?? xmp?.creator,
      producer: info.producer ?? xmp?.producer,
      creationDate: info.creationDate ?? xmp?.creationDate,
      modificationDate: info.modificationDate ?? xmp?.modificationDate,
      pdfVersion: pdfVersion
    )
  }

  /// /Info 딕셔너리를 해소·해석한다. 부재·해소 실패는 전 필드 `nil`인 빈 결과.
  private func collectInfoProperties() async -> InfoProperties {
    guard let infoValue = self.trailer[.info] else {
      return InfoProperties()
    }
    let infoID = infoValue.referenceValue
    guard case let .dictionary(dictionary) = (try? await self.resolve(infoValue)) ?? .null else {
      return InfoProperties()
    }
    let resolved = await self.resolvingInfoStringReferences(in: dictionary)
    return InfoDictionaryParser.parse(
      resolved, objectID: infoID, securityHandler: self.securityHandler
    )
  }

  /// /Info의 표준 8키 값 중 `.reference`를 1레벨 해소한 사본을 만든다 (실패는 원값 유지).
  private func resolvingInfoStringReferences(in dictionary: COSDictionary) async -> COSDictionary {
    var updated = dictionary
    for key in Self.infoStringKeys {
      guard let value = dictionary[key], case .reference = value else {
        continue
      }
      if let resolvedValue = try? await self.resolve(value) {
        updated[key] = resolvedValue
      }
    }
    return updated
  }

  /// /Root /Metadata 스트림을 찾아 XMP를 파싱한다. 무관용 실패 허용 (가정 1).
  private func collectXMPProperties() async -> XMPProperties? {
    guard let rootValue = self.trailer[.root],
      case let .dictionary(catalog) = (try? await self.resolve(rootValue)) ?? .null,
      let metadataID = catalog[.metadataKey]?.referenceValue
    else {
      return nil
    }
    guard let data = try? await self.decodedStreamData(for: metadataID),
      data.count <= CoreLimits.maxXMPMetadataBytes
    else {
      return nil
    }
    return XMPMetadataParser.parse(data)
  }

  /// 헤더 버전과 카탈로그 /Version 중 큰 쪽을 문자열로 반환한다.
  private func resolvedPDFVersionText() async -> String {
    guard let rootValue = self.trailer[.root],
      case let .dictionary(catalog) = (try? await self.resolve(rootValue)) ?? .null,
      let versionName = catalog.name(for: .version),
      let catalogVersion = Self.parsePDFVersionName(versionName.rawValue)
    else {
      return self.version.description
    }
    return max(self.version, catalogVersion).description
  }

  /// `"M.N"` 형식의 이름을 `PDFVersion`으로 파싱한다. 형식 위반이면 `nil`.
  private static func parsePDFVersionName(_ raw: String) -> PDFVersion? {
    let parts = raw.split(separator: ".")
    guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]) else {
      return nil
    }
    return PDFVersion(major: major, minor: minor)
  }
}
