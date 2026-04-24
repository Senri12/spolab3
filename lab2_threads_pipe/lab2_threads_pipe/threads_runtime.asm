; Preemptive threads runtime for StackVMCore + devices.
; Uses SimpleClock + SimplePic for preemptive scheduling.
;
; ISR does FULL context switch: saves current thread SP/RP/PC,
; picks next thread round-robin, restores its SP/RP/PC.
;
; PIC does JMP (not CALL) to handler — no return address pushed.
; ISR uses private operand stack (SP=900) to avoid corrupting threads.
;
; New PDSL instructions: getsp(0x57), setsp(0x58), getrp(0x59), setrp(0x5A)
;
; Device memory map (DATA bank):
;   SimplePic  state:        0x2A000
;     +0x00: IIA (8 bytes)
;     +0x0C: InterruptsAllowed (4 bytes)
;     +0x10: QueueInterrupts (4 bytes)
;     +0x14: InterruptHappened (4 bytes)
;   SimplePic  handlers-map: 0x2A100
;   SimpleClock state:       0x2B000
;   SimplePipe  control:     0x2C000
;
; TCB layout (base 0x28000, max 8 threads, 40 bytes each):
;   +0:  state (0=free, 1=ready, 2=running, 3=done)
;   +8:  saved_PC
;   +16: saved_SP
;   +24: saved_RP
;   +32: func_addr (entry point)
;
; Metadata (base 0x28200):
;   +0:  thread_count
;   +8:  current_thread (index, 99=none)

[section name=_code, bank=CODE, start=0x0]

; ============================================================
; ISR — preemptive context switch handler
; PIC does JMP here. We save everything and switch threads.
; ============================================================

rtContextSwitchHandler:
    ; 1. Save interrupted thread's SP to variable
    ;    getsp pushes SP onto operand stack at slot[SP], SP++
    ;    stv pops it into variable. Net SP change = 0.
    ;    The slot[SP_orig] is "free" (above stack top), so no data lost.
    getsp
    stv     var_isr_saved_sp

    ; 2. Switch to ISR-private operand stack
    ldc     crt_isr_sp          ; 900
    setsp

    ; 3. Save interrupted thread's RP (PIC didn't change it)
    getrp
    stv     var_isr_saved_rp

    ; 4. Read IIA (interrupted PC) from PIC
    ldc     crt_pic_iia
    dload
    stv     var_isr_saved_pc

    ; 5. Clear InterruptHappened
    ldc     crt_pic_happened
    ldc     crt_0
    dstore

    ; 6. Load current_thread index
    ldc     crt_meta_current
    dload
    stv     var_isr_cur

    ; 7. If current == 99 (no thread), skip save
    ldv     var_isr_cur
    ldc     crt_99
    eq
    jnz     _isr_skip_save

    ; 8. Save context to TCB
    ;    TCB base = 0x28000 + cur * 40
    ldv     var_isr_cur
    ldc     crt_40
    mul
    ldc     crt_tcb_base
    add
    stv     var_isr_tcb_addr

    ; saved_PC = IIA
    ldv     var_isr_tcb_addr
    ldc     crt_8
    add
    ldv     var_isr_saved_pc
    dstore

    ; saved_SP
    ldv     var_isr_tcb_addr
    ldc     crt_16
    add
    ldv     var_isr_saved_sp
    dstore

    ; saved_RP
    ldv     var_isr_tcb_addr
    ldc     crt_24
    add
    ldv     var_isr_saved_rp
    dstore

    ; state = READY (1)
    ldv     var_isr_tcb_addr
    ldc     crt_1
    dstore

_isr_skip_save:
    ; --- Pick next thread (round-robin) ---
    ldc     crt_meta_count
    dload
    stv     var_isr_count

    ; next = (current + 1) % count
    ldv     var_isr_cur
    ldc     crt_1
    add
    stv     var_isr_next

    ; Wrap
    ldv     var_isr_next
    ldv     var_isr_count
    ge
    jz      _isr_no_wrap
    ldc     crt_0
    stv     var_isr_next
_isr_no_wrap:

    ; Search for a non-DONE thread
    ldc     crt_0
    stv     var_isr_tries

