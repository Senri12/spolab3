[section ram, code]

start:
    mov     sp, #1040000
    mov     fp, sp
    mov     [200000], #0

    mov     [1000216], #1

probe_wait:
    mov     r1, [1000240]
    mov     r2, [200000]
    add     r2, r2, #1
    mov     [200000], r2
    cmp     r2, #5
    blt     probe_wait
    halt
