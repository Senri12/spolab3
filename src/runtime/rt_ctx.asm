; rt_ctx.asm — cooperative context switching for TacVm13
;
; Design: each thread's TCB stores only saved_sp.
; All register values live on the thread's own stack in a "yield-frame".
;
; Yield-frame layout (push r1..r28 then fp; pop fp then r28..r1):
;   [sp+  0] = fp
;   [sp+  4] = r28
;   [sp+  8] = r27
;   ...
;   [sp+112] = r1
;   [sp+116] = return_addr  (pushed by `call ctxYield` / `call ctxDispatch`)
;
; Memory layout:
;   SCHED_STATE = 500000
;     +0  current_thread_idx  (0 = scheduler)
;     +4  thread_count        (task threads 1..N)
;
;   TCB_ARRAY   = 502000, TCB_SIZE = 8
;     TCB[i] at 502000 + i*8
;     +0  saved_sp
;     +4  status (0=free, 1=ready, 2=running, 3=done)
;
;   STACKS = 600000, STACK_SIZE = 2048 per thread
;     Thread i stack top = 600000 + (i+1)*2048
;
; Initial stack for a newly-created thread i (set up by ctxCreate):
;   [top- 4] = arg           ← taskBody argument, at [fp+8] after prologue
;   [top- 8] = 0             ← sentinel return address (taskBody must not return)
;   [top-12] = func_addr     ← ret in ctxDispatch jumps here (taskBody entry)
;   [top-16..top-128] = 0    ← yield-frame slots (r1..r28, fp)
;   sp_initial = top - 128   ← TCB[i].saved_sp


; ──────────────────────────────────────────────────────────────────
; void ctxInit()
; Initialize scheduler state. Call once from main.
; ──────────────────────────────────────────────────────────────────
ctxInit:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r1, #500000
    mov     [r1 + 0], #0        ; current_thread = 0 (scheduler)
    mov     [r1 + 4], #0        ; thread_count = 0
    mov     r2, #502000         ; TCB[0] = scheduler
    mov     [r2 + 0], #0        ; saved_sp = 0 (filled when first ctxDispatch runs)
    mov     [r2 + 4], #2        ; status = running
    mov     r1, #0
ctxInit_exit:
    add     sp, sp, #0
    pop     fp
    ret

; ──────────────────────────────────────────────────────────────────
; int ctxCurrentTask()
; Returns the current task index: current_thread_idx - 1.
; Task threads are 1-indexed, so thread 1 = task 0, thread 2 = task 1, etc.
; ──────────────────────────────────────────────────────────────────
ctxCurrentTask:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r1, #500000
    mov     r1, [r1 + 0]        ; current_thread_idx
    sub     r1, r1, #1          ; task_idx = thread_idx - 1
ctxCurrentTask_exit:
    add     sp, sp, #0
    pop     fp
    ret

; ──────────────────────────────────────────────────────────────────
; void ctxReset()
; Reset thread_count to 0 so the next ctxCreate starts at thread 1 again.
; Call before the second algorithm run.
; ──────────────────────────────────────────────────────────────────
ctxReset:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r1, #500000
    mov     [r1 + 4], #0        ; thread_count = 0
    mov     r1, #0
ctxReset_exit:
    add     sp, sp, #0
    pop     fp
    ret

