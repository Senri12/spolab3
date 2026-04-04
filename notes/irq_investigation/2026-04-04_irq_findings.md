# IRQ / Scheduler Investigation Notes

Дата: 2026-04-04

## Что подтверждено

1. Для `TacVm13` рабочий механизм ожидания прерывания это не auto-dispatch через handlers-map, а polling через `SimplePic.NextInterrupt`.
2. Адрес `NextInterrupt`:
   - `PIC_BASE = 1000200`
   - `NextInterrupt = PIC_BASE + 40 = 1000240`
3. `NextInterrupt` действительно работает как blocking read:
   - при отладке `irq_next_probe.ptptb` после `cont` и брейкпоинта перед `halt` регистр `r1` был равен `1`
   - это означает, что чтение `mov r1, [1000240]` дождалось сигнала Clock и вернуло nonzero
4. Для работы blocking poll нужны оба флага:
   - `QueueInterrupts = 1` по адресу `1000216`
   - `InterruptsAllowed = 1` по адресу `1000212`
5. Clock в `src/TacVm13.irq-debug.devices.xml` настроен корректно:
   - `CyclesSignalPeriod = 1000`
   - `Signal on-cycles -> Interrupt 0`

## Что оказалось неверным в ранних гипотезах

1. Auto-dispatch через `S_IRQ_HANDLER` для `TacVm13` не подтвердился.
2. Пример со `StackVM` нельзя переносить напрямую:
   - там handlers-map работает в другой memory architecture
   - у нас PIC state и код живут в одном `ram`-банке
3. Тест `irq_handler_once` не является доказательством нерабочих IRQ вообще.
   - Он показывает только то, что auto-dispatch в этой конфигурации не срабатывает.

## Почему старые тесты вводили в заблуждение

### `irq_queue_probe`

- Был включён только `QueueInterrupts = 1`
- `InterruptsAllowed = 0`
- Поэтому `NextInterrupt` возвращал `0` сразу, без реального ожидания

### `irq_poc_interrupt.asm`

- Чтение PIC MMIO происходило до безопасной инициализации
- В режиме `Mode="RAM"` это приводило к `uninitialized memory region access`

### `irq_handler_once`

- Проверялся не тот механизм
- Для `TacVm13` нужно проверять именно `NextInterrupt`, а не auto-dispatch

## Подтверждённый рабочий probe

Файл: `src/irq_next_probe.asm`

Суть:

```asm
mov [1000216], #1
mov [1000212], #1
mov r1, [1000240]
mov [200000], r1
halt
```

Фактический результат через `SpoInspector`:

- брейкпоинт перед `halt`
- `r1 = 1`

Это главное доказательство, что `NextInterrupt` блокирует и разблокируется Clock-сигналом.

## Вывод по таймеру

На текущий момент таймерная основа для планировщика подтверждена:

1. Перед ожиданием нужно выставлять `InterruptsAllowed = 1`
2. Затем читать `NextInterrupt`
3. После возврата читать/обновлять состояние планировщика
4. При следующем тике снова переустанавливать `InterruptsAllowed = 1`

Практический шаблон:

```asm
mov [1000212], #1
mov r1, [1000240]
```

## Что удалось выяснить про отладчик

### Полезное

1. Новый `SpoInspector` реально пригоден для автоматических сценариев через `--script`
2. Команды вида:
   - `break <addr>`
   - `cont`
   - `regs`
   работают и дали ключевой результат по `r1 = 1`

### Важная доработка

В `tools/SpoInspector/Program.cs` была добавлена поддержка raw ASM binaries без секции `simplelang.debug.json`.

Теперь при отсутствии секции отладчик не падает сразу, а пишет предупреждение:

`[warn] Debug section 'simplelang.debug.json' not found — using empty metadata (raw ASM mode).`

Это позволило отлаживать `.ptptb`, собранные напрямую из ASM.

### Ограничение

В debug session чтение runtime-written RAM через `mem` оказалось ненадёжным:

- `mem ram 200000 4`
- `mem ram 200004 4`

часто завершается `Uninitialized memory region access`, даже когда логически запись уже должна была произойти.

