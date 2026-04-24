# SPO Lab 3 — итоговый справочник проекта

Этот файл — единая карта проекта: что реализовано, как собирать и запускать программы, как устроены VM/TacVm13, SimpleLang/PDSL, ввод-вывод, инспектор, решения `task2_v71`, и какие ограничения важно помнить.

Справочник сверялся с текущими исходниками и скриптами, а не только со старыми README: `complete/q2_threads.txt`, `complete/*.ps1`, `complete/*.devices.xml`, `src/runtime/*.asm`, `src/cfg_builder.c`, `src/TacVm13.target.pdsl`.

## Быстрый статус

Проект содержит рабочую цепочку:

```text
SimpleLang/PDSL source
-> tools/remote-parser.ps1
-> asm + dgml + sym
-> tools/remotetasks-assemble.ps1
-> ptptb
-> tools/remotetasks-run.ps1 / tools/remotetasks-inspect.ps1
-> результат VM
```

Основная целевая архитектура: `TacVm13`, описание лежит в `src/TacVm13.target.pdsl`.

Подтверждённые рабочие сценарии:

- Smoke-test `src/test_echo.txt`.
- Интерактивный калькулятор `src/test.txt`.
- Лабораторная 5: классы, шаблоны и перегрузки через `src/classTest.txt`.
- Task 2, variant 71, query 1: `complete/q1_query.txt`, `complete/q1_raw200.txt`, `complete/q1_block200.txt`.
- Task 2, variant 71, query 2 threaded: `complete/q2_threads.txt`.

Текущий важный результат: `q2_threads` для варианта 71 работает на 50 строках `N_ВЕДОМОСТИ` и 3 типах ведомостей. Реальный вывод:

```text
1;142400
1;142401
1;142402
#3
```

Время последнего проверенного запуска: около 83 секунд. Файл результата `build/task2_v71/q2_threads.result.txt` имеет 120 байт, то есть 30 символов UTF-32 LE.

## Главные директории

| Путь | Назначение |
|---|---|
| `src/` | Грамматика, генератор, VM-описание, runtime ASM, исходники тестовых программ |
| `src/runtime/` | Низкоуровневые runtime-функции: `in/out`, pipe I/O, block I/O, context switching |
| `src/task2_v71/` | Рабочие и отладочные исходники task2 variant 71 |
| `complete/` | Финальные/готовые сценарии запуска, devices XML и входные данные |
| `complete/data/` | Подготовленные CSV и бинарные входы для task2 |
| `tools/` | Скрипты компиляции/сборки/запуска, RemoteTasks Manager, SpoInspector |
| `build/` | Генерируемые артефакты: `.asm`, `.dgml`, `.sym`, `.ptptb`, результаты |
| `pdf_text/` | Текст, извлечённый из PDF с заданиями и описаниями |
| `lab2_threads_pipe/` | Отдельный threaded pipe пример для другой VM/подхода |

## Главные файлы

| Файл | Назначение |
|---|---|
| `src/SimpleLang.g` | ANTLR-грамматика языка |
| `src/cfg_builder.c` | Основной генератор CFG/TAC/ASM и большая часть codegen-логики |
| `src/main.c` | Точка входа парсера/генератора |
| `src/TacVm13.target.pdsl` | Описание ISA, регистров, памяти и инструкций TacVm13 |
| `src/runtime/in.asm`, `src/runtime/out.asm` | Runtime для hidden `INPUT`/`OUTPUT` |
| `src/runtime/pipe_in*.asm` | Чтение из SimplePipe каналов |
| `src/runtime/pipe_out.asm` | Запись в SimplePipe Output |
| `src/runtime/pipe_typed.asm` | Типизированное чтение byte/half/int/char/string из pipe |
| `src/runtime/pipe_block.asm` | Блочное чтение из pipe |
| `src/runtime/rt_ctx.asm` | Низкоуровневый cooperative context switching, подключается генератором автоматически |
| `src/runtime/rt_threads.asm` | Thread bridge для `funcAddr(taskBody)`, подключается только явно через `-ExtraAsmFiles` |
| `tools/remote-parser.ps1` | Удалённая компиляция SimpleLang в ASM через SSH |
| `tools/remotetasks-assemble.ps1` | Сборка ASM в `.ptptb` через RemoteTasks |
| `tools/remotetasks-run.ps1` | Запуск `.ptptb` через RemoteTasks |
| `tools/remotetasks-inspect.ps1` | Запуск SpoInspector/debugger |
| `tools/SpoInspector/Program.cs` | Инспектор/debugger для lab 4 |
| `Makefile` | Удобные цели `asm`, `assemble`, `run`, `poc-*` |

