@testable import CameraAccess
import XCTest
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// LaTeX in solver text: splitting prose from `$...$` / `$$...$$`, preparing formulas for SwiftMath, the readable fallback,
/// and (on iOS) a solution PDF with typeset math.
final class MathTextTests: XCTestCase {
  // MARK: Splitting

  func testInlineAndDisplayMathAreSeparatedFromProse() {
    XCTAssertEqual(MathText.segments(#"Since $a = 1.20\,\mathrm{s^{-1}}$, $$\frac{\partial u}{\partial x} = a$$ follows."#), [
      .text("Since "), .inline(#"a = 1.20\,\mathrm{s^{-1}}"#), .text(", "), .display(#"\frac{\partial u}{\partial x} = a"#),
      .text(" follows."),
    ])
    XCTAssertEqual(MathText.segments(#"so \(x^2\) and \[y = 2\]"#), [.text("so "), .inline("x^2"), .text(" and "), .display("y = 2")])
    XCTAssertEqual(MathText.segments("No math here (1a)."), [.text("No math here (1a).")])
    XCTAssertEqual(MathText.segments(""), [])
  }

  func testDoubleDollarsAreMatchedBeforeSingleOnes() {
    XCTAssertEqual(MathText.segments("$$x$$"), [.display("x")])
    XCTAssertEqual(MathText.segments("$a$$b$"), [.inline("a"), .inline("b")])
    XCTAssertEqual(MathText.segments("$$ x^2\n + 1 $$"), [.display("x^2\n + 1")])
    XCTAssertEqual(MathText.segments(#"$$a = \$5$$"#), [.display(#"a = \$5"#)], "An escaped dollar inside math does not close it.")
  }

  func testEscapedAndUnmatchedDollarsStayLiteral() {
    XCTAssertEqual(MathText.segments(#"Pay \$5 now"#), [.text("Pay $5 now")])
    XCTAssertEqual(MathText.segments("It costs $5 and $10 more"), [.text("It costs $5 and $10 more")])
    XCTAssertEqual(MathText.segments("Costs $5 for $x$ items"), [.text("Costs $5 for "), .inline("x"), .text(" items")])
    XCTAssertEqual(MathText.segments("price: $5"), [.text("price: $5")])
    XCTAssertEqual(MathText.segments("$x"), [.text("$x")])
    XCTAssertEqual(MathText.segments("$$x"), [.text("$$x")])
    XCTAssertEqual(MathText.segments("the $5 $"), [.text("the $5 $")])
    XCTAssertEqual(MathText.segments("$ x = 1 $"), [.inline("x = 1")], "Spaces inside are fine when the formula is clearly LaTeX.")
    XCTAssertEqual(MathText.segments("$5$"), [.inline("5")], "A matched dollar pair is math.")
  }

  func testEmptyMathIsDropped() {
    XCTAssertEqual(MathText.segments("a $$ $$ b"), [.text("a  b")])
    XCTAssertEqual(MathText.segments("a $ $ b"), [.text("a $ $ b")])
    XCTAssertEqual(MathText.segments(#"a \( \) b"#), [.text("a  b")])
  }

  // MARK: Readable fallback

  func testPlainFallbackReadsLikeMath() {
    XCTAssertEqual(MathText.plain(#"\frac{\partial u}{\partial x} = a = 1.20\,\mathrm{s^{-1}}"#), "∂u/∂x = a = 1.20 s⁻¹")
    XCTAssertEqual(MathText.plain(#"\frac{a}{b}"#), "a/b")
    XCTAssertEqual(MathText.plain(#"\dfrac{n(n+1)}{2}"#), "(n(n+1))/2")
    XCTAssertEqual(MathText.plain(#"\frac{dy}{dx}"#), "dy/dx")
    XCTAssertEqual(MathText.plain(#"x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}"#), "x = (−b ± √(b²−4ac))/(2a)")
    XCTAssertEqual(MathText.plain(#"\sqrt{x}"#), "√x")
    XCTAssertEqual(MathText.plain(#"\sqrt[3]{8} = 2"#), "³√8 = 2")
    XCTAssertEqual(MathText.plain("x^{2} + y^2 + z^{n+1}"), "x² + y² + zⁿ⁺¹")
    XCTAssertEqual(MathText.plain("x_{0} + y_{max} + v_{x} + w_{\\text{avg}}"), "x₀ + yₘₐₓ + vₓ + w_avg")
    XCTAssertEqual(MathText.plain(#"\alpha + \beta \le \pi"#), "α + β ≤ π")
    XCTAssertEqual(MathText.plain(#"\Delta x \approx 0.5\,\text{m}"#), "Δx ≈ 0.5 m")
    XCTAssertEqual(MathText.plain(#"F = m \cdot a, \quad 2 \times 3 \neq 5"#), "F = m · a, 2 × 3 ≠ 5")
    XCTAssertEqual(MathText.plain(#"\int_0^1 x^2\,dx = \frac{1}{3}"#), "∫₀¹ x² dx = 1/3")
    XCTAssertEqual(MathText.plain(#"\sum_{i=1}^{n} i"#), "∑ᵢ₌₁ⁿ i")
    XCTAssertEqual(MathText.plain(#"\lim_{x \to \infty} \frac{1}{x} = 0"#), "lim_(x → ∞) 1/x = 0")
    XCTAssertEqual(MathText.plain(#"\left( \frac{a}{b} \right)^2"#), "(a/b)²")
    XCTAssertEqual(MathText.plain(#"\theta = 30^\circ, \; f'(x) = 2x"#), "θ = 30°, f′(x) = 2x")
    XCTAssertEqual(MathText.plain(#"\vec{F} = m\vec{a}, \hat{x}, \bar{v}"#), "F⃗ = ma⃗, x̂, v̄")
    XCTAssertEqual(MathText.plain(#"\mathbf{v}\cdot\mathbf{w}"#), "v · w")
    XCTAssertEqual(MathText.plain(#"\sin\theta + \ln 2"#), "sin θ + ln 2")
    XCTAssertEqual(MathText.plain(#"\text{well-known} - 1"#), "well-known − 1")
    XCTAssertEqual(MathText.readable(#"Answer: $v = 3\,\mathrm{m/s}$ (about \$2)"#), "Answer: v = 3 m/s (about $2)")
    XCTAssertEqual(MathText.readable("Problem 1(a)"), "Problem 1(a)", "Text without math is unchanged.")
  }

  // MARK: Preparing formulas for SwiftMath

  func testTypesettableRewritesWhatSwiftMathWouldDropOrReject() {
    XCTAssertEqual(MathText.typesettable(#"\dfrac{a}{b}"#), #"\frac{a}{b}"#)
    XCTAssertEqual(MathText.typesettable("f'(x) = 2x"), #"f^{\prime}(x) = 2x"#)
    XCTAssertEqual(MathText.typesettable("f''"), #"f^{\prime\prime}"#)
    XCTAssertEqual(MathText.typesettable("v = 3 m/s² × 2"), #"v = 3 m/s^{2} \times  2"#)
    XCTAssertEqual(MathText.typesettable("θ = 30°"), #"\theta  = 30^{\circ}"#)
    XCTAssertEqual(MathText.typesettable("x₁ − x₀"), "x_{1} - x_{0}")
    XCTAssertEqual(MathText.typesettable(#"\left\lvert x \right\rvert \implies \big( y \big)"#), #"\left| x \right| \Rightarrow  ( y )"#)
    XCTAssertEqual(MathText.typesettable(#"50\%"#), #"50\%"#)
    XCTAssertEqual(MathText.typesettable("50%"), #"50\%"#)
    XCTAssertEqual(MathText.typesettable("a~b"), #"a\ b"#)
    XCTAssertEqual(MathText.typesettable(#"x =\, -1"#), "x =-1", "A space before a binary operator is dropped (SwiftMath debug assertion).")
    XCTAssertEqual(MathText.typesettable(#"\begin{align*} a &= b \\ c &= d \end{align*}"#), #"\begin{aligned} a &= b \\ c &= d \end{aligned}"#)
    XCTAssertNil(MathText.typesettable("√2"), "A symbol SwiftMath would silently drop goes to the readable fallback.")
    // A single backslash in the model's JSON turns \frac into form feed + "rac" and \theta into tab + "heta".
    XCTAssertEqual(MathText.segments("$\u{0C}rac{1}{2} + \u{09}heta$"), [.inline(#"\frac{1}{2} + \theta"#)])
    XCTAssertEqual(MathText.typesettable("\u{08}eta + \u{0A}abla"), #"\beta + \nabla"#)
    XCTAssertEqual(MathText.plain("x\nc"), "x\nc", "A real line break before an unknown word is kept.")
    XCTAssertNil(MathText.typesettable("  "))
  }

  // MARK: PDF

  #if canImport(UIKit) && canImport(PDFKit)
  func testPDFTypesetsInlineAndDisplayMathWithoutRawLaTeX() throws {
    let problem = SolvedProblem(
      problem: #"A flow has $u = a x$ with $a = 1.20\,\mathrm{s^{-1}}$. Find $\frac{\partial u}{\partial x}$ and $\int_0^1 x^2\,dx$."#,
      steps: [
        #"Differentiate: $$\frac{\partial u}{\partial x} = a = 1.20\,\mathrm{s^{-1}}$$ which is constant."#,
        #"Integrate: $$\int_0^1 x^2\,dx = \left[\frac{x^3}{3}\right]_0^1 = \frac{1}{3}$$"#,
        #"Matrix check: $$A = \begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}, \quad \det A = -2$$"#,
        #"Unsupported command falls back to text: $\therefore\ x \approx 0.33$ STEPSENTINEL"#,
      ],
      answer: #"MATHANSWER $\frac{\partial u}{\partial x} = 1.20\,\mathrm{s^{-1}}$ and $\sum_{i=1}^{n} i = \frac{n(n+1)}{2}$"#,
      check: #"Units of $\sqrt{x^2 + y^2}$ are $\mathrm{m}$; costs \$5."#,
      label: "1(a)", sourcePages: [1], reviewNote: #"NEEDS REVIEW: check $\alpha$"#)
    let page = SolvedPage(readable: true, retakeReason: "", title: "Math typesetting", problems: [problem])
    let data = try SolutionPDF.render(page: page, sources: [])
    let pdf = try XCTUnwrap(PDFDocument(data: data))
    XCTAssertGreaterThanOrEqual(pdf.pageCount, 1)
    let text = pdf.string ?? ""
    let compact = text.filter { !$0.isWhitespace }
    for marker in ["Differentiate:", "whichisconstant.", "MATHANSWER", "STEPSENTINEL", "costs$5."] {
      XCTAssertTrue(compact.contains(marker), "Missing \(marker) in \(text)")
    }
    XCTAssertFalse(compact.replacingOccurrences(of: "costs$5", with: "").contains("$"), "Raw math delimiters leaked: \(text)")
    for raw in [#"\frac"#, #"\partial"#, #"\mathrm"#, #"\int"#, #"\begin"#, #"\therefore"#] {
      XCTAssertFalse(text.contains(raw), "Raw LaTeX \(raw) leaked: \(text)")
    }
    XCTAssertTrue(text.contains("∴") || compact.contains("x≈0.33"), "The readable fallback should print the unsupported formula.")
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "com.adobe.pdf")
    attachment.name = "math-typesetting.pdf"; attachment.lifetime = .keepAlways; add(attachment)
  }

  func testTypesetFormulaSitsOnTheBaselineAndFits() throws {
    let inline = try XCTUnwrap(MathTypesetter.typeset(#"\frac{a}{b}"#, display: false, fontSize: 13, maxWidth: 520, maxHeight: 560))
    XCTAssertGreaterThan(inline.ascent, 0); XCTAssertGreaterThan(inline.descent, 0)
    XCTAssertGreaterThan(inline.width, 0)
    let wide = String(repeating: "x + ", count: 60) + "x"
    let display = try XCTUnwrap(MathTypesetter.typeset(wide, display: true, fontSize: 13, maxWidth: 520, maxHeight: 560))
    XCTAssertLessThanOrEqual(display.width, 520.5, "A long display formula is scaled down to the text width.")
    XCTAssertNil(MathTypesetter.typeset(#"\frac{a"#, display: false, fontSize: 13, maxWidth: 520, maxHeight: 560),
      "A formula SwiftMath cannot parse returns nil so the caller can fall back to text.")
  }
  #endif
}
