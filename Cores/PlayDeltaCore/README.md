# PlayDeltaCore

DeltaCore frontend for [Play!](https://github.com/jpd002/Play-), pinned to
`d44bfa1814b729d4a3ed3c6c3a945432d5ee5bbe` (2026-09-03). Upstream sources and
nested dependencies remain submodules; the adapter does not implement a PS2 CPU.

## Build

Initialize the pinned sources with `git submodule update --init --recursive
Cores/PlayDeltaCore/Play`. CMake 3.24+ and Xcode are required. The workspace builds
the `PlayBackend` dependency automatically before linking `PlayDeltaCore`.
ARM64 iOS/tvOS devices and ARM64 simulators are supported; deployment target 17.0.
The tvOS app registers the core. The iOS framework also builds, but PS2 is not yet
added to the iOS app's system picker or touchscreen skins.

Standalone backend example:

```sh
Cores/PlayDeltaCore/build-backend.sh appletvos Release
```

## Runtime

Play! requires JIT; there is no interpreter fallback in this integration. The
preflight uses the exact CodeGen allocator, verifies that its mapping actually
has execute permission, and tests the RX → RW → RX patch transitions. A debugger
flag alone is not proof of executable-memory permission. The probe does not jump
into generated instructions: tvOS may terminate a denied execution with SIGBUS,
which cannot be caught as a C++ exception. Failed allocation/protection is checked
in Release as well as Debug builds. The library reports the actual denied API.

`get-task-allow` permits debugger attachment; it does not itself grant JIT.
macOS's `MAP_JIT`/`pthread_jit_write_protect_np` mechanism is kept separate from
iOS/tvOS's memory-protection path. No entitlement or signing bypass is added.
N64's existing CPU configuration is unchanged. Passing simulator checks does not
establish that a physical Apple TV's current tvOS policy permits JIT.

Play! owns its CPU/GS threads and frame limiter. Delta receives a 640x448 OpenGL ES 3
presentation surface and stereo 16-bit 44100 Hz audio. Both DualShock 2 controller
ports are mapped, including sticks and L3/R3. Analog face-button pressure, vibration,
multitaps, cheats and fast-forward are not exposed in this first integration.

Memory cards are per ROM and archived to `.ps2save` when Delta saves. Save states
use Play!'s complete VM serializer (including timing), rather than the incomplete
libretro serializer. Saving pauses the VM and publishes the completed state
atomically. Imported save states remain dependent on the upstream core version.

Single-file uploads: ISO, CHD, CSO, ISZ, and MIPS ELF. ISO contents must contain an
ISO9660 `SYSTEM.CNF` with `BOOT2`; GameCube disc magic is checked separately. ELF
architecture distinguishes MIPS/PS2 from PowerPC/GameCube. CUE/BIN and MDS/MDF
multi-file imports are not exposed yet.

## Smoke test

Generate a small original PS2 executable without a PS2 SDK or copyrighted assets:

```sh
python3 Cores/PlayDeltaCore/Tests/generate-smoke-elf.py /tmp/Delta-PS2-Smoke.elf
```

It draws a red rectangle and writes `0x12345678` to EE RAM at `0x00100400`.
A tvOS simulator harness has verified startup, visible GS output, pause, state
save/load, stop and a second startup. This does not establish commercial-game
compatibility or Apple TV performance. Silent Hill 4 is the intended device test;
its upstream compatibility reports still carry the `state-ingame` label.

Upstream licenses are bundled as `THIRD_PARTY_NOTICES.txt` in the framework.

### JIT memory regression tests

```sh
python3 Cores/PlayDeltaCore/Tests/run-jit-memory-tests.py
```

This builds production CodeGen with assertions disabled and substitutes only
`vm_protect` to reproduce denied protection and a false success result without
execute permission. It also executes real ARM64 code, patches and executes it
again, copies a block, and checks failed patch transitions. Its temporary simulator
and executable are removed afterwards. It does not grant device JIT permission.

On the tested Apple TV 4K (second generation), tvOS 27.0 (24J361), debugger
attachment was insufficient: ordinary RW → RX returned success but the mapping
remained read-only, RWX mapped as RW, and MAP_JIT was rejected. This is a result
for that tested configuration, not a claim that every tvOS release behaves alike.
The preflight must report this as unavailable; no verified activation workaround
has been established for that device configuration.
