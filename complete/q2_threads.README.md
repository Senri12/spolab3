# q2_threads — Вариант 71, Задание 2

3-поточный pipeline на TacVm13 VM, выполняющий SQL-подобный запрос к двум CSV-файлам через software-каналы (SPSC ring buffers) и **кооперативную многозадачность с пассивным ожиданием** (BLOCKED state, wait reasons, sync + async API).

## Модель синхронизации

Поток никогда не «крутится» в ожидании — он переходит в `BLOCKED` (status = 4) и сохраняет в parallel-массиве `WAIT_REASON_BASE = 503000` (4 байта на поток) причину сна. Когда другой поток выполняет `ctxWake(reason)`, все BLOCKED-потоки с совпадающим reason переводятся обратно в `READY` (1).

Encoding wait reasons (см. [q2_threads.txt](q2_threads.txt) → `streamReadReason` / `streamWriteReason`):

| Reason | Что ждёт |
|--------|----------|
| 1 | данные в qStream(0) (читатель) |
| 2 | свободное место в qStream(0) (писатель) |
| 3 | данные в qStream(1) (читатель) |
| 4 | свободное место в qStream(1) (писатель) |

Планировщик `nextRunnable()` выбирает только потоки в `READY` — `DONE` и `BLOCKED` пропускаются. Если ни одного `READY` нет, а `done < 3` — это deadlock, программа печатает `!` в Output и завершается с кодом 1.

API в q2_threads:
- **Sync (блокирующее):** `qStreamWrite(s, v)`, `qStreamRead(s) -> -1 при closed-empty`
- **Async (вариант 71 spec):** `qStreamWriteAsync(s, v) -> 1 / 0`, `qStreamReadAsync(s) -> v / -1 closed / -2 would-block`
- **Close:** `qStreamClose(s)` — помечает поток закрытым и будит **всех** ждущих читателей и писателей.

Runtime-примитивы (rt_ctx.asm):
- `ctxBlock(reason)` — сохраняет yield-frame, ставит TCB.status=4, сохраняет reason, переключается на планировщика.
- `ctxWake(reason)` — итерирует TCBs 1..thread_count, переводит BLOCKED+matching → READY и обнуляет reason. Не переключает потоки.
- `ctxIsBlocked(idx)` — диагностика.

## Запрос

```sql
SELECT v.ТВ_ИД, v.ЧЛВК_ИД
FROM Н_ВЕДОМОСТИ v
JOIN Н_ТИПЫ_ВЕДОМОСТЕЙ t ON v.ТВ_ИД = t.ИД
WHERE v.ИД > 1250981
```

Фильтр и JOIN выполняются потоково, без буферизации всех строк в памяти.

## Архитектура

```
┌─────────────┐   qStream(0) ┌──────────┐
│ Input0      │──────────────▶│ printer  │
│ types.csv   │              │          │
│ (thread 0)  │              │ Phase 1: │
│ typesParser │              │ accumul  │
└─────────────┘              │ types →  │
                             │ [760004+]│
┌─────────────┐   qStream(1) │          │    ┌─────────┐
│ Input1      │──────────────▶│ Phase 2: │───▶│ Output  │
│ ved.csv     │              │ JOIN →   │    │ result  │
│ (thread 1)  │              │ printRow │    │ .txt    │
│ vedParser   │              │ count++  │    └─────────┘
└─────────────┘              └──────────┘
                              (thread 2)
```

- **typesParser** (thread 0) — читает N_ТИПЫ_ВЕДОМОСТЕЙ из Input0, шлёт typeId в qStream(0), закрывает поток.
- **vedParser** (thread 1) — читает 50 строк N_ВЕДОМОСТИ из Input1, шлёт тройки (id, tvId, chlvkId) в qStream(1).
- **printer** (thread 2) — в Phase 1 сохраняет все typeId в таблицу в памяти; в Phase 2 читает тройки из qStream(1), фильтрует `id > 1250981`, делает JOIN по `tvId`, выводит `tvId;chlvkId\n` в SimplePipe Output.

## Файлы проекта

