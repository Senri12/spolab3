; pipeOut(x) -> blocking send to SimplePipe SyncSend register.
; SimplePipe control base in devices.xml: 1000032
;   +0 = SyncSend
pipeOut:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, [fp + 8]
    mov     r3, #1000032
    mov     [r3 + 0], r2
    mov     r1, #0
pipeOut_exit:
    add     sp, sp, #0
    pop     fp
    ret