## Быстрые команды

Все команды ниже запускать из корня репозитория.

### Smoke-test

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remote-parser.ps1 -InputFile .\src\test_echo.txt -AsmOutput .\build\test_echo.asm -ParseTreeOutput .\build\test_echo.dgml
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-assemble.ps1 -AsmListing .\build\test_echo.asm -DefinitionFile .\src\TacVm13.target.pdsl -ArchName TacVm13 -BinaryOutput .\build\test_echo.ptptb
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 -BinaryFile .\build\test_echo.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -RunMode InputFile -InputFile .\build\test_echo.stdin.txt -StdinRegStorage INPUT -StdoutRegStorage OUTPUT -ArchName TacVm13
```

### Lab 5 / classTest

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remote-parser.ps1 -InputFile .\src\classTest.txt -AsmOutput .\build\classTest.asm -ParseTreeOutput .\build\classTest.dgml -RemoteRunTimeoutSeconds 180
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-assemble.ps1 -AsmListing .\build\classTest.asm -DefinitionFile .\src\TacVm13.target.pdsl -ArchName TacVm13 -BinaryOutput .\build\classTest.ptptb
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 -BinaryFile .\build\classTest.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -RunMode InteractiveInput -StdinRegStorage INPUT -StdoutRegStorage OUTPUT -ArchName TacVm13
```

### Через Makefile

```powershell
make asm INPUT_FILE=src/classTest.txt ASM_FILE=build/classTest.asm DGML_FILE=build/classTest.dgml
make assemble INPUT_FILE=src/classTest.txt ASM_FILE=build/classTest.asm DGML_FILE=build/classTest.dgml BINARY_FILE=build/classTest.ptptb
make run INPUT_FILE=src/classTest.txt ASM_FILE=build/classTest.asm DGML_FILE=build/classTest.dgml BINARY_FILE=build/classTest.ptptb RUN_MODE=InteractiveInput
```

## Task 2 variant 71

### Готовые сценарии

| Команда | Что делает |
|---|---|
| `powershell -ExecutionPolicy Bypass -File .\complete\run_q1_50.ps1` | Query 1, бинарный input, 50 строк |
| `powershell -ExecutionPolicy Bypass -File .\complete\run_q1_200.ps1` | Query 1, бинарный input, 200 строк |
| `powershell -ExecutionPolicy Bypass -File .\complete\run_q1_raw200.ps1` | Query 1, raw CSV, 200 строк |
| `powershell -ExecutionPolicy Bypass -File .\complete\run_q1_block200.ps1` | Query 1, block pipe reader, 200 строк |
| `powershell -ExecutionPolicy Bypass -File .\complete\run_q2_mini.ps1` | Мини-тест pipe/output |
| `powershell -ExecutionPolicy Bypass -File .\complete\run_q2_threads.ps1` | Query 2, threaded pipeline, 50 строк |

### Query 2 threaded

Файл программы: `complete/q2_threads.txt`.

Запрос:

```sql
SELECT v.ТВ_ИД, v.ЧЛВК_ИД
FROM Н_ВЕДОМОСТИ v
JOIN Н_ТИПЫ_ВЕДОМОСТЕЙ t ON v.ТВ_ИД = t.ИД
WHERE v.ИД > 1250981
```

