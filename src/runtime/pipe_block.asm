; pipe_block.asm -- block/buffered byte reader for SimplePipe channels.
;
; Two implementations per channel (X = nothing/0/1/2):
;
;   pipeBlockReadX(byte[] buf, int n) -> int
;       Simple: reads n bytes via movb (1 device access per byte).
;
;   pipeBlockReadFastX(byte[] buf, int n) -> int
;       Fast: reads n bytes via mov (1 device access per 4 bytes) +
;       band/bshr unpack. Handles n not divisible by 4.
;
; Both store one byte per buf[i] in a packed byte[] (stride = 1, movb store).
; Returns n (bytes read).
;
; Channel control-base / SyncReceive (+8):
;   default : 1000032 / 1000040
;   ch0     : 196608  / 196616
;   ch1     : 200704  / 200712
;   ch2     : 204800  / 204808

; ============================================================
; INTERNAL: __pipeBlockRead_movb(buf, n, sync_recv_addr)
; [fp+8]  = buf (byte[] base address, stride=1)
; [fp+12] = n
; [fp+16] = sync_recv_addr
; Returns n.
; Local: [fp-4]=i
; ============================================================
__pipeBlockRead_movb:
    push    fp
    mov     fp, sp
    sub     sp, sp, #4

    mov     r2, #0
    mov     [fp + -4], r2       ; i = 0

__pipeBlockRead_movb_loop:
    mov     r2, [fp + -4]       ; i
    mov     r3, [fp + 12]       ; n
    cmp     r2, r3
    bge     __pipeBlockRead_movb_done

    ; read 1 byte from device
    mov     r5, [fp + 16]       ; sync_recv_addr
    movb    r3, [r5 + 0]        ; r3 = byte [0..255]

    ; buf[i] = r3   (byte[], stride=1)
    mov     r2, [fp + -4]       ; i
    mov     r4, [fp + 8]        ; buf base
    add     r4, r4, r2          ; &buf[i] = base + i
    movb    [r4 + 0], r3        ; store 1 byte

    ; i++
    mov     r2, [fp + -4]
    add     r2, r2, #1
    mov     [fp + -4], r2
    jmp     __pipeBlockRead_movb_loop

__pipeBlockRead_movb_done:
    mov     r1, [fp + 12]
    add     sp, sp, #4
    pop     fp
    ret

; ============================================================
; INTERNAL: __pipeBlockRead_fast(buf, n, sync_recv_addr)
; [fp+8]  = buf (byte[] base address, stride=1)
; [fp+12] = n
; [fp+16] = sync_recv_addr
; Reads groups of 4 bytes via mov, remainder via movb.
; Returns n.
; Locals: [fp-4]=i, [fp-8]=word, [fp-12]=rem, [fp-16]=n4
; ============================================================
__pipeBlockRead_fast:
    push    fp
    mov     fp, sp
    sub     sp, sp, #16

    ; n4 = n / 4   (whole 4-byte groups)
    ; rem = n - n4*4
    mov     r2, [fp + 12]       ; n
    mov     r3, #4
    div     r4, r2, r3
    mov     [fp + -16], r4      ; n4

    mul     r3, r4, r3          ; n4 * 4
    sub     r3, r2, r3
    mov     [fp + -12], r3      ; rem = n mod 4

    mov     r2, #0
    mov     [fp + -4], r2       ; i = 0 (byte index)

    ; --- phase 1: full 4-byte groups ---
__pipeBlockRead_fast_loop4:
    mov     r2, [fp + -4]       ; i
    mov     r3, [fp + -16]      ; n4
    mov     r4, #4
    mul     r3, r3, r4          ; n4 * 4
    cmp     r2, r3
    bge     __pipeBlockRead_fast_rem

    ; word = mov [sync_recv_addr]
    mov     r5, [fp + 16]
    mov     r3, [r5 + 0]        ; r3 = 4-byte word (LE)

    ; unpack 4 bytes into buf[i..i+3]
    ; stride = 1: address = base + i (no mul)

    ; byte 0: word & 255  → buf[i]
    mov     r6, r3
    band    r6, r6, #255
    mov     r7, [fp + -4]       ; i
    mov     r4, [fp + 8]        ; buf base
    add     r7, r4, r7          ; base + i
    movb    [r7 + 0], r6

    ; byte 1: (word >> 8) & 255  → buf[i+1]
    bshr    r6, r3, #8
    band    r6, r6, #255
    mov     r7, [fp + -4]       ; i
    add     r7, r7, #1          ; i+1
    mov     r4, [fp + 8]        ; buf base
    add     r7, r4, r7          ; base + i + 1
    movb    [r7 + 0], r6

    ; byte 2: (word >> 16) & 255  → buf[i+2]
    bshr    r6, r3, #16
    band    r6, r6, #255
    mov     r7, [fp + -4]       ; i
    add     r7, r7, #2          ; i+2
    mov     r4, [fp + 8]        ; buf base
    add     r7, r4, r7          ; base + i + 2
    movb    [r7 + 0], r6

    ; byte 3: (word >> 24) & 255  → buf[i+3]
    bshr    r6, r3, #24
    band    r6, r6, #255
    mov     r7, [fp + -4]       ; i
    add     r7, r7, #3          ; i+3
    mov     r4, [fp + 8]        ; buf base
    add     r7, r4, r7          ; base + i + 3
    movb    [r7 + 0], r6

    mov     r2, [fp + -4]
    add     r2, r2, #4
    mov     [fp + -4], r2
    jmp     __pipeBlockRead_fast_loop4

    ; --- phase 2: remaining 1-3 bytes via movb ---
