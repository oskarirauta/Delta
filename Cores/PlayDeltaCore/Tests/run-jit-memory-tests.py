#!/usr/bin/env python3
"""Run production CodeGen memory tests in a disposable arm64 tvOS simulator (Release assertions disabled)."""
import json
from pathlib import Path
import subprocess
import tempfile

core = Path(__file__).resolve().parents[1]

def run(arguments, **kwargs):
    return subprocess.run(list(map(str, arguments)), check=True, timeout=180, **kwargs)

sdk = subprocess.check_output(["xcrun", "--sdk", "appletvsimulator", "--show-sdk-path"], text=True).strip()
runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "--json"]))["runtimes"]
runtime = next(item["identifier"] for item in reversed(runtimes) if item.get("isAvailable") and "tvOS" in item["identifier"])
with tempfile.TemporaryDirectory(prefix="delta-play-jit-tests-") as directory:
    executable = Path(directory) / "PlayJITMemoryTests"
    run(["xcrun", "--sdk", "appletvsimulator", "clang++", "-target", "arm64-apple-tvos17.0-simulator",
         "-isysroot", sdk, "-std=c++17", "-DNDEBUG", "-Dvm_protect=PlayTestVMProtect",
         "-I", core / "Play/deps/Framework/include", "-I", core / "Play/deps/CodeGen/include",
         core / "Play/deps/CodeGen/src/MemoryFunction.cpp", core / "Tests/JITMemoryTests.cpp", "-o", executable])
    device = subprocess.check_output(["xcrun", "simctl", "create", "Delta-Play-JIT-Tests",
        "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K", runtime], text=True).strip()
    try:
        run(["xcrun", "simctl", "boot", device])
        run(["xcrun", "simctl", "bootstatus", device, "-b"])
        result = run(["xcrun", "simctl", "spawn", device, executable], capture_output=True, text=True)
        print(result.stdout)
        assert "ALL JIT MEMORY TESTS PASSED" in result.stdout, result.stderr
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True)
        run(["xcrun", "simctl", "delete", device])
