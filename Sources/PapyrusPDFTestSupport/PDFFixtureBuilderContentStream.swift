import Foundation

// ``PDFFixtureBuilder/ContentStreamSpec`` 정의. 파일 분리는 순수 조직적 이유(타입 길이
// 제한)이며, `PDFFixtureBuilder`에 직접 선언한 것과 완전히 동일한 타입·의미를 갖는다.
//
// 아래 3단 중첩(PDFFixtureBuilder → ContentStreamSpec → Encoding/LengthStyle/StreamEOL)은
// 설계 문서(§2.7b)가 명시한 구조를 그대로 따른다 — 이 구조는 SwiftLint 기본
// `nesting`(최대 1단) 규칙과 충돌하므로, 이 파일 범위에서만 규칙을 끈다.
// swiftlint:disable nesting

extension PDFFixtureBuilder {
  /// 전 페이지가 공유하는 콘텐츠 스트림 명세.
  package struct ContentStreamSpec: Sendable {
    /// 스트림 원문 (인코딩 전).
    package var body: Data

    /// 페이로드 인코딩. 순서 = 인코딩 적용 순서(디코딩은 역순 `/Filter` 배열).
    package var encodings: [Encoding]

    /// `/Length` 기록 방식.
    package var lengthStyle: LengthStyle

    /// `stream` 키워드 직후 EOL (파서 EOL 변형 테스트용).
    package var streamEOL: StreamEOL

    /// 지원하는 페이로드 인코딩 종류.
    package enum Encoding: Sendable {
      /// `/FlateDecode`.
      case flate
      /// `/LZWDecode` (기본 `/EarlyChange` 1 — 미기록, 스펙 기본값과 일치).
      case lzw
      /// `/ASCIIHexDecode`.
      case asciiHex
      /// `/ASCII85Decode`.
      case ascii85
      /// `/RunLengthDecode`.
      case runLength
    }

    /// `/Length` 기록 방식.
    package enum LengthStyle: Sendable, Equatable {
      /// 정확한 정수 `/Length`.
      case direct
      /// `/Length N 0 R` (별도 정수 객체).
      case indirect
      /// 의도적 불일치 (파서 복구 경로 검증용). 실제 길이에 `delta`를 더한 값을 기록한다.
      case directWrong(delta: Int)
    }

    /// `stream` 키워드 직후 EOL. `cr`은 비표준(파서 경고 검증용).
    package enum StreamEOL: Sendable {
      /// LF(`0x0A`) 단독 — 표준.
      case lf
      /// CRLF(`0x0D 0x0A`) — 표준.
      case crlf
      /// CR(`0x0D`) 단독 — 비표준(파서가 `nonstandardStreamEOL` 경고를 남긴다).
      case cr

      /// 이 EOL 변형이 기록하는 원시 바이트.
      var bytes: [UInt8] {
        switch self {
        case .lf:
          return [0x0A]
        case .crlf:
          return [0x0D, 0x0A]
        case .cr:
          return [0x0D]
        }
      }
    }

    /// 콘텐츠 스트림 명세를 생성한다.
    /// - Parameters:
    ///   - body: 스트림 원문 (인코딩 전).
    ///   - encodings: 페이로드 인코딩 (기본 없음 — 미압축).
    ///   - lengthStyle: `/Length` 기록 방식 (기본 `.direct`).
    ///   - streamEOL: `stream` 키워드 직후 EOL (기본 `.lf`).
    package init(
      body: Data,
      encodings: [Encoding] = [],
      lengthStyle: LengthStyle = .direct,
      streamEOL: StreamEOL = .lf
    ) {
      self.body = body
      self.encodings = encodings
      self.lengthStyle = lengthStyle
      self.streamEOL = streamEOL
    }
  }
}

// swiftlint:enable nesting

// MARK: - 콘텐츠 스트림 인코딩 헬퍼 (파일 분리로 `PDFFixtureBuilder` 본체 길이 관리)

extension PDFFixtureBuilder {
  /// 인코딩 하나를 순방향(인코딩 방향)으로 적용한다.
  static func applyEncoding(
    _ encoding: ContentStreamSpec.Encoding, to data: Data
  ) -> Data {
    switch encoding {
    case .flate:
      return PDFFilterEncoders.flate(data)
    case .lzw:
      return PDFFilterEncoders.lzw(data)
    case .asciiHex:
      return PDFFilterEncoders.asciiHex(data)
    case .ascii85:
      return PDFFilterEncoders.ascii85(data)
    case .runLength:
      return PDFFilterEncoders.runLength(data)
    }
  }

  /// 인코딩 종류에 대응하는 PDF 표준 필터 이름.
  static func filterName(for encoding: ContentStreamSpec.Encoding) -> String {
    switch encoding {
    case .flate:
      return "/FlateDecode"
    case .lzw:
      return "/LZWDecode"
    case .asciiHex:
      return "/ASCIIHexDecode"
    case .ascii85:
      return "/ASCII85Decode"
    case .runLength:
      return "/RunLengthDecode"
    }
  }

  /// `/Length`에 기록할 정수 값을 결정한다 (`.directWrong`은 의도적으로 어긋난 값).
  static func declaredLength(
    for encoded: Data, style: ContentStreamSpec.LengthStyle
  ) -> Int {
    switch style {
    case .direct, .indirect:
      return encoded.count
    case let .directWrong(delta):
      return encoded.count + delta
    }
  }
}
