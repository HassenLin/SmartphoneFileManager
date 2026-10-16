import Foundation
import Testing
@testable import AFMCore

// 原 Kotlin 版測試（CommandLineTokenizerTest、ShellOutputFilterTest、TextEncodingTest…）的對應移植，
// 外加這版新增的解析器（devices -l、stat 檔名含 |、dumpsys battery）。

@Suite("CommandLineTokenizer")
struct CommandLineTokenizerTests {
    @Test func splitsPlainArguments() throws {
        #expect(try CommandLineTokenizer.tokenize("adb  -s abc   shell ls") == ["adb", "-s", "abc", "shell", "ls"])
    }

    @Test func keepsQuotedSpaces() throws {
        #expect(try CommandLineTokenizer.tokenize(#"adb push "/Users/me/My File.txt" '/sdcard/a b'"#)
                == ["adb", "push", "/Users/me/My File.txt", "/sdcard/a b"])
    }

    @Test func handlesEscapes() throws {
        #expect(try CommandLineTokenizer.tokenize(#"adb push My\ File.txt "a\"b""#) == ["adb", "push", "My File.txt", "a\"b"])
    }

    @Test func emptyQuotedArgument() throws {
        #expect(try CommandLineTokenizer.tokenize(#"adb shell """#) == ["adb", "shell", ""])
    }

    @Test func rejectsUnclosedQuote() {
        #expect(throws: AdbError.self) { try CommandLineTokenizer.tokenize("adb 'oops") }
    }
}

@Suite("ShellText / RemotePath")
struct ShellTextTests {
    @Test func quotesSingleQuote() {
        #expect(ShellText.quote("it's") == #"'it'\''s'"#)
        #expect(ShellText.quote("中文 檔名") == "'中文 檔名'")
    }

    @Test func quoteForInputKeepsSimplePaths() {
        #expect(ShellText.quoteForInput("/sdcard/Download") == "/sdcard/Download")
        #expect(ShellText.quoteForInput("/sdcard/a b") == "'/sdcard/a b'")
    }

    @Test func pathOperations() {
        #expect(RemotePath.join("/", "sdcard") == "/sdcard")
        #expect(RemotePath.join("/sdcard/", "a") == "/sdcard/a")
        #expect(RemotePath.parent(of: "/sdcard/a") == "/sdcard")
        #expect(RemotePath.parent(of: "/sdcard") == "/")
        #expect(RemotePath.normalize("/a/./b/../c//d") == "/a/c/d")
        #expect(RemotePath.resolve("../x", from: "/sdcard/Download") == "/sdcard/x")
        #expect(RemotePath.name(of: "/sdcard/a.txt") == "a.txt")
    }
}

@Suite("Parsers")
struct ParserTests {
    @Test func parsesDevicesList() {
        let lines = [
            "* daemon started successfully",
            "List of devices attached",
            "emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1",
            "192.168.1.5:5555       device product:panther model:Pixel_7 device:panther transport_id:3",
            "R5CT1234               unauthorized usb:1-1 transport_id:2",
            "",
        ]
        let devices = AdbDeviceInfo.parse(lines)
        #expect(devices.map(\.serial) == ["emulator-5554", "192.168.1.5:5555", "R5CT1234"])
        #expect(devices[1].model == "Pixel_7")
        #expect(devices[1].isWireless)
        #expect(devices[0].isEmulator)
        #expect(!devices[2].isReady)
    }

    @Test func noHeaderMeansNoDevices() {
        #expect(AdbDeviceInfo.parse(["error: cannot connect to daemon"]).isEmpty)
    }

    @Test func parsesStatOutputWithPipeInName() {
        let lines = [
            "directory|drwxrwx--x|3488|1700000000|Download",
            "regular file|-rw-rw----|1024|1700000100|a|b.txt",
            "/system/bin/sh: stat: '.[!.]*': No such file or directory",
        ]
        let files = StatParser.parse(lines, parent: "/sdcard")
        #expect(files.count == 2)
        #expect(files[0].isDirectory && files[0].path == "/sdcard/Download")
        #expect(files[1].name == "a|b.txt" && files[1].size == 1024)
        #expect(files[1].modified == Date(timeIntervalSince1970: 1_700_000_100))
    }

    @Test func parsesSearchResultsWithAbsolutePaths() {
        let files = StatParser.parse(["regular file|-rw-rw----|5|1|/sdcard/Download/x.apk"], parent: nil)
        #expect(files.first?.path == "/sdcard/Download/x.apk")
        #expect(files.first?.kind == .apk)
    }

    @Test func parsesBatteryAndDf() {
        let battery = DeviceInfoService.parseBattery([
            "Current Battery Service state:", "  AC powered: false", "  USB powered: true",
            "  status: 2", "  health: 2", "  level: 50", "  scale: 100", "  voltage: 4100", "  temperature: 285",
        ])
        #expect(battery.percentage == 50 && battery.usbPowered && battery.status == 2)
        #expect(battery.temperatureCelsius == 28.5)

        let storage = DeviceInfoService.parseDf([
            "Filesystem      1K-blocks     Used Available Use% Mounted on",
            "/dev/block/dm-5 115000000 50000000  65000000  44% /data",
        ])
        #expect(storage.totalBytes == 115_000_000 * 1024)
        #expect(storage.freeBytes == 65_000_000 * 1024)
    }