; ──────────────────────────────────────────────────────────────────
; void ctxCreate(int func_addr, int arg)
; Create a new task thread.  Thread index = ++thread_count (1-based).
; arg is passed to the thread function as its first (and only) argument.
; ──────────────────────────────────────────────────────────────────
ctxCreate:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, [fp + 8]        ; func_addr
    mov     r3, [fp + 12]       ; arg

    ; Allocate thread slot: idx = thread_count + 1
    mov     r4, #500000
    mov     r5, [r4 + 4]        ; r5 = thread_count
    add     r5, r5, #1          ; new thread index
    mov     [r4 + 4], r5        ; update thread_count

    ; TCB[r5] at 502000 + r5*8
    mov     r6, #8
    mul     r6, r5, r6
    add     r6, r6, #502000     ; r6 = &TCB[r5]

    ; Stack top for thread r5: 600000 + r5*2048
    mov     r7, #2048
    mul     r7, r5, r7
    add     r7, r7, #600000     ; r7 = stack_top

    ; Write arg at [top-4]
    sub     r8, r7, #4
    mov     [r8 + 0], r3

    ; Write sentinel return address (0) at [top-8]
    sub     r8, r7, #8
    mov     [r8 + 0], #0

    ; Write func_addr at [top-12]  — ret in ctxDispatch jumps here
    sub     r8, r7, #12
    mov     [r8 + 0], r2

    ; Zero r1..r28 and fp slots: [top-16] down to [top-128] inclusive (29 words)
    sub     r9, r7, #16         ; start (r1 slot = sp_initial+112 = top-16)
    sub     r10, r7, #132       ; exclusive lower bound
ctxCreate_zloop:
    cmp     r9, r10
    ble     ctxCreate_zdone
    mov     [r9 + 0], #0
    sub     r9, r9, #4
    jmp     ctxCreate_zloop
ctxCreate_zdone:

    ; Set TCB
    sub     r8, r7, #128        ; sp_initial = top - 128
    mov     [r6 + 0], r8        ; TCB[r5].saved_sp = sp_initial
    mov     [r6 + 4], #1        ; TCB[r5].status   = READY

    mov     r1, #0
ctxCreate_exit:
    add     sp, sp, #0
    pop     fp
    ret

; ──────────────────────────────────────────────────────────────────
; void ctxDispatch(int to_idx)
; Scheduler → task thread.  Saves scheduler context, restores task context.
; Blocks until the task calls ctxYield (or ctxExit).
;
; Calling convention: caller does `push to_idx; call ctxDispatch`.
; After yield-frame is pushed, to_idx is at [sp+120].
; ──────────────────────────────────────────────────────────────────
ctxDispatch:
    ; Push yield-frame (no normal prologue)
    push    r1
    push    r2
    push    r3
    push    r4
    push    r5
    push    r6
    push    r7
    push    r8
    push    r9
    push    r10
    push    r11
    push    r12
    push    r13
    push    r14
    push    r15
    push    r16
    push    r17
    push    r18
    push    r19
    push    r20
    push    r21
    push    r22
    push    r23
    push    r24
    push    r25
    push    r26
    push    r27
    push    r28
    push    fp
    ; Stack: [sp+0]=fp [sp+4]=r28 ... [sp+112]=r1 [sp+116]=ret_addr [sp+120]=to_idx

    ; Save scheduler sp → TCB[0]
    mov     r1, #502000
    mov     [r1 + 0], sp
    mov     [r1 + 4], #2        ; TCB[0].status = running (scheduler is running)

    ; Read to_idx (still on stack before sp switch)
    mov     r2, [sp + 120]      ; to_idx

    ; Compute TCB[to_idx]: 502000 + to_idx*8
    mov     r3, #8
    mul     r3, r2, r3
    add     r3, r3, #502000     ; r3 = &TCB[to_idx]

    ; Update current thread
    mov     r4, #500000
    mov     [r4 + 0], r2        ; current_thread = to_idx
    mov     [r3 + 4], #2        ; task status = RUNNING

    ; Switch to task stack
    mov     sp, [r3 + 0]        ; sp = task's saved_sp

    ; Restore task's context
    pop     fp
    pop     r28
    pop     r27
    pop     r26
    pop     r25
    pop     r24
    pop     r23
    pop     r22
    pop     r21
    pop     r20
    pop     r19
    pop     r18
    pop     r17
    pop     r16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     r7
    pop     r6
    pop     r5
    pop     r4
    pop     r3
    pop     r2
    pop     r1
    ret     ; → task's saved PC (taskBody on first dispatch, or inside ctxYield on subsequent)

