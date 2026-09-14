//
//  ObjCExceptionTests.swift
//  AerialTests
//
//  The ObjC exception catcher the wallpaper extension wraps its
//  private-API calls in. Pins the contract: values and Swift errors pass
//  through untouched, an NSException — hand-raised or framework-raised —
//  becomes an ObjCExceptionError with name, reason, context and frames.
//

import Testing
import Foundation
@testable import Aerial

@Suite("ObjCException")
struct ObjCExceptionTests {
    struct SwiftFailure: Error, Equatable { let code: Int }

    @Test("a normal body returns its value")
    func passthrough() throws {
        let value = try ObjCException.catching("t") { 41 + 1 }
        #expect(value == 42)
        #expect(ObjCException.attempt("t") { "ok" } == "ok")
    }

    @Test("a Swift error thrown inside the body propagates unchanged")
    func swiftErrorPropagates() {
        #expect(throws: SwiftFailure(code: 7)) {
            try ObjCException.catching("t") { throw SwiftFailure(code: 7) }
        }
        let attempted: Int? = ObjCException.attempt("t") { throw SwiftFailure(code: 1) }
        #expect(attempted == nil)
    }

    @Test("a raised NSException becomes an ObjCExceptionError carrying name, reason and context")
    func raisedExceptionIsCaught() {
        let error = #expect(throws: ObjCExceptionError.self) {
            try ObjCException.catching("unit-test") {
                NSException(name: .genericException, reason: "boom", userInfo: nil).raise()
            }
        }
        #expect(error?.name == NSExceptionName.genericException.rawValue)
        #expect(error?.reason == "boom")
        #expect(error?.context == "unit-test")
        #expect(error?.description == "NSGenericException in unit-test: boom")
    }

    @Test("a framework-raised exception (unknown KVC key) is caught the same way")
    func frameworkExceptionIsCaught() {
        let error = #expect(throws: ObjCExceptionError.self) {
            try ObjCException.catching("kvc") { _ = NSObject().value(forKey: "definitelyNotAKey") }
        }
        #expect(error?.name == NSExceptionName.undefinedKeyException.rawValue)
        let attempted = ObjCException.attempt("kvc") { NSObject().value(forKey: "definitelyNotAKey") }
        #expect(attempted == nil)
    }

    @Test("the unwinding frames are captured and a missing reason is spelled out")
    func callStackCaptured() {
        let error = #expect(throws: ObjCExceptionError.self) {
            try ObjCException.catching("stack") {
                NSException(name: .internalInconsistencyException, reason: nil, userInfo: nil).raise()
            }
        }
        #expect(!(error?.callStack.isEmpty ?? true))
        #expect(error?.reason == "(no reason)")
    }
}
