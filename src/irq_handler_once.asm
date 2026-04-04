[section ram, code]

start:
    mov     sp, #1040000
    mov     fp, sp
    mov     [200000], #0

    mov     [1000300], irq_handler
    mov     [1000304], #0
    mov     [1000216], #1
    mov     [1000212], #1

    mov     r2, #5000000
spin:
    sub     r2, r2, #1
    bgt     spin
    ; timeout — [200000] still 0, no dispatch happened
    halt

irq_handler:
    mov     [200000], #1
    halt