Архитектура:

```text
Input0: types.csv  -> typesParser -> qStream(0) -> printer phase 1
Input1: ved.csv    -> vedParser   -> qStream(1) -> printer phase 2 -> Output
```

Потоки:

- `typesParser`: читает `Н_ТИПЫ_ВЕДОМОСТЕЙ` из `Input0`, отправляет `typeId` в `qStream(0)`.
- `vedParser`: читает `Н_ВЕДОМОСТИ` из `Input1`, не фильтрует, отправляет все тройки `id`, `tvId`, `chlvkId` в `qStream(1)`.
- `printer`: сначала собирает таблицу типов в памяти, затем применяет фильтр `id > 1250981`, делает JOIN по `tvId` и печатает `tvId;chlvkId`.

Ключевые детали:

- Используются SPSC ring buffers на 16 элементов через `memLoad`/`memStore`.
- Планировщик cooperative round-robin находится в `main`.
- Для потоков используется автоматически подключаемый `rt_ctx.asm` и явно линкуемый `rt_threads.asm`.
- Результат пишется через SimplePipe Output в UTF-32 LE.
- Текущий вход: 3 типа ведомостей и 50 строк ведомостей.
- Для полного варианта можно поднять `while (rows < 50)` до `while (rows < 200)` и заменить Input1 в `complete/q2_threads.devices.xml` на `complete/data/q1.ved200.csv`; запуск будет заметно дольше.

Текущие входные файлы из `complete/data/`:

| Файл | Размер | Для чего |
|---|---:|---|
| `q1.types200.csv` | 644 байта | Input0 для типов, кратен 4 |
| `q1.ved50.csv` | 9704 байта | Input1 для текущего `q2_threads`, кратен 4 |
| `q1.ved200.csv` | 38144 байта | Input1 для полного/200-row варианта, дополнен до кратности 256 для block-чтения |
| `q1.bin50.dat` | 604 байта | Бинарный input q1 50 |
| `q1.bin200.dat` | 2404 байта | Бинарный input q1 200 |

Ручной запуск `q2_threads`:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remote-parser.ps1 `
  -InputFile .\complete\q2_threads.txt `
  -AsmOutput .\build\task2_v71\q2_threads.asm `
  -ParseTreeOutput .\build\task2_v71\q2_threads.dgml

powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-assemble.ps1 `
  -AsmListing .\build\task2_v71\q2_threads.asm `
  -ExtraAsmFiles .\src\runtime\rt_threads.asm `
  -DefinitionFile .\src\TacVm13.target.pdsl `
  -ArchName TacVm13 `
  -BinaryOutput .\build\task2_v71\q2_threads.ptptb `
  -SkipInspectorEmbed

powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 `
  -BinaryFile .\build\task2_v71\q2_threads.ptptb `
  -DefinitionFile .\src\TacVm13.target.pdsl `
  -DevicesFile .\complete\q2_threads.devices.xml `
  -RunMode WithIo `
  -ArchName TacVm13
