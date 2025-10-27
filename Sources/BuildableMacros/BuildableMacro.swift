//
//  File.swift
//  BuildableKit
//
//  Created by Arte.k on 25.10.2025.
//

// BuildableMacro.swift
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

fileprivate func isStored(_ b: PatternBindingSyntax) -> Bool { b.accessorBlock == nil }
fileprivate func name(of b: PatternBindingSyntax) -> String? {
  b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
}
fileprivate func type(of b: PatternBindingSyntax) -> String? {
  b.typeAnnotation?.type.trimmedDescription
}

// ------------ MEMBER PART: put enums + static builder INSIDE the model ------------
public struct BuildableMacro: MemberMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf decl: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {

    guard let nominal = decl.as(StructDeclSyntax.self) else { return [] }
    let model = nominal.name.text

    // Collect stored, non-static props (order matters)
    var props: [(name: String, type: String)] = []
    for m in nominal.memberBlock.members {
      guard let v = m.decl.as(VariableDeclSyntax.self),
            v.modifiers.contains(where: { $0.name.text == "static" }) != true else { continue }
      for b in v.bindings {
        guard isStored(b), let n = name(of: b), let t = type(of: b) else { continue }
        props.append((n, t))
      }
    }
    if props.isEmpty { return [] }

    let enums = props.map { "public enum Has\($0.name.prefix(1).uppercased() + $0.name.dropFirst()) {}" }
                     .joined(separator: "\n")

    let code = """
    public enum Start {}
    \(enums)

    public static var builder: \(model)Builder<Start> { \(model)Builder<Start>() }
    """
    return [DeclSyntax(stringLiteral: code)]
  }
}

// ------------ PEER PART: emit the Builder type as a top-level peer ------------
extension BuildableMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf decl: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {

    guard let nominal = decl.as(StructDeclSyntax.self) else { return [] }
    let model = nominal.name.text

    // Collect stored, non-static props
    var props: [(name: String, type: String)] = []
    for m in nominal.memberBlock.members {
      guard let v = m.decl.as(VariableDeclSyntax.self),
            v.modifiers.contains(where: { $0.name.text == "static" }) != true else { continue }
      for b in v.bindings {
        guard isStored(b), let n = name(of: b), let t = type(of: b) else { continue }
        props.append((n, t))
      }
    }
    if props.isEmpty { return [] }

    // Build state chain names: Start -> HasA -> HasB -> ...
    let states = ["Start"] + props.map { "Has" + $0.name.prefix(1).uppercased() + $0.name.dropFirst() }

    // Storage
    let storage = props.map { "  private var \($0.name): \($0.type)?" }.joined(separator: "\n")
    let initParams  = props.map { "\($0.name): \($0.type)? = nil" }.joined(separator: ", ")
    let initAssigns = props.map { "self.\($0.name) = \($0.name)" }.joined(separator: "\n    ")

    // Setters as methods WITH where-clauses (no extensions!)
    let setters = props.enumerated().map { (idx, p) -> String in
      let from = states[idx]      // Start for first
      let to   = states[idx + 1]  // next HasX
      let carry = props.map { q in
        q.name == p.name ? "\(q.name): value" : "\(q.name): self.\(q.name)"
      }.joined(separator: ", ")

      return """
        public func set\(p.name.prefix(1).uppercased() + p.name.dropFirst())(_ value: \(p.type)) -> \(model)Builder<\(model).\(to)> where State == \(model).\(from) {
          \(model)Builder<\(model).\(to)>(\(carry))
        }
      """
    }.joined(separator: "\n\n")

    // Build (gated by where-clause on final state)
    let ctorArgs = props.map { "\($0.name): \($0.name)!" }.joined(separator: ", ")
    let buildMethod = """
      func build() -> \(model) where State == \(model).\(states.last!) {
        \(model)(\(ctorArgs))
      }
    """

    let code = """
    struct \(model)Builder<State> {
    \(storage)

      public init() {}
      internal init(\(initParams)) {
        \(initAssigns)
      }

    \(setters)

    \(buildMethod)
    }
    """
    return [DeclSyntax(stringLiteral: code)]
  }
}