; ──────────────────────────────────────────────────────────────────
; void ctxYield()
; Task thread → scheduler.  Saves task context, restores scheduler context.
; Blocks until the scheduler calls ctxDispatch for this thread again.
; ──────────────────────────────────────────────────────────────────
ctxYield:
    ; Push yield-frame
    push    r1
    push    r2
    push    r3
    push    r4
    push    r5
    push    r6
    push    r7
    push    r8
    push    r9
    push    r10
    push    r11
    push    r12
    push    r13
    push    r14
    push    r15
    push    r16
    push    r17
    push    r18
    push    r19
    push    r20
    push    r21
    push    r22
    push    r23
    push    r24
    push    r25
    push    r26
    push    r27
    push    r28
    push    fp
    ; Stack: [sp+0]=fp ... [sp+112]=r1 [sp+116]=ret_addr

    ; Get current thread index (r1, r2 free — their values are on stack)
    mov     r1, #500000
    mov     r2, [r1 + 0]        ; current_thread_idx

    ; TCB[r2]
    mov     r3, #8
    mul     r3, r2, r3
    add     r3, r3, #502000

    ; Save task sp → TCB[r2]
    mov     [r3 + 0], sp
    mov     [r3 + 4], #1        ; status = READY

    ; Switch to scheduler stack (TCB[0])
    mov     r3, #502000
    mov     sp, [r3 + 0]

    ; Update current = 0 (r1 = 500000 still valid)
    mov     [r1 + 0], #0

    ; Restore scheduler's context
    pop     fp
    pop     r28
    pop     r27
    pop     r26
    pop     r25
    pop     r24
    pop     r23
    pop     r22
    pop     r21
    pop     r20
    pop     r19
    pop     r18
    pop     r17
    pop     r16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     r7
    pop     r6
    pop     r5
    pop     r4
    pop     r3
    pop     r2
    pop     r1
    ret     ; → back inside ctxDispatch in the scheduler

; ──────────────────────────────────────────────────────────────────
; void ctxBlock(int reason)
; Task calls this to passively wait for an event identified by `reason`.
; Sets TCB[current].status = BLOCKED (4) and writes `reason` into a
; parallel array WAIT_REASON_BASE = 503000 (4 bytes per thread).
; The thread is woken later by a ctxWake call with the same reason.
;
; Calling convention: caller does `push reason; call ctxBlock`.
; After yield-frame is pushed, reason is at [sp+120].
; ──────────────────────────────────────────────────────────────────
ctxBlock:
    push    r1
    push    r2
    push    r3
    push    r4
    push    r5
    push    r6
    push    r7
    push    r8
    push    r9
    push    r10
    push    r11
    push    r12
    push    r13
    push    r14
    push    r15
    push    r16
    push    r17
    push    r18
    push    r19
    push    r20
    push    r21
    push    r22
    push    r23
    push    r24
    push    r25
    push    r26
    push    r27
    push    r28
    push    fp
    ; Stack: [sp+0]=fp ... [sp+112]=r1 [sp+116]=ret_addr [sp+120]=reason

    mov     r1, #500000
    mov     r2, [r1 + 0]        ; current_thread_idx

    ; TCB[r2] at 502000 + r2*8
    mov     r3, #8
    mul     r3, r2, r3
    add     r3, r3, #502000

    ; Save sp, mark BLOCKED (4)
    mov     [r3 + 0], sp
    mov     [r3 + 4], #4

    ; Save reason into WAIT_REASON_BASE + r2*4 (= 503000 + r2*4)
    mov     r4, [sp + 120]      ; reason argument
    mov     r5, #4
    mul     r5, r2, r5
    add     r5, r5, #503000
    mov     [r5 + 0], r4

    ; Switch to scheduler stack (TCB[0])
    mov     r3, #502000
    mov     sp, [r3 + 0]
    mov     [r1 + 0], #0        ; current = 0

    ; Restore scheduler context
    pop     fp
    pop     r28
    pop     r27
    pop     r26
    pop     r25
    pop     r24
    pop     r23
    pop     r22
    pop     r21
    pop     r20
    pop     r19
    pop     r18
    pop     r17
    pop     r16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     r7
    pop     r6
    pop     r5
    pop     r4
    pop     r3
    pop     r2
    pop     r1
    ret     ; → back inside ctxDispatch

