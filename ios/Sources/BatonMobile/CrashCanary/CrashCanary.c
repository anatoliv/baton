#include "CrashCanary.h"

#include <stdint.h>

__attribute__((noinline, optnone, noreturn))
void baton_ios_trigger_test_crash(void) {
    volatile uint8_t *invalid_address = (volatile uint8_t *)(uintptr_t)1;
    *invalid_address = 0x42;
    __builtin_trap();
}
