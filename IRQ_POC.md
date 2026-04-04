# IRQ / Interrupt Investigation — TacVm13 (Lab 1 Scheduler)

## Архитектурный вывод (ПОДТВЕРЖДЕНО ТЕСТАМИ)

**TacVm13 использует polling-модель через `NextInterrupt`:**
1. Установить `[1000216] = 1` (QueueInterrupts)
2. Установить `[1000212] = 1` (InterruptsAllowed)
3. Читать `[1000240]` → **БЛОКИРУЕТСЯ** до прихода прерывания от Clock → возвращает **1**
4. Обработать прерывание (шаг планировщика)
5. Повторить с шага 3 (возможно, нужно снова установить InterruptsAllowed)

Это **не auto-dispatch**. CPU не прерывается аппаратно. Вместо этого — программный blocking poll.

### Доказательство (irq_next_probe.asm + inspector):
- После `step 7` ip застрял на 0x30 (инструкция `mov r1, [1000240]` не продвинулась) — БЛОКИРУЕТСЯ
- После `cont` (свободный запуск): программа дошла до breakpoint 0x40, **r1 = 0x1** ✓
- Clock с CyclesSignalPeriod=1000 разблокировал NextInterrupt примерно через 1000 циклов

---

## MMIO Layout — полная спецификация

### SimplePic state (base PIC_BASE = 1000200, Length=48)

| Byte offset | Address  | Type | Field                         | Описание |
|-------------|----------|------|-------------------------------|----------|
| +0          | 1000200  | u8   | InterruptedInstructionAddress | Адрес прерванной инструкции (пишется устройством при прерывании) |
| +8          | 1000208  | i4   | InterruptHandlersTableEntrySize | Инициализируется из параметра HandlersTableEntrySize |
| +12         | 1000212  | b    | **InterruptsAllowed**         | 1 = разрешить прерывания; 0 = отложить |
| +16         | 1000216  | b    | **QueueInterrupts**           | 1 = ставить в очередь; 0 = игнорировать |
| +20         | 1000220  | b    | InterruptHappened             | Устанавливается устройством; нужно вручную сбросить |
| +24         | 1000224  | i4   | DeviceTypeId                  | Id типа устройства-источника |
| +28         | 1000228  | i4   | DeviceId                      | Id устройства-источника |
| +32         | 1000232  | i4   | SignalId                      | Id сигнала |
| +36         | 1000236  | i4   | InterruptId                   | Id прерывания |
| +40         | **1000240** | bool | **NextInterrupt**          | **Blocking In Register**: блокируется до прихода прерывания → возвращает nonzero |

### SimplePic handlers-map (base 1000300, Length=64, HandlersTableEntrySize=4)

| Offset | Address | Поле |
|--------|---------|------|
| +0     | 1000300 | Handler for interrupt 0 (4 bytes = адрес функции в `codeRamBank`) |
| +4     | 1000304 | Handler for interrupt 1 |
| ...    | ...     | ... |

### SimpleClock state (base 1000400, Length=72)

| Offset | Address | Type | Field |
|--------|---------|------|-------|
| +0     | 1000400 | i8   | Ticks |
| +8     | 1000408 | i8   | UnixTime |
| +16    | 1000416 | i4   | DayOfYear |
| +20    | 1000420 | i4   | Year |
| +24    | 1000424 | i4   | Month |
| +28    | 1000428 | i4   | Day |
| +32    | 1000432 | i4   | Hour |
| +36    | 1000436 | i4   | Minute |
| +40    | 1000440 | i4   | Second |
| +44    | 1000444 | i4   | Millisecond |
| +48    | 1000448 | u8   | **Cycles** (счётчик исполненных инструкций) |
| +56    | 1000456 | i8   | TicksSignalPeriod |
| +64    | 1000464 | u8   | **CyclesSignalPeriod** (0=выкл; N=каждые N инструкций) |

---

## Сравнение с примером (StackVM)

