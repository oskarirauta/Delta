# Switch 2 controllers

This integration uses the app-owned controller registry and adapter from
[jmonster/Delta](https://github.com/jmonster/delta/commit/53ac7b7f863c5ddfdb9e3cbaf03129848094c564),
with additional tvOS integration and L3/R3 mappings. The SDK is an unmodified
submodule pinned to `de2514bc687df810ea804449c8d5c0e88c4702bd`.
The local package exposes its sources to both iOS and tvOS; its Mutex-backed
queues require iOS/tvOS 18 and Xcode 26 or newer.

Original Switch Joy-Con and Pro controllers continue to use Apple's native
GameController support. Switch 2 controllers use the explicit **Find Switch 2
Controllers** screen (iOS: Settings → Controllers → Switch 2; tvOS: library).
Allow Bluetooth access and hold Sync. Discovery lasts 60 seconds. Do not connect
the same controller through another Bluetooth controller application concurrently.

Supported models: Pro Controller 2, individual Joy-Con 2 halves in horizontal
orientation, and the Switch 2 NSO GameCube controller. Controllers share player
slots with native controllers, release held inputs on disconnect/interruption,
and are disconnected when the application backgrounds. Find must be used again
on return. Combined Joy-Con pairs, motion, mouse and rumble are not implemented.
On tvOS use the Siri Remote to navigate menus; it never supplies gameplay input.
A disconnected gameplay controller triggers the existing pause/reconnect alert.

The adapter tests in `Tests/ControllerIntegrationTests.swift` exercise the real
registry, service, mappings and DeltaCore receiver machinery with a substituted
radio. They include delayed/stale reports, connection replacement, interruption,
player conflicts, reentrancy, sustained-input release and thumbstick clicks.
Run after an arm64 tvOS simulator build:

```sh
python3 Integrations/Switch2Kit/Tests/run-tests.py --frameworks /path/to/Build/Products/Release-appletvsimulator
```

The runner builds a test-enabled SDK, substitutes fatal assertions for XCTest in
a temporary harness, runs all test methods against production adapter code, and
removes its simulator and files. It does not connect to physical controllers.

Attribution and upstream license notices are preserved in the SDK's
[CREDITS.md](Vendor/Switch2Kit/CREDITS.md) and
[LICENSES](Vendor/Switch2Kit/LICENSES/README.md).
