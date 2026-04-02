# TacVm13: VM, запуск и полезные детали

Этот файл фиксирует актуальное состояние проекта:

- целевая VM: `TacVm13`
- генерация `asm`: удалённый ANTLR-парсер
- сборка и запуск: `Portable.RemoteTasks.Manager.exe`
- основной ввод-вывод: скрытые storages `INPUT` / `OUTPUT`
- запасной ввод-вывод: `vm0device` через `TacVm13.devices.xml`
- пользовательские `in()` / `out(...)`: обычные вызовы runtime-функций, а не захардкоженные special-case инструкции генератора

## 1. Основная цепочка

Рабочий конвейер такой:

```text
simpleLang source
-> ANTLR parser на удалённом сервере
-> AST / CFG / TAC / asm
-> runtime asm (in.asm / out.asm) дописывается в итоговый листинг
-> Portable.RemoteTasks Assemble
-> .ptptb
-> Portable.RemoteTasks Execute
```

Где это находится:

- грамматика: `src/SimpleLang.g`
- генератор CFG/TAC/asm: `src/cfg_builder.c`
- описание архитектуры: `src/TacVm13.target.pdsl`
- запасные устройства: `src/TacVm13.devices.xml`
- runtime-функции ввода-вывода:
  - `src/runtime/in.asm`
  - `src/runtime/out.asm`
- удалённый парсер:
  - `tools/remote-parser.ps1`
- сборка `.ptptb`:
  - `tools/remotetasks-assemble.ps1`
- запуск:
  - `tools/remotetasks-run.ps1`

## 2. Что такое TacVm13

`TacVm13` это целевая ISA, описанная в `src/TacVm13.target.pdsl`.

Сейчас в ней:

- 32 обычных 32-битных регистра: `r0..r28`, `fp`, `sp`, `r31`
- служебный регистр `ip`
- служебный регистр `cmp_result`
- скрытый storage `INPUT[8]`
- скрытый storage `OUTPUT[8]`

Важные alias:

- `fp = R29`
- `sp = R30`

Что важно помнить:

- `r0` не является аппаратным нулём
- флагового регистра наподобие `ZF/NF/CF/VF` нет
- сравнения и ветвления завязаны на `cmp_result`

## 3. Память и адресация

В архитектуре один банк памяти:

```text
ram [0x00000000 .. 0x000FFFFF]
```

Свойства:

- размер: 1 MiB
- `cell = 8`
- little-endian
- побайтная адресация

В одном и том же `ram` лежат:

- код
- данные
- стек
- при режиме `WithIo` ещё и MMIO устройства

Итоговый листинг должен начинаться с:

```asm
[section ram, code]
```

Обычно bootstrap такой:

```asm
start:
    mov     sp, #1040000
    mov     fp, sp
    call    main
    halt
```

То есть стек стартует сверху RAM и растёт вниз.

## 4. Формат инструкций

Все инструкции фиксированного размера:

```text
8 байт
```

Из этого следуют две важные вещи:

- `ip` хранит байтовый адрес инструкции
- переход на следующую инструкцию обычно делается как `ip = ip + 8`

Используемые поля:

- `reg`
- `imm32`
- `addr20`
- `label32`
- `off16`

Практически важно:

- переходы и `call` у нас сейчас идут через `label32`
- смещения памяти `[base + off]` обрабатываются как знаковые

## 5. Основные инструкции

### 5.1. Данные и память

Поддерживаются:

- `mov dst, src`
- `mov dst, #imm`
- `mov dst, label`
- `mov dst, [base + off]`
- `mov dst, [addr]`
- `mov [base + off], src`
- `mov [base + off], #imm`
- `mov [addr], src`
- `mov [addr], #imm`
- `mov [addr], label`

Память читается и пишется словами по 4 байта:

```text
ram:4[address]
```

### 5.2. Стек

Поддерживаются:

- `push rX`
- `pop rX`

Семантика:

```text
push rX => sp = sp - 4; ram:4[sp] = rX
pop  rX => rX = ram:4[sp]; sp = sp + 4
```

### 5.3. Арифметика

Основной набор:

- `add`
- `sub`
- `mul`
- `div`
- `and`
- `or`
- `xor`
- `shl`
- `shr`
- `not`

### 5.4. Сравнение и ветвления

Сравнение:

- `cmp lhs, rhs`
- `cmp lhs, #rhs`

Семантика:

```text
cmp_result = lhs - rhs
```

Ветвления:

- `jmp`
- `beq`
- `bne`
- `blt`
- `bgt`
- `ble`
- `bge`

Важно:

- signed-семантика для `blt/bgt/ble/bge` уже исправлена
- условные переходы смотрят на `cmp_result`, а не на набор флагов

### 5.5. Вызовы

Есть:

- `call`
- `ret`
- `halt`
- `nop`

Семантика вызова:

```text
call label =>
    sp = sp - 4
    ram:4[sp] = ip + 8
    ip = label
```

Семантика возврата:

```text
ret =>
    ip = ram:4[sp]
    sp = sp + 4
```

## 6. Ввод-вывод

### 6.1. Основной режим: hidden INPUT / OUTPUT

Сейчас основной путь запуска это:

- `ExecuteBinaryWithInteractiveInput`
- `ExecuteBinaryWithInput`

В них VM использует скрытые storages:

- `INPUT`
- `OUTPUT`

Соответствующие инструкции ISA:

```text
in dst   => dst = INPUT
out src  => OUTPUT = src & 0xFF
out #imm => OUTPUT = imm & 0xFF
```

То есть основной путь сейчас не требует `devices.xml`.

### 6.2. Запасной режим: vm0device

Файл:

- `src/TacVm13.devices.xml`

Там описан `SimplePipe`:

- имя устройства: `vm0device`
- режим: `ByteStream`
- binding: `stdio`

Он отображается в `ram` начиная с адреса `1000032`.

Этот режим используется при запуске:

```text
ExecuteBinaryWithIo
```

То есть:

- основной путь: `INPUT/OUTPUT`
- запасной путь: `vm0device`

## 7. Где реально лежат in/out

Надо различать 3 уровня.

### 7.1. В языке

В исходнике simpleLang можно писать:

```c
int c = in();
out(c);
out('\n');
```

Для грамматики это обычные вызовы функций.

### 7.2. В runtime

Сейчас пользовательские `in()` и `out(...)` реализованы как обычные runtime-функции:

- `src/runtime/in.asm`
- `src/runtime/out.asm`

Примеры:

```asm
in:
    ...
    in      r1
    ...
    ret
```

```asm
out:
    ...
    mov     r2, [fp + 8]
    out     r2
    mov     r1, #0
    ...
    ret
```

То есть генератор теперь делает не низкоуровневый `out` сразу, а обычный `call out`.

### 7.3. В ISA

Низкоуровневые инструкции `in/out` всё равно существуют в `src/TacVm13.target.pdsl`.

Их использует runtime-asm.

## 8. Как runtime попадает в итоговый asm

Генератор `src/cfg_builder.c`:

- строит `asm` из функций программы
- потом дописывает runtime-листинги
- затем делает постобработку меток в числовые адреса

Итог:

- в `build/test_program.asm` или `build/test_echo.asm` в конце есть метки `in:` и `out:`
- вызовы на них уже преобразованы в байтовые адреса

## 9. Соглашение о вызовах

Это уже не ISA, а соглашение генератора.

### 9.1. Аргументы и результат

- аргументы кладутся в стек справа налево
- результат функции возвращается в `r1`
- после `call` вызывающий код сам очищает стек

Пример:

```asm
mov     r7, #65
push    r7
call    out
add     sp, sp, #4
```

### 9.2. Пролог и эпилог

Обычная функция:

```asm
push    fp
mov     fp, sp
sub     sp, sp, #<local_size>
...
add     sp, sp, #<local_size>
pop     fp
ret
```

### 9.3. Кадр стека

После пролога:

```text
[fp + 0]   старый fp
[fp + 4]   адрес возврата
[fp + 8]   аргумент 1
[fp + 12]  аргумент 2
...
[fp - 4]   локальная 1
[fp - 8]   локальная 2
...
```

## 10. Как собирать и запускать

### 10.1. Генерация asm на удалённом сервере

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remote-parser.ps1 `
  -InputFile .\src\test.txt `
  -AsmOutput .\build\test_program.asm `
  -ParseTreeOutput .\build\test_program.dgml
```

Что делает скрипт:

- копирует `src/` на удалённый сервер
- запускает там ANTLR и сборку парсера
- получает назад `.asm` и `.dgml`