_isr_find_loop:
    ldv     var_isr_tries
    ldv     var_isr_count
    ge
    jnz     _isr_no_thread

    ; Read state of candidate
    ldv     var_isr_next
    ldc     crt_40
    mul
    ldc     crt_tcb_base
    add
    dload
    stv     var_isr_state

    ; If DONE (3) or WAITING (4), skip
    ldv     var_isr_state
    ldc     crt_3
    eq
    jnz     _isr_try_next

    ldv     var_isr_state
    ldc     crt_4
    eq
    jnz     _isr_try_next

    ; Found a runnable thread (state 1=READY or 2=RUNNING)
    jmp     _isr_found

_isr_try_next:
    ldv     var_isr_next
    ldc     crt_1
    add
    stv     var_isr_next
    ldv     var_isr_next
    ldv     var_isr_count
    ge
    jz      _isr_try_no_wrap
    ldc     crt_0
    stv     var_isr_next
_isr_try_no_wrap:
    ldv     var_isr_tries
    ldc     crt_1
    add
    stv     var_isr_tries
    jmp     _isr_find_loop

_isr_no_thread:
    hlt

_isr_found:
    ; If next == current and current != 99, just return to same thread
    ldv     var_isr_next
    ldv     var_isr_cur
    eq
    jnz     _isr_return_same

    ; --- Switch to next thread ---
    ; Update current_thread = next
    ldc     crt_meta_current
    ldv     var_isr_next
    dstore

    ; Compute TCB base for next thread
    ldv     var_isr_next
    ldc     crt_40
    mul
    ldc     crt_tcb_base
    add
    stv     var_isr_tcb_addr

    ; Set state = RUNNING (2)
    ldv     var_isr_tcb_addr
    ldc     crt_2
    dstore

    ; Load saved_PC (0 = first start)
    ldv     var_isr_tcb_addr
    ldc     crt_8
    add
    dload
    stv     var_tmp_pc

    ldv     var_tmp_pc
    ldc     crt_0
    eq
    jz      _isr_restore_existing

    ; --- First start ---
    ; Load func_addr as PC
    ldv     var_isr_tcb_addr
    ldc     crt_32
    add
    dload
    stv     var_tmp_pc

    ; Load initial SP/RP from TCB
    ldv     var_isr_tcb_addr
    ldc     crt_16
    add
    dload
    stv     var_tmp_sp

    ldv     var_isr_tcb_addr
    ldc     crt_24
    add
    dload
    stv     var_tmp_rp

    ; Switch to thread's stacks
    ldv     var_tmp_sp
    setsp
    ldv     var_tmp_rp
    setrp

    ; Mark as started (saved_PC = nonzero)
    ldv     var_isr_tcb_addr
    ldc     crt_8
    add
    ldc     crt_1
    dstore

    ; Push func_addr onto return stack, then ret to jump there
    ldv     var_tmp_rp
    ldc     crt_8
    mul
    ldc     crt_ret_stack_base
    add
    ldv     var_tmp_pc
    dstore

    getrp
    ldc     crt_1
    add
    setrp

    ; Re-enable interrupts
    ldc     crt_pic_allowed
    ldc     crt_1
    dstore
    ldc     crt_pic_queue
    ldc     crt_1
    dstore

    ret                         ; → func_addr

_isr_restore_existing:
    ; Load saved SP/RP/PC
    ldv     var_isr_tcb_addr
    ldc     crt_16
    add
    dload
    stv     var_tmp_sp

    ldv     var_isr_tcb_addr
    ldc     crt_24
    add
    dload
    stv     var_tmp_rp

    ldv     var_isr_tcb_addr
    ldc     crt_8
    add
    dload
    stv     var_tmp_pc

    ; Switch to thread's stacks
    ldv     var_tmp_sp
    setsp
    ldv     var_tmp_rp
    setrp

    ; Push saved_PC onto return stack and ret to jump there
    getrp
    ldc     crt_8
    mul
    ldc     crt_ret_stack_base
    add
    ldv     var_tmp_pc
    dstore

    getrp
    ldc     crt_1
    add
    setrp

    ; Re-enable interrupts
    ldc     crt_pic_allowed
    ldc     crt_1
    dstore
    ldc     crt_pic_queue
    ldc     crt_1
    dstore

    ret                         ; → saved_PC (resume thread)

