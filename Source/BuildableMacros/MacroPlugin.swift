//
//  File.swift
//  BuildableKit
//
//  Created by Arte.k on 25.10.2025.
//

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct BuildablePlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        BuildableMacro.self,
        MarkerMacro.self,
    ]
}
