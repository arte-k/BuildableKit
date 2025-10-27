//
//  File.swift
//  BuildableKit
//
//  Created by Arte.k on 25.10.2025.
//

import Foundation

@attached(member, names: arbitrary)
@attached(peer,   names: suffixed(Builder))
public macro Buildable() =
  #externalMacro(module: "BuildableMacros", type: "BuildableMacro")

