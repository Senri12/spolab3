; pipe_typed.asm -- typed reader API over SimplePipe.
;
; movb/movh/mov read exactly 1/2/4 bytes per device access.
; No buffering state is needed — each call consumes exactly the
; requested number of bytes from the device stream.
;
; API (X = nothing / 0 / 1 / 2 for the four channels):
;   pipeTypedReadByteX()                 -> int  [0..255]
;   pipeTypedReadHalfX()                 -> int  16-bit LE
;   pipeTypedReadIntX()                  -> int  32-bit LE  (same as pipeInX)
;   pipeTypedReadUnitX(int n)            -> int  n bytes LE, n in {1,2,4}
;   pipeTypedReadCharX()                 -> int  UTF-8 code point
;   pipeTypedReadAsciiIntX()             -> int  parsed ASCII decimal
;   pipeTypedReadStringX(d,buf,max_len)  -> int  chars written (excl. terminator)
;   pipeTypedResetX()                    -> void no-op, kept for source compat

; ---------------------------------------------------------------------------
; Channel control-base addresses (SyncReceive is at control_base + 8)
;   default : 1000032
;   channel0: 196608
;   channel1: 200704
;   channel2: 204800
; ---------------------------------------------------------------------------

; ---------------------------------------------------------------------------
; Internal helpers -- signature: __pipeTypedReadByte(int control_base)
; ---------------------------------------------------------------------------

; int __pipeTypedReadByte(int control_base)
; [fp+8] = control_base
__pipeTypedReadByte:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0

    mov     r2, [fp + 8]
    mov     r3, #8
    add     r4, r2, r3
    movb    r1, [r4 + 0]

__pipeTypedReadByte_exit:
    add     sp, sp, #0
    pop     fp
    ret

; int __pipeTypedReadHalf(int control_base)
; [fp+8] = control_base
__pipeTypedReadHalf:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0

    mov     r2, [fp + 8]
    mov     r3, #8
    add     r4, r2, r3
    movh    r1, [r4 + 0]

__pipeTypedReadHalf_exit:
    add     sp, sp, #0
    pop     fp
    ret

; int __pipeTypedReadUnit(int control_base, int unit_bytes)
; [fp+8]  = control_base
; [fp+12] = unit_bytes (1, 2, or 4)
__pipeTypedReadUnit:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0

    mov     r2, [fp + 8]
    mov     r3, #8
    add     r4, r2, r3       ; r4 = SyncReceive address

    mov     r2, [fp + 12]    ; unit_bytes

    cmp     r2, #1
    bne     __pipeTypedReadUnit_try2
    movb    r1, [r4 + 0]
    jmp     __pipeTypedReadUnit_exit

__pipeTypedReadUnit_try2:
    cmp     r2, #2
    bne     __pipeTypedReadUnit_word
    movh    r1, [r4 + 0]
    jmp     __pipeTypedReadUnit_exit

__pipeTypedReadUnit_word:
    mov     r1, [r4 + 0]

__pipeTypedReadUnit_exit:
    add     sp, sp, #0
    pop     fp
    ret

; int __pipeTypedReadChar(int control_base)
; Reads one UTF-8 code point (1-3 bytes).
; [fp+8] = control_base
__pipeTypedReadChar:
    push    fp
    mov     fp, sp
    sub     sp, sp, #16

    ; [fp-4]  b0
    ; [fp-8]  b1
    ; [fp-12] b2
    ; [fp-16] value

    mov     r2, [fp + 8]
    push    r2
    call    __pipeTypedReadByte
    add     sp, sp, #4
    mov     [fp + -4], r1    ; b0

    mov     r2, [fp + -4]
    cmp     r2, #128
    blt     __pipeTypedReadChar_ascii

    cmp     r2, #224
    blt     __pipeTypedReadChar_two

    ; 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx
    mov     r2, [fp + 8]
    push    r2
    call    __pipeTypedReadByte
    add     sp, sp, #4
    mov     [fp + -8], r1    ; b1

    mov     r2, [fp + 8]
    push    r2
    call    __pipeTypedReadByte
    add     sp, sp, #4
    mov     [fp + -12], r1   ; b2

    mov     r2, [fp + -4]
    mov     r3, #224
    sub     r4, r2, r3
    mov     r2, #4096
    mul     r4, r4, r2
    mov     [fp + -16], r4

    mov     r2, [fp + -8]
    mov     r3, #128
    sub     r4, r2, r3
    mov     r2, #64
    mul     r4, r4, r2
    mov     r2, [fp + -16]
    add     r4, r2, r4
    mov     [fp + -16], r4

    mov     r2, [fp + -16]
    mov     r3, [fp + -12]
    add     r4, r2, r3
    mov     r2, #128
    sub     r4, r4, r2
    mov     r1, r4
    jmp     __pipeTypedReadChar_exit