_isr_return_same:
    ; Same thread, just return to it via IIA
    ; Restore thread's SP and RP
    ldv     var_isr_saved_sp
    setsp
    ldv     var_isr_saved_rp
    setrp

    ; Push IIA onto return stack and ret
    getrp
    ldc     crt_8
    mul
    ldc     crt_ret_stack_base
    add
    ldv     var_isr_saved_pc
    dstore

    getrp
    ldc     crt_1
    add
    setrp

    ; Re-enable interrupts
    ldc     crt_pic_allowed
    ldc     crt_1
    dstore
    ldc     crt_pic_queue
    ldc     crt_1
    dstore

    ret                         ; → IIA (resume same thread)

; ============================================================
; rtCreateThread(func_addr) — register a new thread
; ============================================================

rtCreateThread_int:
    stv     var_rt_arg0

    ldc     crt_meta_count
    dload
    stv     var_rt_idx

    ; TCB base = 0x28000 + idx * 40
    ldv     var_rt_idx
    ldc     crt_40
    mul
    ldc     crt_tcb_base
    add
    stv     var_rt_tcb

    ; state = READY (1)
    ldv     var_rt_tcb
    ldc     crt_1
    dstore

    ; saved_PC = 0 (not started)
    ldv     var_rt_tcb
    ldc     crt_8
    add
    ldc     crt_0
    dstore

    ; saved_SP = idx * 100
    ldv     var_rt_tcb
    ldc     crt_16
    add
    ldv     var_rt_idx
    ldc     crt_100
    mul
    dstore

    ; saved_RP = idx * 100
    ldv     var_rt_tcb
    ldc     crt_24
    add
    ldv     var_rt_idx
    ldc     crt_100
    mul
    dstore

    ; func_addr
    ldv     var_rt_tcb
    ldc     crt_32
    add
    ldv     var_rt_arg0
    dstore

    ; thread_count++
    ldv     var_rt_idx
    ldc     crt_1
    add
    stv     var_rt_idx
    ldc     crt_meta_count
    ldv     var_rt_idx
    dstore

    ret

; ============================================================
; rtExitThread() — mark current thread as done, spin forever
; The next ISR will switch away from this thread.
; ============================================================

rtExitThread:
    ldc     crt_meta_current
    dload
    stv     var_rt_idx

    ; If current == 99 (main), go directly to yield skip_save
    ldv     var_rt_idx
    ldc     crt_99
    eq
    jnz     _exit_do_switch

    ; Set state = DONE (3)
    ldv     var_rt_idx
    ldc     crt_40
    mul
    ldc     crt_tcb_base
    add
    ldc     crt_3
    dstore

_exit_do_switch:
    ; Jump directly into yield's pick_next, skipping save.
    ; This way DONE state is NOT overwritten by yield's save.
    ; Set var_yield_cur for pick_next logic.
    ldc     crt_meta_current
    dload
    stv     var_yield_cur
    jmp     _yield_skip_save
    ; Note: _yield_skip_save → pick_next → found → switch to next thread.
    ; If no thread found → _yield_none → hlt.

; ============================================================
; rtYield — cooperative context switch
; Called via "call rtYield" from SL code.
; Saves current thread SP/RP, picks next READY thread,
; restores its SP/RP, returns into it.
; If no other thread is READY, returns immediately.
; ============================================================

rtYield:
    ; Capture SP and RP immediately (before any stack operations)
    getsp
    stv     var_yield_sp
    getrp
    stv     var_yield_rp

    ; Load current thread
    ldc     crt_meta_current
    dload
    stv     var_yield_cur

    ; If current == 99 (main before threads start), skip save
    ldv     var_yield_cur
    ldc     crt_99
    eq
    jnz     _yield_skip_save

    ; Compute TCB address
    ldv     var_yield_cur
    ldc     crt_40
    mul
    ldc     crt_tcb_base
    add
    stv     var_yield_tcb

    ; Write saved_SP to TCB
    ldv     var_yield_tcb
    ldc     crt_16
    add
    ldv     var_yield_sp
    dstore

    ; Write saved_RP to TCB
    ldv     var_yield_tcb
    ldc     crt_24
    add
    ldv     var_yield_rp
    dstore

    ; saved_PC = 1 (nonzero = already started)
    ldv     var_yield_tcb
    ldc     crt_8
    add
    ldc     crt_1
    dstore

    ; state = READY (so scheduler can pick this thread again)
    ldv     var_yield_tcb
    ldc     crt_1
    dstore

_yield_skip_save:
    ; Pick next READY thread (round-robin)
    ldc     crt_meta_count
    dload
    stv     var_yield_count

    ldv     var_yield_cur
    ldc     crt_1
    add
    stv     var_yield_next

    ldv     var_yield_next
    ldv     var_yield_count
    ge
    jz      _yield_no_wrap2
    ldc     crt_0
    stv     var_yield_next