| Файл | Назначение |
|------|-----------|
| [complete/q2_threads.txt](q2_threads.txt) | Исходник PDSL — три функции-потока + main-диспетчер |
| [complete/q2_threads.devices.xml](q2_threads.devices.xml) | Конфигурация устройств: Input0, Input1, Output как SimplePipe |
| [complete/run_q2_threads.ps1](run_q2_threads.ps1) | PowerShell-раннер: компайл → ассембл (с rt_threads.asm) → запуск |
| [complete/data/q1.types200.csv](data/q1.types200.csv) | Входные данные — 3 типа ведомостей (644 байт, mod 4 = 0) |
| [complete/data/q1.ved50.csv](data/q1.ved50.csv) | Входные данные — 50 строк ведомостей (9704 байт, mod 4 = 0) |
| [build/task2_v71/q2_threads.asm](../build/task2_v71/q2_threads.asm) | Сгенерированный ассемблер (результат step 1) |
| [build/task2_v71/q2_threads.ptptb](../build/task2_v71/q2_threads.ptptb) | Скомпилированный бинарь (результат step 2) |
| [build/task2_v71/q2_threads.result.txt](../build/task2_v71/q2_threads.result.txt) | Вывод программы в UTF-32 LE |

## Запуск

### Полный раннер

```powershell
& complete\run_q2_threads.ps1
```

Выполняет три шага последовательно:
1. **Compile** (remote-parser.ps1) — генерирует `.asm` из `.txt` через удалённый парсер (SSH → localhost:5555 → gcc + cfg_builder.c на сервере)
2. **Assemble** (remotetasks-assemble.ps1) — Portable.RemoteTasks.Manager.exe шлёт `.asm` + `rt_threads.asm` на сервер через SSL, получает `.ptptb`
3. **Run** (remotetasks-run.ps1) — Manager.exe запускает бинарь в режиме `WithIo`, I/O маппится на файлы из devices.xml

Типичное время: ~90 секунд (из них ~80с — сама VM).

### Пошаговый запуск

```powershell
# Шаг 1: компайл
& tools\remote-parser.ps1 `
    -InputFile "complete\q2_threads.txt" `
    -AsmOutput "build\task2_v71\q2_threads.asm" `
    -ParseTreeOutput "build\task2_v71\q2_threads.dgml"

# Шаг 2: ассембл (ОБЯЗАТЕЛЬНО -ExtraAsmFiles с rt_threads.asm — иначе taskBody-мост не резолвится)
& tools\remotetasks-assemble.ps1 `
    -AsmListing "build\task2_v71\q2_threads.asm" `
    -ExtraAsmFiles "src\runtime\rt_threads.asm" `
    -DefinitionFile "src\TacVm13.target.pdsl" `
    -ArchName TacVm13 `
    -BinaryOutput "build\task2_v71\q2_threads.ptptb" `
    -SkipInspectorEmbed

# Шаг 3: запуск
& tools\remotetasks-run.ps1 `
    -BinaryFile "build\task2_v71\q2_threads.ptptb" `
    -DefinitionFile "src\TacVm13.target.pdsl" `
    -DevicesFile "complete\q2_threads.devices.xml" `
    -RunMode WithIo `
    -ArchName TacVm13

# Прочитать результат (файл в UTF-32 LE)
$raw = [System.IO.File]::ReadAllBytes("build\task2_v71\q2_threads.result.txt")
[System.Text.Encoding]::UTF32.GetString($raw)
```

## Параметры и настройки

### В исходнике `q2_threads.txt`

| Место | Что меняется | Текущее значение |
|-------|-------------|------------------|
| `vedParser` → `while (rows < 50)` | Число читаемых строк ведомостей | 50 |
| `vedParser` → `if (id > 1250981)` | Фильтр | id > 1250981 |
| `typesParser` → `while (rows < 3)` | Число читаемых типов | 3 |

**Важно:** при смене CSV проверь:
- Размер файла должен быть **кратен 4 байтам** (SimplePipe читает 32-битными словами и блокируется на EOF, если остаток < 4 байт). Паддить пустой строкой: `printf '\n\n' >> file.csv`
- Количество строк в коде (`rows < N`) должно быть ≤ числа данных в CSV — иначе vedParser зависнет на `pipeIn1()` ожидая следующее слово.

### В `q2_threads.devices.xml`

| Устройство | Имя | Адрес | PipeSpec параметр | Назначение |
|-----------|-----|-------|-------------------|------------|
| SimplePipe | `Input0` | 196608 (ctrl) / 196616 (SyncReceive) | `fifo:in:complete/data/q1.types200.csv:out:src/task2_v71/q2.threads.unused_0.out.txt` | Чтение types CSV через `pipeIn0()` |
| SimplePipe | `Input1` | 200704 (ctrl) / 200712 (SyncReceive) | `fifo:in:complete/data/q1.ved50.csv:out:src/task2_v71/q2.threads.unused_1.out.txt` | Чтение ved CSV через `pipeIn1()` |
| SimplePipe | `Output` | 1000032 (ctrl, SyncSend) | `fifo:in:src/task2_v71/raw_pipe.empty.in:out:build/task2_v71/q2_threads.result.txt` | Вывод результата через `pipeOut(byte)` |