__pipeTypedReadChar_two:
    ; 2-byte sequence: 110xxxxx 10xxxxxx
    mov     r2, [fp + 8]
    push    r2
    call    __pipeTypedReadByte
    add     sp, sp, #4
    mov     [fp + -8], r1    ; b1

    mov     r2, [fp + -4]
    mov     r3, #192
    sub     r4, r2, r3
    mov     r2, #64
    mul     r4, r4, r2
    mov     [fp + -16], r4

    mov     r2, [fp + -16]
    mov     r3, [fp + -8]
    add     r4, r2, r3
    mov     r2, #128
    sub     r4, r4, r2
    mov     r1, r4
    jmp     __pipeTypedReadChar_exit

__pipeTypedReadChar_ascii:
    mov     r1, [fp + -4]
__pipeTypedReadChar_exit:
    add     sp, sp, #16
    pop     fp
    ret

; int __pipeTypedReadAsciiInt(int control_base)
; Reads ASCII decimal digits until a non-digit, returns parsed integer.
; [fp+8] = control_base
__pipeTypedReadAsciiInt:
    push    fp
    mov     fp, sp
    sub     sp, sp, #16

    ; [fp-4]  result  = 0
    ; [fp-8]  sign    = 1
    ; [fp-12] started = 0
    ; [fp-16] ch
    mov     r2, #0
    mov     [fp + -4], r2
    mov     r2, #1
    mov     [fp + -8], r2
    mov     r2, #0
    mov     [fp + -12], r2

__pipeTypedReadAsciiInt_loop:
    mov     r2, [fp + 8]
    push    r2
    call    __pipeTypedReadByte
    add     sp, sp, #4
    mov     [fp + -16], r1

    mov     r2, [fp + -12]
    cmp     r2, #0
    bne     __pipeTypedReadAsciiInt_started

    ; skip leading '"'
    mov     r2, [fp + -16]
    cmp     r2, #34
    beq     __pipeTypedReadAsciiInt_loop

    ; handle leading '-'
    cmp     r2, #45
    bne     __pipeTypedReadAsciiInt_started
    mov     [fp + -8], #-1
    mov     [fp + -12], #1
    jmp     __pipeTypedReadAsciiInt_loop

__pipeTypedReadAsciiInt_started:
    mov     r2, [fp + -16]
    cmp     r2, #48
    blt     __pipeTypedReadAsciiInt_done
    cmp     r2, #57
    bgt     __pipeTypedReadAsciiInt_done

    mov     r2, [fp + -4]
    mov     r3, #10
    mul     r4, r2, r3
    mov     r2, [fp + -16]
    mov     r3, #48
    sub     r2, r2, r3
    add     r4, r4, r2
    mov     [fp + -4], r4

    mov     [fp + -12], #1
    jmp     __pipeTypedReadAsciiInt_loop

__pipeTypedReadAsciiInt_done:
    mov     r2, [fp + -8]
    cmp     r2, #0
    bge     __pipeTypedReadAsciiInt_ret
    mov     r2, #0
    mov     r3, [fp + -4]
    sub     r4, r2, r3
    mov     [fp + -4], r4

__pipeTypedReadAsciiInt_ret:
    mov     r1, [fp + -4]
__pipeTypedReadAsciiInt_exit:
    add     sp, sp, #16
    pop     fp
    ret

; int __pipeTypedReadString(int control_base, int delim, int buf_addr, int max_len)
; [fp+8]  = control_base
; [fp+12] = delim
; [fp+16] = buf_addr
; [fp+20] = max_len
; Returns: number of chars read (excluding terminator).
__pipeTypedReadString:
    push    fp
    mov     fp, sp
    sub     sp, sp, #16

    ; [fp-4]  len  = 0
    ; [fp-8]  cap  = max_len - 1
    ; [fp-12] ch
    ; [fp-16] addr (temp)
    mov     r2, #0
    mov     [fp + -4], r2

    mov     r2, [fp + 20]
    mov     r3, #1
    sub     r4, r2, r3
    mov     [fp + -8], r4