_yield_no_wrap2:

    ldc     crt_0
    stv     var_yield_tries

_yield_find2:
    ldv     var_yield_tries
    ldv     var_yield_count
    ge
    jnz     _yield_none         ; no runnable thread, return

    ; Read state of candidate
    ldv     var_yield_next
    ldc     crt_40
    mul
    ldc     crt_tcb_base
    add
    dload
    stv     var_yield_state

    ; Skip DONE(3) and WAITING(4)
    ldv     var_yield_state
    ldc     crt_3
    eq
    jnz     _yield_try_next2

    ldv     var_yield_state
    ldc     crt_4
    eq
    jnz     _yield_try_next2

    ; Found runnable thread
    jmp     _yield_found2

_yield_try_next2:
    ldv     var_yield_next
    ldc     crt_1
    add
    stv     var_yield_next
    ldv     var_yield_next
    ldv     var_yield_count
    ge
    jz      _yield_try_no_wrap2
    ldc     crt_0
    stv     var_yield_next
_yield_try_no_wrap2:
    ldv     var_yield_tries
    ldc     crt_1
    add
    stv     var_yield_tries
    jmp     _yield_find2

_yield_none:
    ; No runnable threads left — halt VM cleanly
_yield_halt_loop:
    hlt
    jmp     _yield_halt_loop

_yield_found2:
    ; If same thread, just return
    ldv     var_yield_next
    ldv     var_yield_cur
    eq
    jnz     _yield_none

    ; Update current_thread = next
    ldc     crt_meta_current
    ldv     var_yield_next
    dstore

    ; Compute next thread TCB
    ldv     var_yield_next
    ldc     crt_40
    mul
    ldc     crt_tcb_base
    add
    stv     var_yield_tcb

    ; Set state = RUNNING
    ldv     var_yield_tcb
    ldc     crt_2
    dstore

    ; Check saved_PC: 0 = first start
    ldv     var_yield_tcb
    ldc     crt_8
    add
    dload
    stv     var_yield_pc

    ldv     var_yield_pc
    ldc     crt_0
    eq
    jz      _yield_restore2

    ; --- First start ---
    ldv     var_yield_tcb
    ldc     crt_32
    add
    dload
    stv     var_yield_pc        ; func_addr

    ldv     var_yield_tcb
    ldc     crt_16
    add
    dload
    stv     var_yield_sp

    ldv     var_yield_tcb
    ldc     crt_24
    add
    dload
    stv     var_yield_rp

    ; Mark started
    ldv     var_yield_tcb
    ldc     crt_8
    add
    ldc     crt_1
    dstore

    ; Switch stacks
    ldv     var_yield_sp
    setsp
    ldv     var_yield_rp
    setrp

    ; Push func_addr on return stack and ret
    ldv     var_yield_rp
    ldc     crt_8
    mul
    ldc     crt_ret_stack_base
    add
    ldv     var_yield_pc
    dstore

    getrp
    ldc     crt_1
    add
    setrp

    ret                         ; → func_addr

_yield_restore2:
    ; Restore existing thread
    ldv     var_yield_tcb
    ldc     crt_16
    add
    dload
    stv     var_yield_sp

    ldv     var_yield_tcb
    ldc     crt_24
    add
    dload
    stv     var_yield_rp

    ; Switch stacks
    ldv     var_yield_sp
    setsp
    ldv     var_yield_rp
    setrp

    ; ret unwinds through: rtYield → swPipeRead/Write → thread code
    ret

; ============================================================
; rtWriteInt(value) — print digit via SimplePipe
; No yield needed — ISR handles preemption.
; ============================================================

rtWriteInt_int:
    stv     var_rt_arg0

    ldc     crt_pipe_send
    ldv     var_rt_arg0
    ldc     crt_48              ; '0'
    add
    dstoreb

    ret

; ============================================================
; rtSetupInterrupts — configure PIC + Clock
; ============================================================

rtSetupInterrupts:
    ; Cooperative mode: no hardware interrupts.
    ; Context switch via rtYield called from pipe operations.
    ret

; ============================================================
; rtInitThreading — initialize metadata
; ============================================================

