import Foundation

/// Mathematics in solver text.
///
/// The solver writes math as LaTeX inside its JSON strings: `$...$` inline and `$$...$$` on a line of its own (`\(...\)` and
/// `\[...\]` are accepted too), with `\$` for a literal dollar sign. `segments` splits a string into prose and formulas,
/// `typesettable` prepares a formula for SwiftMath, and `plain` turns a formula into readable Unicode when it cannot be typeset.
/// This part is pure Foundation so it is tested on Linux; the PDF typesetter at the end of the file needs UIKit and SwiftMath.
enum MathText {
  enum Segment: Equatable, Sendable {
    case text(String)
    case inline(String)
    case display(String)
  }

  // MARK: Splitting text and formulas

  /// Splits `text` into prose and formulas. `$$` is matched before `$`. A `$` with no valid partner stays a literal dollar sign,
  /// so "costs $5 and $10" is prose: an inline formula may not start or end with a space (unless it clearly holds LaTeX) and its
  /// closing `$` may not be followed by a digit. Empty formulas are dropped.
  static func segments(_ text: String) -> [Segment] {
    let chars = Array(text)
    var result: [Segment] = []
    var prose = ""
    var index = 0
    func emit(_ segment: Segment) {
      if !prose.isEmpty { result.append(.text(prose)); prose = "" }
      result.append(segment)
    }
    func body(_ start: Int, _ end: Int) -> String {
      repairedEscapes(String(chars[start..<end])).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    while index < chars.count {
      let char = chars[index]
      let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
      if char == "\\" {
        if next == "$" { prose.append("$"); index += 2; continue }
        if next == "\\" { prose.append("\\\\"); index += 2; continue }
        if next == "(" || next == "[", let end = backslashCloser(next == "(" ? ")" : "]", in: chars, from: index + 2) {
          let math = body(index + 2, end)
          if !math.isEmpty { emit(next == "(" ? .inline(math) : .display(math)) }
          index = end + 2; continue
        }
        prose.append(char); index += 1; continue
      }
      if char == "$" {
        if next == "$" {
          if let end = dollarCloser(in: chars, from: index + 2, double: true) {
            let math = body(index + 2, end)
            if !math.isEmpty { emit(.display(math)) }
            index = end + 2; continue
          }
          prose.append("$$"); index += 2; continue
        }
        if let end = dollarCloser(in: chars, from: index + 1, double: false), validInline(chars, open: index, close: end) {
          emit(.inline(body(index + 1, end)))
          index = end + 1; continue
        }
        prose.append("$"); index += 1; continue
      }
      prose.append(char); index += 1
    }
    if !prose.isEmpty { result.append(.text(prose)) }
    return result
  }

  /// `text` with every formula replaced by its readable Unicode form; prose without math is returned unchanged (apart from `\$`).
  static func readable(_ text: String) -> String {
    segments(text).map { segment -> String in
      switch segment {
      case .text(let prose): return prose
      case .inline(let math), .display(let math): return plain(math)
      }
    }.joined()
  }

  /// The next unescaped `$` (or `$$`) at or after `start`; a backslash inside math escapes the next character.
  private static func dollarCloser(in chars: [Character], from start: Int, double: Bool) -> Int? {
    var index = start
    while index < chars.count {
      if chars[index] == "\\" { index += 2; continue }
      if chars[index] == "$" {
        if !double { return index }
        if index + 1 < chars.count, chars[index + 1] == "$" { return index }
      }
      index += 1
    }
    return nil
  }

  private static func backslashCloser(_ closer: Character, in chars: [Character], from start: Int) -> Int? {
    var index = start
    while index + 1 < chars.count {
      if chars[index] == "\\" {
        if chars[index + 1] == closer { return index }
        index += 2; continue
      }
      index += 1
    }
    return nil
  }

  private static func validInline(_ chars: [Character], open: Int, close: Int) -> Bool {
    let content = chars[(open + 1)..<close]
    guard let first = content.first, let last = content.last, !content.allSatisfy(\.isWhitespace) else { return false }
    if close + 1 < chars.count, chars[close + 1].isASCII, chars[close + 1].isNumber { return false }
    if String(content).contains("\n\n") { return false }
    let tight = !first.isWhitespace && !last.isWhitespace
    return tight || content.contains { "\\^_{}=".contains($0) }
  }

  // MARK: Preparing a formula for SwiftMath

  /// `latex` rewritten for SwiftMath 1.7, or nil when it would be typeset wrongly. SwiftMath silently drops characters it does not
  /// know (any non-ASCII symbol, `'`, `~`, `%`), so common Unicode symbols become commands, primes become `^{\prime}`, and a
  /// formula that still holds a non-ASCII character is left to `plain`. Common commands SwiftMath lacks are mapped to ones it has.
  static func typesettable(_ latex: String) -> String? {
    let latex = repairedEscapes(latex)
    var source = ""
    var pendingScript: (mark: Character, text: String)?
    func flushScript() {
      if let script = pendingScript { source += "\(script.mark){\(script.text)}"; pendingScript = nil }
    }
    for char in latex {
      if let ascii = superscriptToASCII[char] {
        if pendingScript?.mark != "^" { flushScript(); pendingScript = ("^", "") }
        pendingScript?.text.append(ascii); continue
      }
      if let ascii = subscriptToASCII[char] {
        if pendingScript?.mark != "_" { flushScript(); pendingScript = ("_", "") }
        pendingScript?.text.append(ascii); continue
      }
      flushScript()
      if let command = unicodeToLaTeX[char] { source += command } else if char.isNewline || char == "\t" { source += " " } else { source.append(char) }
    }
    flushScript()
    for (pattern, template) in commandRewrites {
      source = source.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
    // SwiftMath's cases and aligned need exactly two columns; a one-column system gets an empty second column / becomes gather.
    source = rewriteEnvironment("cases", in: source) { body in
      guard !body.contains("&") else { return nil }
      var rows = body.components(separatedBy: "\\\\")
      if rows.count > 1, rows.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { rows.removeLast() }
      return rows.map { $0 + " &" }.joined(separator: "\\\\")
    }
    for environment in ["aligned", "split"] {
      source = rewriteEnvironment(environment, in: source, renamedTo: "gather") { body in body.contains("&") ? nil : body }
    }
    // SwiftMath ignores ', ~, % and # in math; escape or spell them out (skipping escaped ones such as \%).
    var output = ""
    var chars = Array(source)[...]
    while let char = chars.popFirst() {
      if char == "\\" {
        output.append(char)
        if let escaped = chars.popFirst() { output.append(escaped == ":" ? ">" : escaped) }  // \: is spelled \> in SwiftMath
        continue
      }
      switch char {
      case "'":
        var primes = "\\prime"
        while chars.first == "'" { chars.removeFirst(); primes += "\\prime" }
        output += "^{\(primes)}"
      case "~": output += "\\ "
      case "%": output += "\\%"
      case "#": output += "\\#"
      default: output.append(char)
      }
    }
    // A spacing command before a binary operator trips a debug assertion in SwiftMath 1.7's spacing table; the space is redundant.
    output = output.replacingOccurrences(of: #"(?<!\\)(\\[,;>! ]|\\q?quad(?![A-Za-z]))\s*(?=[-+]|\\(pm|mp|times|cdot|div)(?![A-Za-z]))"#,
      with: "", options: .regularExpression)
    let trimmed = output.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else { return nil }
    return trimmed
  }

  /// Undoes a common model mistake: a single backslash in the JSON string makes `\frac` a form feed + "rac", `\theta` a tab +
  /// "heta", `\beta`, `\nabla`, `\right` likewise. A control character followed by letters that spell a known command after
  /// b, f, n, r or t becomes that command again; anything else is left alone.
  static func repairedEscapes(_ latex: String) -> String {
    let escapes: [Character: Character] = ["\u{08}": "b", "\u{0C}": "f", "\n": "n", "\r": "r", "\t": "t"]
    guard latex.contains(where: { escapes[$0] != nil }) else { return latex }
    let chars = Array(latex)
    var output = ""
    var index = 0
    while index < chars.count {
      let char = chars[index]
      if let letter = escapes[char] {
        var end = index + 1
        while end < chars.count, chars[end].isASCII, chars[end].isLetter { end += 1 }
        let name = String(letter) + String(chars[(index + 1)..<end])
        if end > index + 1, knownCommands.contains(name) {
          output += "\\" + name
          index = end
          continue
        }
      }
      output.append(char)
      index += 1
    }
    return output
  }

  private static let knownCommands: Set<String> = Set(symbols.keys).union(functions).union([
    "frac", "dfrac", "tfrac", "text", "textbf", "textit", "textrm", "textsf", "texttt", "textnormal", "tilde", "bar", "begin",
    "big", "bigl", "bigr", "bigg", "binom", "boldsymbol", "bm", "boxed", "right", "nonumber", "notag", "nolimits", "not", "tag",
    "frak", "rm", "bf",
  ]).subtracting(["ne", "ni"])  // too short to tell from a line break before "e" or "i"

  /// Rewrites the body of each (non-nested) `\begin{name}...\end{name}`; `rewrite` returns nil to leave one unchanged.
  private static func rewriteEnvironment(_ name: String, in source: String, renamedTo newName: String? = nil,
                                         _ rewrite: (String) -> String?) -> String {
    let begin = "\\begin{\(name)}", end = "\\end{\(name)}"
    var output = "", rest = source[...]
    while let open = rest.range(of: begin), let close = rest.range(of: end, range: open.upperBound..<rest.endIndex) {
      output += rest[..<open.lowerBound]
      let body = String(rest[open.upperBound..<close.lowerBound])
      if let rewritten = rewrite(body) {
        let renamed = newName ?? name
        output += "\\begin{\(renamed)}" + rewritten + "\\end{\(renamed)}"
      } else {
        output += rest[open.lowerBound..<close.upperBound]
      }
      rest = rest[close.upperBound...]
    }
    return output + rest
  }

  private static let commandRewrites: [(String, String)] = [
    (#"\\[dtc]frac(?![A-Za-z])"#, #"\\frac"#),
    (#"\\[lr]vert(?![A-Za-z])"#, "|"),
    (#"\\[lr]Vert(?![A-Za-z])"#, #"\\|"#),
    (#"\\(big|Big|bigg|Bigg)[lrm]?(?![A-Za-z])"#, ""),
    (#"\\middle(?![A-Za-z])"#, ""),
    (#"\\implies(?![A-Za-z])"#, #"\\Rightarrow "#),
    (#"\\impliedby(?![A-Za-z])"#, #"\\Leftarrow "#),
    (#"\\operatorname\*?"#, #"\\mathrm"#),
    (#"\\(boldsymbol|bm)(?![A-Za-z])"#, #"\\mathbf"#),
    (#"\\(textnormal|textup|mbox)(?![A-Za-z])"#, #"\\text"#),
    (#"\\dots[cbmio]?(?![A-Za-z])"#, #"\\ldots "#),
    (#"\\iiint(?![A-Za-z])"#, #"\\int\\!\\!\\int\\!\\!\\int "#),
    (#"\\iint(?![A-Za-z])"#, #"\\int\\!\\!\\int "#),
    (#"\\(leqslant|leqq)(?![A-Za-z])"#, #"\\le "#),
    (#"\\(geqslant|geqq)(?![A-Za-z])"#, #"\\ge "#),
    (#"\\varnothing(?![A-Za-z])"#, #"\\emptyset "#),
    (#"\\overrightarrow(?![A-Za-z])"#, #"\\vec"#),
    (#"\\not\s*=|\\not\s*\\eq(?![A-Za-z])"#, #"\\neq "#),
    (#"\\not\s*\\in(?![A-Za-z])"#, #"\\notin "#),
    (#"\\pmod\{([^{}]*)\}"#, #"\\ (\\mathrm{mod}\\ $1)"#),
    (#"\\b?mod(?![A-Za-z])"#, #"\\ \\mathrm{mod}\\ "#),
    (#"\\SI\{([^{}]*)\}\{([^{}]*)\}"#, #"$1\\,\\mathrm{$2}"#),
    (#"\\(si|unit)\{([^{}]*)\}"#, #"\\mathrm{$2}"#),
    (#"\\(tag|label)\*?\{[^{}]*\}"#, ""),
    (#"\\(nonumber|notag)(?![A-Za-z])"#, ""),
    (#"\\(textcolor|colorbox)\{[^{}]*\}"#, ""),
    (#"\\color\{[^{}]*\}"#, ""),
    (#"\\(boxed|cancel)(?![A-Za-z])"#, ""),
    (#"\\(begin|end)\{(equation|multline)\*?\}"#, ""),
    (#"\\(begin|end)\{(align|alignat|flalign)\*?\}"#, #"\\$1{aligned}"#),
    (#"\\(begin|end)\{gather\*\}"#, #"\\$1{gather}"#),
  ]

  // MARK: Readable fallback

  /// `latex` as readable Unicode text, for formulas SwiftMath cannot typeset: `\frac{a}{b}` → a/b (parenthesized when needed),
  /// `^{2}` → ², `_{x}` → ₓ or _x, Greek letters, ∂ ∞ · × ≤ ≈ and friends, `\sqrt{x}` → √x, `\mathrm{m/s}` → m/s.
  static func plain(_ latex: String) -> String {
    var reader = PlainReader(chars: Array(repairedEscapes(latex)))
    let text = reader.read(until: nil)
    return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
      line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        .replacingOccurrences(of: #"([(\[{]) "#, with: "$1", options: .regularExpression)
        .replacingOccurrences(of: #" ([)\]}])"#, with: "$1", options: .regularExpression)
    }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private struct PlainReader {
    let chars: [Character]
    var index = 0
    var textMode = false

    init(chars: [Character]) { self.chars = chars }

    var peek: Character? { index < chars.count ? chars[index] : nil }

    mutating func skipSpaces() { while let char = peek, char == " " { index += 1 } }

    /// Reads until `stop` (consumed) or the end.
    mutating func read(until stop: Character?) -> String {
      var out = ""
      while let char = peek {
        index += 1
        if let stop, char == stop { return out }
        switch char {
        case "{": out += read(until: "}")
        case "}": continue
        case "\\": out += command()
        case "^": out += MathText.superscripted(argument())
        case "_": out += MathText.subscripted(argument())
        case "'": out += textMode ? "'" : "′"
        case "-": out += textMode ? "-" : "−"
        case "&", "~": out += " "
        default: out.append(char)
        }
      }
      return out
    }

    /// One argument: a braced group, a command, or a single character.
    mutating func argument() -> String {
      skipSpaces()
      guard let char = peek else { return "" }
      index += 1
      switch char {
      case "{": return read(until: "}")
      case "\\": return command()
      case "-": return textMode ? "-" : "−"
      case "'": return "′"
      default: return String(char)
      }
    }

    mutating func optionalBracket() -> String? {
      skipSpaces()
      guard peek == "[" else { return nil }
      index += 1
      return read(until: "]")
    }

    mutating func name() -> String {
      guard let first = peek else { return "" }
      index += 1
      guard first.isLetter, first.isASCII else { return String(first) }
      var name = String(first)
      while let char = peek, char.isLetter, char.isASCII { name.append(char); index += 1 }
      if peek == "*" { index += 1 }
      return name
    }

    mutating func text(_ asText: Bool) -> String {
      let saved = textMode
      textMode = asText || textMode
      defer { textMode = saved }
      return argument()
    }

    mutating func command() -> String {
      let name = name()
      // As in TeX, a control word swallows the spaces after it; keep them only before an operator ("\\alpha + 1").
      if let first = name.first, first.isLetter, !textMode {
        var next = index
        while next < chars.count, chars[next] == " " { next += 1 }
        if next < chars.count, chars[next].isLetter || chars[next].isNumber || chars[next] == "\\" { index = next }
      }
      switch name {
      case "\\": return "\n"
      case ",", ";", ":", ">", " ": return " "
      case "!": return ""
      case "{", "}", "%", "$", "#", "&", "_": return name
      case "|": return "‖"
      case "frac", "dfrac", "tfrac", "cfrac":
        let numerator = argument(), denominator = argument()
        return MathText.wrapped(numerator) + "/" + MathText.wrapped(denominator)
      case "binom":
        let n = argument(), k = argument()
        return "C(\(n), \(k))"
      case "sqrt":
        let degree = optionalBracket()
        let radicand = argument()
        return (degree.map { MathText.superscripted($0) } ?? "") + "√" + MathText.wrapped(radicand)
      case "text", "textrm", "textbf", "textit", "textsf", "texttt", "textnormal", "textup", "mbox", "emph":
        return text(true)
      case "mathrm", "mathbf", "mathit", "mathsf", "mathtt", "mathcal", "mathfrak", "mathnormal", "mathbfit", "boldsymbol", "bm",
        "operatorname", "boxed", "cancel", "underbrace", "overbrace", "displaystyle", "textstyle", "scriptstyle":
        return ["displaystyle", "textstyle", "scriptstyle"].contains(name) ? "" : text(false)
      case "mathbb":
        let letter = argument()
        return ["R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "P": "ℙ"][letter] ?? letter
      case "vec", "overrightarrow": return MathText.accented(argument(), "\u{20D7}")
      case "hat", "widehat": return MathText.accented(argument(), "\u{0302}")
      case "bar", "overline": return MathText.accented(argument(), "\u{0304}")
      case "tilde", "widetilde": return MathText.accented(argument(), "\u{0303}")
      case "dot": return MathText.accented(argument(), "\u{0307}")
      case "ddot": return MathText.accented(argument(), "\u{0308}")
      case "underline": return MathText.accented(argument(), "\u{0332}")
      case "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr",
        "bigm", "Bigm", "middle":
        skipSpaces()
        if peek == "." { index += 1 }
        return ""
      case "limits", "nolimits", "nonumber", "notag": return ""
      case "tag", "label", "color", "phantom", "hphantom", "vphantom":
        _ = argument(); return ""
      case "textcolor", "colorbox":
        _ = argument(); return argument()
      case "not":
        let negated = argument()
        return ["=": "≠", "∈": "∉", "≡": "≢", "<": "≮", ">": "≯", "≤": "≰", "≥": "≱"][negated] ?? negated + "\u{0338}"
      case "pmod": return " (mod \(argument()))"
      case "SI":
        let value = argument(), unit = argument()
        return value + " " + unit
      case "si", "unit": return argument()
      case "begin", "end":
        let environment = argument()
        let delimiters: [String: (String, String)] = ["pmatrix": ("(", ")"), "bmatrix": ("[", "]"), "Bmatrix": ("{", "}"),
          "vmatrix": ("|", "|"), "Vmatrix": ("‖", "‖"), "cases": ("{ ", "")]
        guard let pair = delimiters[environment] else { return "" }
        return name == "begin" ? pair.0 : pair.1
      default:
        if let symbol = MathText.symbols[name] { return MathText.spaced.contains(symbol) ? " \(symbol) " : symbol }
        if MathText.functions.contains(name) {
          if let next = peek, next.isLetter || next.isNumber || next == "\\" { return name + " " }
          return name
        }
        return name
      }
    }
  }

  /// Wraps `text` in parentheses unless it is a single number or a single symbol with scripts (`x²`, `∂u`, `dy`, `Δt`).
  fileprivate static func wrapped(_ text: String) -> String {
    let text = text.trimmingCharacters(in: .whitespaces)
    if text.isEmpty { return "()" }
    if text.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) { return text }
    var bases = 0, prefixed = false
    for scalar in text.unicodeScalars {
      switch scalar.properties.generalCategory {
      case .uppercaseLetter, .lowercaseLetter, .otherLetter, .titlecaseLetter, .decimalNumber:
        bases += 1
      case .modifierLetter, .otherNumber, .nonspacingMark, .enclosingMark:
        continue
      default:
        if "′″°".unicodeScalars.contains(scalar) { continue }
        if bases == 0, !prefixed, "∂∇".unicodeScalars.contains(scalar) { prefixed = true; continue }
        return "(\(text))"
      }
    }
    if bases == 2, !prefixed, let first = text.first, "dΔδ".contains(first) { return text }
    return bases <= 1 ? text : "(\(text))"
  }

  fileprivate static func superscripted(_ text: String) -> String {
    let text = text.trimmingCharacters(in: .whitespaces)
    if text == "∘" { return "°" }
    if !text.isEmpty, text.allSatisfy({ $0 == "′" || $0 == "″" }) { return text }
    let mapped = text.filter { $0 != " " }.map { superscripts[$0] }
    if !mapped.isEmpty, mapped.allSatisfy({ $0 != nil }) { return String(mapped.compactMap { $0 }) }
    return text.count == 1 || text.allSatisfy({ $0.isLetter || $0.isNumber }) ? "^" + text : "^(\(text))"
  }

  fileprivate static func subscripted(_ text: String) -> String {
    let text = text.trimmingCharacters(in: .whitespaces)
    let mapped = text.filter { $0 != " " }.map { subscripts[$0] }
    if !mapped.isEmpty, mapped.allSatisfy({ $0 != nil }) { return String(mapped.compactMap { $0 }) }
    return text.count == 1 || text.allSatisfy({ $0.isLetter || $0.isNumber }) ? "_" + text : "_(\(text))"
  }

  fileprivate static func accented(_ text: String, _ mark: Character) -> String {
    text.isEmpty ? String(mark) : text + String(mark)
  }

  // MARK: Tables

  private static let superscriptToASCII: [Character: Character] = [
    "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9",
    "⁺": "+", "⁻": "-", "⁼": "=", "⁽": "(", "⁾": ")", "ⁿ": "n", "ⁱ": "i",
  ]
  private static let subscriptToASCII: [Character: Character] = [
    "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4", "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9",
    "₊": "+", "₋": "-", "₌": "=", "₍": "(", "₎": ")", "ₐ": "a", "ₑ": "e", "ₒ": "o", "ₓ": "x", "ₕ": "h", "ₖ": "k", "ₗ": "l",
    "ₘ": "m", "ₙ": "n", "ₚ": "p", "ₛ": "s", "ₜ": "t", "ᵢ": "i", "ⱼ": "j", "ᵣ": "r", "ᵤ": "u", "ᵥ": "v",
  ]
  private static let superscripts: [Character: Character] = [
    "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
    "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
    "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ",
    "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ",
    "z": "ᶻ", "A": "ᴬ", "B": "ᴮ", "D": "ᴰ", "E": "ᴱ", "G": "ᴳ", "H": "ᴴ", "I": "ᴵ", "J": "ᴶ", "K": "ᴷ", "L": "ᴸ", "M": "ᴹ",
    "N": "ᴺ", "O": "ᴼ", "P": "ᴾ", "R": "ᴿ", "T": "ᵀ", "U": "ᵁ", "V": "ⱽ", "W": "ᵂ",
  ]
  private static let subscripts: [Character: Character] = [
    "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
    "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎",
    "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ",
    "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ", "β": "ᵦ", "γ": "ᵧ", "ρ": "ᵨ", "φ": "ᵩ", "χ": "ᵪ",
  ]

  private static let greek: [String: String] = [
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
    "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο",
    "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
    "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
    "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
  ]
  fileprivate static let symbols: [String: String] = greek.merging([
    "partial": "∂", "infty": "∞", "nabla": "∇", "cdot": "·", "cdotp": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓",
    "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "•", "le": "≤", "leq": "≤", "leqslant": "≤", "ge": "≥", "geq": "≥",
    "geqslant": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "sim": "∼", "simeq": "≃", "cong": "≅", "equiv": "≡", "propto": "∝",
    "ll": "≪", "gg": "≫", "to": "→", "rightarrow": "→", "longrightarrow": "⟶", "leftarrow": "←", "gets": "←", "Rightarrow": "⇒",
    "Longrightarrow": "⟹", "implies": "⇒", "Leftarrow": "⇐", "impliedby": "⇐", "Leftrightarrow": "⇔", "iff": "⇔",
    "leftrightarrow": "↔", "mapsto": "↦", "uparrow": "↑", "downarrow": "↓", "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂",
    "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇", "cup": "∪", "cap": "∩", "setminus": "∖", "emptyset": "∅",
    "varnothing": "∅", "forall": "∀", "exists": "∃", "neg": "¬", "lnot": "¬", "land": "∧", "wedge": "∧", "lor": "∨", "vee": "∨",
    "oplus": "⊕", "otimes": "⊗", "perp": "⊥", "parallel": "∥", "mid": "|", "angle": "∠", "triangle": "△", "degree": "°",
    "prime": "′", "ldots": "…", "dots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱", "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ",
    "Im": "ℑ", "aleph": "ℵ", "therefore": "∴", "because": "∵", "langle": "⟨", "rangle": "⟩", "lvert": "|", "rvert": "|",
    "vert": "|", "lVert": "‖", "rVert": "‖", "Vert": "‖", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
    "lbrace": "{", "rbrace": "}", "backslash": "\\", "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮", "sum": "∑",
    "prod": "∏", "coprod": "∐", "bigcup": "⋃", "bigcap": "⋂", "checkmark": "✓", "dagger": "†", "square": "□", "Box": "□",
    "surd": "√", "AA": "Å", "colon": ":", "quad": " ", "qquad": " ",
  ]) { current, _ in current }
  /// Relations and binary operators, written with a space on each side.
  fileprivate static let spaced: Set<String> = [
    "≤", "≥", "≠", "≈", "∼", "≃", "≅", "≡", "∝", "≪", "≫", "→", "⟶", "←", "⇒", "⟹", "⇐", "⇔", "↔", "↦", "∈", "∉", "∋", "⊂", "⊆",
    "⊃", "⊇", "×", "·", "÷", "±", "∓", "∪", "∩", "∖", "∧", "∨", "⊕", "⊗",
  ]
  fileprivate static let functions: Set<String> = [
    "sin", "cos", "tan", "sec", "csc", "cot", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "coth", "ln", "log", "lg",
    "exp", "lim", "liminf", "limsup", "max", "min", "sup", "inf", "det", "gcd", "lcm", "deg", "dim", "ker", "arg", "Pr", "hom",
    "mod", "bmod",
  ]
  private static let unicodeToLaTeX: [Character: String] = {
    var table: [Character: String] = [
      "×": "\\times ", "·": "\\cdot ", "⋅": "\\cdot ", "÷": "\\div ", "±": "\\pm ", "∓": "\\mp ", "≤": "\\le ", "≥": "\\ge ",
      "≠": "\\neq ", "≈": "\\approx ", "∼": "\\sim ", "≃": "\\simeq ", "≅": "\\cong ", "≡": "\\equiv ", "∝": "\\propto ",
      "≪": "\\ll ", "≫": "\\gg ", "→": "\\to ", "←": "\\leftarrow ", "⇒": "\\Rightarrow ", "⇐": "\\Leftarrow ",
      "⇔": "\\Leftrightarrow ", "↔": "\\leftrightarrow ", "↦": "\\mapsto ", "∞": "\\infty ", "∂": "\\partial ", "∇": "\\nabla ",
      "∫": "\\int ", "∮": "\\oint ", "∑": "\\sum ", "∏": "\\prod ", "°": "^{\\circ}", "′": "'", "″": "''", "−": "-", "–": "-",
      "…": "\\ldots ", "⋯": "\\cdots ", "∈": "\\in ", "∉": "\\notin ", "⊂": "\\subset ", "⊆": "\\subseteq ", "∪": "\\cup ",
      "∩": "\\cap ", "∀": "\\forall ", "∃": "\\exists ", "∅": "\\emptyset ", "∠": "\\angle ", "⊥": "\\perp ", "∥": "\\parallel ",
      "ℏ": "\\hbar ", "ℓ": "\\ell ", "⟨": "\\langle ", "⟩": "\\rangle ", "∘": "\\circ ", "⊗": "\\otimes ", "⊕": "\\oplus ",
      "µ": "\\mu ", "∆": "\\Delta ", "ε": "\\varepsilon ", "ϵ": "\\epsilon ", "φ": "\\varphi ", "ϕ": "\\phi ",
      "\u{00A0}": " ", "\u{2009}": "\\,", "\u{202F}": "\\,",
      "Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K", "Μ": "M", "Ν": "N", "Ο": "O", "Ρ": "P", "Τ": "T",
      "Χ": "X", "ο": "o",
    ]
    for (name, letter) in greek where table[Character(letter)] == nil { table[Character(letter)] = "\\\(name) " }
    return table
  }()
}

#if canImport(UIKit)
import UIKit
import CoreText
#if canImport(SwiftMath)
import SwiftMath
#endif

/// Typesets solver text for the solution PDF's CoreText layout. Each formula becomes one U+FFFC placeholder whose CTRunDelegate
/// reserves the formula's width, ascent and descent (so inline math sits on the text baseline and lines grow to fit it); the
/// formula image rides along in a custom attribute and is drawn by `drawFormulas` after `CTFrameDraw`. Display math gets its own
/// centered paragraph. A formula SwiftMath cannot typeset is written as `MathText.plain` text instead.
enum MathTypesetter {
  /// One typeset formula in PDF points. Immutable; only used synchronously inside one PDF render.
  final class Formula {
    let image: CGImage
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    init(image: CGImage, width: CGFloat, ascent: CGFloat, descent: CGFloat) {
      self.image = image; self.width = width; self.ascent = ascent; self.descent = descent
    }
  }

  /// The attribute holding a `Formula` on its placeholder character.
  static var formulaKey: NSAttributedString.Key { NSAttributedString.Key("GlassesSolverFormula") }
  /// Formulas are rendered this many times larger and drawn scaled down, for print-sharp bitmaps.
  static let renderScale: CGFloat = 2
  /// Latin Modern's x-height is smaller than the system font's; this keeps math visually the same size as the prose.
  static let mathSizeRatio: CGFloat = 1.1

  /// `text` as one or more paragraphs, each ending in "\n". `attributes` style the prose; formulas are typeset at `fontSize`
  /// and scaled down to at most `maxWidth` by `maxHeight` points.
  static func paragraphs(_ text: String, attributes: [NSAttributedString.Key: Any], fontSize: CGFloat,
                         maxWidth: CGFloat, maxHeight: CGFloat) -> NSAttributedString {
    let output = NSMutableAttributedString(string: "")
    let base = (attributes[.paragraphStyle] as? NSParagraphStyle) ?? NSParagraphStyle.default
    let centeredStyle = NSMutableParagraphStyle()
    centeredStyle.setParagraphStyle(base)
    centeredStyle.alignment = .center
    var centered = attributes
    centered[.paragraphStyle] = centeredStyle
    var current = NSMutableAttributedString(string: "")
    func endParagraph(force: Bool) {
      trimWhitespace(current)
      if current.length > 0 || force {
        output.append(current)
        output.append(NSAttributedString(string: "\n", attributes: attributes))
      }
      current = NSMutableAttributedString(string: "")
    }
    for segment in MathText.segments(text) {
      switch segment {
      case .text(let prose):
        current.append(NSAttributedString(string: prose, attributes: attributes))
      case .inline(let latex):
        current.append(formula(latex, display: false, attributes: attributes, fontSize: fontSize, maxWidth: maxWidth, maxHeight: maxHeight))
      case .display(let latex):
        endParagraph(force: false)
        output.append(formula(latex, display: true, attributes: centered, fontSize: fontSize, maxWidth: maxWidth, maxHeight: maxHeight))
        output.append(NSAttributedString(string: "\n", attributes: centered))
      }
    }
    endParagraph(force: output.length == 0)
    return output
  }

  /// Draws the formula images of `frame`'s lines. Call right after `CTFrameDraw(frame, context)`, in the same y-up context.
  static func drawFormulas(in frame: CTFrame, context: CGContext) {
    guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return }
    let box = CTFrameGetPath(frame).boundingBox
    var origins = [CGPoint](repeating: .zero, count: lines.count)
    CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
    context.saveGState()
    defer { context.restoreGState() }
    context.interpolationQuality = .high
    for (line, origin) in zip(lines, origins) {
      guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { continue }
      for run in runs {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let formula = attributes[formulaKey.rawValue] as? Formula, CTRunGetGlyphCount(run) > 0 else { continue }
        var position = CGPoint.zero
        CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
        let baseline = CGPoint(x: box.minX + origin.x + position.x, y: box.minY + origin.y)
        context.draw(formula.image, in: CGRect(x: baseline.x, y: baseline.y - formula.descent,
                                               width: formula.width, height: formula.ascent + formula.descent))
      }
    }
  }

  /// One formula as a placeholder carrying its image, or as readable text when it cannot be typeset.
  static func formula(_ latex: String, display: Bool, attributes: [NSAttributedString.Key: Any], fontSize: CGFloat,
                      maxWidth: CGFloat, maxHeight: CGFloat) -> NSAttributedString {
    if let formula = typeset(latex, display: display, fontSize: fontSize * mathSizeRatio, maxWidth: maxWidth, maxHeight: maxHeight),
       let attachment = placeholder(for: formula, attributes: attributes) {
      return attachment
    }
    return NSAttributedString(string: MathText.plain(latex), attributes: attributes)
  }

  /// SwiftMath's image of `latex`, scaled to fit, with its baseline position; nil when SwiftMath cannot typeset it.
  static func typeset(_ latex: String, display: Bool, fontSize: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat) -> Formula? {
    #if canImport(SwiftMath)
    guard let source = MathText.typesettable(latex) else { return nil }
    let size = fontSize * renderScale
    var math = MathImage(latex: source, fontSize: size, textColor: .black, labelMode: display ? .display : .text, textAlignment: .left)
    let (error, rendered, layout) = math.asImage()
    guard error == nil, let rendered, let layout, let image = rendered.cgImage,
          rendered.size.width > 0, rendered.size.height > 0 else { return nil }
    // MathImage (SwiftMath 1.7.3) draws the baseline at this height above the image's bottom edge.
    let inkHeight = max(layout.ascent + layout.descent, size / 2)
    let baseline = (rendered.size.height - inkHeight) / 2 + layout.descent
    let width = rendered.size.width / renderScale, height = rendered.size.height / renderScale
    let fit = min(1, maxWidth / width, maxHeight / height)
    let descent = baseline / renderScale * fit
    return Formula(image: image, width: width * fit, ascent: height * fit - descent, descent: descent)
    #else
    return nil
    #endif
  }

  /// U+FFFC with a run delegate that reserves `formula`'s box. The delegate keeps the formula alive (+1, released on dealloc).
  private static func placeholder(for formula: Formula, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString? {
    var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1, dealloc: { refCon in
      Unmanaged<Formula>.fromOpaque(refCon).release()
    }, getAscent: { refCon in
      Unmanaged<Formula>.fromOpaque(refCon).takeUnretainedValue().ascent
    }, getDescent: { refCon in
      Unmanaged<Formula>.fromOpaque(refCon).takeUnretainedValue().descent
    }, getWidth: { refCon in
      Unmanaged<Formula>.fromOpaque(refCon).takeUnretainedValue().width
    })
    let retained = Unmanaged.passRetained(formula)
    guard let delegate = CTRunDelegateCreate(&callbacks, retained.toOpaque()) else {
      retained.release()
      return nil
    }
    var placeholder = attributes
    placeholder[NSAttributedString.Key(kCTRunDelegateAttributeName as String)] = delegate
    placeholder[formulaKey] = formula
    placeholder[.foregroundColor] = UIColor.clear
    return NSAttributedString(string: "\u{FFFC}", attributes: placeholder)
  }

  private static func trimWhitespace(_ text: NSMutableAttributedString) {
    let string = text.string as NSString
    var end = string.length
    while end > 0, let scalar = Unicode.Scalar(string.character(at: end - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
    text.deleteCharacters(in: NSRange(location: end, length: string.length - end))
    var start = 0
    while start < end, let scalar = Unicode.Scalar(string.character(at: start)), CharacterSet.whitespacesAndNewlines.contains(scalar) { start += 1 }
    text.deleteCharacters(in: NSRange(location: 0, length: start))
  }
}
#endif