```

Прочитать UTF-32 LE результат:

```powershell
$raw = [System.IO.File]::ReadAllBytes("build\task2_v71\q2_threads.result.txt")
[System.Text.Encoding]::UTF32.GetString($raw)
```

## Скрипты и параметры

### `tools/remote-parser.ps1`

Компилирует SimpleLang/PDSL source в ASM и DGML через удалённую Linux-среду.

Основные параметры:

- `-InputFile`: исходный `.txt`.
- `-AsmOutput`: путь для `.asm`.
- `-ParseTreeOutput`: путь для `.dgml`.
- `-ParseOnly`: только распарсить.
- `-DebugProgress`: включить прогресс генератора.
- `-ProgressOutput`: скачать progress log.
- `-RemoteRunTimeoutSeconds`: timeout удалённого запуска, полезно для длинных программ.
- `-RemoteHost`, `-RemotePort`, `-RemoteUser`, `-RemotePassword`: SSH-доступ.

По умолчанию используется `localhost:5555`, пользователь `user`, пароль `student`.

### `tools/remotetasks-assemble.ps1`

Собирает ASM в `.ptptb` через RemoteTasks `Assemble`.

Основные параметры:

- `-AsmListing`: входной `.asm`.
- `-ExtraAsmFiles`: дополнительные ASM-файлы для линковки, можно передавать список или `;`-разделённую строку.
- `-DefinitionFile`: PDSL-описание VM.
- `-ArchName`: обычно `TacVm13`.
- `-BinaryOutput`: выходной `.ptptb`.
- `-SkipInspectorEmbed`: не встраивать debug metadata.
- `-TaskTimeoutSeconds`: timeout сборки.
- `-PollIntervalSeconds`: интервал polling.

Важно: скрипт удаляет старый `.ptptb` перед сборкой, чтобы не запустить случайно старый бинарник.

### `tools/remotetasks-run.ps1`

Запускает `.ptptb`.

Основные параметры:

- `-BinaryFile`: бинарник.
- `-DefinitionFile`: VM definition.
- `-DevicesFile`: XML устройств для `WithIo`.
- `-RunMode`: `InteractiveInput`, `InputFile`, `WithIo`.
- `-InputFile`: файл stdin для `InputFile`.
- `-StdinRegStorage`: обычно `INPUT`.
- `-StdoutRegStorage`: обычно `OUTPUT`.
- `-ArchName`: обычно `TacVm13`.

Режимы:

- `InteractiveInput`: hidden `INPUT/OUTPUT`, ручной ввод.
- `InputFile`: hidden `INPUT/OUTPUT`, ввод из файла.
- `WithIo`: устройства из `devices.xml`, нужен для SimplePipe.

### `tools/remotetasks-inspect.ps1`

Запускает SpoInspector/debugger.

Основные параметры:

- `-BinaryFile`: `.ptptb`.
- `-DefinitionFile`: PDSL VM.
- `-RunMode`: `plain`, `inputfile`, `withio`.
- `-InputFile`: файл ввода для `inputfile`.
- `-DevicesFile`: XML устройств для `withio`.
- `-Script`: файл команд инспектора.

Полезные команды в REPL: `regs`, `disas`, `step`, `nextsrc`, `line`, `locals`, `bt`, `bline`, `dline`, `breaks`, `cont`, `quit`.

## TacVm13 VM

### Память

Основной банк:

```text
ram [0x00000000 .. 0x000FFFFF]
```

Свойства:

- Размер около 1 MiB.
- Байтовая адресация.
- Little-endian.
- Код и данные находятся в одном `ram`.

### Регистры

Основные:

- `r0..r28`
- `fp = r29`
- `sp = r30`
- `r31`

Служебные storage:

- `ip`
- `cmp_result`
- `INPUT[8]`
- `OUTPUT[8]`

Важно:

- `r0` не является аппаратным нулём.
- Ветвления используют `cmp_result`.
- Инструкции фиксированного размера: 8 байт.

### Bootstrap

Генератор добавляет стартовый код:

```asm
start:
    mov     sp, #1040000
    mov     fp, sp
    mov     r5, #180000
    mov     r6, #180004
    mov     [r5 + 0], r6
    call    main
    halt
