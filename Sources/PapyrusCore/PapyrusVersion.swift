/// Papyrus 패키지의 버전 정보.
///
/// M0에서는 `Papyrus` umbrella 타겟의 `@_exported` 재수출 배선을 검증하는
/// 스모크 심벌 역할을 겸한다.
public enum PapyrusVersion {
  /// 현재 패키지 버전 문자열 (semver).
  public static let current = "0.1.0"
}