| Аспект | Example (StackVM) | Наш (TacVm13) |
|--------|-------------------|---------------|
| HandlersTableEntrySize | 8 | 4 |
| PIC BankName | DATA | ram |
| Clock CyclesSignalPeriod | 500 | 1000 |
| CPU-уровневый S_IRQ_HANDLER | Нет (тоже) | Нет |
| Auto-dispatch работает | Неизвестно | **Не работает** (тесты) |
| NextInterrupt | Должен работать | **Тестируем** |

**Важное отличие**: В примере PIC handlers-map в банке `DATA`, а `codeRamBankName=CODE`. Это разные банки! В TacVm13 всё в одном банке `ram`. Это потенциальная причина почему auto-dispatch не работает у нас — возможно, механизм ожидает отдельный code bank.

---

## Что было проверено (хронология)

### 1. Auto-dispatch (irq_handler_once.asm)
```asm
mov [1000300], irq_handler   ; handler addr
mov [1000216], #1            ; QueueInterrupts = 1
mov [1000212], #1            ; InterruptsAllowed = 1
spin: sub r2, r2, #1 / bgt spin / halt
irq_handler: mov [200000], #1 / halt
```
**Результат**: Infinite spin — 3+ минуты, handler NOT called. 5M countdown — завершился за ~3с (timeout, не handler).
**Вывод**: Auto-dispatch НЕ РАБОТАЕТ для TacVm13.

### 2. Polling [1000220] без QueueInterrupts
**Результат**: ЗАВИСАНИЕ — поле никогда не становится ненулевым.

### 3. Polling [1000240] только с QueueInterrupts=1 (без InterruptsAllowed)
```asm
; irq_queue_probe: только QueueInterrupts=1, InterruptsAllowed НЕ установлен
mov r1, [1000240]   ; читает 5 раз, каждый раз = 0
```
**Результат**: [200000]=5, без зависания → NextInterrupt возвращает 0 немедленно.
**Вывод**: Без InterruptsAllowed=1 очередь не заполняется. NextInterrupt не блокирует.

### 4. PIC state scan (текущий irq_poc_interrupt.asm)
**Результат**: ОШИБКА `Uninitialized memory region access at 0xf4308`
**Причина**: `0xf4308` hex = `1000200` dec = PIC base. Попытка ЧИТАТЬ Duplex Register до того как устройство или код туда что-то записал. Mode="RAM" — регион в обычной RAM, нужна запись перед чтением.

---

## Ключевые правила

1. **Mode="RAM" MMIO**: ЧИТАТЬ поле можно только после того как туда записано значение (устройством или кодом).
2. **Blocking In Register** (NextInterrupt): читать безопасно всегда — устройство обрабатывает напрямую, не через RAM backing.
3. **Нужны оба флага**: QueueInterrupts=1 И InterruptsAllowed=1 для работы NextInterrupt blocking.
4. **InterruptsAllowed сбрасывается**: "is being reset on interrupt" — возможно, нужно переустанавливать после каждого NextInterrupt.
5. **`beq` / `bgt`**: работают через `cmp_result`, не ALU. После `sub` нужен явный `cmp r, #0`.
6. **`[reg]`**: не работает. Использовать `[reg + 0]` (mov_rm).
7. **`iret` = `ret`**: просто pop ip from stack. Для scheduler — полезно для context switch.

---

## Следующий тест: irq_next_probe.asm

Файл: `src/irq_next_probe.asm`

```asm
start:
    mov sp, #1040000 / mov fp, sp
    mov [200000], #0 / mov [200004], #0
    
    mov [1000216], #1    ; QueueInterrupts = 1
    mov [1000212], #1    ; InterruptsAllowed = 1
    
    mov r1, [1000240]    ; БЛОКИРУЕТСЯ до Clock (каждые 1000 инструкций)
    
    mov [200000], r1     ; ожидаемый результат: nonzero
    mov [200004], #1     ; маркер достижения halt
    halt
```

