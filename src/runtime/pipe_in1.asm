; pipeIn1() -> blocking receive from task2_v71 Input1 SimplePipe.
; control base: 200704, SyncReceive register = base + 8
pipeIn1:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r3, #200712
    mov     r1, [r3 + 0]
pipeIn1_exit:
    add     sp, sp, #0
    pop     fp
    ret

; pipeIn1_next12() -> read from 200716 (offset 12), call ONLY after pipeIn1()
pipeIn1_next12:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r3, #200716
    mov     r1, [r3 + 0]
pipeIn1_next12_exit:
    add     sp, sp, #0
    pop     fp
    ret

; pipeIn1_next16() -> read from 200720 (offset 16), call ONLY after pipeIn1()
pipeIn1_next16:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r3, #200720
    mov     r1, [r3 + 0]
pipeIn1_next16_exit:
    add     sp, sp, #0
    pop     fp
    ret

; pipeIn1_next20() -> read from 200724 (offset 20), call ONLY after pipeIn1()
pipeIn1_next20:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r3, #200724
    mov     r1, [r3 + 0]
pipeIn1_next20_exit:
    add     sp, sp, #0
    pop     fp
    ret

; inboxSync() -> int
; blocking read from Input1 inbox base address (200960 = 0x31100)
; like pipeIn1() but via inbox channel — may trigger bulk fill
inboxSync:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r3, #200960
    mov     r1, [r3 + 0]
inboxSync_exit:
    add     sp, sp, #0
    pop     fp
    ret

; inboxRead(int byteOffset) -> int
; reads int32 from Input1 inbox buffer at 200960 (0x31100) + byteOffset
inboxRead:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, [fp + 8]
    mov     r3, #200960
    add     r3, r3, r2
    mov     r1, [r3 + 0]
inboxRead_exit:
    add     sp, sp, #0
    pop     fp
    ret

; pipeIn1_next24() -> read from 200728 (offset 24), call ONLY after pipeIn1()
pipeIn1_next24:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r3, #200728
    mov     r1, [r3 + 0]
pipeIn1_next24_exit:
    add     sp, sp, #0
    pop     fp
    ret

; getArrayAddr1(int[] arr) -> int
; returns the RAM address of the array (pointer value)
getArrayAddr1:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r1, [fp + 8]
getArrayAddr1_exit:
    add     sp, sp, #0
    pop     fp
    ret

; pipeIn1_off0() -> read from Input1 base+0 (blocking?)
pipeIn1_off0:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r3, #200704
    mov     r1, [r3 + 0]
pipeIn1_off0_exit:
    add     sp, sp, #0
    pop     fp
    ret

; pipeIn1_off4() -> read from Input1 base+4 (blocking?)
pipeIn1_off4:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r3, #200708
    mov     r1, [r3 + 0]
pipeIn1_off4_exit:
    add     sp, sp, #0
    pop     fp
    ret

; pipeIn1_off12() -> read from Input1 base+12
pipeIn1_off12:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r3, #200716
    mov     r1, [r3 + 0]
pipeIn1_off12_exit:
    add     sp, sp, #0
    pop     fp
    ret

; pipeIn1_off16() -> read from Input1 base+16
pipeIn1_off16:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r3, #200720
    mov     r1, [r3 + 0]
pipeIn1_off16_exit:
    add     sp, sp, #0
    pop     fp
    ret

; pipeIn1_off20() -> read from Input1 base+20
pipeIn1_off20:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r3, #200724
    mov     r1, [r3 + 0]
pipeIn1_off20_exit:
    add     sp, sp, #0
    pop     fp
    ret

; pipeIn1_off24() -> read from Input1 base+24
pipeIn1_off24:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r3, #200728
    mov     r1, [r3 + 0]
pipeIn1_off24_exit:
    add     sp, sp, #0
    pop     fp
    ret

; tightRead4(int out[4]) -> reads offsets 8,12,16,20 back-to-back into array
; minimal instructions between reads to test if device pre-fills buffer
tightRead4:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r5, [fp + 8]        ; r5 = out[] base address
    mov     r3, #200712
    mov     r1, [r3 + 0]        ; read offset 8 (blocking SyncReceive)
    mov     [r5 + 0], r1
    mov     r1, [r3 + 4]        ; read offset 12 immediately
    mov     [r5 + 4], r1
    mov     r1, [r3 + 8]        ; read offset 16
    mov     [r5 + 8], r1
    mov     r1, [r3 + 12]       ; read offset 20
    mov     [r5 + 12], r1
    mov     r1, #0
tightRead4_exit:
    add     sp, sp, #0
    pop     fp
    ret

; ctrlRead1(int offset) -> int
; non-blocking read of int32 from Input1 control base (200704) + offset
ctrlRead1:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, [fp + 8]
    mov     r3, #200704
    add     r3, r3, r2
    mov     r1, [r3 + 0]
ctrlRead1_exit:
    add     sp, sp, #0
    pop     fp
    ret

; ctrlWrite1(int offset, int value)
; write int32 to Input1 control base (200704) + offset
ctrlWrite1:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, [fp + 8]
    mov     r4, [fp + 12]
    mov     r3, #200704
    add     r3, r3, r2
    mov     [r3 + 0], r4
    mov     r1, #0
ctrlWrite1_exit:
    add     sp, sp, #0
    pop     fp
    ret
