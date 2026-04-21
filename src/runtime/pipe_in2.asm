; pipeIn2() -> blocking receive from task2_v71 Input2 SimplePipe.
; control base: 204800, SyncReceive register = base + 8
pipeIn2:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r3, #204808
    mov     r1, [r3 + 0]
pipeIn2_exit:
    add     sp, sp, #0
    pop     fp
    ret