Чтобы запустить на других входных данных:
```xml
<Parameter Name="PipeSpec" Value="fifo:in:path/to/your/types.csv:out:..." />
<Parameter Name="PipeSpec" Value="fifo:in:path/to/your/veds.csv:out:..." />
```

### CLI-параметры run-скрипта

`run_q2_threads.ps1` параметров не принимает — жёстко зашиты пути. Для изменения редактируй переменные в начале файла.

`remotetasks-run.ps1` поддерживает режимы:
- `-RunMode WithIo` — используется devices.xml, I/O маппится на файлы (используем мы)
- `-RunMode InputFile` — stdin/stdout через ОС-файлы и регистры (для программ с raw `out` инструкцией, напр. `src/6.txt`)
- `-RunMode InteractiveInput` — интерактивный stdin

## Формат входных данных

### types.csv (N_ТИПЫ_ВЕДОМОСТЕЙ)

UTF-8 с BOM (EF BB BF), заголовок + 3 строки. Поля разделены `;`. Первое поле — ИД типа (int).

Пример:
```
"ИД";"НАИМЕНОВАНИЕ";"ISU_UCHEB";...
1;"Ведомость";ISU_UCHEB;2011-11-08 15:55:56.000;...
2;"Экзаменационный лист";ISU_UCHEB;...
3;"Перезачет";ISU_UCHEB;...
```

### ved.csv (N_ВЕДОМОСТИ)

UTF-8 с BOM, заголовок + ≥50 строк. Минимум 8 полей (парсер пропускает поля 3-7):

| Колонка | Имя | Читается как |
|---------|-----|--------------|
| 1 | ИД | `id` (int, для фильтра) |
| 2 | ЧЛВК_ИД | `chlvkId` (int, выводится) |
| 3-7 | НОМЕР, ОЦЕНКА, СРОК, ДАТА, СЕС_ИД | skip (5 полей) |
| 8 | ТВ_ИД | `tvId` (int, для JOIN) |
| 9+ | остальные | skipLine |

## Формат выхода

Каждый выведенный символ — 4 байта UTF-32 LE. Декодировать в PowerShell:
```powershell
$raw = [System.IO.File]::ReadAllBytes("build\task2_v71\q2_threads.result.txt")
[System.Text.Encoding]::UTF32.GetString($raw)
```

Формат текста:
```
<tvId>;<chlvkId>
<tvId>;<chlvkId>
...
#<count>
```

Последняя строка `#N` — количество совпавших строк (служит маркером корректного завершения).

Пример реального вывода на 50 строках:
```
1;142400
1;142401
1;142402
#3
```

## Карта памяти VM

| Диапазон | Назначение |
|---------|-----------|
| 500000 | SCHED_STATE[0] = current_thread_idx |
| 500004 | SCHED_STATE[1] = thread_count |
| 502000-502031 | TCB array (4 × 8 байт): +0 saved_sp, +4 status (0 free, 1 ready, 2 running, 3 done, **4 blocked**) |
| 503000-503015 | WAIT_REASON array (4 × 4 байт): причина BLOCKED-сна каждого потока |
| 600000 | TCB[0] stack (scheduler) — не используется, но зарезервирован |
| 602048-604095 | Thread 1 stack (typesParser) |
| 604096-606143 | Thread 2 stack (vedParser) |
| 606144-608191 | Thread 3 stack (printer) |
| 760000 | `typesCount` — число записанных типов |
| 760004+ | Таблица типов (int[typesCount]) |
| 810000-810079 | qStream(0) [types → printer]: buffer[0..15] + head(64) + tail(68) + count(72) + closed(76) |
| 811024-811103 | qStream(1) [veds → printer] |
| 196608+ | Input0 SimplePipe (types CSV) |
| 200704+ | Input1 SimplePipe (ved CSV) |
| 1000032+ | Output SimplePipe |

## Системные зависимости

### Runtime ASM-файлы, которые линкуются

Автоматически через `cfg_builder.c:append_runtime_asm()` (см. `src/cfg_builder.c:6373`):
- `in.asm`, `out.asm` — CPU-уровень I/O (не используется в q2_threads, но включено)
- `pipe_in.asm`, `pipe_in0.asm`, `pipe_in1.asm`, `pipe_in2.asm` — blocking read from SimplePipe channels
- `pipe_out.asm` — blocking write to SimplePipe SyncSend
- `pipe_typed.asm`, `pipe_block.asm` — альтернативные API (типизированные / блочные)
- `timer.asm` — `initTimer`, `waitForTick` (для IRQ-based планирования, не используется)
- `rt_ctx.asm` — **критичный**: `ctxInit`, `ctxCreate`, `ctxDispatch`, `ctxYield`, `ctxExit`, `ctxBlock`, `ctxWake`, `ctxIsBlocked`