    @Test func parsesProps() {
        let props = DeviceInfoService.parseProps(["[ro.product.model]: [Pixel 7]", "[ro.build.version.sdk]: [34]"])
        #expect(props["ro.product.model"] == "Pixel 7")
        #expect(props["ro.build.version.sdk"] == "34")
    }

    @Test func parsesPackages() {
        #expect(AppPackageService.parsePackages(["package:com.a.b", "junk", "package:"]) == ["com.a.b"])
    }

    @Test func rejectsShellInjectionInPackageName() {
        #expect(throws: AdbError.self) { try AppPackageService.validate("com.a; rm -rf /") }
        #expect(throws: Never.self) { try AppPackageService.validate("com.example.app_1") }
    }

    @Test func rejectsBadFileNames() {
        #expect(throws: AdbError.self) { try RemoteFileService.validateName("a/b") }
        #expect(throws: AdbError.self) { try RemoteFileService.validateName("..") }
        #expect(throws: Never.self) { try RemoteFileService.validateName("新檔案 (1).txt") }
    }
}

@Suite("Terminal")
struct TerminalTests {
    @Test func filterCapturesDirectoryMarker() {
        let filter = ShellOutputFilter()
        #expect(filter.filter("__AFM_PWD__=/sdcard\r") == .directory("/sdcard"))
        #expect(filter.filter("stty -echo 2>/dev/null; export PS1=''") == .suppressed)
        #expect(filter.filter("shell@panther:/ $ ") == .suppressed)
        #expect(filter.filter("/sdcard #") == .suppressed)
        #expect(filter.filter("hello world") == .output("hello world"))
    }

    @Test func completionToken() {
        #expect(ShellCompletion.token(in: "ls /sdc") == .init(startIndex: 3, value: "/sdc"))
        #expect(ShellCompletion.token(in: "cat 'My Fi") == .init(startIndex: 4, value: "My Fi"))
        #expect(ShellCompletion.longestCommonPrefix(["Download", "Documents", "DCIM"]) == "D")
        #expect(ShellCompletion.longestCommonPrefix(["Music", "Music2"]) == "Music")
    }
}

@Suite("Model")
struct ModelTests {
    struct Entry: FileEntry {
        var name: String
        var isDirectory: Bool
        var size: Int64 = 0
        var modified: Date? = nil
        var id: String { name }
    }

    @Test func typeSortPutsFoldersFirstWithNaturalOrder() {
        let entries = [Entry(name: "file10", isDirectory: false), Entry(name: "b", isDirectory: true),
                       Entry(name: "file2", isDirectory: false), Entry(name: "A", isDirectory: true)]
        #expect(SortType.typeAscending.sorted(entries).map(\.name) == ["A", "b", "file2", "file10"])
        #expect(SortType.typeDescending.sorted(entries).map(\.name) == ["file10", "file2", "b", "A"])
    }

    @Test func byteFormat() {
        #expect(ByteFormat.string(512) == "512 B")
        #expect(ByteFormat.string(1536) == "1.50 KB")
        #expect(ByteFormat.string(1024 * 1024) == "1 MB")
    }

    @Test func textDecodingDetectsBig5AndUtf8() {
        #expect(TextCodec.decode(Data("plain ascii".utf8)).encoding == .utf8)
        let big5 = TextEncoding.named("Big5")!
        let data = "繁體中文測試，這是一段比較長的文字用來偵測編碼。".data(using: big5.encoding)!
        let decoded = TextCodec.decode(data)
        #expect(decoded.text.contains("繁體中文"))
    }

    @Test func losslessEncodingUpgradesToUtf8() {
        let latin1 = TextEncoding.named("ISO-8859-1")!
        let kept = TextCodec.encodeLosslessly("café", preferred: latin1)
        #expect(kept.encoding == latin1 && !kept.upgraded)
        let upgraded = TextCodec.encodeLosslessly("café 中文", preferred: latin1)
        #expect(upgraded.encoding == .utf8 && upgraded.upgraded)
        #expect(String(data: upgraded.data, encoding: .utf8) == "café 中文")
    }

    @Test func bookmarkFileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("afm-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = BookmarkFile(url: url)
        try file.save([Bookmark(name: "下載", path: "/sdcard/Download")])
        #expect(file.load().first?.path == "/sdcard/Download")
    }

    @Test func fileKinds() {
        #expect(FileKind(fileName: "a.PNG") == .image)
        #expect(FileKind(fileName: "build.gradle").isEditableText)
        #expect(!FileKind(fileName: "a.bin").isEditableText)
    }
}

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test func collectsOutputAndExitCode() async throws {
        let output = try await ProcessRunner.run("/bin/sh", ["-c", "echo hi; echo err >&2; exit 3"])
        #expect(output.exitCode == 3)
        #expect(output.lines.sorted() == ["err", "hi"])
    }

    @Test func timesOut() async {
        await #expect(throws: AdbError.self) {
            try await ProcessRunner.run("/bin/sleep", ["5"], timeout: .milliseconds(200))
        }
    }

    @Test func cancellationTerminatesChild() async {
        let task = Task { try await ProcessRunner.run("/bin/sleep", ["5"], timeout: nil) }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let start = Date()
        _ = await task.result
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func streamsLinesSplitOnCarriageReturn() async throws {
        var lines: [String] = []
        for try await line in ProcessRunner.lines("/bin/sh", ["-c", "printf '[ 10%%]\\r[ 50%%]\\rdone\\n'"]) {
            lines.append(line)
        }
        #expect(lines == ["[ 10%]", "[ 50%]", "done"])
    }
}
