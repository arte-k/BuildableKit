//
//  File.swift
//  BuildableKit
//
//  Created by Arte.k on 25.10.2025.
//

import Foundation

@attached(memberAttribute)
public macro Required() =
  #externalMacro(module: "BuildableMacros", type: "NoopMarkerMacro")

@attached(memberAttribute)
public macro Accumulating(adder: String? = nil) =
  #externalMacro(module: "BuildableMacros", type: "NoopMarkerMacro")