### 10.2. Сборка `.ptptb`

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-assemble.ps1 `
  -AsmListing .\build\test_program.asm `
  -DefinitionFile .\src\TacVm13.target.pdsl `
  -ArchName TacVm13 `
  -BinaryOutput .\build\test_program.ptptb
```

### 10.3. Интерактивный запуск

Основной режим:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 `
  -BinaryFile .\build\test_program.ptptb `
  -DefinitionFile .\src\TacVm13.target.pdsl `
  -RunMode InteractiveInput `
  -StdinRegStorage INPUT `
  -StdoutRegStorage OUTPUT `
  -ArchName TacVm13
```

### 10.4. Запуск с файлом ввода

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 `
  -BinaryFile .\build\test_program.ptptb `
  -DefinitionFile .\src\TacVm13.target.pdsl `
  -RunMode InputFile `
  -InputFile .\build\test_program_plus12.stdin.txt `
  -StdinRegStorage INPUT `
  -StdoutRegStorage OUTPUT `
  -ArchName TacVm13
```

### 10.5. Запуск через vm0device

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 `
  -BinaryFile .\build\test_program.ptptb `
  -DefinitionFile .\src\TacVm13.target.pdsl `
  -DevicesFile .\src\TacVm13.devices.xml `
  -RunMode WithIo `
  -ArchName TacVm13
```

## 11. Запуск через make

Актуальные переменные в `Makefile`:

- `INPUT_FILE`
- `ASM_FILE`
- `DGML_FILE`
- `BINARY_FILE`
- `RUN_MODE`
- `STDIN_FILE`
- `STDIN_REG`
- `STDOUT_REG`

Примеры:

Только генерация:

```powershell
make asm INPUT_FILE=src/test.txt ASM_FILE=build/test_program.asm DGML_FILE=build/test_program.dgml
```

Генерация и сборка:

```powershell
make assemble INPUT_FILE=src/test.txt ASM_FILE=build/test_program.asm DGML_FILE=build/test_program.dgml BINARY_FILE=build/test_program.ptptb
```

Полный запуск с файлом ввода:

```powershell
make run INPUT_FILE=src/test.txt ASM_FILE=build/test_program.asm DGML_FILE=build/test_program.dgml BINARY_FILE=build/test_program.ptptb RUN_MODE=InputFile STDIN_FILE=build/test_program_plus12.stdin.txt STDIN_REG=INPUT STDOUT_REG=OUTPUT
```

## 12. Что проверять в первую очередь

Для smoke-test лучше использовать:

- `src/test_echo.txt`

Потому что это конечная программа:

```text
BEGIN
GOT=x
```

Для более содержательной проверки:

- `src/test.txt`

Это интерактивный калькулятор.

Примеры:

```text
+12
*34
-84
/82
```

Ожидаемо:

```text
>3
>12
>4
>4
>
```

Последний `>` нормален: программа напечатала приглашение следующей итерации, потом упёрлась в EOF.

## 13. Практические замечания

- В PowerShell введённая строка обычно эхоится самой консолью. Поэтому строка вида `>+12` не значит, что калькулятор распечатал `+12`.
- Для интерактивного калькулятора удобнее вводить одну операцию на строку и нажимать `Enter`.
- `readToken()` в `src/test.txt` уже пропускает `CR`, `LF`, пробел и таб.
- Для char-литералов в генераторе уже есть разбор escape-последовательностей, поэтому `'\n'`, `'\r'`, `'\t'`, `'\\'` и подобные варианты работают корректно.
- Генератор после построения листинга резолвит метки в числовые адреса. Это сделано специально, потому что RemoteTasks-assembler плохо работал с символьными target-метками в переходах и вызовах.

## 14. Что сейчас считать главным источником правды

Если есть расхождение между документами и кодом, верить в таком порядке:

1. `src/TacVm13.target.pdsl`
2. `src/runtime/in.asm` и `src/runtime/out.asm`
3. `src/cfg_builder.c`
4. `tools/remotetasks-run.ps1`
5. готовому `build/*.asm`
6. этой документации

Для быстрой проверки структуры проекта полезно смотреть:

- `build/test_program.asm`
- `build/test_echo.asm`
- `build/test_program.dgml`
- `build/test_echo.dgml`
