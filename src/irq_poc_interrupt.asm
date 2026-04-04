[section ram, code]

; PIC-state scan: snapshot 12 words at 1000200..1000244,
; then poll until any word changes. Store changed-offset+1 to [200000].
; Uses [reg + 0] addressing (mov_rm / mov_mr).

start:
    mov     sp, #1040000
    mov     fp, sp

    ; --- snapshot PIC state (12 × 4 bytes) into [201000..201044] ---
    mov     r6, #1000200
    mov     r7, #201000
snap_loop:
    mov     r3, [r6 + 0]
    mov     [r7 + 0], r3
    add     r6, r6, #4
    add     r7, r7, #4
    cmp     r6, #1000248
    blt     snap_loop

    ; --- enable interrupts ---
    mov     [1000212], #1       ; InterruptsAllowed = 1
    mov     [1000216], #1       ; QueueInterrupts   = 1

    ; --- poll loop with countdown ---
    mov     r5, #10000000

outer_loop:
    sub     r5, r5, #1
    cmp     r5, #0
    beq     timeout

    mov     r6, #1000200
    mov     r7, #201000

check_loop:
    mov     r3, [r6 + 0]
    mov     r8, [r7 + 0]
    cmp     r3, r8
    bne     found

    add     r6, r6, #4
    add     r7, r7, #4
    cmp     r6, #1000248
    blt     check_loop
    jmp     outer_loop

found:
    ; r6 = address of changed field; offset = r6 - 1000200
    mov     r0, #1000200
    sub     r0, r6, r0
    add     r0, r0, #1          ; +1 so result is always > 0
    mov     [200000], r0
    halt

timeout:
    mov     [200000], #0        ; no change seen
    halt