__pipeTypedReadString_loop:
    mov     r2, [fp + 8]
    push    r2
    call    __pipeTypedReadByte
    add     sp, sp, #4
    mov     [fp + -12], r1

    mov     r2, [fp + -12]
    mov     r3, [fp + 12]
    cmp     r2, r3
    beq     __pipeTypedReadString_done

    cmp     r2, #10
    beq     __pipeTypedReadString_done

    cmp     r2, #13
    beq     __pipeTypedReadString_done

    mov     r2, [fp + 20]
    cmp     r2, #0
    ble     __pipeTypedReadString_inc

    mov     r2, [fp + -4]
    mov     r3, [fp + -8]
    cmp     r2, r3
    bgt     __pipeTypedReadString_inc

    mov     r2, [fp + -4]
    mov     r3, #4
    mul     r4, r2, r3
    mov     r2, [fp + 16]
    add     r4, r2, r4
    mov     [fp + -16], r4
    mov     r2, [fp + -16]
    mov     r3, [fp + -12]
    mov     [r2 + 0], r3

__pipeTypedReadString_inc:
    mov     r2, [fp + -4]
    add     r3, r2, #1
    mov     [fp + -4], r3
    jmp     __pipeTypedReadString_loop

__pipeTypedReadString_done:
    mov     r2, [fp + 20]
    cmp     r2, #0
    ble     __pipeTypedReadString_ret

    mov     r2, [fp + -4]
    mov     [fp + -16], r2
    mov     r3, [fp + -8]
    cmp     r2, r3
    ble     __pipeTypedReadString_term
    mov     [fp + -16], r3

__pipeTypedReadString_term:
    mov     r2, [fp + -16]
    mov     r3, #4
    mul     r4, r2, r3
    mov     r2, [fp + 16]
    add     r4, r2, r4
    mov     [r4 + 0], #0

__pipeTypedReadString_ret:
    mov     r1, [fp + -4]
__pipeTypedReadString_exit:
    add     sp, sp, #16
    pop     fp
    ret

; ---------------------------------------------------------------------------
; No-op resets (no state to clear, kept for source compatibility)
; ---------------------------------------------------------------------------

pipeTypedReset:
    push    fp
    mov     fp, sp
    mov     r1, #0
    pop     fp
    ret

pipeTypedReset0:
    push    fp
    mov     fp, sp
    mov     r1, #0
    pop     fp
    ret

pipeTypedReset1:
    push    fp
    mov     fp, sp
    mov     r1, #0
    pop     fp
    ret

pipeTypedReset2:
    push    fp
    mov     fp, sp
    mov     r1, #0
    pop     fp
    ret

; ---------------------------------------------------------------------------
; Raw int32 readers (unchanged — same as pipeInX)
; ---------------------------------------------------------------------------

pipeTypedReadInt:
    jmp     pipeIn

pipeTypedReadInt0:
    jmp     pipeIn0

pipeTypedReadInt1:
    jmp     pipeIn1

pipeTypedReadInt2:
    jmp     pipeIn2

; ---------------------------------------------------------------------------
; Byte readers (movb — 1 byte per device access)
; ---------------------------------------------------------------------------

pipeTypedReadByte:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #1000032
    push    r2
    call    __pipeTypedReadByte
    add     sp, sp, #4
    add     sp, sp, #0
    pop     fp
    ret

pipeTypedReadByte0:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #196608
    push    r2
    call    __pipeTypedReadByte
    add     sp, sp, #4
    add     sp, sp, #0
    pop     fp
    ret

pipeTypedReadByte1:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #200704
    push    r2
    call    __pipeTypedReadByte
    add     sp, sp, #4
    add     sp, sp, #0
    pop     fp
    ret

pipeTypedReadByte2:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #204800
    push    r2
    call    __pipeTypedReadByte
    add     sp, sp, #4
    add     sp, sp, #0
    pop     fp
    ret

; ---------------------------------------------------------------------------
; Half-word readers (movh — 2 bytes LE per device access)
; ---------------------------------------------------------------------------

pipeTypedReadHalf:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #1000032
    push    r2
    call    __pipeTypedReadHalf
    add     sp, sp, #4
    add     sp, sp, #0
    pop     fp
    ret

pipeTypedReadHalf0:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #196608
    push    r2
    call    __pipeTypedReadHalf
    add     sp, sp, #4
    add     sp, sp, #0
    pop     fp
    ret

pipeTypedReadHalf1:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #200704
    push    r2
    call    __pipeTypedReadHalf
    add     sp, sp, #4
    add     sp, sp, #0
    pop     fp
    ret

pipeTypedReadHalf2:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #204800
    push    r2
    call    __pipeTypedReadHalf
    add     sp, sp, #4
    add     sp, sp, #0
    pop     fp
    ret

