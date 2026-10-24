import XCTest
@testable import GoProKit

final class GoProFrameAccumulatorTests: XCTestCase {
    func testSinglePacketFrame() {
        let accumulator = GoProFrameAccumulator()
        // 5-bit length header: total payload 4 bytes, then the payload.
        let packet = Data([0x04, 0xAA, 0xBB, 0xCC, 0xDD])

        let frame = accumulator.feed(packet)

        XCTAssertEqual(frame, Data([0xAA, 0xBB, 0xCC, 0xDD]))
    }

    func testMultiPacketFrameWithContinuations() {
        let accumulator = GoProFrameAccumulator()
        let payload = Data((0..<300).map { UInt8($0 % 256) })

        // 13-bit length header: 300 = 0x012C.
        let startPacket = Data([0x21, 0x2C]) + payload.prefix(100)
        XCTAssertNil(accumulator.feed(startPacket))

        let continuation = Data([0x80]) + payload.dropFirst(100).prefix(150)
        XCTAssertNil(accumulator.feed(continuation))

        let lastChunk = Data([0x80]) + payload.dropFirst(250)
        let frame = accumulator.feed(lastChunk)

        XCTAssertEqual(frame, payload)
    }

    func testResetClearsPartialFrame() {
        let accumulator = GoProFrameAccumulator()
        let startPacket = Data([0x21, 0x2C]) + Data(repeating: 0x01, count: 100)
        XCTAssertNil(accumulator.feed(startPacket))

        accumulator.reset()

        // After a reset the next start packet must parse as a new frame.
        let small = Data([0x02, 0xAB, 0xCD])
        XCTAssertEqual(accumulator.feed(small), Data([0xAB, 0xCD]))
    }

    func testEmptyPacketIsIgnored() {
        XCTAssertNil(GoProFrameAccumulator().feed(Data()))
    }
}

final class GoProTLVParserTests: XCTestCase {
    func testParseStatusFrame() {
        // responseType 0x13, one entry: id 7 (battery), 1-byte value 90.
        let frame = Data([0x13, 0x07, 0x01, 0x5A])

        let update = GoProTLVParser.parseQueryResponse(frame)

        XCTAssertEqual(update?.statuses, [7: 90])
        XCTAssertEqual(update?.settings, [:])
        XCTAssertEqual(update?.responseType, 0x13)
    }

    func testParseFrameWithStatusCodeByte() {
        // 0x00 after the type is a status code and must be skipped.
        let frame = Data([0x13, 0x00, 0x07, 0x01, 0x23])

        let update = GoProTLVParser.parseQueryResponse(frame)

        XCTAssertEqual(update?.statuses, [7: 35])
    }

    func testParseMultiByteValue() {
        // id 2 value 1, id 3 value 300 (2 bytes, big-endian).
        let frame = Data([0x12, 0x02, 0x01, 0x01, 0x03, 0x02, 0x01, 0x2C])

        let update = GoProTLVParser.parseQueryResponse(frame)

        XCTAssertEqual(update?.settings, [2: 1, 3: 300])
    }

    func testUnknownResponseTypeIsRejected() {
        XCTAssertNil(GoProTLVParser.parseQueryResponse(Data([0x01, 0x02])))
    }

    func testSettingResponseFrame() {
        // Setting response: type byte 0x00, one entry id 2 value 1.
        let frame = Data([0x00, 0x02, 0x01, 0x01])

        XCTAssertEqual(GoProTLVParser.parseSettingResponse(frame), [2: 1])
    }

    func testTruncatedEntryStopsParsing() {
        // Declared length 5 but only 1 byte follows: nothing parsed, no crash.
        let frame = Data([0x13, 0x07, 0x05, 0x01])

        XCTAssertEqual(GoProTLVParser.parseQueryResponse(frame)?.statuses, [:])
    }
}

final class GoProCommandsTests: XCTestCase {
    func testSetSettingCommandBytes() {
        XCTAssertEqual(GoProCommands.setSetting(settingId: 2, value: 1), [0x03, 0x02, 0x01, 0x01])
        XCTAssertEqual(GoProCommands.setSetting(settingId: 135, value: 3), [0x03, 0x87, 0x01, 0x03])
    }

    func testShutterCommandsMatchAndroid() {
        XCTAssertEqual(GoProCommands.shutterOn, [0x01, 0x01, 0x01])
        XCTAssertEqual(GoProCommands.shutterOff, [0x01, 0x01, 0x00])
        XCTAssertEqual(GoProCommands.keepAlive, [0x01, 0x5B])
        XCTAssertEqual(GoProCommands.wifiApOn, [0x03, 0x17, 0x01, 0x01])
    }

