import XCTest
@testable import MonitrCore

final class CleanupSafetyTests: XCTestCase {
    let home = "/Users/test"

    func testRefusesHomeAndPersonalFolders() {
        for p in [home, home + "/Desktop", home + "/Documents", home + "/Downloads", home + "/Pictures",
                  home + "/Library", home + "/Library/Mobile Documents", home + "/Library/CloudStorage"] {
            XCTAssertNotNil(CleanupSafety.refusal(for: p, home: home), "\(p) must be refused")
        }
    }

    func testRefusesParentsOfHome() {
        XCTAssertNotNil(CleanupSafety.refusal(for: "/", home: home))
        XCTAssertNotNil(CleanupSafety.refusal(for: "/Users", home: home))
    }

    func testRefusesSystemFolders() {
        for p in ["/System", "/System/Library/Caches", "/usr/local/bin", "/Applications", "/Library", "/private/etc/hosts"] {
            XCTAssertNotNil(CleanupSafety.refusal(for: p, home: home), "\(p) must be refused")
        }
    }

    func testRefusesFoldersInsidePersonalFolders() {
        XCTAssertNotNil(CleanupSafety.refusal(for: home + "/Documents/project/build", home: home))
        XCTAssertNotNil(CleanupSafety.refusal(for: home + "/Desktop/screenshots", home: home))
    }

    func testTrailingSlashDoesNotSlipThrough() {
        XCTAssertNotNil(CleanupSafety.refusal(for: home + "/Documents/", home: home))
    }

    func testAllowsCacheStyleFolders() {
        for p in [home + "/Library/Caches/com.example", home + "/.gradle/caches", home + "/projects/app/build",
                  home + "/Library/Developer/Xcode/DerivedData"] {
            XCTAssertNil(CleanupSafety.refusal(for: p, home: home), "\(p) should be allowed")
        }
    }
}

final class NamingTests: XCTestCase {
    func testReverseDNSHelpersGetReadableNames() {
        XCTAssertEqual(Naming.friendlyName("com.apple.WebKit.WebContent"), "Web Content")
        XCTAssertEqual(Naming.friendlyName("com.apple.WebKit.GPU"), "GPU")
        XCTAssertEqual(Naming.friendlyName("com.apple.dt.Xcode.KeychainService"), "Keychain Service")
    }

    func testOrdinaryNamesAreLeftAlone() {
        XCTAssertEqual(Naming.friendlyName("WindowServer"), "WindowServer")
        XCTAssertEqual(Naming.friendlyName("Claude Helper (Renderer)"), "Claude Helper (Renderer)")
        XCTAssertEqual(Naming.friendlyName("STExtractionService.privileged"), "STExtractionService.privileged")
    }

    func testOutermostBundleOwnsNestedHelpers() {
        XCTAssertEqual(
            Naming.outermostBundle(in: "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
            "/Applications/Google Chrome.app")
        XCTAssertNil(Naming.outermostBundle(in: "/usr/libexec/sharingd"))
    }
}

final class NettopParserTests: XCTestCase {
    func testParsesNamesWithDotsAndCommas() {
        let out = """
        ,bytes_in,bytes_out,
        com.apple.WebKi.51604,750242664,17013390,
        Google Chrome H.123,10,20,
        odd,name.77,5,6,
        """
        let r = NettopParser.parse(Data(out.utf8))
        XCTAssertEqual(r[51604]?.0, 750_242_664)
        XCTAssertEqual(r[51604]?.1, 17_013_390)
        XCTAssertEqual(r[123]?.0, 10)
        XCTAssertEqual(r[77]?.1, 6)
        XCTAssertEqual(r.count, 3)
    }

    func testIgnoresGarbage() {
        XCTAssertTrue(NettopParser.parse(Data("nonsense\n,,\n".utf8)).isEmpty)
    }
}

final class RingTests: XCTestCase {
    func testKeepsNewestInOrderAndWraps() {
        var r = Ring(capacity: 3)
        for v in [1.0, 2, 3, 4] { r.push(v) }
        XCTAssertEqual(r.ordered, [2, 3, 4])
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r.pushes, 4)
    }
}

final class FormatTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(Fmt.bytes(UInt64(512)), "512 B")
        XCTAssertEqual(Fmt.bytes(UInt64(1536)), "1.5 KB")
        XCTAssertEqual(Fmt.bytes(UInt64(5 * 1024 * 1024 * 1024)), "5.0 GB")
    }

    func testTrafficLeavesOutIdleDirections() {
        XCTAssertEqual(Fmt.traffic(down: 0, up: 0), "–")
        XCTAssertEqual(Fmt.trafficShort(down: 2048, up: 0), "↓2.0K")
    }

    func testDurations() {
        XCTAssertEqual(Fmt.duration(30), "1m")
        XCTAssertEqual(Fmt.duration(90 * 60), "1h 30m")
        XCTAssertEqual(Fmt.duration(50 * 3600), "2d 2h")
    }

    func testChartScaleRoundsToNiceSteps() {
        XCTAssertEqual(ChartScale.niceCeiling(0), 1)
        XCTAssertEqual(ChartScale.niceCeiling(73), 100)
        XCTAssertEqual(ChartScale.niceCeiling(140), 200)
        XCTAssertEqual(ChartScale.niceCeiling(4100), 5000)
    }
}
