; pipeIn0() -> blocking receive from task2_v71 Input0 SimplePipe.
; control base: 196608, SyncReceive register = base + 8
pipeIn0:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r3, #196616
    mov     r1, [r3 + 0]
pipeIn0_exit:
    add     sp, sp, #0
    pop     fp
    ret