    func testQueryStatusCommand() {
        XCTAssertEqual(GoProCommands.queryStatus([70, 10]), [0x03, 0x13, 70, 10])
    }
}

final class GoProModelTests: XCTestCase {
    func testDisplayNameFromFirmwarePrefix() {
        XCTAssertEqual(GoProModel.displayName(raw: "HD6.01.02.10"), "HERO6 Black")
        XCTAssertEqual(GoProModel.displayName(raw: "H23.01"), "HERO12 Black")
    }

    func testDisplayNameFromHexModelGarbage() {
        // Hex number that maps to a real model resolves like the Android app does.
        XCTAssertEqual(GoProModel.displayName(raw: "00000018"), "HERO6 Black")
        // Hex-looking garbage with no known model stays hidden.
        XCTAssertEqual(GoProModel.displayName(raw: "abcdef12", fallback: "GoPro"), "GoPro")
    }

    func testDisplayNameFallsBackWhenEmpty() {
        XCTAssertEqual(GoProModel.displayName(raw: "", fallback: "HERO Camera"), "HERO Camera")
        XCTAssertEqual(GoProModel.displayName(raw: nil, fallback: "HERO Camera"), "HERO Camera")
    }

    func testDisplayNameKeepsUnknownNames() {
        XCTAssertEqual(GoProModel.displayName(raw: "GoPro 1470"), "GoPro 1470")
    }
}

final class GoProDeviceTests: XCTestCase {
    func testGoProNameHeuristics() {
        XCTAssertTrue(GoProDevice.looksLikeGoPro("GoPro 1470"))
        XCTAssertTrue(GoProDevice.looksLikeGoPro("HERO6 Black"))
        XCTAssertTrue(GoProDevice.looksLikeGoPro("Fusion"))
        XCTAssertTrue(GoProDevice.looksLikeGoPro("Max"))
        XCTAssertFalse(GoProDevice.looksLikeGoPro("iPhone"))
        XCTAssertFalse(GoProDevice.looksLikeGoPro("   "))
    }
}

final class BatteryMappingTests: XCTestCase {
    func testBatteryBarsToPercent() {
        XCTAssertEqual(GoProWifiAPI.batteryPercent(fromBars: 3), 100)
        XCTAssertEqual(GoProWifiAPI.batteryPercent(fromBars: 2), 65)
        XCTAssertEqual(GoProWifiAPI.batteryPercent(fromBars: 1), 35)
        XCTAssertEqual(GoProWifiAPI.batteryPercent(fromBars: 0), 10)
    }

    func testParseStateAddsBatteryFallback() throws {
        let json = Data(#"{"status":{"70":0,"2":3,"10":1},"settings":{"2":1}}"#.utf8)

        let state = try GoProWifiAPI.parseState(json)

        XCTAssertEqual(state.status["70"], 100)
        XCTAssertEqual(state.status["10"], 1)
        XCTAssertEqual(state.settings["2"], 1)
    }
}

final class MediaListTests: XCTestCase {
    func testDecodeCameraMediaList() throws {
        let json = Data("""
        {
          "id": "",
          "media": [
            {
              "d": "100GOPRO",
              "fs": [
                {"n": "GX010123.MP4", "cre": 1700000000, "mod": 1700000100, "s": "12345678"},
                {"n": "G0011234.JPG", "cre": 1700000200, "mod": 1700000200, "s": ""}
              ]
            }
          ]
        }
        """.utf8)

        let list = try JSONDecoder().decode(MediaList.self, from: json)

        XCTAssertEqual(list.media.count, 1)
        let directory = list.media[0]
        XCTAssertEqual(directory.directory, "100GOPRO")
        XCTAssertEqual(directory.files.count, 2)
        XCTAssertEqual(directory.files[0].name, "GX010123.MP4")
        XCTAssertEqual(directory.files[0].byteSize, 12_345_678)
        XCTAssertTrue(directory.files[0].isVideo)
        XCTAssertFalse(directory.files[1].isVideo)
        XCTAssertNil(directory.files[1].byteSize)
    }

    func testDecodePresetList() throws {
        let json = Data("""
        {
          "presetGroupArray": [
            {
              "id": 1000,
              "presetArray": [
                {"id": 42, "mode": 0, "titleId": 0, "icon": 72, "isModified": false, "isFixed": false,
                 "settingArray": [{"id": 2, "value": 1}]}
              ]
            }
          ]
        }
        """.utf8)

        let list = try JSONDecoder().decode(PresetList.self, from: json)

        XCTAssertEqual(list.groups.first?.id, 1000)
        let preset = list.groups.first!.presets[0]
        XCTAssertEqual(preset.id, 42)
        XCTAssertEqual(preset.title, "Cinematic")
        XCTAssertEqual(preset.settings, [PresetSetting(id: 2, value: 1)])
    }
}