```

Смысл:

- Стек стартует сверху RAM.
- `180000` хранит heap pointer.
- `180004` — старт heap.
- Heap инициализируется всегда.

### Calling convention

- Аргументы кладутся в стек справа налево.
- Возврат функции — в `r1`.
- Caller чистит стек после `call`.

Обычный пролог:

```asm
push    fp
mov     fp, sp
sub     sp, sp, #<local_size>
```

Обычный эпилог:

```asm
add     sp, sp, #<local_size>
pop     fp
ret
```

Кадр:

```text
[fp + 0]   old fp
[fp + 4]   return address
[fp + 8]   arg1
[fp + 12]  arg2
[fp - 4]   local1
[fp - 8]   local2
```

### Устройства SimplePipe

Карта каналов:

| Канал | Control base | SyncReceive / SyncSend |
|---|---:|---:|
| default input | `1000032` | SyncReceive `1000040` |
| Output | `1000032` | SyncSend `1000032` |
| Input0 | `196608` | SyncReceive `196616` |
| Input1 | `200704` | SyncReceive `200712` |
| Input2 | `204800` | SyncReceive `204808` |

`mov r, [SyncReceive]` читает 4 байта и блокируется, если данных нет. `pipeOut` пишет в Output через `mov [1000032], value`.

## SimpleLang/PDSL язык

### Поддерживаемые типы

Грамматика знает builtin-типы:

- `bool`
- `byte`
- `int`
- `uint`
- `long`
- `ulong`
- `char`
- `string`
- `void`

На практике наиболее проверены:

- `int`
- `byte`
- `bool`
- `char`
- массивы `int[]`, `byte[]`
- пользовательские классы
- шаблонные классы вроде `List<T>`

Особенности памяти:

- `int` занимает 4 байта.
- `byte` занимает 1 байт.
- `byte[]` имеет stride 1.
- `int[]` имеет stride 4.
- Локальные массивы выделяются в heap, локальная переменная хранит указатель.
- Локальные пользовательские объекты получают место в stack frame.

### Поддерживаемые конструкции

Подтверждено рабочими тестами:

- Функции и forward declarations.
- Аргументы функций.
- `return`.
- `if / else`.
- `while`.
- `do while`.
- `break`, `continue`.
- Массивы.
- Вызовы функций.
- Классы.
- Поля и методы.
- `public` / `private` в грамматике.
- Одиночное наследование в грамматике/модели.
- Шаблонные классы.
- Перегрузка функций и методов по сигнатуре.
- Возврат объектов из функций.
- Member access через `obj.field` / `this.field`.

### Операторы

Грамматика поддерживает:

- Присваивание: `=`.
- Логические: `||`, `&&`, `!`.
- Сравнения: `==`, `!=`, `<`, `>`, `<=`, `>=`.
- Арифметика: `+`, `-`, `*`, `/`, `%`.
- Битовые: `&`, `|`, `^`, `~`, `<<`, `>>`.
- Постфиксные вызовы: `f(...)`, `arr[i]`, `obj.field`.

Практическое правило: сложные выражения лучше разбивать на несколько простых присваиваний. Это не эстетика, а защита от багов генератора.

### Literals

Поддерживаются:

- Decimal: `123`.
- Hex: `0x7B`.
- Binary: `0b1111011`.
- Char: `'A'`, `'\n'`.
- String: `"text"`.
- Bool: `true`, `false`.

## Runtime API

### Hidden stdin/stdout

```c
int in();
void out(int value);
```

Используется с `RunMode InputFile` или `RunMode InteractiveInput`, через `INPUT` и `OUTPUT`.

### SimplePipe word I/O

```c
int pipeIn();
int pipeIn0();
int pipeIn1();
int pipeIn2();
void pipeOut(int value);
```

`pipeInX()` читает 4 байта за раз. `pipeOut(value)` пишет байт/символ в Output SimplePipe.

### Typed pipe I/O

Из `src/runtime/pipe_typed.asm`:

```c
int pipeTypedReadInt0();
int pipeTypedReadByte0();
int pipeTypedReadHalf0();
int pipeTypedReadUnit0(int n);
int pipeTypedReadChar0();
int pipeTypedReadAsciiInt0();
int pipeTypedReadString0(int delim, int buf_addr, int max_len);
```

Есть варианты без суффикса, с `0`, `1`, `2`.

Семантика:

- `ReadByte`: читает ровно 1 байт через `movb`.
- `ReadHalf`: читает 2 байта little-endian через `movh`.
- `ReadInt`: читает 4 байта через `mov`.
- `ReadUnit(n)`: `n` должен быть `1`, `2` или `4`.
- `ReadChar`: читает UTF-8 code point.
- `ReadAsciiInt`: читает ASCII decimal integer.
- `ReadString`: читает до delimiter/newline.

### Block pipe I/O

Из `src/runtime/pipe_block.asm` labels не типизированы на уровне ASM; тип массива задаётся декларацией в `.txt` программе:

```c
int pipeBlockRead(int[] buf, int n);
int pipeBlockRead0(int[] buf, int n);
int pipeBlockRead1(int[] buf, int n);
int pipeBlockRead2(int[] buf, int n);

