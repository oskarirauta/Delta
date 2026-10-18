// Exercise production CodeGen, including tvOS returning success without execute permission.
#include <mach/mach.h>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <initializer_list>
#include "MemoryFunction.h"

extern "C" kern_return_t RealVMProtect(vm_map_t, vm_address_t, vm_size_t, boolean_t, vm_prot_t) asm("_vm_protect");
static int failureMode = 0;
extern "C" kern_return_t PlayTestVMProtect(vm_map_t task, vm_address_t address, vm_size_t size, boolean_t maximum, vm_prot_t protection) {
    if(failureMode == 1) return KERN_PROTECTION_FAILURE;
    if(failureMode == 2) protection &= ~VM_PROT_EXECUTE;
    return RealVMProtect(task, address, size, maximum, protection);
}
static void require(bool condition, const char *message) {
    if(!condition) throw std::runtime_error(message);
}
int main() {
    try {
        const uint32 instructions[] = {0x52800541, 0xb9000001, 0xd65f03c0}; // *context = 42; return
        CMemoryFunction block(instructions, sizeof(instructions));
        int value = 0; block(&value); require(value == 42, "Generated instructions did not run");
        block.BeginModify();
        const uint32 changed = 0x52800561; // *context = 43
        std::memcpy(block.GetCode(), &changed, sizeof(changed));
        block.EndModify(); block(&value); require(value == 43, "Patched instructions did not run");
        auto copy = block.CreateInstance(); value = 0; copy(&value); require(value == 43, "Copied code did not run");
        for(int mode : {1, 2}) {
            failureMode = mode;
            bool rejected = false;
            try { CMemoryFunction denied(instructions, sizeof(instructions)); }
            catch(const std::runtime_error &error) { rejected = true; std::printf("EXPECTED: %s\n", error.what()); }
            require(rejected, "Denied code was accepted");
        }
        failureMode = 1;
        bool patchDenied = false;
        try { block.BeginModify(); } catch(const std::runtime_error &) { patchDenied = true; }
        require(patchDenied, "Denied patch was accepted");
        failureMode = 0; block.BeginModify(); failureMode = 2;
        patchDenied = false;
        try { block.EndModify(); } catch(const std::runtime_error &) { patchDenied = true; }
        require(patchDenied, "Patch without executable permission was accepted");
        failureMode = 0;
        std::puts("ALL JIT MEMORY TESTS PASSED");
        return 0;
    } catch(const std::exception &error) {
        std::fprintf(stderr, "FAIL: %s\n", error.what());
        return 1;
    }
}