; ──────────────────────────────────────────────────────────────────
; void ctxWake(int reason)
; Iterate every task TCB (1..thread_count) and move any thread whose
; status is BLOCKED (4) and wait_reason equals `reason` back to READY (1).
; Wait reason slot is cleared.  Does not switch stacks — pure book-keeping.
; ──────────────────────────────────────────────────────────────────
ctxWake:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, [fp + 8]        ; reason

    mov     r3, #500000
    mov     r4, [r3 + 4]        ; thread_count
    mov     r5, #1              ; i = 1
ctxWake_loop:
    cmp     r5, r4
    bgt     ctxWake_done

    ; TCB[i] at 502000 + i*8
    mov     r6, #8
    mul     r6, r5, r6
    add     r6, r6, #502000
    mov     r7, [r6 + 4]        ; status
    cmp     r7, #4
    bne     ctxWake_next        ; not BLOCKED

    ; reason slot = 503000 + i*4
    mov     r8, #4
    mul     r8, r5, r8
    add     r8, r8, #503000
    mov     r9, [r8 + 0]
    cmp     r9, r2
    bne     ctxWake_next

    ; Wake: status = READY (1), wait_reason = 0
    mov     [r6 + 4], #1
    mov     [r8 + 0], #0

ctxWake_next:
    add     r5, r5, #1
    jmp     ctxWake_loop
ctxWake_done:
    mov     r1, #0
    add     sp, sp, #0
    pop     fp
    ret

; ──────────────────────────────────────────────────────────────────
; int ctxIsBlocked(int idx)
; Returns 1 if TCB[idx].status == BLOCKED (4), 0 otherwise.
; ──────────────────────────────────────────────────────────────────
ctxIsBlocked:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, [fp + 8]        ; idx

    mov     r3, #8
    mul     r3, r2, r3
    add     r3, r3, #502000
    mov     r4, [r3 + 4]        ; status
    cmp     r4, #4
    bne     ctxIsBlocked_no
    mov     r1, #1
    jmp     ctxIsBlocked_exit
ctxIsBlocked_no:
    mov     r1, #0
ctxIsBlocked_exit:
    add     sp, sp, #0
    pop     fp
    ret

; ──────────────────────────────────────────────────────────────────
; void ctxExit()
; Task calls this when done.  Marks thread DONE, switches to scheduler.
; Does not return to the caller.
; ──────────────────────────────────────────────────────────────────
ctxExit:
    ; No need to save task context — we're done
    mov     r1, #500000
    mov     r2, [r1 + 0]        ; current thread idx

    ; TCB[r2].status = DONE
    mov     r3, #8
    mul     r3, r2, r3
    add     r3, r3, #502000
    mov     [r3 + 4], #3

    ; current = 0
    mov     [r1 + 0], #0

    ; Switch to scheduler stack
    mov     r3, #502000
    mov     sp, [r3 + 0]

    ; Restore scheduler
    pop     fp
    pop     r28
    pop     r27
    pop     r26
    pop     r25
    pop     r24
    pop     r23
    pop     r22
    pop     r21
    pop     r20
    pop     r19
    pop     r18
    pop     r17
    pop     r16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     r7
    pop     r6
    pop     r5
    pop     r4
    pop     r3
    pop     r2
    pop     r1
    ret     ; → back inside ctxDispatch