int pipeBlockReadFast(int[] buf, int n);
int pipeBlockReadFast0(int[] buf, int n);
int pipeBlockReadFast1(int[] buf, int n);
int pipeBlockReadFast2(int[] buf, int n);
```

Для `byte[]` в текущей PDSL-практике используется такая декларация, как в `complete/q1_block200.txt`:

```c
int pipeBlockReadFast1(byte[] buf, int n);
```

Правило безопасности: если читается ровно `n` байт блоком, input file должен иметь достаточно данных. Если файл закончится раньше, VM зависнет на blocking read. Для block-режима часто нужно padding до кратности блока.

### Memory builtins

```c
int memLoad(int addr);
void memStore(int addr, int value);
int memLoadByte(int addr);
int memLoadHalf(int addr);
int funcAddr(symbol);
```

Используются для ручных структур данных, SPSC queues, таблиц и function pointers.

### Thread/context runtime

Из `rt_ctx.asm`:

```c
void ctxInit();
void ctxReset();
void ctxCreate(int func_addr, int arg);
void ctxDispatch(int to_idx);
void ctxYield();
void ctxExit();
int ctxCurrentTask();
```

Для программ с `funcAddr(taskBody)` нужно линковать:

```powershell
-ExtraAsmFiles .\src\runtime\rt_threads.asm
```

Причина: `rt_threads.asm` содержит мост `taskBody: jmp global_taskBody_1_int`. Для программ без `taskBody` этот файл специально не подключается автоматически, иначе ломалась бы линковка.

## Формат входов и выходов task2

### CSV через SimplePipe

SimplePipe отдаёт байты, но word read потребляет 4 байта. Если код читает через `pipeInX()`, важно:

- Размер файла желательно делать кратным 4 байтам.
- Если в конце файла остаётся 1-3 байта, blocking `mov` может зависнуть.
- Количество строк в `while (rows < N)` должно быть не больше реального числа строк.

### Output

В `q1/q2` вывод часто пишется через `pipeOut`, а результат получается UTF-32 LE, потому что каждый символ записан как 32-битное значение.

Чтение:

```powershell
$raw = [System.IO.File]::ReadAllBytes("build\task2_v71\q2_threads.result.txt")
[System.Text.Encoding]::UTF32.GetString($raw)
```

Формат `q2_threads`:

```text
<tvId>;<chlvkId>
...
#<count>
```

`#N` — маркер корректного завершения и количество найденных строк.

## Карта памяти `q2_threads`

| Диапазон/адрес | Назначение |
|---:|---|
| `500000` | `SCHED_STATE[0]`, текущий thread index |
| `500004` | `SCHED_STATE[1]`, thread count |
| `502000..502031` | TCB array: `saved_sp`, `status` |
| `600000` | Зарезервированный scheduler stack |
| `602048..604095` | Stack thread 1 / `typesParser` |
| `604096..606143` | Stack thread 2 / `vedParser` |
| `606144..608191` | Stack thread 3 / `printer` |
| `760000` | `typesCount` |
| `760004+` | Таблица typeId |
| `810000..810079` | `qStream(0)` buffer/head/tail/count/closed |
| `811024..811103` | `qStream(1)` buffer/head/tail/count/closed |
| `196608+` | Input0 SimplePipe |
| `200704+` | Input1 SimplePipe |
| `1000032+` | Output SimplePipe |

