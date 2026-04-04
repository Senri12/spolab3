; initTimer() — enable SimplePic + SimpleClock for blocking-poll scheduling
; No args, returns 0.
; SimplePic MMIO (base 1000200):
;   +16 = QueueInterrupts  (1000216)
;   +12 = InterruptsAllowed(1000212)
initTimer:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     [1000216], #1
    mov     [1000212], #1
    mov     r1, #0
initTimer_exit:
    add     sp, sp, #0
    pop     fp
    ret

; waitForTick() — block until next SimpleClock tick, return 1.
; Re-enables InterruptsAllowed before blocking (device resets it after each tick).
; SimplePic MMIO:
;   +12 = InterruptsAllowed (1000212)
;   +40 = NextInterrupt     (1000240) — Blocking In Register
waitForTick:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     [1000212], #1
    mov     r1, [1000240]
waitForTick_exit:
    add     sp, sp, #0
    pop     fp
    ret
