; pipeIn() -> blocking receive from SimplePipe SyncReceive register.
; SimplePipe control base in devices.xml: 1000032
;   +8 = SyncReceive
pipeIn:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r3, #1000040
    mov     r1, [r3 + 0]
pipeIn_exit:
    add     sp, sp, #0
    pop     fp
    ret