__pipeBlockRead_fast_rem:
    mov     r2, [fp + -12]      ; rem
    cmp     r2, #0
    ble     __pipeBlockRead_fast_done

    mov     r5, [fp + 16]       ; sync_recv_addr
    mov     r4, [fp + 8]        ; buf base
    mov     r9, [fp + -4]       ; current byte index

__pipeBlockRead_fast_rem_loop:
    mov     r2, [fp + -12]
    cmp     r2, #0
    ble     __pipeBlockRead_fast_done

    movb    r3, [r5 + 0]        ; 1 byte from device

    mov     r7, r4
    add     r7, r7, r9          ; base + i (stride=1)
    movb    [r7 + 0], r3        ; store 1 byte

    add     r9, r9, #1
    mov     r2, [fp + -12]
    sub     r2, r2, #1
    mov     [fp + -12], r2
    jmp     __pipeBlockRead_fast_rem_loop

__pipeBlockRead_fast_done:
    mov     r1, [fp + 12]
    add     sp, sp, #16
    pop     fp
    ret

; ============================================================
; PUBLIC API -- movb variants (simple, 1 device read/byte)
; ============================================================

pipeBlockRead:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #1000040        ; default SyncReceive
    push    r2
    mov     r2, [fp + 12]
    push    r2
    mov     r2, [fp + 8]
    push    r2
    call    __pipeBlockRead_movb
    add     sp, sp, #12
    add     sp, sp, #0
    pop     fp
    ret

pipeBlockRead0:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #196616
    push    r2
    mov     r2, [fp + 12]
    push    r2
    mov     r2, [fp + 8]
    push    r2
    call    __pipeBlockRead_movb
    add     sp, sp, #12
    add     sp, sp, #0
    pop     fp
    ret

pipeBlockRead1:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #200712
    push    r2
    mov     r2, [fp + 12]
    push    r2
    mov     r2, [fp + 8]
    push    r2
    call    __pipeBlockRead_movb
    add     sp, sp, #12
    add     sp, sp, #0
    pop     fp
    ret

pipeBlockRead2:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #204808
    push    r2
    mov     r2, [fp + 12]
    push    r2
    mov     r2, [fp + 8]
    push    r2
    call    __pipeBlockRead_movb
    add     sp, sp, #12
    add     sp, sp, #0
    pop     fp
    ret

; ============================================================
; PUBLIC API -- fast variants (1 device read/4 bytes)
; ============================================================

pipeBlockReadFast:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #1000040
    push    r2
    mov     r2, [fp + 12]
    push    r2
    mov     r2, [fp + 8]
    push    r2
    call    __pipeBlockRead_fast
    add     sp, sp, #12
    add     sp, sp, #0
    pop     fp
    ret

pipeBlockReadFast0:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #196616
    push    r2
    mov     r2, [fp + 12]
    push    r2
    mov     r2, [fp + 8]
    push    r2
    call    __pipeBlockRead_fast
    add     sp, sp, #12
    add     sp, sp, #0
    pop     fp
    ret

pipeBlockReadFast1:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #200712
    push    r2
    mov     r2, [fp + 12]
    push    r2
    mov     r2, [fp + 8]
    push    r2
    call    __pipeBlockRead_fast
    add     sp, sp, #12
    add     sp, sp, #0
    pop     fp
    ret

pipeBlockReadFast2:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #204808
    push    r2
    mov     r2, [fp + 12]
    push    r2
    mov     r2, [fp + 8]
    push    r2
    call    __pipeBlockRead_fast
    add     sp, sp, #12
    add     sp, sp, #0
    pop     fp
    ret
