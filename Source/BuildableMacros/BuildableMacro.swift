//
//  File.swift
//  BuildableKit
//
//  Created by Arte.k on 25.10.2025.
//


import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - Helper model moved out of the macro method
struct Field {
    let name: String
    let type: String
    let isRequired: Bool
    let accumulatingAdder: String?  // non-nil if accumulating, adder name
    let defaultExpr: String?        // initializer literal if provided

    init(name: String, type: String, isRequired: Bool, accumulatingAdder: String?, defaultExpr: String?) {
        self.name = name
        self.type = type
        self.isRequired = isRequired
        self.accumulatingAdder = accumulatingAdder
        self.defaultExpr = defaultExpr
    }
}

// MARK: - Marker macros (@Required / @Accumulating)
// These are *memberAttribute* macros: they don't emit code, they just mark fields.
public struct MarkerMacro: MemberAttributeMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] { [] }
}

// MARK: - Buildable member macro (generates nested Builder + Stage types)
public struct BuildableMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf decl: some DeclGroupSyntax,
        in ctx: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // ---- Model name (identifier → name)
        guard let structDecl = decl.as(StructDeclSyntax.self) else { return [] }
        let modelName = structDecl.name.text   // use .name, not .identifier

        // ---- Parse explicit order: @Buildable(order: ["a","b","c"])
        var explicitOrder: [String] = []
        if let labeled = node.arguments?.as(LabeledExprListSyntax.self) {
            for arg in labeled where arg.label?.text == "order" {
                if let array = arg.expression.as(ArrayExprSyntax.self) {
                    for el in array.elements {
                        if let s = el.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue {
                            explicitOrder.append(s)
                        }
                    }
                }
            }
        }

        // ---- Collect stored properties (single binding vars)
        var fields: [Field] = []

        for member in structDecl.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard v.bindings.count == 1, let b = v.bindings.first else { continue }
            guard let idPattern = b.pattern.as(IdentifierPatternSyntax.self) else { continue }
            guard let typeAnno = b.typeAnnotation?.type.description.trimmingCharacters(in: .whitespacesAndNewlines),
                  !typeAnno.isEmpty else { continue }

            let name = idPattern.identifier.text

            // Attributes (AttributeListSyntax is NOT optional here)
            var isRequired = false
            var accumulatingAdder: String? = nil
            for a in v.attributes {
                guard let attr = a.as(AttributeSyntax.self) else { continue }
                let attrName = attr.attributeName.trimmedDescription
                if attrName == "Required" { isRequired = true }
                if attrName == "Accumulating" {
                    if let tuple = attr.arguments?.as(LabeledExprListSyntax.self) {
                        for el in tuple where el.label?.text == "adder" {
                            if let lit = el.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue {
                                accumulatingAdder = lit
                            }
                        }
                    }
                    if accumulatingAdder == nil {
                        let cap = name.prefix(1).uppercased() + name.dropFirst()
                        accumulatingAdder = "add\(cap)"
                    }
                }
            }

            // Default value expression (if any)
            var def: String? = nil
            if let initValue = b.initializer?.value {
                def = initValue.description.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // Cheap defaults for common cases
                let t = typeAnno.replacingOccurrences(of: " ", with: "")
                if t.hasPrefix("[") && t.hasSuffix("]") {
                    def = t.contains(":") ? "[:]" : "[]"
                } else if t.hasPrefix("Set<") {
                    def = "Set()"
                } else if t.hasSuffix("?") {
                    def = "nil"
                }
            }

            fields.append(Field(name: name,
                                type: typeAnno,
                                isRequired: isRequired,
                                accumulatingAdder: accumulatingAdder,
                                defaultExpr: def))
        }

        // ---- Determine ordered steps: required + accumulating properties
        let stepNames: [String] = {
            if !explicitOrder.isEmpty { return explicitOrder }
            return fields.filter { $0.isRequired || $0.accumulatingAdder != nil }.map { $0.name }
        }()

        // For quick lookup
        let byName = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })

        // Helper for building ctor args
        func valueExpr(for f: Field) -> String {
            if stepNames.contains(f.name) { return "s_\(f.name)" }       // collected during stages
            if let def = f.defaultExpr { return def }                     // default or nil
            return "\(f.type)()"                                          // last resort
        }

        var decls: [DeclSyntax] = []

        // ---- Builder entrypoint
        let firstStage = stepNames.isEmpty ? "Final" : "Stage0"
        let builderDecl = """
        public struct Builder {
            public init() {}
            public func start() -> \(firstStage) { .init() }
            public func callAsFunction() -> \(firstStage) { start() }
        }
        """
        decls.append(DeclSyntax(stringLiteral: builderDecl))

        // ---- Stages generation
        if !stepNames.isEmpty {
            // Stage0 .. Stage(N-2)
            for (idx, step) in stepNames.enumerated() where idx < stepNames.count - 1 {
                let stageName = "Stage\(idx)"
                let nextStage = "Stage\(idx + 1)"
                let prevNames = Array(stepNames.prefix(idx))
                let storedDecls = prevNames
                    .map { "let s_\($0): \(byName[$0]!.type)" }
                    .joined(separator: "\n        ")

                let param = byName[step]!
                let setterName = "set" + param.name.prefix(1).uppercased() + param.name.dropFirst()
                let ctorParams = prevNames
                    .map { "s_\($0): \(byName[$0]!.type)" }
                    .joined(separator: ", ")
                let ctorBody = prevNames
                    .map { "self.s_\($0) = s_\($0)" }
                    .joined(separator: "\n            ")

                let passArgs = (prevNames.map { "s_\($0): s_\($0)" } + ["s_\(param.name): value"])
                    .joined(separator: ", ")

                let setter = """
                public func \(setterName)(_ value: \(param.type)) -> \(nextStage) {
                    return .init(\(passArgs))
                }
                """

                let stageDecl = """
                public struct \(stageName) {
                    \(storedDecls.isEmpty ? "" : storedDecls)

                    public init(\(ctorParams)) {
                        \(ctorBody)
                    }

                    \(setter)
                }
                """
                decls.append(DeclSyntax(stringLiteral: stageDecl))
            }

            // Final stage (Stage(N-1) → Final with adder/build)
            if let last = stepNames.last, let lastField = byName[last] {
                let finalStored = stepNames.map { "let s_\($0): \(byName[$0]!.type)" }.joined(separator: "\n        ")
                let finalInitParams = stepNames.map { "s_\($0): \(byName[$0]!.type)" }.joined(separator: ", ")
                let finalInitBody = stepNames.map { "self.s_\($0) = s_\($0)" }.joined(separator: "\n            ")

                var bodyPieces: [String] = []

                // Accumulating adder on Final (repeatable)
                if let adder = lastField.accumulatingAdder {
                    let t = lastField.type.replacingOccurrences(of: " ", with: "")
                    if t.hasPrefix("[") && t.contains(":") && t.hasSuffix("]") {
                        // Dictionary
                        let inner = String(t.dropFirst().dropLast())
                        let parts = inner.split(separator: ":", maxSplits: 1).map { String($0) }
                        let keyT = parts.count == 2 ? parts[0] : "AnyHashable"
                        let valT = parts.count == 2 ? parts[1] : "Any"
                        bodyPieces.append("""
                        public func \(adder)(_ key: \(keyT), _ value: \(valT)) -> Self {
                            var dict = s_\(last)
                            dict[key] = value
                            return .init(\(stepNames.map { n in n == last ? "s_\(n): dict" : "s_\(n): s_\(n)" }.joined(separator: ", ")))
                        }
                        """)
                    } else if t.hasPrefix("[") && t.hasSuffix("]") && !t.contains(":") {
                        // Array
                        let elem = String(t.dropFirst().dropLast())
                        bodyPieces.append("""
                        public func \(adder)(_ value: \(elem)) -> Self {
                            var arr = s_\(last)
                            arr.append(value)
                            return .init(\(stepNames.map { n in n == last ? "s_\(n): arr" : "s_\(n): s_\(n)" }.joined(separator: ", ")))
                        }
                        """)
                    } else if t.hasPrefix("Set<") {
                        let elem = t.dropFirst(4).dropLast()
                        bodyPieces.append("""
                        public func \(adder)(_ value: \(elem)) -> Self {
                            var set = s_\(last)
                            set.insert(value)
                            return .init(\(stepNames.map { n in n == last ? "s_\(n): set" : "s_\(n): s_\(n)" }.joined(separator: ", ")))
                        }
                        """)
                    } else {
                        // Fallback: overwrite
                        bodyPieces.append("""
                        public func \(adder)(_ value: \(lastField.type)) -> Self {
                            return .init(\(stepNames.map { n in n == last ? "s_\(n): value" : "s_\(n): s_\(n)" }.joined(separator: ", ")))
                        }
                        """)
                    }
                }

                // Build() assembles all fields (steps + non-steps with defaults)
                let ctorArgs = fields.map { f in "\(f.name): \(valueExpr(for: f))" }.joined(separator: ", ")
                bodyPieces.append("""
                public func build() -> \(modelName) {
                    \(modelName)(\(ctorArgs))
                }
                """)

                let finalDecl = """
                public struct Final {
                    \(finalStored)

                    public init(\(finalInitParams)) {
                        \(finalInitBody)
                    }

                    \(bodyPieces.joined(separator: "\n\n                    "))
                }
                """
                decls.append(DeclSyntax(stringLiteral: finalDecl))

                // Bridge Stage(N-1) → Final
                if stepNames.count >= 2 {
                    let idx = stepNames.count - 2
                    let prevStageName = "Stage\(idx)"
                    let prevNames = Array(stepNames.prefix(idx))
                    let setterName = "set" + last.prefix(1).uppercased() + last.dropFirst()

                    let storedDecls = prevNames.map { "let s_\($0): \(byName[$0]!.type)" }.joined(separator: "\n        ")
                    let ctorParams = prevNames.map { "s_\($0): \(byName[$0]!.type)" }.joined(separator: ", ")
                    let ctorBody = prevNames.map { "self.s_\($0) = s_\($0)" }.joined(separator: "\n                ")
                    let passArgs = (prevNames.map { "s_\($0): s_\($0)" } + ["s_\(last): value"]).joined(separator: ", ")

                    let stageDecl = """
                    public struct \(prevStageName) {
                        \(storedDecls.isEmpty ? "" : storedDecls)

                        public init(\(ctorParams)) {
                            \(ctorBody)
                        }

                        public func \(setterName)(_ value: \(lastField.type)) -> Final {
                            .init(\(passArgs))
                        }
                    }
                    """
                    decls.append(DeclSyntax(stringLiteral: stageDecl))
                } else {
                    // Single-step model: Stage0 → Final
                    let setterName = "set" + last.prefix(1).uppercased() + last.dropFirst()
                    let stage0 = """
                    public struct Stage0 {
                        public init() {}
                        public func \(setterName)(_ value: \(lastField.type)) -> Final {
                            .init(s_\(last): value)
                        }
                    }
                    """
                    decls.append(DeclSyntax(stringLiteral: stage0))
                }
            }
        } else {
            // No steps → just Final with defaults + helper Stage0
            let ctorArgs = fields.map { f in "\(f.name): \(valueExpr(for: f))" }.joined(separator: ", ")
            let finalDecl = """
            public struct Final {
                public init() {}
                public func build() -> \(modelName) { \(modelName)(\(ctorArgs)) }
            }
            """
            decls.append(DeclSyntax(stringLiteral: finalDecl))

            let stage0 = """
            public struct Stage0 {
                public init() {}
                public func build() -> \(modelName) { Final().build() }
            }
            """
            decls.append(DeclSyntax(stringLiteral: stage0))
        }

        return decls
    }
}
