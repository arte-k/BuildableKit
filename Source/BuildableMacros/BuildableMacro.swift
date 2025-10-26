//
//  File.swift
//  BuildableKit
//
//  Created by Arte.k on 25.10.2025.
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

public struct MarkerMacro: MemberAttributeMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] { return [] }
}

private struct Field {
    let name: String
    let type: String
    let isRequired: Bool
    let accumulatingAdder: String? // nil if not accumulating
}

public struct BuildableMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf decl: some DeclSyntaxProtocol,
        in ctx: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        guard let structDecl = decl.as(StructDeclSyntax.self) else { return [] }
        let modelName = structDecl.name.text

        // Parse explicit order: @Buildable(order: ["a","b","c"])
        var explicitOrder: [String] = []
        if let args = node.arguments?.as(LabeledExprListSyntax.self) {
            for arg in args {
                if arg.label?.text == "order",
                   let array = arg.expression.as(ArrayExprSyntax.self) {
                    explicitOrder = array.elements.compactMap { $0.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue }
                }
            }
        }

        // Collect stored props with markers
        var fields: [Field] = []
        for member in structDecl.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard v.bindings.count == 1, let b = v.bindings.first else { continue }
            guard let idPattern = b.pattern.as(IdentifierPatternSyntax.self) else { continue }
            guard let typeAnno = b.typeAnnotation?.type.description.trimmingCharacters(in: .whitespacesAndNewlines),
                  !typeAnno.isEmpty else { continue }

            let name = idPattern.identifier.text

            // detect markers on decl
            var isRequired = false
            var accumulatingAdder: String? = nil

            let attrs = v.attributes
            
            for attr in attrs {
                guard let a = attr.as(AttributeSyntax.self) else { continue }
                let attrName = a.attributeName.trimmedDescription
                if attrName == "Required" { isRequired = true }
                if attrName == "Accumulating" {
                    // try parse adder: Accumulating(adder: "addHeader")
                    if let tuple = a.arguments?.as(LabeledExprListSyntax.self) {
                        for el in tuple where el.label?.text == "adder" {
                            accumulatingAdder = el.expression.as(StringLiteralExprSyntax.self)?
                                .representedLiteralValue ?? nil
                        }
                    }
                    if accumulatingAdder == nil {
                        // default adder: "add" + CapitalizedName
                        accumulatingAdder = "add" + name.prefix(1).uppercased() + name.dropFirst()
                    }
                }
            }
            

            fields.append(.init(name: name, type: typeAnno, isRequired: isRequired, accumulatingAdder: accumulatingAdder))
        }

        // Compute ordered steps: prefer explicit, else declared order of required+accumulating
        let stepNames: [String] = {
            if !explicitOrder.isEmpty { return explicitOrder }
            // Include only fields that are Required or Accumulating (others treated as defaulted)
            return fields.filter { $0.isRequired || $0.accumulatingAdder != nil }.map { $0.name }
        }()

        // Quick map for lookup
        let fieldByName = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })

        // Build stages
        var decls: [DeclSyntax] = []
        var stageNames: [String] = []

        for (idx, step) in stepNames.enumerated() {
            let stageName = "\(modelName)BuilderStage\(idx)"
            stageNames.append(stageName)

            guard let f = fieldByName[step] else { continue }

            let storagePrefix = "s"
            let prefixDecls: [String] = fields.map {
                "let \(storagePrefix)_\($0.name): \($0.type)\(defaultSuffix($0))"
            }

            let setOrAddMethod: String = {
                if let adder = f.accumulatingAdder {
                    // Accumulating step: repeatable adder that returns *same* stage
                    if isMapType(f.type) {
                        return """
                        public func \(adder)(_ key: \(mapKeyType(f.type)), _ value: \(mapValueType(f.type))) -> \(stageName) {
                            var copy = \(storagePrefix)_\(f.name)
                            copy[key] = value
                            return .init(\(initArgs(storagePrefix: storagePrefix, fields: fields, overwrites: [f.name: "copy"])))
                        }
                        """
                    } else if isArrayType(f.type) {
                        return """
                        public func \(adder)(_ value: \(arrayElementType(f.type))) -> \(stageName) {
                            var copy = \(storagePrefix)_\(f.name)
                            copy.append(value)
                            return .init(\(initArgs(storagePrefix: storagePrefix, fields: fields, overwrites: [f.name: "copy"])))
                        }
                        """
                    } else if isSetType(f.type) {
                        return """
                        public func \(adder)(_ value: \(setElementType(f.type))) -> \(stageName) {
                            var copy = \(storagePrefix)_\(f.name)
                            copy.insert(value)
                            return .init(\(initArgs(storagePrefix: storagePrefix, fields: fields, overwrites: [f.name: "copy"])))
                        }
                        """
                    } else {
                        // fallback: treat like set
                        return """
                        public func \(adder)(_ value: \(f.type)) -> \(stageName) {
                            return .init(\(initArgs(storagePrefix: storagePrefix, fields: fields, overwrites: [f.name: "value"])))
                        }
                        """
                    }
                } else {
                    // Required single set -> advance to next stage
                    let nextStage = (idx + 1 < stepNames.count) ? "\(modelName)BuilderStage\(idx+1)" : "\(modelName)BuilderFinal"
                    let methodName = "set" + step.prefix(1).uppercased() + step.dropFirst()
                    return """
                    public func \(methodName)(_ value: \(f.type)) -> \(nextStage) {
                        return .init(\(initArgs(storagePrefix: storagePrefix, fields: fields, overwrites: [f.name: "value"])))
                    }
                    """
                }
            }()

            let buildIfLast: String = {
                if idx == stepNames.count - 1 {
                    // Final stage will be separate type; we still add nothing here.
                    return ""
                } else {
                    return ""
                }
            }()

            let stage =
            """
            public struct \(stageName) {
                \(prefixDecls.joined(separator: "\n    "))

                public init(\(initParams(fields: fields, storagePrefix: storagePrefix))) {
                    \(initBody(fields: fields, storagePrefix: storagePrefix))
                }

                \(setOrAddMethod)
                \(buildIfLast)
            }
            """
            decls.append(DeclSyntax(stringLiteral: stage))
        }

        // Final stage type with build()
        let finalStageName = "\(modelName)BuilderFinal"
        stageNames.append(finalStageName)
        let finalStage =
        """
        public struct \(finalStageName) {
            \(fields.map { "let s_\($0.name): \($0.type)\(defaultSuffix($0))" }.joined(separator: "\n    "))

            public init(\(initParams(fields: fields, storagePrefix: "s"))) {
                \(initBody(fields: fields, storagePrefix: "s"))
            }

            public func build() -> \(modelName) {
                return \(modelName)(\(fields.map { "\($0.name): s_\($0.name)" }.joined(separator: ", ")))
            }
        }
        """
        decls.append(DeclSyntax(stringLiteral: finalStage))

        // Generate the wrapper entrypoint: Model.Builder()
        let startInitArgs = initArgs(storagePrefix: "Self()", fields: fields, overwrites: [:], asLiterals: true)
        let wrapper =
        """
        extension \(modelName) {
            public struct Builder {
                public init() {}
                public func callAsFunction() -> \(stageNames.first ?? finalStageName) { start() }
                public func start() -> \(stageNames.first ?? finalStageName) {
                    return \((stageNames.first ?? finalStageName))(\(startInitArgs))
                }
            }
        }
        """
        decls.append(DeclSyntax(stringLiteral: wrapper))

        return decls
    }
}