rtInitThreading:
    ldc     crt_meta_count
    ldc     crt_0
    dstore

    ldc     crt_meta_current
    ldc     crt_99
    dstore

    ; pipe_count = 0
    ldc     crt_meta_pipecount
    ldc     crt_0
    dstore

    ret

; ============================================================
; rtThreadSleep() — put current thread to WAITING state
; Called with interrupts enabled; disables them, sets state, spins.
; ISR will skip this thread. Another thread must wake it.
; ============================================================

rtThreadSleep:
    ; Disable interrupts
    ldc     crt_pic_allowed
    ldc     crt_0
    dstore

    ; Set current thread state = WAITING (4)
    ldc     crt_meta_current
    dload
    stv     var_rt_idx

    ldv     var_rt_idx
    ldc     crt_40
    mul
    ldc     crt_tcb_base
    add
    ldc     crt_4
    dstore

    ; Re-enable interrupts
    ldc     crt_pic_allowed
    ldc     crt_1
    dstore
    ldc     crt_pic_queue
    ldc     crt_1
    dstore

    ; Spin — ISR will preempt and skip us (state=WAITING)
    ; When woken (state set back to READY), ISR will schedule us again
    ; and we return from here
_sleep_spin:
    jmp     _sleep_spin

; ============================================================
; rtThreadWake(thread_id) — set thread state to READY
; ============================================================

rtThreadWake_int:
    ; thread_id on stack
    ; TCB[thread_id].state = READY (1)
    ldc     crt_40
    mul
    ldc     crt_tcb_base
    add
    ldc     crt_1
    dstore
    ret

; ============================================================
; rtLoad(addr) — load 8-byte value from DATA[addr]
; ============================================================

rtLoad_int:
    ; addr on stack → dload reads DATA[addr], pushes value
    dload
    ret

; ============================================================
; rtStore(addr, value) — store 8-byte value to DATA[addr]
; SL pushes addr first, value second → stack: [addr, value]
; dstore pops [addr, value] and writes DATA[addr] = value
; ============================================================

rtStore_int_int:
    dstore
    ret

; ============================================================
; rtDeviceReadByte(device_ctrl_addr) — read byte from SyncReceive
; SyncReceive is at device_ctrl_addr + 8
; Returns byte value (0-255) or -1 on EOF
; ============================================================

rtDeviceReadByte_int:
    ; device_ctrl_addr on stack
    ldc     crt_8
    add                         ; addr + 8 = SyncReceive
    dloadb                      ; read one byte
    ret

; ============================================================
; rtDeviceSendByte(device_ctrl_addr, byte) — write byte to SyncSend
; Stack: [device_ctrl_addr, byte]
; SyncSend is at device_ctrl_addr + 0
; Need to swap: dstoreb expects [addr, value]
; SL pushes addr first, byte second — already correct order!
; ============================================================

rtDeviceSendByte_int_int:
    dstoreb
    ret

; ============================================================
; NEW Pipe API — stack-only, no global variables
; Safe for cooperative multithreading.
;
; Layout: ctrl = 0x29000 + pid*32 (+0:head, +8:tail, +16:cap=33, +24:closed)
; Buffer: 0x29400 + pid*264 (33 slots * 8 bytes)
; Pipe count at 0x28218 = 164376
; ============================================================

; swPipeCreate() — allocate new pipe, returns pipe_id
; SL-called names: swPipeCreate, swPipeWrite_int_int, swPipeRead_int, swPipeClose_int
; Lock-free ring buffer: writer only touches tail, reader only touches head.
; No stv/ldv for pipe state — safe with cooperative yield.
; Uses stv/ldv only for pipe_id and value (saved before yield, restored after).

; --- swPipeCreate() → pipe_id ---
swPipeCreate:
    ; pid = DATA[meta_pipecount]
    ldc     crt_meta_pipecount
    dload                       ; stack: [pid]
    ; ctrl = pipe_ctrl_base + pid * 32
    ; Init ctrl: head=0, tail=0, cap=33, closed=0 (4 dstores = 32 bytes)
    ; We need pid on stack for later, so duplicate via stv/ldv
    stv     var_rt_arg0         ; save pid
    ldv     var_rt_arg0
    ldc     crt_32
    mul
    ldc     crt_pipe_ctrl_base
    add                         ; stack: [ctrl_addr]
    ; head=0, tail=0 → dstore(ctrl, 0) writes 8 bytes: head=0 AND tail=0
    stv     var_rt_tcb          ; save ctrl
    ; head = 0
    ldv     var_rt_tcb
    ldc     crt_0
    dstore
    ; tail = 0
    ldv     var_rt_tcb
    ldc     crt_8
    add
    ldc     crt_0
    dstore
    ; cap = 33
    ldv     var_rt_tcb
    ldc     crt_16
    add
    ldc     crt_pipe_cap
    dstore
    ; closed = 0
    ldv     var_rt_tcb
    ldc     crt_24
    add
    ldc     crt_0
    dstore
    ; pipe_count = pid + 1
    ldc     crt_meta_pipecount
    ldv     var_rt_arg0
    ldc     crt_1
    add
    dstore
    ; return pid
    ldv     var_rt_arg0
    ret