Явно через `-ExtraAsmFiles`:
- `rt_threads.asm` — `rtCreateThread`, `rtExitThread`, **мост `taskBody: jmp global_taskBody_1_int`**. Обязателен при использовании `funcAddr(taskBody)`.

**Почему rt_threads.asm вынесен?** В нём есть безусловный `jmp global_taskBody_1_int`, требующий наличия функции `taskBody(int)` в исходнике. Для программ без threads (например `src/6.txt`) это вызывало ошибку линковки. После нашего фикса в `src/cfg_builder.c` файл больше не авто-включается, и программы с threads должны его линковать явно.

### Используемые внешние функции (declare `void foo();`)

```c
// Context switching (rt_ctx.asm)
void ctxInit();               // init scheduler state
void ctxReset();              // reset thread_count to 0
void ctxCreate(int func_addr, int arg);   // allocate thread
void ctxDispatch(int to_idx); // scheduler → thread, blocks until yield/exit/block
void ctxYield();              // thread → scheduler (status = READY)
void ctxExit();               // thread done, never returns
int ctxCurrentTask();         // returns current_thread_idx - 1

// Passive blocking primitives (rt_ctx.asm)
void ctxBlock(int reason);    // thread → scheduler (status = BLOCKED, reason saved)
void ctxWake(int reason);     // wake all BLOCKED threads with matching reason
int  ctxIsBlocked(int idx);   // diagnostic: 1 if TCB[idx].status == BLOCKED

// SimplePipe I/O (pipe_in0.asm, pipe_in1.asm, pipe_out.asm)
int pipeIn0();                // blocking read 4 bytes (packed LE) from Input0
int pipeIn1();                // blocking read 4 bytes from Input1
void pipeOut(int value);      // blocking write to Output SyncSend

// Memory primitives (builtins in cfg_builder.c)
int memLoad(int addr);
void memStore(int addr, int value);

// Function-pointer (builtin)
int funcAddr(symbol);         // returns address of named function
```

## Использование в коде — паттерны

### Software SPSC ring buffer + пассивная синхронизация

Каждый поток имеет 16-слотовый буфер в фиксированной области памяти (810000 для stream 0, 811024 для stream 1). Для single-producer single-consumer нет гонок при кооперативном переключении — writer меняет только tail, reader только head.

```c
qStreamInit(0);                 // init buffer layout

// Sync (passive blocking):
qStreamWrite(0, value);         // count==16 → ctxBlock(2); woken когда reader читает
int v = qStreamRead(0);         // count==0 && !closed → ctxBlock(1); -1 при closed-empty

// Async (returns immediately):
int ok = qStreamWriteAsync(0, value);   // 1 written, 0 would-block
int v  = qStreamReadAsync(0);           // value / -1 closed / -2 would-block

qStreamClose(0);                // mark closed + ctxWake всех ждущих
```

Производитель после успешной записи делает `ctxWake(readReason)` → если читатель был BLOCKED, его статус становится READY, и планировщик возьмёт его следующим. Симметрично читатель будит писателя через `ctxWake(writeReason)`.

### Создание потоков

```c
int addr = funcAddr(taskBody);   // ОБЯЗАТЕЛЬНО через локалку — в multi-arg call funcAddr генерит [fp+0]
ctxCreate(addr, 0);              // arg=0 → taskBody(0) → typesParser
ctxCreate(addr, 1);              // arg=1 → vedParser
ctxCreate(addr, 2);              // arg=2 → printer

void taskBody(int stage) {
    if (stage == 0) { typesParser(0); return; }
    if (stage == 1) { vedParser(0); return; }
    printer(0);
}
```

### Round-robin планировщик

```c
while (done < 3) {
    current = nextRunnable(current);       // find non-done thread
    if (current >= 0) {
        ctxDispatch(current + 1);          // TCB indices are 1-based
    }
    done = finishedCount();
}
```

## Ограничения и ловушки

1. **CSV должен быть кратен 4 байтам** — `pipeIn0/pipeIn1` читают 32-битные слова и блокируются навсегда на частичном хвосте. Паддить `\n` при необходимости.
2. **Число строк в `while (rows < N)` ≤ данных в CSV** — иначе зависание.
3. **Сложные выражения в memLoad/memStore** миcкомпилируются. Всегда разбивай на последовательные присваивания (см. `project_pdsl_compiler_bugs.md`):
   - `memStore(ADDR, memLoad(ADDR)+1)` → сначала load в локалку, потом инкремент, потом store
   - `return memLoad(A + i*K + N)` → вычислить адрес пошагово