## Производительность

Наблюдения:

- VM медленная: ориентировочно тысячи инструкций в секунду, не миллионы.
- В этой модели главный ресурс — количество инструкций, а не реальные memory/device latencies.
- `q2_mini`: около 2.2 секунды.
- `q2_threads` на 50 строках: около 83 секунд.
- `q1_raw200`: около 258 секунд.
- `q1_block200`: около 293 секунд.
- `q2_threads` на 200 строках ожидаемо может занимать несколько минут.

Почему block read не всегда быстрее:

- `pipeBlockReadFast` снижает количество device reads.
- Но добавляет распаковку, состояние буфера и вызовы функций.
- В TacVm13 все инструкции стоят примерно одинаково, поэтому лишние инструкции могут съесть выигрыш.

Фактическая разница в текущих версиях: `q1_raw200.txt` читает через `pipeIn1()` и распаковывает байты битовыми `& 255` / `>> 8`, а `q1_block200.txt` читает блоками по 256 байт через `pipeBlockReadFast1(byte[] buf, 256)`.

## Известные баги компилятора и обходы

### 1. `memStore(ADDR, memLoad(ADDR) + 1)` клобберит адрес

Плохо:

```c
memStore(770000, memLoad(770000) + 1);
```

Хорошо:

```c
int cnt = 0;
cnt = memLoad(770000);
cnt = cnt + 1;
memStore(770000, cnt);
```

### 2. `memStore(ADDR, localVar + N)` тоже может клобберить адрес

Плохо:

```c
memStore(760000, typesCount + 1);
```

Хорошо:

```c
typesCount = typesCount + 1;
memStore(760000, typesCount);
```

### 3. Сложные адреса в `memLoad`/`memStore` опасны

Плохо:

```c
return memLoad(502000 + i * 8 + 4);
```

Хорошо:

```c
int addr = 0;
int off = 0;
addr = 502000;
off = i * 8;
addr = addr + off;
addr = addr + 4;
return memLoad(addr);
```

### 4. `if (funcCall() != N)` может игнорировать вызов

Плохо:

```c
if (taskStateOf(idx + 1) != 3) {
    return idx;
}
```

Хорошо:

```c
int st = 0;
st = taskStateOf(idx + 1);
if (st == 3) {
} else {
    return idx;
}
```

### 5. Builtin names затеняют пользовательские функции

Не называй свои функции так:

```text
taskState
setTaskState
taskArrival
setTaskArrival
taskBurst
setTaskBurst
taskRemaining
setTaskRemaining
taskCompletion
setTaskCompletion
schedQueueHead
setSchedQueueHead
schedQueueTail
setSchedQueueTail
schedQueueCount
setSchedQueueCount
queueEntry
setQueueEntry
```

Используй имена вроде `tcbState`, `taskStateOf`, `queueEntryAt`.

### 6. Mid-function declarations ломают offsets

Пиши в C89-стиле: все локальные переменные объявлять в начале функции.

Плохо:

```c
int f() {
    doSomething();
    int x = 0;
    return x;
}
```

Хорошо:

```c
int f() {
    int x = 0;
    doSomething();
    return x;
}
```

### 7. `return arr[pos]`

Этот баг был исправлен в `src/cfg_builder.c`: раньше возвращался pointer, а не элемент. Если симптом вернётся, проверять RETURN postfix handling.

## Практический стиль безопасного PDSL

Писать лучше так:

- Все locals объявлять в начале функции.
- Любой сложный адрес считать пошагово.
- Результат function call перед сравнением класть в local.
- Избегать `!=` вокруг вызовов; часто проще инвертировать через `==`.
- Не вкладывать `memLoad` внутрь `memStore`.
- Не передавать `funcAddr(...)` напрямую в multi-arg call; сначала сохранить в local.
- Проверять generated ASM, если программа зависла или печатает нули.
- Для CSV всегда проверять размер файла и кратность чтения.

