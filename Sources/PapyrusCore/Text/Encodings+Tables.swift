// ``PDFBaseEncoding``의 정적 테이블 데이터. 파일 분리는 순수 조직적 이유(파일 길이 제한,
// M4 설계 §7 말미)이며, 타입·의미는 `Encodings.swift`와 동일하다.

extension PDFBaseEncoding {
  /// ASCII 가시 영역(32...126) 공통 베이스 테이블을 만든다. 세 인코딩 모두 이 영역을
  /// 공유하며(따옴표류 두 코드만 예외), override로 세부 편차만 덮어쓴다.
  static func buildTable(overrides: [Int: String]) -> [String?] {
    var table = Self.asciiBaseTable()
    for (code, name) in overrides {
      table[code] = name
    }
    return table
  }

  /// ASCII 가시 영역(32...126) 글리프 이름 테이블. PostScript 관례상 알파벳 글리프
  /// 이름은 문자 자신과 동일하다(`"A"`, `"z"` 등).
  private static func asciiBaseTable() -> [String?] {
    var table = [String?](repeating: nil, count: 256)
    let punctuation: [Int: String] = [
      32: "space", 33: "exclam", 34: "quotedbl", 35: "numbersign", 36: "dollar",
      37: "percent", 38: "ampersand", 39: "quotesingle", 40: "parenleft", 41: "parenright",
      42: "asterisk", 43: "plus", 44: "comma", 45: "hyphen", 46: "period", 47: "slash",
      48: "zero", 49: "one", 50: "two", 51: "three", 52: "four", 53: "five", 54: "six",
      55: "seven", 56: "eight", 57: "nine", 58: "colon", 59: "semicolon", 60: "less",
      61: "equal", 62: "greater", 63: "question", 64: "at", 91: "bracketleft",
      92: "backslash", 93: "bracketright", 94: "asciicircum", 95: "underscore", 96: "grave",
      123: "braceleft", 124: "bar", 125: "braceright", 126: "asciitilde"
    ]
    for (code, name) in punctuation {
      table[code] = name
    }
    for code in 65...90 {
      table[code] = String(UnicodeScalar(UInt8(code)))
    }
    for code in 97...122 {
      table[code] = String(UnicodeScalar(UInt8(code)))
    }
    return table
  }

  /// StandardEncoding이 ASCII 베이스와 갈리는 지점 — 조판용 따옴표(quoteright/quoteleft).
  static let standardOverrides: [Int: String] = [39: "quoteright", 96: "quoteleft"]

  /// WinAnsiEncoding 고역(128...255) — Windows-1252 근사(정의되지 않은 코드는 미기재).
  static let winAnsiOverrides: [Int: String] = [
    128: "Euro", 130: "quotesinglbase", 131: "florin", 132: "quotedblbase",
    133: "ellipsis", 134: "dagger", 135: "daggerdbl", 136: "circumflex",
    137: "perthousand", 138: "Scaron", 139: "guilsinglleft", 140: "OE",
    142: "Zcaron", 145: "quoteleft", 146: "quoteright", 147: "quotedblleft",
    148: "quotedblright", 149: "bullet", 150: "endash", 151: "emdash", 152: "tilde",
    153: "trademark", 154: "scaron", 155: "guilsinglright", 156: "oe", 158: "zcaron",
    159: "Ydieresis", 160: "space", 161: "exclamdown", 162: "cent", 163: "sterling",
    164: "currency", 165: "yen", 166: "brokenbar", 167: "section", 168: "dieresis",
    169: "copyright", 170: "ordfeminine", 171: "guillemotleft", 172: "logicalnot",
    173: "hyphen", 174: "registered", 175: "macron", 176: "degree", 177: "plusminus",
    178: "twosuperior", 179: "threesuperior", 180: "acute", 181: "mu", 182: "paragraph",
    183: "periodcentered", 184: "cedilla", 185: "onesuperior", 186: "ordmasculine",
    187: "guillemotright", 188: "onequarter", 189: "onehalf", 190: "threequarters",
    191: "questiondown", 192: "Agrave", 193: "Aacute", 194: "Acircumflex", 195: "Atilde",
    196: "Adieresis", 197: "Aring", 198: "AE", 199: "Ccedilla", 200: "Egrave",
    201: "Eacute", 202: "Ecircumflex", 203: "Edieresis", 204: "Igrave", 205: "Iacute",
    206: "Icircumflex", 207: "Idieresis", 208: "Eth", 209: "Ntilde", 210: "Ograve",
    211: "Oacute", 212: "Ocircumflex", 213: "Otilde", 214: "Odieresis", 215: "multiply",
    216: "Oslash", 217: "Ugrave", 218: "Uacute", 219: "Ucircumflex", 220: "Udieresis",
    221: "Yacute", 222: "Thorn", 223: "germandbls", 224: "agrave", 225: "aacute",
    226: "acircumflex", 227: "atilde", 228: "adieresis", 229: "aring", 230: "ae",
    231: "ccedilla", 232: "egrave", 233: "eacute", 234: "ecircumflex", 235: "edieresis",
    236: "igrave", 237: "iacute", 238: "icircumflex", 239: "idieresis", 240: "eth",
    241: "ntilde", 242: "ograve", 243: "oacute", 244: "ocircumflex", 245: "otilde",
    246: "odieresis", 247: "divide", 248: "oslash", 249: "ugrave", 250: "uacute",
    251: "ucircumflex", 252: "udieresis", 253: "yacute", 254: "thorn", 255: "ydieresis"
  ]

