#pragma once
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Callbacks execute on Play!'s GS/audio threads. The frontend owns their lifetime.
typedef struct {
    void (*prepare_video)(void *);
    void (*present_video)(void *);
    void (*write_audio)(void *, const int16_t *, unsigned);
    void *context;
} DeltaPlayCallbacks;
bool delta_play_start(const char *disc, const char *storage, DeltaPlayCallbacks);
void delta_play_stop(void);
void delta_play_pause(void);
bool delta_play_running(void);
void delta_play_resume(void);
void delta_play_input(unsigned player, unsigned input, float value);
bool delta_play_state(const char *path, bool load);
const char *delta_play_error(void);
// Check the actual generated-code allocator and patch transitions.
bool delta_play_probe_jit(char *message, unsigned capacity);
#ifdef __cplusplus
}
#endif
