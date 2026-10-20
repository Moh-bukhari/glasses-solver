import Foundation

struct SolvedProblem: Codable, Sendable {
  let problem: String
  let steps: [String]
  let answer: String
  let check: String
  var label: String? = nil
  var sourcePages: [Int]? = nil
  var reviewNote: String? = nil
}
struct SolvedPage: Codable, Sendable {
  let readable: Bool
  let retakeReason: String
  let title: String
  let problems: [SolvedProblem]
  var coverage: String? = nil
  var providers: String? = nil
}

enum SolverError: LocalizedError {
  case message(String)
  var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

