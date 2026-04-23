# Изменения: типизированное чтение и битовые операции в TacVm13

## Содержание
1. [Контекст](#контекст)
2. [Изменения TacVm13.target.pdsl](#изменения-tacvm13targetpdsl)
3. [Изменения cfg_builder.c](#изменения-cfg_builderc)
4. [Модуль pipe_typed.asm — полный API](#модуль-pipe_typedasm--полный-api)
5. [Оптимизация q1_raw200 — результаты](#оптимизация-q1_raw200--результаты)
6. [Диагностика и исправленные баги](#диагностика-и-исправленные-баги)

---

## Контекст

TacVm13 — 32-битная учебная VM. До внесения изменений единственный способ читать из устройства
(SimplePipe ByteStream) — инструкция `mov r1, [addr]`, которая всегда читает **ровно 4 байта** (int32).
Каждый вызов `pipeIn()` / `pipeTypedReadByte()` потреблял 4 байта из потока.

Цель доработок:
- Добавить в ISA инструкции чтения **1 байта** (`movb`) и **2 байт** (`movh`)
- Добавить в компилятор **битовые операции** `& | ^ << >>`
- Переписать `pipe_typed.asm` так, чтобы `pipeTypedReadByteX()` читал **ровно 1 байт** из устройства
- Оптимизировать код, использующий побайтовый разбор CSV

---

## Изменения TacVm13.target.pdsl

### Новые инструкции (opcodes 0x0B–0x0E)

Добавлены четыре инструкции после `mov_al` (opcode 0x0A):

| Мнемоника    | Opcode | Формат         | Семантика |
|:-------------|:-------|:---------------|:----------|
| `movb r, [base+off]` | `0x0B` | reg, reg, off16 | `dst = ram:1[base+off] & 0xFF` |
| `movb r, [addr]`     | `0x0C` | reg, addr       | `dst = ram:1[addr] & 0xFF`     |
| `movh r, [base+off]` | `0x0D` | reg, reg, off16 | `dst = ram:2[base+off] & 0xFFFF` |
| `movh r, [addr]`     | `0x0E` | reg, addr       | `dst = ram:2[addr] & 0xFFFF`   |

> **Важно**: в TacVm13 `ram:1[...]` знако-расширяет байт до 32 бит (например, `0xEF` → `-17`).
> Поэтому в семантике явно применяется маска `& 0xFF` / `& 0xFFFF`.

```pdsl
instruction movb_rm = {
    0000 1011, reg as dst, reg as base, off16 as off,
    0000 0000 0000 0000 0000 0000 0000 00
} {
    let signed_off = off;
    if off >= 0x8000 then signed_off = off - 0x10000;
    let address = base + signed_off;
    dst = ram:1[address] & 0xFF;
    ip = ip + 8;
};
```

### Новые мнемоники для битовых инструкций

VM изначально имела инструкции `and_rrr`, `or_rrr`, `xor_rrr`, `shl_rrr`, `shr_rrr` и их `_rri`-варианты,
но **мнемоники для них не были объявлены**. Добавлены в конец блока `mnemonics`:

```pdsl
mnemonic band for and_rrr(dst, lhs, rhs) "{1}, {2}, {3}",
              for and_rri(dst, lhs, rhs) "{1}, {2}, #{3}";
mnemonic bor  for or_rrr(dst, lhs, rhs)  "{1}, {2}, {3}",
              for or_rri(dst, lhs, rhs)  "{1}, {2}, #{3}";
mnemonic bxor for xor_rrr(dst, lhs, rhs) "{1}, {2}, {3}",
              for xor_rri(dst, lhs, rhs) "{1}, {2}, #{3}";
mnemonic bshl for shl_rrr(dst, lhs, rhs) "{1}, {2}, {3}",
              for shl_rri(dst, lhs, rhs) "{1}, {2}, #{3}";
mnemonic bshr for shr_rrr(dst, lhs, rhs) "{1}, {2}, {3}",
              for shr_rri(dst, lhs, rhs) "{1}, {2}, #{3}";
```

> `and` и `or` — зарезервированные слова в PDSL, поэтому используются имена `band`/`bor`.

---

## Изменения cfg_builder.c

### 1. Встроенные функции `memLoadByte` и `memLoadHalf`

В функции `emit_builtin_call_to_reg` добавлены два буилтина:

```c
// int memLoadByte(int address)  — читает 1 байт, zero-extended
if (strcmp(fname, "memLoadByte") == 0) {
    eval_arg_to_reg(args[0], 2, st, head, tail, pending_label_ptr);
    emit_instr(head, tail, "movb", reg(dst_reg), mem_op(2, 0), zero_reg(), ...);
    return 1;
}

// int memLoadHalf(int address)  — читает 2 байта LE, zero-extended
if (strcmp(fname, "memLoadHalf") == 0) {
    eval_arg_to_reg(args[0], 2, st, head, tail, pending_label_ptr);
    emit_instr(head, tail, "movh", reg(dst_reg), mem_op(2, 0), zero_reg(), ...);
    return 1;
}
```

Использование в SL-коде:
```c
int b = memLoadByte(address);   // читает 1 байт из RAM
int h = memLoadHalf(address);   // читает 2 байта из RAM (LE)
```

### 2. Битовые операторы `& | ^ << >>`

Ранее операторы были известны лексеру (`is_binop`), но **ни в одном пути генерации кода
не эмитировали инструкцию** — результатом всегда был мусор в `r4`.

Исправлено в **двух местах**:

#### `eval_arg_to_reg` (выражения-аргументы, индексы массивов)

```c
else if (!strcmp(op, "&"))  emit_instr(head, tail, "band", reg(4), reg(2), reg(3), NULL);
else if (!strcmp(op, "|"))  emit_instr(head, tail, "bor",  reg(4), reg(2), reg(3), NULL);
else if (!strcmp(op, "^"))  emit_instr(head, tail, "bxor", reg(4), reg(2), reg(3), NULL);
else if (!strcmp(op, "<<")) emit_instr(head, tail, "bshl", reg(4), reg(2), reg(3), NULL);
else if (!strcmp(op, ">>")) emit_instr(head, tail, "bshr", reg(4), reg(2), reg(3), NULL);
```

#### `generate_single_statement` — ветка `x = y op z` (строки ~5246+)

```c
else if (!strcmp(op, "&"))  emit_instr(head, tail, "band", reg(4), reg(2), reg(3), NULL);
else if (!strcmp(op, "|"))  emit_instr(head, tail, "bor",  reg(4), reg(2), reg(3), NULL);
else if (!strcmp(op, "^"))  emit_instr(head, tail, "bxor", reg(4), reg(2), reg(3), NULL);
else if (!strcmp(op, "<<")) emit_instr(head, tail, "bshl", reg(4), reg(2), reg(3), NULL);
else if (!strcmp(op, ">>")) emit_instr(head, tail, "bshr", reg(4), reg(2), reg(3), NULL);
```

Теперь SL-код вида:
```c
ch = state[0] & 255;
state[0] = state[0] >> 8;
x = a | b;
y = a ^ b;
z = a << 2;
```
— компилируется корректно.

> Парсинг выражений `a op b` с пробелами работает через `sscanf(..., "%63s %3s %63s", ...)`.
> Оператор `>>` (2 символа) помещается в буфер `char op[4]` без проблем.

---

## Модуль pipe_typed.asm — полный API

Файл: `src/runtime/pipe_typed.asm`. Подключается автоматически компилятором (перечислен в `kRuntimeFiles[]`).

### Адреса каналов

| Канал   | control_base | SyncReceive (control_base+8) |
|:--------|:-------------|:-----------------------------|
| default | `1000032`    | `1000040`                    |
| ch0     | `196608`     | `196616`                     |
| ch1     | `200704`     | `200712`                     |
| ch2     | `204800`     | `204808`                     |

### Внутренние хелперы (не для прямого вызова)

| Функция | Аргумент | Возврат | Описание |
|:--------|:---------|:--------|:---------|
| `__pipeTypedReadByte(base)` | control_base | `int [0..255]` | 1 байт через `movb` |
| `__pipeTypedReadHalf(base)` | control_base | `int [0..65535]` | 2 байта через `movh` |
| `__pipeTypedReadUnit(base, n)` | control_base, n∈{1,2,4} | `int` | n байт (выбирает movb/movh/mov) |
| `__pipeTypedReadChar(base)` | control_base | `int` | UTF-8 code point (1–3 байта) |
| `__pipeTypedReadAsciiInt(base)` | control_base | `int` | ASCII-десятичное целое |
| `__pipeTypedReadString(base,delim,buf,max)` | control_base, delim, buf_addr, max_len | `int` | строка до разделителя |

### Публичные функции — суффикс X = ничего / 0 / 1 / 2

#### Сброс состояния (no-op)
```c
void pipeTypedReset();    // no-op, совместимость
void pipeTypedReset0();
void pipeTypedReset1();
void pipeTypedReset2();
```
Состояния нет — функции оставлены для обратной совместимости с кодом, который их вызывал.

#### Чтение int32 (псевдонимы pipeIn)
```c
int pipeTypedReadInt();   // == pipeIn()
int pipeTypedReadInt0();  // == pipeIn0()
int pipeTypedReadInt1();  // == pipeIn1()
int pipeTypedReadInt2();  // == pipeIn2()
```
Читает **4 байта** из устройства за один вызов.

#### Чтение 1 байта (movb)
```c
int pipeTypedReadByte();   // default channel
int pipeTypedReadByte0();  // channel 0
int pipeTypedReadByte1();  // channel 1
int pipeTypedReadByte2();  // channel 2
```
Возвращает `[0..255]`. Потребляет **ровно 1 байт** из потока устройства.

#### Чтение 2 байт (movh, little-endian)
```c
int pipeTypedReadHalf();
int pipeTypedReadHalf0();
int pipeTypedReadHalf1();
int pipeTypedReadHalf2();
```
Возвращает `[0..65535]` (LE). Потребляет **ровно 2 байта**.

#### Чтение n байт (выбор по n)
```c
int pipeTypedReadUnit(int n);    // n ∈ {1, 2, 4}
int pipeTypedReadUnit0(int n);
int pipeTypedReadUnit1(int n);
int pipeTypedReadUnit2(int n);
```
- `n=1` → `movb` (1 байт)
- `n=2` → `movh` (2 байта LE)
- `n=4` → `mov`  (4 байта LE)

#### Чтение UTF-8 символа
```c
int pipeTypedReadChar();
int pipeTypedReadChar0();
int pipeTypedReadChar1();
int pipeTypedReadChar2();
```
Читает 1–3 байта UTF-8, возвращает Unicode code point.

#### Чтение ASCII-числа
```c
int pipeTypedReadAsciiInt();
int pipeTypedReadAsciiInt0();
int pipeTypedReadAsciiInt1();
int pipeTypedReadAsciiInt2();
```
Пропускает ведущий `"`, обрабатывает знак `-`, читает цифры до первого не-цифрового символа.

#### Чтение строки до разделителя
```c
int pipeTypedReadString(int delim, int buf_addr, int max_len);
int pipeTypedReadString0(int delim, int buf_addr, int max_len);
int pipeTypedReadString1(int delim, int buf_addr, int max_len);
int pipeTypedReadString2(int delim, int buf_addr, int max_len);
```
Читает байты до `delim`, `\n` или `\r`. Записывает в `buf_addr` (int-массив, 4 байта/элемент).
Возвращает количество прочитанных символов (без терминатора).

---

## Оптимизация q1_raw200 — результаты

### Версии и время выполнения

| Версия | Подход `readByte` | Буфер | Время (полный пайплайн) |
|:-------|:------------------|:------|:------------------------|
| Baseline (исходная) | `pipeIn1()` + `div`/`mul` распаковка байт | `reader[2]` (word+count) | ~298.85 с |
| Сломанная (промежуточная) | `pipeTypedReadByte1()` × 1024 в `fillBuffer` | `reader[1026]` | >2143 с (таймаут) |
| **Оптимизированная (итог)** | **`pipeIn1()` + `& 255` / `>> 8`** | **`reader[2]`** | **258.6 с** |

**Ускорение: ~13% (298.85 с → 258.6 с)**

### Почему сломанная версия зависала

1. 1024 вызова `pipeTypedReadByte1()` в `fillBuffer` = ~10 000+ инструкций за одно заполнение буфера
2. `fillBuffer` читал ровно 1024 байта, не зная о конце CSV — при малом файле блокировался навсегда

### Почему оптимизированная быстрее исходной

Исходная распаковка байтов:
```c
// старый readByte: для каждого байта из буфера 1024 элементов
ch = state[pos + 2];  // индекс масштабируется через mul каждый раз
```

Новая распаковка через сдвиги:
```c
int readByte(int[] state) {
    if (state[1] <= 0) {
        state[0] = pipeIn1();   // 1 вызов = 4 байта
        state[1] = 4;
    }
    ch = state[0] & 255;        // band — 1 инструкция
    state[0] = state[0] >> 8;   // bshr — 1 инструкция
    state[1] = state[1] - 1;
    return ch;
}
```

- Нет индексирования массива (`mul + add + mov` заменены на `band + bshr`)
- `reader[2]` вместо `reader[1026]` — меньше стека
- Новые инструкции `band`/`bshr` исполняются VM напрямую

---

## Диагностика и исправленные баги

### Баг 1: знаковое расширение `movb`

**Проблема**: `ram:1[address]` в TacVm13 знако-расширяет байт. `0xEF` (239) читался как `-17`.

**Исправление**: в семантике инструкций PDSL добавлена маска:
```pdsl
dst = ram:1[address] & 0xFF;
```

### Баг 2: битовые операторы не генерировали инструкции

**Проблема**: `ch = state[0] & 255` компилировалось в:
```asm
mov r2, [state[0]]   ; r2 = state[0]
mov r3, #255         ; r3 = 255
; ← пропущена инструкция band r4, r2, r3
mov [fp + -4], r4    ; ch = мусор из r4
```
Зависание: CSV-парсер никогда не находил `\n`, `rowCount` не рос.

**Исправление**: добавлены `else if` ветки для `& | ^ << >>` в `generate_single_statement`
и `eval_arg_to_reg` в `cfg_builder.c`.

### Баг 3: `and`/`or` — зарезервированные слова PDSL

**Проблема**: `mnemonic and ...` давало `Unexpected token "and"; expected: name`.

**Исправление**: мнемоники переименованы в `band`/`bor`/`bxor`/`bshl`/`bshr`.
В `cfg_builder.c` эмиттируются эти же имена.

---

## Файлы, затронутые изменениями

| Файл | Что изменено |
|:-----|:-------------|
| `src/TacVm13.target.pdsl` | Инструкции `movb_rm`, `movb_ra`, `movh_rm`, `movh_ra`; мнемоники `movb`, `movh`; мнемоники `band`, `bor`, `bxor`, `bshl`, `bshr` |
| `src/cfg_builder.c` | Буилтины `memLoadByte`, `memLoadHalf`; битовые операторы в `eval_arg_to_reg` и `generate_single_statement` |
| `src/runtime/pipe_typed.asm` | Полная переработка: `movb`/`movh` транспорт, без состояния, все публичные API |
| `complete/q1_raw200.txt` | `readByte` переведён на `pipeIn1()` + `& 255` / `>> 8`, `reader[2]` |
