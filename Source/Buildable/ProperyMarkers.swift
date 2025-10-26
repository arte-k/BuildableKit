//
//  File.swift
//  BuildableKit
//
//  Created by Arte.k on 25.10.2025.
//

import Foundation

@attached(peer) public macro Required() =
  #externalMacro(module: "BuildableMacros", type: "NoopMarkerMacro")

@attached(peer) public macro Accumulating(adder: String? = nil) =
  #externalMacro(module: "BuildableMacros", type: "NoopMarkerMacro")
