// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "Papyrus",
  platforms: [
    .iOS(.v18),
    .macOS(.v15)
  ],
  products: [
    // 제품은 umbrella 하나만 노출한다. (ARCHITECTURE.md 확정)
    .library(name: "Papyrus", targets: ["Papyrus"])
  ],
  targets: [
    // ── 라이브러리 타겟 (의존 방향: UI → Rendering → Core) ──
    .target(name: "PapyrusCore"),
    .target(name: "PapyrusRendering", dependencies: ["PapyrusCore"]),
    .target(name: "PapyrusUI", dependencies: ["PapyrusRendering", "PapyrusCore"]),
    .target(name: "Papyrus", dependencies: ["PapyrusUI", "PapyrusRendering", "PapyrusCore"]),

    // ── 테스트 지원 (제품 비노출, 의존성 없음) ──
    .target(name: "PapyrusTestSupport"),

    // ── 테스트 타겟 ──
    .testTarget(
      name: "PapyrusTests",
      dependencies: ["Papyrus", "PapyrusRendering", "PapyrusUI"]
    ),
    .testTarget(
      name: "PapyrusTestSupportTests",
      dependencies: ["PapyrusTestSupport"]
    ),
    .testTarget(
      name: "PapyrusCoreTests",
      dependencies: ["PapyrusCore", "PapyrusTestSupport"]
    )
  ],
  swiftLanguageModes: [.v6]
)