4. **Имена `taskState`, `setTaskState`, `queueEntry`, etc. зарезервированы** как builtin — использовать `tcbState`, `taskStateOf` и т.п.
5. **`if (funcCall() != X)` миcкомпилируется** — сохранять результат в локалку, инвертировать условие на `== X`.
6. **Все локальные переменные объявлять в начале функции** (C89-style) — mid-function декларации могут ломать стек.
7. **VM медленная** — ~1000-2000 инструкций/сек. 50 строк = ~80 секунд. 200 строк ≈ 5-7 минут.
8. **`out.asm` → raw `out` инструкция** не пишет в SimplePipe — нужен режим `InputFile` или другой механизм захвата. `pipeOut` пишет в SimplePipe SyncSend → файл.
9. **Wait reasons должны быть >0** — значение 0 в WAIT_REASON_BASE интерпретируется как «не ждёт», поэтому `ctxBlock(0)` сделает поток BLOCKED-без-будильника (он никогда не проснётся, кроме как через `qStreamClose`). Все reason-коды в [q2_threads.txt](q2_threads.txt) начинаются с 1.
10. **Каждый qStreamWrite/Read должен заканчиваться `ctxWake`** — иначе ждущая сторона никогда не проснётся. `qStreamClose` страхует, будя сразу обоих.

## Отладка

### Вывод не растёт / 0 байт

Проверить по очереди:
1. Есть ли бинарник? `ls build/task2_v71/q2_threads.ptptb`
2. Зомби-процессы `Portable.RemoteTasks.Manager.exe` / `powershell` от прошлых зависаний → `Get-Process | Where-Object { ... }` и убить.
3. CSV выровнен? `wc -c file.csv; echo $((size % 4))` — должно быть 0.
4. Сгенерированный ASM для подозрительной функции — grep `"^global_funcName"` в `.asm` и проверить register clobbering.
5. Добавить отладочные `pipeOut('X')` / `printInt(var)` в критичные места.

### Примеры реальных багов и фиксов

- **Phase 1 сохраняла 0 типов** → `memStore(760000, typesCount + 1)` miscompile: фикс через `typesCount = typesCount + 1; memStore(760000, typesCount);`
- **Фильтр `id > 1250981` в vedParser не работал** → функция `taskState` коллидировала с builtin: переименована в `tcbState`.
- **nextRunnable всегда возвращал -1** → `if (taskState(idx+1) != 3)` miscompile: разделено на `st = taskState(idx+1); if (st == 3) else return idx;`.
- **Программа зависала в typesParser** на последнем слове CSV → файл не кратен 4 байтам: добавил `\n` padding.

## Производительность

| Нагрузка | Время | Инструкций (оценка) |
|---------|-------|---------------------|
| q2_mini (2 потока, 16 pipeOut) | 2.2с | ~2000 |
| q2_threads 50 строк | 83с | ~160,000 |
| q2_threads 200 строк (оценка) | ~6-8 мин | ~700,000 |

Узкое место — `readByte` (40 инструкций на байт, из них 4 — собственно чтение устройства). Альтернатива — `pipeBlockReadFast` с блочным чтением (см. [q1_block200.txt](q1_block200.txt)), но в однопоточной прошивке это не даёт ускорения из-за VM модели «1 такт на инструкцию».

## Связанные документы

- [project_pdsl_compiler_bugs.md](../../../../../Users/shabu/.claude/projects/d--ITMO-spolab3/memory/project_pdsl_compiler_bugs.md) — каталог всех найденных багов компилятора PDSL с обходами
- [project_byte_type_impl.md](../../../../../Users/shabu/.claude/projects/d--ITMO-spolab3/memory/project_byte_type_impl.md) — byte[] тип, pipeBlockReadFast, предыдущие фиксы cfg_builder.c
- [project_tacvm13_observations.md](../../../../../Users/shabu/.claude/projects/d--ITMO-spolab3/memory/project_tacvm13_observations.md) — архитектура VM, карта устройств, модель производительности
- [src/lab1.txt](../src/lab1.txt) — референсная threaded программа (SPN/RR1 симулятор) — показывает паттерн `taskBody`-as-yield-loop
- [src/runtime/rt_ctx.asm](../src/runtime/rt_ctx.asm) — реализация context switching (yield-frame, TCB layout)
- [lab2_threads_pipe/README.md](../lab2_threads_pipe/README.md) — аналогичная задача на StackVMCore VM (другая ISA, preemptive IRQ-based scheduling)
