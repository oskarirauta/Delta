#include "DeltaPlayBackend.h"
#include "MemoryFunction.h"
#include <cstdio>
#include "PS2VM.h"
#include "PS2VM_Preferences.h"
#include "AppConfig.h"
#include "gs/GSH_OpenGL/GSH_OpenGL.h"
#include "PathUtils.h"
#include <array>
#include <algorithm>
#include <mutex>
#include <memory>
#include <string>

static std::unique_ptr<CPS2VM> vm;
static DeltaPlayCallbacks callbacks = {};
static fs::path basePath;
static std::string lastError;
static bool booted = false;
static fs::path discPath;

fs::path CAppConfig::GetBasePath() const { return basePath; }

class DeltaGS final : public CGSH_OpenGL {
public:
    DeltaGS() : CGSH_OpenGL(true) {}
    void InitializeImpl() override {
        callbacks.prepare_video(callbacks.context);
        GLint framebuffer = 0;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &framebuffer);
        m_presentFramebuffer = framebuffer;
        PRESENTATION_PARAMS params;
        params.mode = PRESENTATION_MODE_FIT;
        params.windowWidth = 640;
        params.windowHeight = 448;
        SetPresentationParams(params);
        CGSH_OpenGL::InitializeImpl();
    }
    void PresentBackbuffer() override { callbacks.present_video(callbacks.context); }
};

class DeltaSound final : public CSoundHandler {
public:
    void Reset() override {}
    void RecycleBuffers() override {}
    bool HasFreeBuffers() override { return true; }
    void Write(int16 *samples, unsigned count, unsigned rate) override {
        // Play!'s SPU output is interleaved stereo at 44100 Hz.
        if(rate == 44100) callbacks.write_audio(callbacks.context, samples, count);
    }
};

class DeltaPad final : public CPadHandler {
public:
    std::mutex mutex;
    std::array<std::array<float, PS2::CControllerInfo::MAX_BUTTONS>, 2> inputs = {};
    void Set(unsigned player, unsigned input, float value) {
        if(player >= inputs.size() || input >= inputs[0].size()) return;
        std::lock_guard<std::mutex> lock(mutex);
        inputs[player][input] = std::max(-1.f, std::min(1.f, value));
    }
    void Update(uint8 *ram) override {
        std::lock_guard<std::mutex> lock(mutex);
        for(auto *listener : m_interfaces) {
            for(unsigned port = 0; port < inputs.size(); ++port) {
                for(unsigned i = 0; i < inputs[port].size(); ++i) {
                    auto button = static_cast<PS2::CControllerInfo::BUTTON>(i);
                    if(PS2::CControllerInfo::IsAxis(button)) {
                        listener->SetAxisState(port, button, static_cast<uint8>((inputs[port][i] + 1.f) * 127.5f), ram);
                    } else {
                        listener->SetButtonState(port, button, inputs[port][i] > 0.5f, ram);
                    }
                }
            }
        }
    }
};

extern "C" bool delta_play_start(const char *disc, const char *storage, DeltaPlayCallbacks cb) {
    if(vm) return false;
    lastError.clear();
    try {
        basePath = fs::path(storage);
        Framework::PathUtils::EnsurePathExists(basePath);
        callbacks = cb;
        discPath = fs::path(disc);
        CGSH_OpenGL::RegisterPreferences();
        vm = std::make_unique<CPS2VM>();
        vm->Initialize();
        // CAppConfig is a singleton: explicitly update per-game paths each launch.
        auto &config = CAppConfig::GetInstance();
        for(auto setting : {PREF_PS2_MC0_DIRECTORY, PREF_PS2_MC1_DIRECTORY}) {
            auto path = basePath / (setting == std::string(PREF_PS2_MC0_DIRECTORY) ? "mc0" : "mc1");
            Framework::PathUtils::EnsurePathExists(path);
            config.SetPreferencePath(setting, path);
        }
        config.SetPreferencePath(PREF_PS2_CDROM0_PATH, discPath);
        config.SetPreferenceBoolean(PREF_PS2_LIMIT_FRAMERATE, true);
        config.SetPreferenceInteger(PREF_AUDIO_SPUBLOCKCOUNT, 22);
        config.SetPreferenceInteger(PREF_CGSH_OPENGL_RESOLUTION_FACTOR, 1);
        vm->ReloadFrameRateLimit();
        vm->CreateGSHandler([] { return new DeltaGS(); });
        vm->CreatePadHandler([] { return new DeltaPad(); });
        vm->CreateSoundHandler([] { return new DeltaSound(); });
        booted = false;
        return true;
    } catch(const std::exception &error) {
        lastError = error.what();
        delta_play_stop();
        return false;
    }
}
extern "C" void delta_play_stop() {
    if(!vm) return;
    vm->Pause();
    vm->DestroyPadHandler();
    vm->DestroyGSHandler();
    vm->DestroySoundHandler();
    vm->Destroy();
    vm.reset();
    booted = false;
}
extern "C" bool delta_play_running() { return vm && vm->GetStatus() == CVirtualMachine::RUNNING; }
extern "C" void delta_play_pause() { if(vm) vm->Pause(); }
extern "C" void delta_play_resume() {
    if(!vm) return;
    if(!booted) {
        vm->Reset();
        auto extension = discPath.extension().string();
        std::transform(extension.begin(), extension.end(), extension.begin(), ::tolower);
        if(extension == ".elf") vm->m_ee->m_os->BootFromFile(discPath);
        else vm->m_ee->m_os->BootFromCDROM();
        booted = true;
    }
    vm->Resume();
}
extern "C" void delta_play_input(unsigned player, unsigned input, float value) {
    if(vm && vm->GetPadHandler()) static_cast<DeltaPad *>(vm->GetPadHandler())->Set(player, input, value);
}
extern "C" bool delta_play_state(const char *path, bool load) {
    if(!vm || !booted) return false;
    bool running = vm->GetStatus() == CVirtualMachine::RUNNING;
    vm->Pause();
    bool result = load ? vm->LoadState(fs::path(path)).get() : vm->SaveState(fs::path(path)).get();
    if(running) vm->Resume();
    if(!result) lastError = load ? "Play! could not load the save state." : "Play! could not save the state.";
    return result;
}
extern "C" const char *delta_play_error() { return lastError.c_str(); }

extern "C" bool delta_play_probe_jit(char *message, unsigned capacity) {
    try {
        // ARM64 mov w0,#42; ret. Validate permissions without executing a probe
        // that tvOS could terminate with an uncatchable code-signing exception.
        const uint32_t instructions[] = {0x52800540, 0xd65f03c0};
        CMemoryFunction block(instructions, sizeof(instructions));
        block.BeginModify();
        block.EndModify();
        if(message && capacity) message[0] = 0;
        return true;
    } catch(const std::exception &error) {
        if(message && capacity) std::snprintf(message, capacity, "%s", error.what());
        return false;
    }
}
