//
//  File.swift
//  BuildableKit
//
//  Created by Arte.k on 26.10.2025.
//

import Foundation
import XCTest
import Buildable

@Buildable
struct Person {
    var name: String
    var age: Int = 0
}

final class ExampleBuildableTest: XCTestCase {
    func testBuilder() {
        let p = Person
//            .setName("Alice")
//            .setAge(1)
//            .build()
        
            
        XCTAssertEqual(p.name, "Alice")
    }
}

