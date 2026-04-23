# pipe_block.asm — Block Pipe Reader

`src/runtime/pipe_block.asm` provides buffered N-byte reads from SimplePipe channels.

---

## API

### Simple (1 device read per byte via `movb`)

```c
int pipeBlockRead(int[] buf, int n);    // default channel
int pipeBlockRead0(int[] buf, int n);   // channel 0
int pipeBlockRead1(int[] buf, int n);   // channel 1
int pipeBlockRead2(int[] buf, int n);   // channel 2
```

### Fast (1 device read per 4 bytes via `mov` + `band`/`bshr` unpack)

```c
int pipeBlockReadFast(int[] buf, int n);    // default channel
int pipeBlockReadFast0(int[] buf, int n);   // channel 0
int pipeBlockReadFast1(int[] buf, int n);   // channel 1
int pipeBlockReadFast2(int[] buf, int n);   // channel 2
```

Both variants store one byte per `buf[i]` as `int` in `[0..255]` and return `n`.  
The fast variant handles `n` not divisible by 4 via `movb` for the remainder.

---

## Usage (PDSL)

Declare as extern and pass a local `int[]` array:

```c
int pipeBlockReadFast1(int[] buf, int n);
// ...
int main() {
    int buf[256];
    pipeBlockReadFast1(buf, 256);
    // buf[0]..buf[255] now hold one byte each
}
```

---

## Known Compiler Limitation: Variable-Index Array Read

The PDSL compiler does **not** support variable-index array reads on the RHS of an assignment:

```c
ch = buf[i];   // BROKEN — emits no code, ch stays 0
```

**Workaround 1** — pass as function argument (goes through `eval_arg_to_reg`):
```c
printInt(buf[i]);   // OK
```

**Workaround 2** — wrap in a helper that uses `return arr[pos]`:
```c
int getElem(int[] arr, int pos) {
    return arr[pos];   // return path uses eval_arg_to_reg
}
// ...
ch = getElem(buf, i);   // OK
```

Fixed-index reads are always fine:
```c
ch = buf[0];      // OK — constant index
ch = state[1];    // OK — constant index
```

---

## Channel MMIO Addresses

| Channel | control_base | SyncReceive (+8) |
|---------|-------------|-----------------|
| default | 1000032     | 1000040         |
| ch0     | 196608      | 196616          |
| ch1     | 200704      | 200712          |
| ch2     | 204800      | 204808          |

---

## Performance Comparison

| Method                                   | Device reads/byte | Notes                                 |
|------------------------------------------|-------------------|---------------------------------------|
| `pipeIn1()` every 4 bytes (current q1)   | 0.25              | 1 function call per 4 bytes           |
| `pipeBlockRead1(buf, n)`                 | 1.0               | movb loop                             |
| `pipeBlockReadFast1(buf, n)`             | 0.25              | Same MMIO count; 1 call for n bytes   |

When input device is the bottleneck (blocking SyncReceive), block reads offer minimal speedup  
because the number of MMIO accesses is unchanged. Gains appear only when CPU/call overhead  
dominates (i.e., data is buffered on the device side and arrives faster than it is consumed).

---

## Implementation Notes

### Internal helpers

```asm
__pipeBlockRead_movb(buf, n, sync_recv_addr)
    [fp+8]=buf  [fp+12]=n  [fp+16]=sync_recv_addr
    Locals: [fp-4]=i  [fp-8]=write_ptr

__pipeBlockRead_fast(buf, n, sync_recv_addr)
    [fp+8]=buf  [fp+12]=n  [fp+16]=sync_recv_addr
    Locals: [fp-4]=i  [fp-8]=word  [fp-12]=rem  [fp-16]=n4
    Reads floor(n/4) full words, then remainder via movb.
    IMPORTANT: reloads r4=[fp+8] before each byte's address computation
               (r4 is clobbered by the add-to-base in byte 0).
```

Public wrappers push `sync_recv_addr` for their channel and delegate to the internal helper.

---

## Probe Test Results

Probe: `src/task2_v71/pipe_block_probe.txt` reads 8 bytes via each method from ch0.

Input: first 16 bytes of `q2.lyudi_dbg.noheader.csv` (UTF-8 BOM + CSV data).

```
S:239 187 191 34 49 49 49 55     (movb, bytes 0-7)
F:51 50 34 59 34 208 161 208     (fast, bytes 8-15)
```

`239 187 191` = UTF-8 BOM, `34`=`"`, `49 49 49 55`=`"117`  — correct.