  /// MacRomanEncoding 고역(128...255) — Mac OS Roman 근사.
  static let macRomanOverrides: [Int: String] = [
    128: "Adieresis", 129: "Aring", 130: "Ccedilla", 131: "Eacute", 132: "Ntilde",
    133: "Odieresis", 134: "Udieresis", 135: "aacute", 136: "agrave", 137: "acircumflex",
    138: "adieresis", 139: "atilde", 140: "aring", 141: "ccedilla", 142: "eacute",
    143: "egrave", 144: "ecircumflex", 145: "edieresis", 146: "iacute", 147: "igrave",
    148: "icircumflex", 149: "idieresis", 150: "ntilde", 151: "oacute", 152: "ograve",
    153: "ocircumflex", 154: "odieresis", 155: "otilde", 156: "uacute", 157: "ugrave",
    158: "ucircumflex", 159: "udieresis", 160: "dagger", 161: "degree", 162: "cent",
    163: "sterling", 164: "section", 165: "bullet", 166: "paragraph", 167: "germandbls",
    168: "registered", 169: "copyright", 170: "trademark", 171: "acute", 172: "dieresis",
    174: "AE", 175: "Oslash", 177: "plusminus", 180: "yen", 181: "mu",
    187: "ordfeminine", 188: "ordmasculine", 190: "ae", 191: "oslash",
    192: "questiondown", 193: "exclamdown", 194: "logicalnot", 196: "florin",
    199: "guillemotleft", 200: "guillemotright", 201: "ellipsis", 202: "space",
    203: "Agrave", 204: "Atilde", 205: "Otilde", 206: "OE", 207: "oe", 208: "endash",
    209: "emdash", 210: "quotedblleft", 211: "quotedblright", 212: "quoteleft",
    213: "quoteright", 214: "divide", 216: "ydieresis", 217: "Ydieresis",
    219: "currency", 220: "guilsinglleft", 221: "guilsinglright", 222: "fi", 223: "fl",
    224: "daggerdbl", 225: "periodcentered", 226: "quotesinglbase", 227: "quotedblbase",
    228: "perthousand", 229: "Acircumflex", 230: "Ecircumflex", 231: "Aacute",
    232: "Edieresis", 233: "Egrave", 234: "Iacute", 235: "Icircumflex", 236: "Idieresis",
    237: "Igrave", 238: "Oacute", 239: "Ocircumflex", 241: "Ograve", 242: "Uacute",
    243: "Ucircumflex", 244: "Ugrave", 245: "dotlessi", 246: "circumflex", 247: "tilde",
    248: "macron", 249: "breve", 250: "dotaccent", 251: "ring", 252: "cedilla",
    253: "hungarumlaut", 254: "ogonek", 255: "caron"
  ]
}