Поэтому для подтверждения результатов сейчас надёжнее использовать:

1. регистры (`regs`)
2. брейкпоинты перед `halt`
3. перенос интересующих значений в регистры перед остановкой

## Что проверено по памяти

Файл: `src/mem_roundtrip_test.asm`

Проверка:

```asm
mov r0, #42
mov [200000], r0
mov r1, [200000]

mov r2, #100
mov [200004], r2
mov r3, [200004]
```

Результат в отладчике:

- `r1 = 42`
- `r3 = 100`

То есть обычные `mov [addr], reg` и `mov reg, [addr]` в принципе работают корректно.

## Что остаётся не до конца объяснённым

В `irq_sched_minimal.asm` значения, записанные в RAM-счётчики, не подтвердились через финальное чтение в регистры:

- `r5 = 6` подтверждает, что цикл по тикам дошёл до конца
- `r1 = 1` подтверждает, что IRQ polling срабатывал
- но `r2/r3` не показали ожидаемые значения из RAM

Пока это выглядит как проблема именно конкретного scheduler-probe / debug-наблюдаемости, а не общая неработоспособность RAM:

- чистый memory roundtrip работает
- `NextInterrupt` работает

## Важная несогласованность в документации

В `IRQ_POC.md` местами фигурирует `HandlersTableEntrySize = 4`, но в актуальных XML:

- `src/TacVm13.irq-debug.devices.xml`
- `src/TacVm13.irq-poc.devices.xml`

стоит:

```xml
<Parameter Name="HandlersTableEntrySize" Value="8" />
```

Это нужно считать актуальным значением конфигурации.

## Какие артефакты уже есть

ASM probes:

- `src/irq_next_probe.asm`
- `src/irq_timing_probe.asm`
- `src/irq_sched_minimal.asm`
- `src/irq_sched_regs.asm`
- `src/mem_roundtrip_test.asm`

Собранные бинарники:

- `build/irq_next_probe.ptptb`
- `build/irq_timing_probe.ptptb`
- `build/irq_sched_minimal.ptptb`
- `build/irq_sched_regs.ptptb`
- `build/mem_roundtrip_test.ptptb`

Связанные файлы:

- `IRQ_POC.md`
- `INSPECTOR.md`
- `tools/SpoInspector/Program.cs`
- `tools/remotetasks-inspect.ps1`

## Практический вывод на сейчас

1. Таймер через `NextInterrupt` для `TacVm13` подтверждён и пригоден как основа планировщика.
2. Делать ставку нужно на blocking poll, а не на auto-dispatch.
3. Следующий этап имеет смысл строить вокруг scheduler loop вида:
   - разрешить IRQ
   - ждать `NextInterrupt`
   - выполнить один scheduler-step
   - повторить
4. При проверке результатов лучше выводить ключевые значения в регистры перед `halt`, а не полагаться на `mem`.

---

## Сессия 2026-04-04 (продолжение) — Диагностика irq_sched_minimal

### Anomaly: r0=0x10=16 в результатах

irq_sched_minimal.asm запустили 6 тиков. Регистры на halt:
- `r5 = 6` ✓ (тик-счётчик правильный)
- `r4 = 0` ✓ (round-robin правильно завернулся)
- `r1 = 1` ✓ (последний NextInterrupt вернул 1)
- `r0 = 0x10 = 16` ✗ (должно быть 30 = результат task1 с `+10` за 3 тика)
- `r2 = 0` ✗ (должно быть 3 — task0 counter)
- `r3 = 0` ✗ (должно быть 30 — task1 counter)

### Что было исключено

1. **Базовая память работает**: `mem_roundtrip_test.asm` подтвердил r1=42, r3=100 для адресов 200000, 200004.
2. **Devices не мешают**: roundtrip с `withio` + devices.xml дал те же корректные результаты.
3. **Цикл завершился**: r5=6 доказывает ровно 6 итераций.

### Гипотеза о `r0=16`

Возможно, `#10` интерпретируется как hex `0x10 = 16`. Если так:
- task1 добавляет 16 вместо 10
- После 1 запуска task1: r0 = 16
- Но тогда r3 должен быть 48 (3 × 16), а не 0

