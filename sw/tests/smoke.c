// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>

volatile uint32_t smoke_limit = 10;
volatile uint32_t smoke_result;

int main(void)
{
    uint32_t sum = 0;

    __asm__ volatile (".word 0x00102013" ::: "memory");
    __asm__ volatile (".word 0x00302013" ::: "memory");

    for (uint32_t value = 1; value <= smoke_limit; value++) {
        sum += value;
    }

    smoke_result = sum;

    __asm__ volatile (".word 0x00402013" ::: "memory");
    __asm__ volatile (".word 0x00202013" ::: "memory");
    return 0;
}
