import Foundation
@testable import PapyrusPDFCore
import PapyrusPDFTestSupport
import Testing

// `COSParserTests`·`COSParserStreamTests` 공용 테스트 케이스 타입·헬퍼. 파일 분리는 순수
// 조직적 이유(파일 길이 제한)다.

/// 스트림 EOL 변형 케이스.
struct StreamEOLCase: Sendable, CustomTestStringConvertible {
  let eol: PDFFixtureBuilder.ContentStreamSpec.StreamEOL
  let expectsWarning: Bool
  let label: String
  var testDescription: String { self.label }
}

/// xorshift64 기반 결정적 PRNG (고정 시드 스모크 퍼징용).
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
  }

  mutating func next() -> UInt64 {
    self.state ^= self.state << 13
    self.state ^= self.state >> 7
    self.state ^= self.state << 17
    return self.state
  }
}

/// 테스트 전용 보조 에러.
enum TestSupportError: Error {
  case notAStream
}

/// 스니펫 전체를 하나의 값으로 파싱한다 (`COSParser.parseObject(at:)` 경유).
func parseValue(_ source: String) throws(COSParseError) -> COSObject {
  let file = MappedFile(data: Data(source.utf8))
  var parser = COSParser(file: file)
  return try parser.parseObject(at: 0)
}

/// 파싱 결과가 스트림이라고 가정하고 `fileRange` 페이로드를 꺼낸다.
func fileRange(of object: COSObject) throws -> Range<Int> {
  guard case let .stream(stream) = object, case let .fileRange(range) = stream.payload else {
    Issue.record("스트림 객체가 아님: \(object)")
    throw TestSupportError.notAStream
  }
  return range
}

func hasNonstandardStreamEOLWarning(_ warnings: [ParseWarning]) -> Bool {
  warnings.contains {
    if case .nonstandardStreamEOL = $0 {
      return true
    }
    return false
  }
}

func hasStreamLengthMismatchWarning(_ warnings: [ParseWarning]) -> Bool {
  warnings.contains {
    if case .streamLengthMismatch = $0 {
      return true
    }
    return false
  }
}
