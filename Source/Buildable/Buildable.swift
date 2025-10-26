//
//  File.swift
//  BuildableKit
//
//  Created by Arte.k on 25.10.2025.
//

import Foundation

@attached(peer, names: arbitrary)
public macro Buildable(order: [String] = []) =
  #externalMacro(module: "BuildableMacros", type: "BuildableMacro")