; ---------------------------------------------------------------------------
; Unit readers — arbitrary width: int pipeTypedReadUnitX(int n), n in {1,2,4}
; ---------------------------------------------------------------------------

pipeTypedReadUnit:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, [fp + 8]
    push    r2
    mov     r2, #1000032
    push    r2
    call    __pipeTypedReadUnit
    add     sp, sp, #8
    add     sp, sp, #0
    pop     fp
    ret

pipeTypedReadUnit0:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, [fp + 8]
    push    r2
    mov     r2, #196608
    push    r2
    call    __pipeTypedReadUnit
    add     sp, sp, #8
    add     sp, sp, #0
    pop     fp
    ret

pipeTypedReadUnit1:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, [fp + 8]
    push    r2
    mov     r2, #200704
    push    r2
    call    __pipeTypedReadUnit
    add     sp, sp, #8
    add     sp, sp, #0
    pop     fp
    ret

pipeTypedReadUnit2:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, [fp + 8]
    push    r2
    mov     r2, #204800
    push    r2
    call    __pipeTypedReadUnit
    add     sp, sp, #8
    add     sp, sp, #0
    pop     fp
    ret

; ---------------------------------------------------------------------------
; UTF-8 char readers
; ---------------------------------------------------------------------------

pipeTypedReadChar:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #1000032
    push    r2
    call    __pipeTypedReadChar
    add     sp, sp, #4
    add     sp, sp, #0
    pop     fp
    ret

pipeTypedReadChar0:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #196608
    push    r2
    call    __pipeTypedReadChar
    add     sp, sp, #4
    add     sp, sp, #0
    pop     fp
    ret

pipeTypedReadChar1:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #200704
    push    r2
    call    __pipeTypedReadChar
    add     sp, sp, #4
    add     sp, sp, #0
    pop     fp
    ret

pipeTypedReadChar2:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #204800
    push    r2
    call    __pipeTypedReadChar
    add     sp, sp, #4
    add     sp, sp, #0
    pop     fp
    ret

; ---------------------------------------------------------------------------
; ASCII integer readers
; ---------------------------------------------------------------------------

pipeTypedReadAsciiInt:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #1000032
    push    r2
    call    __pipeTypedReadAsciiInt
    add     sp, sp, #4
    add     sp, sp, #0
    pop     fp
    ret

pipeTypedReadAsciiInt0:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #196608
    push    r2
    call    __pipeTypedReadAsciiInt
    add     sp, sp, #4
    add     sp, sp, #0
    pop     fp
    ret

pipeTypedReadAsciiInt1:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #200704
    push    r2
    call    __pipeTypedReadAsciiInt
    add     sp, sp, #4
    add     sp, sp, #0
    pop     fp
    ret

pipeTypedReadAsciiInt2:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, #204800
    push    r2
    call    __pipeTypedReadAsciiInt
    add     sp, sp, #4
    add     sp, sp, #0
    pop     fp
    ret

; ---------------------------------------------------------------------------
; Byte-string readers until delimiter / LF / CR
; Signature: int pipeTypedReadStringX(int delim, int buf_addr, int max_len)
; ---------------------------------------------------------------------------

pipeTypedReadString:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, [fp + 16]
    push    r2
    mov     r2, [fp + 12]
    push    r2
    mov     r2, [fp + 8]
    push    r2
    mov     r2, #1000032
    push    r2
    call    __pipeTypedReadString
    add     sp, sp, #16
    add     sp, sp, #0
    pop     fp
    ret

pipeTypedReadString0:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, [fp + 16]
    push    r2
    mov     r2, [fp + 12]
    push    r2
    mov     r2, [fp + 8]
    push    r2
    mov     r2, #196608
    push    r2
    call    __pipeTypedReadString
    add     sp, sp, #16
    add     sp, sp, #0
    pop     fp
    ret

pipeTypedReadString1:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, [fp + 16]
    push    r2
    mov     r2, [fp + 12]
    push    r2
    mov     r2, [fp + 8]
    push    r2
    mov     r2, #200704
    push    r2
    call    __pipeTypedReadString
    add     sp, sp, #16
    add     sp, sp, #0
    pop     fp
    ret

pipeTypedReadString2:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, [fp + 16]
    push    r2
    mov     r2, [fp + 12]
    push    r2
    mov     r2, [fp + 8]
    push    r2
    mov     r2, #204800
    push    r2
    call    __pipeTypedReadString
    add     sp, sp, #16
    add     sp, sp, #0
    pop     fp
    ret
