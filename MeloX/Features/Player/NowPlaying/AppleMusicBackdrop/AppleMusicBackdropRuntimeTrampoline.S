#if defined(__arm64__)

.text
.p2align 2
.globl _MeloXCreateMediaCoreBackdropHost
_MeloXCreateMediaCoreBackdropHost:
    pacibsp
    stp x20, x30, [sp, #-16]!
    mov x16, x0
    mov x20, x1
    mov x0, x2
    mov w1, w3
    blr x16
    ldp x20, x30, [sp], #16
    retab

#elif defined(__x86_64__)

.text
.globl _MeloXCreateMediaCoreBackdropHost
_MeloXCreateMediaCoreBackdropHost:
    xorq %rax, %rax
    retq

#endif