**Ожидаемые результаты:**
| [200000] | [200004] | Что произошло |
|----------|----------|---------------|
| nonzero  | 1        | ✓ NextInterrupt blocking РАБОТАЕТ! |
| 0        | 1        | NextInterrupt вернул 0 (неверная настройка?) |
| VM зависает | - | NextInterrupt блокирует, но Clock не приходит |

---

## План для планировщика (после подтверждения NextInterrupt)

```asm
scheduler_loop:
    ; Wait for next timer tick (every 1000 cycles)
    mov r1, [1000240]      ; block until Clock fires
    
    ; Re-enable for next interrupt (if InterruptsAllowed resets on interrupt)
    mov [1000212], #1
    
    ; --- context switch ---
    ; 1. Save current thread context (all registers to thread TCB)
    ; 2. Advance to next thread (round-robin)
    ; 3. Restore next thread context
    ; 4. Jump to next thread's saved IP
    jmp scheduler_loop
```

---

## Рабочий процесс

### Сборка
```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-assemble.ps1 `
  -AsmListing src/irq_next_probe.asm -BinaryOutput build/irq_next_probe.ptptb
```

### Запуск (quick submit + poll)
```bash
# Submit
cd "d:/ITMO/СПО/SPO 3" && ./tools/RemoteTasks/Portable.RemoteTasks.Manager.exe \
  -sslcfg ./tools/RemoteTasks/ssl-cfg.yaml -ul 505979 -up 9d7a3ade-... \
  -q -s ExecuteBinaryWithIo \
  devices.xml src/TacVm13.irq-debug.devices.xml \
  definitionFile src/TacVm13.target.pdsl archName TacVm13 \
  binaryFileToRun build/irq_next_probe.ptptb \
  codeRamBankName ram ipRegStorageName ip finishMnemonicName halt
```

### Отладка с инспектором
```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-inspect.ps1 `
  -BinaryFile .\build\irq_next_probe.ptptb `
  -DefinitionFile .\src\TacVm13.target.pdsl `
  -RunMode withio `
  -DevicesFile .\src\TacVm13.irq-debug.devices.xml
```
Затем в REPL: `step` до инструкции `mov r1, [1000240]`, потом `step` снова и смотреть — завис ли или сразу вернул значение.

### Polling результата (через PS1 файл из-за Cyrillic-path бага)
```powershell
# Сохранить в C:/Users/shabu/AppData/Local/Temp/poll.ps1:
Set-Location "D:\ITMO\СПО\SPO 3"
$mgr = ".\tools\RemoteTasks\Portable.RemoteTasks.Manager.exe"
$ssl = ".\tools\RemoteTasks\ssl-cfg.yaml"
$id  = "<taskId>"
& $mgr -sslcfg $ssl -ul 505979 -up 9d7a3ade-... -g $id 2>&1 | Write-Host

# Запустить:
powershell.exe -File "C:/Users/shabu/AppData/Local/Temp/poll.ps1"
```

### Важные баги с Manager.exe
- `-w` зависает из bash → использовать `-q` + `-g` polling
- Кириллица в пути → через `.ps1` файл + Set-Location
- После зависания: `Get-Process 'Portable.RemoteTasks.Manager' | Stop-Process -Force`

---

## Текущие файлы

| Файл | Статус | Описание |
|------|--------|----------|
| `src/irq_next_probe.asm` | **НОВЫЙ, НЕ ТЕСТИРОВАН** | Минимальный тест NextInterrupt blocking |
| `src/irq_handler_once.asm` | Протестирован — auto-dispatch НЕ работает | Auto-dispatch probe |
| `src/irq_queue_probe.asm` | Протестирован — подтвердил что QueueInterrupts без InterruptsAllowed → немедленный return 0 | Queue probe |
| `src/irq_poc_interrupt.asm` | ОШИБКА: uninitialized read | PIC scan тест (нужен zero-init fix) |
| `src/TacVm13.irq-debug.devices.xml` | OK | Devices для тестов (без SimplePipe) |
| `src/TacVm13.irq-poc.devices.xml` | OK | Devices с SimplePipe |
