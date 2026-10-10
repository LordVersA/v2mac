import Foundation
import Testing
@testable import V2MacCore

@Suite struct ExitLookupTests {
    func parse(_ text: String) -> ExitInfo? { ExitLookup.parse(Data(text.utf8)) }

    @Test func readsEverySourceShape() {
        let who = parse(#"{"ip":"203.0.113.7","success":true,"country":"Netherlands","country_code":"NL","city":"Amsterdam"}"#)
        #expect(who == ExitInfo(ip: "203.0.113.7", countryCode: "NL", city: "Amsterdam"))
        let info = parse(#"{"ip":"2001:db8::7","city":"Frankfurt am Main","country":"DE","org":"AS64500 Example"}"#)
        #expect(info == ExitInfo(ip: "2001:db8::7", countryCode: "DE", city: "Frankfurt am Main"))
        let trace = parse("fl=1\nh=www.cloudflare.com\nip=203.0.113.7\nloc=fi\nwarp=off\n")
        #expect(trace == ExitInfo(ip: "203.0.113.7", countryCode: "FI", city: nil))
    }

    @Test func rejectsAnswersWithoutAnAddress() {
        #expect(parse(#"{"success":false,"message":"limit reached","ip":"203.0.113.7"}"#) == nil)
        #expect(parse(#"{"country_code":"NL"}"#) == nil)
        #expect(parse("<html>blocked</html>") == nil)
        #expect(parse(#"{"ip":"not an address"}"#) == nil)
    }

    @Test func flagAndPlace() {
        let exit = ExitInfo(ip: "203.0.113.7", countryCode: "NL", city: "Amsterdam")
        #expect(exit.flag == "🇳🇱")
        #expect(exit.place(locale: Locale(identifier: "en_US")) == "Amsterdam, Netherlands")
        #expect(ExitInfo(ip: "203.0.113.7", countryCode: "DE").place(locale: Locale(identifier: "en_US")) == "Germany")
        #expect(ExitInfo(ip: "203.0.113.7").place() == nil)
        #expect(ExitInfo(ip: "203.0.113.7").flag == nil)
    }
}
