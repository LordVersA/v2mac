import Foundation
import Testing
@testable import V2MacCore

@Suite struct JSONValueTests {
    @Test func roundTrip() throws {
        let json = #"{"a":[1,2.5,"x",true,null],"b":{"c":"d"}}"#
        let value = try JSONValue.parse(Data(json.utf8))
        #expect(value["a"]?[0]?.intValue == 1)
        #expect(value["a"]?[1]?.doubleValue == 2.5)
        #expect(value["a"]?[2]?.stringValue == "x")
        #expect(value["a"]?[3]?.boolValue == true)
        #expect(value["a"]?[4] == .null)
        #expect(value["b"]?["c"]?.stringValue == "d")
        let again = try JSONValue.parse(try value.data())
        #expect(again == value)
    }

    @Test func wholeNumbersEncodeWithoutDecimalPoint() throws {
        let text = String(decoding: try JSONValue.object(["port": 10808]).data(), as: UTF8.self)
        #expect(text == #"{"port":10808}"#)
    }

    @Test func booleansAreNotNumbers() throws {
        let value = try JSONValue.parse(Data(#"[true,1]"#.utf8))
        #expect(value[0] == .bool(true))
        #expect(value[1] == .number(1))
    }

    @Test func settingReplacesKey() {
        let base: JSONValue = ["a": 1]
        let v = base.setting("a", to: 2).setting("b", to: "x")
        #expect(v["a"]?.intValue == 2)
        #expect(v["b"]?.stringValue == "x")
    }

    @Test func serialisationIsDeterministic() throws {
        let v: JSONValue = ["b": 1, "a": 2]
        #expect(String(decoding: try v.data(), as: UTF8.self) == #"{"a":2,"b":1}"#)
    }
}