; --- swPipeWrite(pipe_id, value) ---
; Lock-free: only writes tail. If full, yields and retries.
swPipeWrite_int_int:
    stv     var_rt_arg1         ; value
    stv     var_rt_arg0         ; pipe_id

_sw_write_retry:
    ; ctrl = pipe_ctrl_base + pipe_id * 32
    ldv     var_rt_arg0
    ldc     crt_32
    mul
    ldc     crt_pipe_ctrl_base
    add                         ; stack: [ctrl]
    ; tail = DATA[ctrl+8]
    stv     var_rt_tcb
    ldv     var_rt_tcb
    ldc     crt_8
    add
    dload                       ; stack: [tail]
    stv     var_pipe_tail
    ; next_tail = tail + 1
    ldv     var_pipe_tail
    ldc     crt_1
    add                         ; stack: [next_tail]
    ; if next_tail >= 33 → next_tail = 0
    stv     var_pipe_head       ; reuse as next_tail temp
    ldv     var_pipe_head
    ldc     crt_pipe_cap
    ge
    jz      _sw_write_no_wrap
    ldc     crt_0
    stv     var_pipe_head
_sw_write_no_wrap:
    ; head = DATA[ctrl]
    ldv     var_rt_tcb
    dload                       ; stack: [head]
    ; if next_tail == head → pipe full, yield
    ldv     var_pipe_head       ; next_tail
    eq
    jnz     _sw_write_full
    ; Not full: write value to buffer
    ; buf_addr = pipe_data_base + pipe_id * 264 + tail * 8
    ldv     var_rt_arg0
    ldc     crt_264
    mul
    ldc     crt_pipe_data_base
    add
    ldv     var_pipe_tail
    ldc     crt_8
    mul
    add                         ; stack: [buf_slot_addr]
    ldv     var_rt_arg1         ; value
    dstore
    ; DATA[ctrl+8] = next_tail
    ldv     var_rt_tcb
    ldc     crt_8
    add
    ldv     var_pipe_head       ; next_tail
    dstore
    ret

_sw_write_full:
    ; Save pipe_id and value on operand stack (thread-local) before yield
    ldv     var_rt_arg0         ; pipe_id
    ldv     var_rt_arg1         ; value → stack: [..., pid, val]
    call    rtYield
    ; Restore after yield (stack preserved by yield)
    stv     var_rt_arg1         ; value
    stv     var_rt_arg0         ; pipe_id
    jmp     _sw_write_retry

; --- swPipeRead(pipe_id) → value ---
; Lock-free: only writes head. If empty, checks closed or yields.
swPipeRead_int:
    stv     var_rt_arg0         ; pipe_id

_sw_read_retry:
    ; ctrl = pipe_ctrl_base + pipe_id * 32
    ldv     var_rt_arg0
    ldc     crt_32
    mul
    ldc     crt_pipe_ctrl_base
    add                         ; stack: [ctrl]
    stv     var_rt_tcb
    ; head = DATA[ctrl]
    ldv     var_rt_tcb
    dload                       ; stack: [head]
    stv     var_pipe_head
    ; tail = DATA[ctrl+8]
    ldv     var_rt_tcb
    ldc     crt_8
    add
    dload                       ; stack: [tail]
    ; if head == tail → empty
    ldv     var_pipe_head
    eq
    jnz     _sw_read_empty
    ; Not empty: read value from buffer
    ; buf_addr = pipe_data_base + pipe_id * 264 + head * 8
    ldv     var_rt_arg0
    ldc     crt_264
    mul
    ldc     crt_pipe_data_base
    add
    ldv     var_pipe_head
    ldc     crt_8
    mul
    add
    dload                       ; stack: [value]
    stv     var_rt_arg1
    ; new_head = head + 1
    ldv     var_pipe_head
    ldc     crt_1
    add
    stv     var_pipe_head
    ldv     var_pipe_head
    ldc     crt_pipe_cap
    ge
    jz      _sw_read_no_wrap
    ldc     crt_0
    stv     var_pipe_head
