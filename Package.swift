// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "PapyrusPDF",
  platforms: [
    .iOS(.v18),
    .macOS(.v15)
  ],
  products: [
    // 제품은 umbrella 하나만 노출한다. (ARCHITECTURE.md 확정)
    .library(name: "PapyrusPDF", targets: ["PapyrusPDF"])
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0")
  ],
  targets: [
    // ── 라이브러리 타겟 (의존 방향: UI → Rendering → Core) ──
    .target(name: "PapyrusPDFCore"),
    .target(name: "PapyrusPDFRendering", dependencies: ["PapyrusPDFCore"]),
    .target(name: "PapyrusPDFUI", dependencies: ["PapyrusPDFRendering", "PapyrusPDFCore"]),
    .target(
      name: "PapyrusPDF",
      dependencies: ["PapyrusPDFUI", "PapyrusPDFRendering", "PapyrusPDFCore"]
    ),

    // ── 테스트 지원 (제품 비노출, 의존성 없음) ──
    .target(name: "PapyrusPDFTestSupport"),

    // ── 테스트 타겟 ──
    .testTarget(
      name: "PapyrusPDFTests",
      dependencies: ["PapyrusPDF", "PapyrusPDFRendering", "PapyrusPDFUI", "PapyrusPDFTestSupport"]
    ),
    .testTarget(
      name: "PapyrusPDFTestSupportTests",
      dependencies: ["PapyrusPDFTestSupport"]
    ),
    .testTarget(
      name: "PapyrusPDFCoreTests",
      dependencies: ["PapyrusPDFCore", "PapyrusPDFTestSupport"]
    ),
    .testTarget(
      name: "PapyrusPDFRenderingTests",
      dependencies: ["PapyrusPDFRendering", "PapyrusPDFCore", "PapyrusPDFTestSupport"]
    ),
    .testTarget(
      name: "PapyrusPDFUITests",
      dependencies: [
        "PapyrusPDFUI", "PapyrusPDFRendering", "PapyrusPDFCore", "PapyrusPDFTestSupport"
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