Это не объясняет r2=r3=0.

### Текущая гипотеза (нужна проверка)

Счётчики [200004]/[200008] не сохраняются через цикл с `mov r1, [1000240]` (blocking read).
Возможно, InterruptsAllowed resetting также сбрасывает что-то в памяти? Или breakpoint не в том месте?

### Следующий тест: irq_sched_regs.asm

Та же логика, но счётчики в **регистрах** r6/r7 (без RAM stores):
- r6 = task0 count (ожидание: 3)
- r7 = task1 sum (ожидание: 30 или 48 если `#10`=hex)

Если r6=3 и r7=30 — проблема с памятью.
Если r6=3 и r7=48 — `#10` интерпретируется как hex (баг в ожиданиях документации).
Если r6=r7=0 — что-то другое.

Halt offset: 22 инструкции × 8 = **176**. Скрипт: `break 176 / cont / regs / quit`

### Рабочие команды (избегаем зависаний)

```powershell
# Сборка:
powershell.exe -Command "& 'D:\ITMO\СПО\SPO 3\tools\remotetasks-assemble.ps1' -AsmListing 'D:\ITMO\СПО\SPO 3\src\<file>.asm' -BinaryOutput 'D:\ITMO\СПО\SPO 3\build\<file>.ptptb' -SkipInspectorEmbed"

# Inspect:
powershell.exe -Command "& 'D:\ITMO\СПО\SPO 3\tools\remotetasks-inspect.ps1' -BinaryFile '...' -DefinitionFile '...\TacVm13.target.pdsl' -RunMode withio -DevicesFile '...\TacVm13.irq-debug.devices.xml' -Script '...\script.txt'"
```

---

## Сессия 2026-04-04 (продолжение 3) — Решение алиасинга через register-relative addressing

### Итог диагностики addr_stride_test

Тест `src/addr_stride_test.asm` (адреса 200000, 200016, 200032, 200048, 200064, 200072):

```
r0=40, r1=40, r2=40, r3=40  → все 4 адреса алиасят на одну ячейку
r4=60                        → 200064 тоже алиасит (=last write [200072]=60)
```

**Вывод: минимальный шаг для различимых ячеек = 256 байт.**

Ассемблер кодирует addr20 как `byte_address >> 8` (или обрезает биты [7:0]).
Все адреса в диапазоне `[N*256 .. N*256 + 255]` алиасят на одну ячейку.

Примеры различимых адресов: `200000`, `200256`, `200512`, ...

### Корень проблемы irq_sched_minimal

Все 4 адреса: 200000, 200004, 200008, 200012 — в одном 256-байтовом блоке → алиасируют.
Последняя запись в цикле `mov [200012], r4` писала `0`, поэтому r2=r3=0.

### Исправление: register-relative addressing

Инструкции `mov_rm`, `mov_mr`, `mov_mi` вычисляют адрес как `base_reg + sign_extend(off16)`
через 32-битную арифметику — **без addr20, без алиасинга**.

Паттерн:
```asm
mov r28, #200000      ; base pointer
mov r27, #200256      ; второй base pointer (>=256 байт разница)
mov [r28 + 0], #0     ; запись (mov_mi)
mov r0, [r28 + 4]     ; чтение (mov_rm)
mov [r27 + 0], r0     ; запись (mov_mr)
```

### ПОДТВЕРЖДЕНО: irq_sched_regrel.asm

Файл: `src/irq_sched_regrel.asm`
Бинарник: `build/irq_sched_regrel.ptptb`
Скрипт: `build/regrel_script.txt` (break 240 / cont / regs / quit)

**Результаты при halt (offset 240):**
```
r5 = 6    ✓  tick counter
r4 = 0    ✓  round-robin wrapped correctly
r6 = 3    ✓  task0 counter (3 × 1 = 3)
r7 = 30   ✓  task1 sum     (3 × 10 = 30)
r28 = 200000   TCB0 base
r27 = 200256   TCB1 base
```

Планировщик с таймером + register-relative memory — полностью рабочий.