_sw_read_no_wrap:
    ; DATA[ctrl] = new_head
    ldv     var_rt_tcb
    ldv     var_pipe_head
    dstore
    ; return value
    ldv     var_rt_arg1
    ret

_sw_read_empty:
    ; Check closed: DATA[ctrl+24]
    ldv     var_rt_tcb
    ldc     crt_24
    add
    dload
    ldc     crt_1
    eq
    jnz     _sw_read_eof
    ; Not closed: save pipe_id on stack, yield, restore
    ldv     var_rt_arg0         ; pipe_id → stack
    call    rtYield
    stv     var_rt_arg0         ; restore pipe_id
    jmp     _sw_read_retry

_sw_read_eof:
    ; return -1
    ldc     crt_0
    ldc     crt_1
    sub
    ret

; --- swPipeClose(pipe_id) ---
swPipeClose_int:
    ; ctrl = pipe_ctrl_base + pipe_id * 32
    ldc     crt_32
    mul
    ldc     crt_pipe_ctrl_base
    add
    ; DATA[ctrl+24] = 1 (closed)
    ldc     crt_24
    add
    ldc     crt_1
    dstore
    ret

[section name=_const, bank=CONSTANTS, start=0x10000]

crt_0:
    dq 0
crt_1:
    dq 1
crt_2:
    dq 2
crt_3:
    dq 3
crt_4:
    dq 4
crt_8:
    dq 8
crt_16:
    dq 16
crt_24:
    dq 24
crt_32:
    dq 32
crt_40:
    dq 40
crt_48:
    dq 48
crt_56:
    dq 56
crt_99:
    dq 99
crt_100:
    dq 100
crt_256:
    dq 256
crt_264:
    dq 264
crt_pipe_cap:
    dq 33
crt_tcb_base:
    dq 163840
crt_meta_count:
    dq 164352
crt_meta_current:
    dq 164360
crt_meta_pipecount:
    dq 164376

; Pipe control blocks base: 0x29000 = 167936
crt_pipe_ctrl_base:
    dq 167936
; Pipe data buffers base: 0x29100 = 168192
crt_pipe_data_base:
    dq 168192

crt_pic_iia:
    dq 172032
crt_pic_allowed:
    dq 172044
crt_pic_queue:
    dq 172048
crt_pic_happened:
    dq 172052
crt_pic_handlers:
    dq 172288

crt_clock_ticks:
    dq 176184
crt_clock_cycles:
    dq 176192

crt_pipe_send:
    dq 180224

crt_ret_stack_base:
    dq 192512

crt_handler_addr:
    dq rtContextSwitchHandler

crt_isr_sp:
    dq 900

crt_cycles_period:
    dq 50000

[section name=_data, bank=DATA, start=0x20000]

var_tmp_sp:
    resq 1
var_tmp_rp:
    resq 1
var_tmp_pc:
    resq 1

var_isr_cur:
    resq 1
var_isr_next:
    resq 1
var_isr_count:
    resq 1
var_isr_tcb_addr:
    resq 1
var_isr_state:
    resq 1
var_isr_tries:
    resq 1

var_isr_tmp_pc:
    resq 1
var_isr_saved_sp:
    resq 1
var_isr_saved_rp:
    resq 1
var_isr_saved_pc:
    resq 1

; Yield working variables (separate from ISR vars!)
var_yield_cur:
    resq 1
var_yield_next:
    resq 1
var_yield_count:
    resq 1
var_yield_tries:
    resq 1
var_yield_state:
    resq 1
var_yield_tcb:
    resq 1
var_yield_sp:
    resq 1
var_yield_rp:
    resq 1
var_yield_pc:
    resq 1

var_rt_arg0:
    resq 1
var_rt_arg1:
    resq 1
var_rt_idx:
    resq 1
var_rt_tcb:
    resq 1

; Pipe working variables
var_pipe_ctrl:
    resq 1
var_pipe_count:
    resq 1
var_pipe_cap:
    resq 1
var_pipe_head:
    resq 1
var_pipe_tail:
    resq 1
