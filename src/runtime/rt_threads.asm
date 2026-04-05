; rt_threads.asm — threads.sl compatibility wrappers + helper stubs
;
; TacVm13 uses polling interrupts (blocking MMIO read), so true preemptive
; context-switching is not possible.  Real cooperative context switching is
; implemented in rt_ctx.asm.  These wrappers adapt the threads.sl API to it.

; rtSetupInterrupts() — identical to initTimer
rtSetupInterrupts:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     [1000216], #1       ; SimplePic QueueInterrupts = 1
    mov     [1000212], #1       ; SimplePic InterruptsAllowed = 1
    mov     r1, #0
rtSetupInterrupts_exit:
    add     sp, sp, #0
    pop     fp
    ret

; rtInitThreading() — initialise context-switching state (delegates to ctxInit)
rtInitThreading:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    call    ctxInit
    mov     r1, #0
rtInitThreading_exit:
    add     sp, sp, #0
    pop     fp
    ret

; rtCreateThread(int func_addr) — create thread with no argument (arg = 0)
rtCreateThread:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, [fp + 8]        ; func_addr
    mov     r3, #0              ; arg = 0 (push #imm not supported)
    push    r3
    push    r2                  ; func_addr
    call    ctxCreate
    add     sp, sp, #8
    mov     r1, #0
rtCreateThread_exit:
    add     sp, sp, #0
    pop     fp
    ret

; rtExitThread() — mark current thread done, return to scheduler
rtExitThread:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    call    ctxExit            ; does not return
    mov     r1, #0
rtExitThread_exit:
    add     sp, sp, #0
    pop     fp
    ret

; taskBody — label alias required by funcAddr(taskBody) in C code.
; The compiler emits `mov r1, taskBody` but generates the function as
; `global_taskBody_1_int`.  This stub bridges the name.
taskBody:
    jmp     global_taskBody_1_int

; rtWriteInt(int value) — write a single digit via SimplePipe (pipeOut analog)
rtWriteInt:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, [fp + 8]        ; value
    add     r2, r2, #48         ; + '0'
    push    r2
    call    pipeOut
    add     sp, sp, #4
    mov     r1, #0
rtWriteInt_exit:
    add     sp, sp, #0
    pop     fp
    ret
