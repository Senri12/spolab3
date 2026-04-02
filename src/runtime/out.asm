out:
    push    fp
    mov     fp, sp
    sub     sp, sp, #0
    mov     r2, [fp + 8]
    out     r2
    mov     r1, #0
out_exit:
    add     sp, sp, #0
    pop     fp
    ret
