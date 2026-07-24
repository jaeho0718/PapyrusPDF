import Foundation
import Papyrus
import PapyrusTestSupport
import Testing

/// 5,000페이지 합성 PDF 성능 게이트 (설계 §5.6 PG1-PG4).
///
/// `PAPYRUS_PERF=1` 환경 플래그 뒤에서만 실행된다 — CI/로컬 기본 실행에서는 스킵된다.
/// `ContinuousClock` 수동 측정 + 3회 중앙값으로 노이즈를 완화한다 (`.timeLimit`은 분 단위만
/// 표현 가능해 250ms/1ms 문턱값 판정에는 쓸 수 없다 — ARCHITECTURE.md 수정 권고 2).
///
/// **게이트 판정은 release 빌드(`-c release`) 기준이다** (r1). debug 빌드는 옵티마이저
/// 부재로 동일 코드가 임계값을 초과하는 것이 정상이며(실측: debug 432ms vs release
/// 193ms), 게이트 판정에 쓰지 않는다 — `PAPYRUS_PERF=1 swift test -c release --filter
/// PerformanceGateTests`가 M3 완료 기준의 정본 판정 절차다. debug로 돌리면(예: 기본
/// `swift test`) 통과가 보장되지 않으며 이는 로직 결함이 아니라 빌드 설정 문제다.
///
/// 임계값(250ms/1ms)은 로컬 release 실측 기준(배율 1)이며 불변이다. env
/// `PAPYRUS_PERF_SCALE`(Double, 부재·비양수 → 1.0)을 곱해 공유 CI 러너의 하드웨어
/// 변동만 흡수한다(§5.8) — 배율 적용 사실은 실패 메시지에 표기한다.
@Suite(
  .enabled(if: ProcessInfo.processInfo.environment["PAPYRUS_PERF"] == "1"),
  .serialized,
  .timeLimit(.minutes(1))
)
struct PerformanceGateTests {
  /// 스위트 내 1회만 생성되어 공유되는 5,000페이지 픽스처(스타일별) — 게이트 측정 구간에
  /// 생성 비용이 포함되지 않도록 한다 (PG4).
  private static let pageCount = 5_000

  private static let classicTableData: Data = PDFFixtureBuilder(
    pageCount: Self.pageCount, xrefStyle: .classicTable
  ).build().data

  private static let objectStreamsData: Data = PDFFixtureBuilder(
    pageCount: Self.pageCount, xrefStyle: .objectStreams
  ).build().data

  /// `PAPYRUS_PERF_SCALE` 예산 배율. 부재·파싱 실패·비양수는 전부 1.0 (배율 미적용).
  private static let perfScale: Double = {
    guard let raw = ProcessInfo.processInfo.environment["PAPYRUS_PERF_SCALE"],
      let value = Double(raw), value > 0
    else {
      return 1.0
    }
    return value
  }()

  // MARK: PG1 — 5,000페이지 .classicTable 열기+pageCount

  /// PG1: `open(data:)` + `pageCount` 중앙값 < 250ms(× 배율).
  @Test func classicTableOpenAndPageCountUnder250Milliseconds() async throws {
    var samples: [Duration] = []
    for _ in 0..<3 {
      let clock = ContinuousClock()
      let start = clock.now
      let document = try await PapyrusDocument.open(data: Self.classicTableData)
      _ = try await document.pageCount
      samples.append(clock.now - start)
    }
    let median = Self.median(samples)
    let budget = Self.scaledBudget(milliseconds: 250)
    #expect(median < budget, "중앙값 \(median)이 예산 \(budget)(배율 \(Self.perfScale))을 초과함")
  }

  // MARK: PG2 — warm page(at:)

  /// PG2: PG1 이후 균등 분포 1,000회 호출 총시간/1,000 < 1ms(× 배율).
  @Test func warmPageAtAveragesUnder1Millisecond() async throws {
    let document = try await PapyrusDocument.open(data: Self.classicTableData)
    _ = try await document.pageCount // 평탄화를 미리 유발(warm-up).

    let callCount = 1_000
    let clock = ContinuousClock()
    let start = clock.now
    for index in 0..<callCount {
      let pageIndex = (index * Self.pageCount) / callCount
      _ = try await document.page(at: pageIndex)
    }
    let elapsed = clock.now - start
    let average = elapsed / callCount
    let budget = Self.scaledBudget(milliseconds: 1)
    #expect(average < budget, "평균 \(average)이 예산 \(budget)(배율 \(Self.perfScale))을 초과함")
  }

  // MARK: PG3 — 5,000페이지 .objectStreams

  /// PG3: 5,000페이지 `.objectStreams` open + pageCount < 250ms(× 배율, ObjStm 압축 해제
  /// 경유 최악 경로).
  @Test func objectStreamsOpenAndPageCountUnder250Milliseconds() async throws {
    var samples: [Duration] = []
    for _ in 0..<3 {
      let clock = ContinuousClock()
      let start = clock.now
      let document = try await PapyrusDocument.open(data: Self.objectStreamsData)
      _ = try await document.pageCount
      samples.append(clock.now - start)
    }
    let median = Self.median(samples)
    let budget = Self.scaledBudget(milliseconds: 250)
    #expect(median < budget, "중앙값 \(median)이 예산 \(budget)(배율 \(Self.perfScale))을 초과함")
  }

  // MARK: PG5 — M7 검색 스트림 완주 (선택)

  /// PG5: 100페이지 문서 전체 검색(매치 없음 — 전 페이지 순회 강제) 완주 중앙값 <
  /// 200ms(× 배율). 회귀 감지용 관대한 상한.
  @Test func fullDocumentSearchCompletesUnder200Milliseconds() async throws {
    let searchScanData = PDFFixtureBuilder(pageCount: 100).build().data
    var samples: [Duration] = []
    for _ in 0..<3 {
      let document = try await PapyrusDocument.open(data: searchScanData)
      let clock = ContinuousClock()
      let start = clock.now
      for try await _ in document.search("needle") {}
      samples.append(clock.now - start)
    }
    let median = Self.median(samples)
    let budget = Self.scaledBudget(milliseconds: 200)
    #expect(median < budget, "중앙값 \(median)이 예산 \(budget)(배율 \(Self.perfScale))을 초과함")
  }
}

// MARK: - 측정 헬퍼

extension PerformanceGateTests {
  /// 3개 표본의 중앙값 (짝수 개는 이 스위트에서 쓰지 않으므로 홀수 전제로 단순화).
  private static func median(_ samples: [Duration]) -> Duration {
    samples.sorted()[samples.count / 2]
  }

  /// 기준 예산(ms)에 `perfScale`을 곱한 최종 예산을 만든다.
  private static func scaledBudget(milliseconds base: Int) -> Duration {
    .milliseconds(Int((Double(base) * Self.perfScale).rounded()))
  }
}
