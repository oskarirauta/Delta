#!/usr/bin/env python3
"""Run production adapter tests with an assertion harness in a disposable tvOS simulator."""
import argparse, json, pathlib, plistlib, re, shutil, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parents[3]
def run(args, **kw):
    return subprocess.run(list(map(str,args)), check=True, timeout=180, **kw)
HELPERS='''import UIKit
func XCTAssertTrue(_ v: Bool, file: StaticString = #filePath, line: UInt = #line) { if !v { fatalError("true assertion failed: \\(file):\\(line)") } }
func XCTAssertFalse(_ v: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(!v, file: file, line: line) }
func XCTAssertNil<T>(_ v: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(v == nil, file: file, line: line) }
func XCTAssertNotNil<T>(_ v: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(v != nil, file: file, line: line) }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if a != b { fatalError("equal assertion failed: \\(a) vs \\(b) at \\(file):\\(line)") } }
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(abs(a-b) <= accuracy, file: file, line: line) }
@main final class Harness: UIResponder, UIApplicationDelegate {
 var window: UIWindow?
 func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
  window = UIWindow(frame: UIScreen.main.bounds); window?.rootViewController = UIViewController(); window?.makeKeyAndVisible()
  Task { @MainActor in
'''
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--frameworks", required=True, type=pathlib.Path,
                    help="Build/Products/Release-appletvsimulator from an arm64 Delta-tvOS build")
args = parser.parse_args()
assert (args.frameworks / "DeltaCore.framework").is_dir(), "Build the tvOS simulator app first"
sdk = subprocess.check_output(["xcrun", "--sdk", "appletvsimulator", "--show-sdk-path"], text=True).strip()
runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "--json"]))["runtimes"]
runtime = next(r["identifier"] for r in reversed(runtimes) if r.get("isAvailable") and "tvOS" in r["identifier"])
base = ["xcrun", "swiftc", "-sdk", sdk, "-target", "arm64-apple-tvos18.0-simulator"]
with tempfile.TemporaryDirectory(prefix="delta-switch2-tests-") as work:
    work = pathlib.Path(work); app = work / "Tests.app"; app.mkdir()
    vendor = ROOT / "Integrations/Switch2Kit/Vendor/Switch2Kit/Sources/Switch2Kit"
    run(base + ["-swift-version", "6", "-package-name", "DeltaSwitch2Kit", "-module-name", "Switch2Kit", "-enable-testing", "-emit-library", "-emit-module", "-emit-module-path", work/"Switch2Kit.swiftmodule", "-o", app/"libSwitch2Kit.dylib", "-Xlinker", "-install_name", "-Xlinker", "@executable_path/libSwitch2Kit.dylib"] + list(vendor.rglob("*.swift")))
    source = (ROOT / "Integrations/Switch2Kit/Tests/ControllerIntegrationTests.swift").read_text().replace("import XCTest", "").replace(": XCTestCase", "")
    names = re.findall(r"    func (test\w+)\(", source)
    harness = HELPERS + "\n".join(f'await ControllerIntegrationTests().{n}(); print("PASS {n}")' for n in names) + '''
print("ALL CONTROLLER TESTS PASSED"); fflush(stdout); exit(0)
}; return true
}}
'''
    (work/"Harness.swift").write_text(source + "\n" + harness)
    run(base + ["-swift-version", "5", "-I", work, "-L", app, "-lSwitch2Kit", "-F", args.frameworks, "-framework", "DeltaCore", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks", "-o", app/"Harness", work/"Harness.swift"] + list((ROOT/"Integrations/Switch2Kit/Adapter").glob("*.swift")))
    (app/"Frameworks").mkdir()
    for name in ["DeltaCore", "ZIPFoundation"]:
        src = args.frameworks / (name + ".framework")
        if src.exists(): shutil.copytree(src, app/"Frameworks"/src.name)
    (app/"Info.plist").write_bytes(plistlib.dumps(dict(CFBundleIdentifier="local.delta.switch2tests", CFBundleExecutable="Harness", CFBundleName="Tests", CFBundlePackageType="APPL", MinimumOSVersion="18.0", UIDeviceFamily=[3], LSRequiresIPhoneOS=True)))
    run(["codesign", "--force", "--deep", "--sign", "-", app])
    device = subprocess.check_output(["xcrun", "simctl", "create", "Delta-Switch2-Tests", "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K", runtime], text=True).strip()
    try:
        run(["xcrun", "simctl", "boot", device])
        run(["xcrun", "simctl", "bootstatus", device, "-b"])
        run(["xcrun", "simctl", "install", device, app])
        result = run(["xcrun", "simctl", "launch", "--console-pty", device, "local.delta.switch2tests"], capture_output=True, text=True)
        print(result.stdout)
        assert "ALL CONTROLLER TESTS PASSED" in result.stdout, result.stderr
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True)
        subprocess.run(["xcrun", "simctl", "delete", device], check=True)
