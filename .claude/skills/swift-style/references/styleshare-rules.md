# StyleShare swift-style-guide 전체 규칙 정리

원문: https://github.com/StyleShare/swift-style-guide
(Papyrus 적용 기준. SwiftLint 규칙 매핑은 `.swiftlint.yml` 참조)

## 목차

1. [코드 레이아웃](#코드-레이아웃)
2. [네이밍](#네이밍)
3. [클로저](#클로저)
4. [타입 표기](#타입-표기)
5. [클래스와 구조체](#클래스와-구조체)
6. [주석과 구조화](#주석과-구조화)
7. [기타 관례](#기타-관례)

## 코드 레이아웃

### 들여쓰기와 공백
- 들여쓰기는 **2칸 스페이스** (탭 금지)
- 콜론은 **오른쪽에만** 공백: `let names: [String: String]?`
- 연산자 오버로딩 정의 시 연산자와 괄호 사이 한 칸: `func ** (lhs: Int, rhs: Int)`

### 줄 길이
- 한 줄 최대 **99자**

### 줄바꿈
- 함수 정의가 길면 여는 괄호 뒤에서 줄바꿈, 파라미터를 2칸 들여쓰기:

```swift
func collectionView(
  _ collectionView: UICollectionView,
  cellForItemAt indexPath: IndexPath
) -> UICollectionViewCell {
```

- 함수 호출이 길면 파라미터 이름 기준으로 줄바꿈
- 클로저가 2개 이상이면 반드시 각각 줄바꿈
- `if let`이 길면 줄바꿈 후 한 칸 들여쓰기 연속
- `guard let`이 길면 줄바꿈·들여쓰기, `else`는 `guard`와 정렬

### 빈 줄
- 빈 줄에 공백(trailing whitespace) 금지
- 파일은 빈 줄로 끝남
- `// MARK:` 위아래에 빈 줄

### import
- 알파벳 순 정렬
- 내장 프레임워크 먼저, 빈 줄 하나, 그다음 서드파티:

```swift
import UIKit

import SwiftyColor
import Then
```

## 네이밍

- **클래스·구조체·프로토콜·enum 타입**: UpperCamelCase, 접두사 없음
- **함수**: lowerCamelCase. `get` 접두사 금지 (`memberList()` ❌ → `members` 프로퍼티나
  적절한 동사). 액션 메서드는 "주어 + 동사 + 목적어": `backButtonDidTap()`,
  `originalPriceLabelDidTap()`
- **변수·상수**: lowerCamelCase. 상수도 SCREAMING_SNAKE_CASE 금지
- **enum case**: lowerCamelCase
- **약어**: 첫 요소면 소문자로 시작, 아니면 전부 대문자 —
  `userID`, `html`, `websiteURL`, `urlString`, `htmlString`
- **델리게이트 메서드**: 프로토콜명으로 네임스페이스 —
  `func userCellDidSetProfileImage(_ cell: UserCell)`

## 클로저

- 파라미터·반환 없는 타입은 `() -> Void` (`() -> ()` 금지)
- 정의 시 파라미터 괄호 생략: `{ operation, responseObject in`
- 타입 추론 가능하면 타입 생략
- 유일한 클로저 인자면 trailing closure로 라벨 생략

## 타입 표기

- `Array<T>` 대신 `[T]`
- `Dictionary<T, U>` 대신 `[T: U]`

## 클래스와 구조체

- 클래스·구조체 **내부에서 `self` 명시적 사용**
- 구조체 생성 시 Swift 이니셜라이저 사용: `CGRect(x:y:width:height:)`
  (`CGRectMake` 등 레거시 금지)

## 주석과 구조화

- 문서 주석은 `///`
- `// MARK:`로 관련 코드 구획화
- 프로토콜 구현은 extension으로 분리하고 `// MARK: - ProtocolName`

## 기타 관례

- 변수는 가능하면 선언과 동시에 초기화
- 상속되지 않는 클래스는 `final`
- 상수 그룹핑에는 enum 사용 (인스턴스화 방지):

```swift
final class SomeView: UIView {
  private enum Metric {
    static let profileImageViewLeft = 10.0
  }
  private enum Font {
    static let nameLabel = UIFont.boldSystemFont(ofSize: 14)
  }
}
```
