import Foundation

// `PDFFixtureBuilder`의 M4 텍스트 추출 픽스처 명세 타입 + 기록 로직. 파일 분리는 순수
// 조직적 이유(§6)이며, `.classicTable` 전용이다(가정 12).
//
// 다단 중첩(PDFFixtureBuilder → TextFixtureSpec → TextPageSpec/FontFixtureSpec/…)은 설계
// 문서(§6.2)가 명시한 구조를 그대로 따른다 — SwiftLint 기본 `nesting`(최대 1단) 규칙과
// 충돌하므로 이 파일 범위에서만 끈다.
// swiftlint:disable nesting

extension PDFFixtureBuilder {
  /// M4 텍스트 픽스처 명세. 설정 시 `.classicTable` 전용·타 스펙 배타 (가정 12).
  /// 페이지 수 == `pages.count`.
  package struct TextFixtureSpec: Sendable {
    /// 페이지별 명세 (문서 순서).
    package var pages: [TextPageSpec]

    /// 텍스트 픽스처 명세를 생성한다.
    /// - Parameter pages: 페이지별 명세.
    package init(pages: [TextPageSpec]) {
      self.pages = pages
    }

    /// 페이지 하나의 명세.
    package struct TextPageSpec: Sendable {
      /// 콘텐츠 스트림 원문 (연산자 시퀀스 그대로).
      package var operations: String
      /// `/Resources /Font` 항목들.
      package var fonts: [FontFixtureSpec]
      /// `/Resources /XObject` 항목들 (Form).
      package var formXObjects: [FormXObjectFixtureSpec]
      /// 콘텐츠 스트림 인코딩 (기본 `[]` — 미압축. LZW 조합 테스트용).
      package var encodings: [ContentStreamSpec.Encoding]
      /// `/Contents`를 배열(세그먼트 분할)로 기록할 분할 지점들 (기본 `[]` — 단일).
      /// 값은 `operations`의 UTF-8 바이트 오프셋.
      package var segmentBreaks: [Int]

      /// 페이지 명세를 생성한다.
      /// - Parameters:
      ///   - operations: 콘텐츠 스트림 원문.
      ///   - fonts: `/Resources /Font` 항목들 (기본 `[]`).
      ///   - formXObjects: `/Resources /XObject` 항목들 (기본 `[]`).
      ///   - encodings: 콘텐츠 스트림 인코딩 (기본 `[]`).
      ///   - segmentBreaks: `/Contents` 분할 지점들 (기본 `[]`).
      package init(
        operations: String, fonts: [FontFixtureSpec] = [],
        formXObjects: [FormXObjectFixtureSpec] = [],
        encodings: [ContentStreamSpec.Encoding] = [], segmentBreaks: [Int] = []
      ) {
        self.operations = operations
        self.fonts = fonts
        self.formXObjects = formXObjects
        self.encodings = encodings
        self.segmentBreaks = segmentBreaks
      }
    }

    /// 폰트 하나의 명세. 동등한 스펙을 여러 페이지/폼이 공유하면 객체도 공유된다
    /// (TC4 dedupe 검증용, §6.2 기록 규칙).
    package struct FontFixtureSpec: Sendable, Equatable {
      /// `/Resources /Font` 내 이 폰트의 리소스 이름 (예: `"F1"`).
      package var resourceName: String
      /// 폰트 종류.
      package var kind: Kind
      /// `/FontDescriptor` 값 (`nil`이면 디스크립터 미기록).
      package var descriptor: DescriptorSpec?

      /// 단순 폰트 명세를 생성한다.
      package init(resourceName: String, kind: Kind, descriptor: DescriptorSpec? = nil) {
        self.resourceName = resourceName
        self.kind = kind
        self.descriptor = descriptor
      }

      /// 폰트 종류.
      package enum Kind: Sendable, Equatable {
        /// 단순 폰트 (`/Type1` 고정 — 해석 경로는 Subtype 무관).
        case simple(
          baseFont: String, baseEncoding: String?, differences: [Int: String],
          firstChar: Int, widths: [Int], toUnicode: [UInt8: String]?
        )
        /// Type0 + Identity-H. `cidWidths`는 `/W`의 `[c1 c2 w]` 형식으로 기록.
        case type0IdentityH(
          baseFont: String, toUnicode: [UInt16: String], cidWidths: [CIDWidthRange],
          defaultWidth: Int
        )
        /// Type0 + 임베디드 CMap 원문 (CID CMap 소스 그대로 기록).
        case type0EmbeddedCMap(
          baseFont: String, cmapSource: String, toUnicode: [UInt16: String]?, defaultWidth: Int
        )
        /// Type0 + 사전정의 CMap 이름 (U+FFFD 경로 검증용 — ToUnicode 미기록).
        case type0Predefined(baseFont: String, cmapName: String)
      }

      /// `/W` 균일 구간 하나 (`[first last width]`).
      package struct CIDWidthRange: Sendable, Equatable {
        /// 구간 시작 CID.
        package var first: Int
        /// 구간 끝 CID.
        package var last: Int
        /// 구간 폭.
        package var width: Int

        /// 구간을 생성한다.
        package init(first: Int, last: Int, width: Int) {
          self.first = first
          self.last = last
          self.width = width
        }
      }

      /// `/FontDescriptor` 값 명세.
      package struct DescriptorSpec: Sendable, Equatable {
        /// `/Ascent`.
        package var ascent: Int
        /// `/Descent`.
        package var descent: Int
        /// `/MissingWidth` (`nil`이면 미기록).
        package var missingWidth: Int?

        /// 디스크립터 명세를 생성한다.
        package init(ascent: Int, descent: Int, missingWidth: Int? = nil) {
          self.ascent = ascent
          self.descent = descent
          self.missingWidth = missingWidth
        }
      }
    }

    /// Form XObject 하나의 명세.
    package struct FormXObjectFixtureSpec: Sendable {
      /// `/Resources /XObject` 내 이 폼의 리소스 이름 (예: `"Fm1"`).
      package var resourceName: String
      /// 콘텐츠 스트림 원문.
      package var operations: String
      /// `/Matrix` (6원소, 기본 항등).
      package var matrix: [Double]
      /// 폼 자체 리소스 폰트 (페이지 폰트와 독립된 이름 공간, 객체는 스펙 동등성으로 공유).
      package var fonts: [FontFixtureSpec]

      /// 폼 명세를 생성한다.
      /// - Parameters:
      ///   - resourceName: 리소스 이름.
      ///   - operations: 콘텐츠 스트림 원문.
      ///   - matrix: `/Matrix` (기본 항등 `[1 0 0 1 0 0]`).
      ///   - fonts: 폼 자체 리소스 폰트 (기본 `[]`).
      package init(
        resourceName: String, operations: String, matrix: [Double] = [1, 0, 0, 1, 0, 0],
        fonts: [FontFixtureSpec] = []
      ) {
        self.resourceName = resourceName
        self.operations = operations
        self.matrix = matrix
        self.fonts = fonts
      }
    }
  }
}

// swiftlint:enable nesting