## Отладка

### Если программа зависла

Проверить по порядку:

1. Есть ли свежий `.ptptb`, не остался ли старый.
2. Не завис ли `Portable.RemoteTasks.Manager.exe` от прошлого запуска.
3. Корректен ли `devices.xml`.
4. Достаточно ли байт во входных файлах.
5. Кратно ли 4 байтам чтение через `pipeInX`.
6. Не превышает ли `rows < N` реальное количество строк.
7. Нет ли опасных паттернов `memStore/memLoad/if(funcCall)`.
8. Есть ли нужный `-ExtraAsmFiles .\src\runtime\rt_threads.asm` для threads.

### Посмотреть процессы RemoteTasks

```powershell
Get-Process | Where-Object { $_.Path -like '*Portable.RemoteTasks.Manager.exe' }
```

Остановить локально зависшие менеджеры:

```powershell
Get-Process | Where-Object { $_.Path -like '*Portable.RemoteTasks.Manager.exe' } | Stop-Process -Force
```

### Проверить ASM

```powershell
rg -n "^global_functionName|memLoad|memStore|call" build\task2_v71\q2_threads.asm
```

Особенно смотреть:

- Есть ли `call` перед сравнением результата функции.
- Не перезатирается ли `r2` между вычислением адреса и `mov [r2+0], ...`.
- Не заменена ли пользовательская функция builtin-обращением.

## RemoteTasks Manager

Используется `tools/RemoteTasks/Portable.RemoteTasks.Manager.exe`.

Подтверждённые remote tasks:

- `Assemble`
- `ExecuteBinaryWithInteractiveInput`
- `ExecuteBinaryWithInput`
- `ExecuteBinaryWithIo`

Вручную обычно не нужен: пользоваться `tools/remotetasks-assemble.ps1` и `tools/remotetasks-run.ps1`.

Если нужно посмотреть список задач:

```powershell
tools\RemoteTasks\Portable.RemoteTasks.Manager.exe -sslcfg tools\RemoteTasks\ssl-cfg.yaml -ul 505979 -up 9d7a3ade-42cd-4693-85e6-5367bbe31597 -l 0
```

## Документы проекта

| Файл | Что читать |
|---|---|
| `README.md` | Короткая карта проекта |
| `TESTING.md` | Проверочные сценарии |
| `VIRTUAL_MACHINE.md` | Подробности TacVm13 |
| `REMOTE_TASKS_MANAGER.md` | Памятка по RemoteTasks |
| `INSPECTOR.md` | Инспектор/debugger |
| `LAB5.md` | Лабораторная 5 |
| `programm.md` | Состояние языка и генератора |
| `complete/README.md` | Готовые q1-сценарии |
| `complete/q2_threads.README.md` | Подробности threaded q2 |
| `complete/PIPE_BLOCK_API.md` | Block pipe API |
| `complete/CHANGES_TYPED_IO.md` | Изменения typed I/O и bit ops |

## Источник правды

Если документы расходятся с кодом, верить в таком порядке:

1. `src/TacVm13.target.pdsl`
2. `src/cfg_builder.c`
3. `src/runtime/*.asm`
4. `tools/*.ps1`
5. Реально сгенерированному `build/*.asm`
6. Готовым сценариям в `complete/`
7. Этому справочнику

## Мини-чеклист перед сдачей

- `complete/run_q2_threads.ps1` проходит и печатает ожидаемый `#3`.
- В `complete/q2_threads.txt` выставлено нужное количество строк (`50` или `200`).
- `complete/q2_threads.devices.xml` указывает на нужные CSV.
- Входные CSV не обрываются на некратном чтении.
- Для threaded-сборки есть `-ExtraAsmFiles src\runtime\rt_threads.asm`.
- Результат декодируется как UTF-32 LE.
- В финальном ответе указано время выполнения и фактический вывод.