// ---------- helpers (stringly-typed but OK for MVP) ----------

private func defaultSuffix(_ f: Field) -> String {
    if f.accumulatingAdder != nil {
        // default to empty collection if no initializer provided in source
        return ""
    }
    return "" // keep simple; could inspect default values later
}

private func initParams(fields: [Field], storagePrefix: String) -> String {
    fields.map { "\(storagePrefix)_\($0.name): \($0.type)" }.joined(separator: ", ")
}

private func initBody(fields: [Field], storagePrefix: String) -> String {
    fields.map { "self.\(storagePrefix)_\($0.name) = \(storagePrefix)_\($0.name)" }.joined(separator: "\n        ")
}

private func initArgs(storagePrefix: String, fields: [Field], overwrites: [String:String], asLiterals: Bool = false) -> String {
    fields.map {
        if let ow = overwrites[$0.name] { return "s_\($0.name): \(ow)" }
        if asLiterals {
            // naive zero-inits for collections
            if isArrayType($0.type) { return "s_\($0.name): []" }
            if isMapType($0.type) { return "s_\($0.name): [:]" }
            if isSetType($0.type) { return "s_\($0.name): Set()" }
        }
        return "s_\($0.name): \(storagePrefix).s_\($0.name)"
    }.joined(separator: ", ")
}

private func isArrayType(_ t: String) -> Bool { t.trimmingCharacters(in: .whitespaces).hasPrefix("[") && t.hasSuffix("]") && !t.contains(":") }
private func isMapType(_ t: String) -> Bool { t.trimmingCharacters(in: .whitespaces).hasPrefix("[") && t.contains(":") && t.hasSuffix("]") }
private func isSetType(_ t: String) -> Bool { t.trimmingCharacters(in: .whitespaces).hasPrefix("Set<") }
private func arrayElementType(_ t: String) -> String {
    guard let l = t.firstIndex(of: "["), let r = t.firstIndex(of: "]") else { return "Any" }
    return String(t[t.index(after: l)..<r]).trimmingCharacters(in: .whitespaces)
}
private func mapKeyType(_ t: String) -> String {
    guard let l = t.firstIndex(of: "["), let c = t.firstIndex(of: ":"), let r = t.firstIndex(of: "]") else { return "AnyHashable" }
    return String(t[t.index(after: l)..<c]).trimmingCharacters(in: .whitespaces)
}
private func mapValueType(_ t: String) -> String {
    guard let c = t.firstIndex(of: ":"), let r = t.firstIndex(of: "]") else { return "Any" }
    return String(t[t.index(after: c)..<r]).trimmingCharacters(in: .whitespaces)
}
private func setElementType(_ t: String) -> String {
    guard let l = t.firstIndex(of: "<"), let r = t.lastIndex(of: ">") else { return "AnyHashable" }
    return String(t[t.index(after: l)..<r]).trimmingCharacters(in: .whitespaces)
}

