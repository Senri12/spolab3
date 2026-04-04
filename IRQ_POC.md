# IRQ / Interrupt Investigation — TacVm13 (Lab 1 Scheduler)

## Цель
Разобраться, как работают прерывания в TacVm13, чтобы реализовать планировщик задач на основе таймера.

---

## Архитектура прерываний TacVm13

### Ключевые отличия от StackVM
- **TacVm13 не имеет** CPU-уровневых хранилищ `S_IRQ_HANDLER` / `S_IRQ_ENABLED`.
- Всё управление прерываниями — через MMIO устройств **SimplePic** и **SimpleClock**.
- `iret` идентичен `ret`: `ip = ram:4[sp]; sp = sp + 4` (просто всплывает адрес возврата).
- `halt`: `ip = ip + 8` (framework останавливает VM по этому мнемонику).

### Инструкции адресации
- `mov r, [addr]` (`mov_ra`) — берёт **20-битный немедленный адрес**, не регистр!
- `mov r, [reg + offset]` (`mov_rm`) — регистровая адресация с константным смещением.
  - Вариант `[reg + 0]` работает как регистровый косвенный.
- `beq`/`bgt` смотрят на `cmp_result`, а не на ALU-результат. После `sub` нужен явный `cmp`.

---

## MMIO Layout (из TacVm13.irq-debug.devices.xml)

### SimplePic — base: 1000200, Length=48 (BankName=ram, Mode=RAM)
| Offset | Адрес   | Поле                          |
|--------|---------|-------------------------------|
| +0     | 1000200 | InterruptedInstructionAddress |
| +4     | 1000204 | ?                             |
| +8     | 1000208 | ?                             |
| +12    | 1000212 | **InterruptsAllowed** (пишем 1 чтобы включить) |
| +16    | 1000216 | **QueueInterrupts** (режим очереди) |
| +20    | 1000220 | InterruptHappened             |
| +24..  | 1000224+| ? (нужно выяснить через scan) |

### SimplePic Handlers Map — base: 1000300, Length=64, HandlersTableEntrySize=4
| Offset | Адрес   | Поле |
|--------|---------|------|
| +0     | 1000300 | Handler for interrupt 0 (4 bytes = адрес функции) |
| +4     | 1000304 | Handler for interrupt 1 |
| ...    | ...     | ... |

### SimpleClock — base: 1000400, Length=72
- `CyclesSignalPeriod=1000` — каждые 1000 циклов посылает сигнал `on-cycles` → Interrupt line 0.
- Значит: каждые ~1000 инструкций должен срабатывать прерыватель.

---

## Что было проверено (хронология)

### 1. Auto-dispatch (автоматическая диспетчеризация)
**Гипотеза:** SimplePic видит сигнал от Clock и сам переключает IP на адрес обработчика.

**Код (irq_handler_once.asm):**
```asm
mov [1000300], irq_handler   ; handler addr -> slot 0
mov [1000212], #1            ; InterruptsAllowed = 1
mov r2, #5000000
spin:
    sub r2, r2, #1
    bgt spin
halt

irq_handler:
    mov [200000], #1
    halt
```
**Результат (infinite spin):** 3+ минуты без остановки → auto-dispatch **не работает**.
**Результат (5M countdown):** Завершилась за ~3 сек → timeout, [200000]=0.

---

### 2. Polling [1000220] (InterruptHappened) без QueueInterrupts
**Гипотеза:** Поле 1000220 становится ненулевым когда Clock срабатывает.

**Результат:** **ЗАВИСАНИЕ** — поле никогда не меняется без `QueueInterrupts=1`.

---

### 3. Polling [1000240] с QueueInterrupts=1
**Гипотеза:** С очередью прерываний поле 1000240 содержит ID прерывания.

**Результат:** **ЗАВИСАНИЕ** — поле никогда не меняется.

---

### 4. irq_queue_probe — чтение [1000240] в цикле 5 раз
**Гипотеза:** Проверка факта работы VM и доступа к устройству.

**Код (irq_queue_probe.asm):** Читает [1000240] 5 раз безусловно, считает в [200000].

**Результат:** Завершился успешно ([200000]=5) — **ничего не доказывает** про прерывания, просто читает что есть. Ошибки нет потому что 1000240 = Clock MMIO (base 1000400 − 160), не PIC state.

---

### 5. PIC state scan — снэпшот всех 12 слов MMIO
**Гипотеза:** Снять snapshot 12 слов (1000200..1000244), включить прерывания, ждать изменений.

**Код (irq_poc_interrupt.asm текущий):**
- Читает 12 × 4 байта из 1000200..1000244 в [201000..201044]
- Включает InterruptsAllowed=1 и QueueInterrupts=1
- В 10M-итерационном цикле проверяет каждое слово на изменение
- При изменении: пишет (offset+1) в [200000], halt
- При timeout: [200000]=0, halt

**Результат:** **ОШИБКА** — `Uninitialized memory region access at 0xf4308`

**Причина диагностирована:**
- `0xf4308` hex = `1000200` decimal — первое чтение из PIC MMIO.
- `Mode="RAM"` в devices.xml: регион — обычная RAM, используемая устройством как backing store.
- VM ругается на чтение RAM до первой записи ("uninitialized memory region").
- **Нельзя читать MMIO до того как устройство или наш код туда что-то записал.**

---

## Ключевые выводы

| # | Вывод |
|---|-------|
| 1 | **Mode="RAM"**: MMIO-регион не инициализирован при старте, читать нельзя до записи |
| 2 | **Auto-dispatch не работает** — SimplePic не переключает IP самостоятельно |
| 3 | **QueueInterrupts нужен** — без него InterruptHappened не меняется |
| 4 | **Polling [1000220] и [1000240]** не даёт результата при простом spinning |
| 5 | **`beq` после `sub`** — нужен явный `cmp r, #0` перед `beq` |
| 6 | **`[reg]`** не работает — нужно `[reg + 0]` (`mov_rm`) |

---

## Следующие шаги (план)

### Fix scan теста: Zero-init перед snapshot

Перед snap_loop добавить zero-init чтобы избежать "uninitialized" ошибки:

```asm
; zero-init PIC state region before reading
mov r6, #1000200
zero_loop:
    mov [r6 + 0], #0
    add r6, r6, #4
    cmp r6, #1000248
    blt zero_loop
; теперь snap_loop прочтёт нули — snapshot будет нулями
; потом включаем прерывания и ждём изменений
```

После этого: если что-то ненулевое появится в PIC MMIO → мы найдём какое поле.

### Альтернативный подход: Disable snapshot, только poll

1. Записать нули / init значения в PIC state
2. Включить прерывания (`[1000212]=1`)
3. Polling каждого поля в цикле, ждать non-zero

### Гипотезы для проверки

1. **Write→Read**: После zero-init MMIO можно читать → запустить scan → узнать какое поле меняется.
2. **SimplePic dispatch через iret**: Может SimplePic вызывает обработчик через механизм стека (пушит IP и прыгает на handler), а `iret` (= `ret`) возвращает управление? Тогда обработчик должен завершаться через `iret`, не `halt`.
3. **Handler table format**: HandlersTableEntrySize=4 → 4-байтный адрес. Проверить что `mov [1000300], irq_handler` пишет правильный адрес.
4. **Clock MMIO**: Нужно читать Clock state (1000400) — там может быть счётчик циклов или флаг "fired".

---

## Рабочий процесс (commands)

### Сборка
```powershell
powershell.exe -File "./tools/remotetasks-assemble.ps1" `
  -AsmListing "src/irq_poc_interrupt.asm" `
  -BinaryOutput "build/irq_poc.ptptb"
```

### Запуск (quick submit + poll через PS1 файл)
```bash
# Step 1: Submit (из bash, относительные пути)
cd "d:/ITMO/СПО/SPO 3" && ./tools/RemoteTasks/Portable.RemoteTasks.Manager.exe \
  -sslcfg ./tools/RemoteTasks/ssl-cfg.yaml -ul 505979 -up 9d7a3ade-42cd-4693-85e6-5367bbe31597 \
  -q -s ExecuteBinaryWithIo \
  devices.xml src/TacVm13.irq-debug.devices.xml \
  definitionFile src/TacVm13.target.pdsl \
  archName TacVm13 \
  binaryFileToRun build/irq_poc.ptptb \
  codeRamBankName ram ipRegStorageName ip finishMnemonicName halt
```

```powershell
# Step 2: Poll result — через temp PS1 файл (чтобы избежать encoding багов с Кириллицей)
# Записать в C:/Users/shabu/AppData/Local/Temp/poll_irq.ps1:
Set-Location "D:\ITMO\СПО\SPO 3"
$mgr = ".\tools\RemoteTasks\Portable.RemoteTasks.Manager.exe"
$ssl = ".\tools\RemoteTasks\ssl-cfg.yaml"
$out = & $mgr -sslcfg $ssl -ul 505979 -up 9d7a3ade-42cd-4693-85e6-5367bbe31597 -g <taskId> 2>&1
Write-Host ($out | Out-String)

# Выполнить:
powershell.exe -File "C:/Users/shabu/AppData/Local/Temp/poll_irq.ps1"
```

### Скачать бинарь
```powershell
Set-Location "D:\ITMO\СПО\SPO 3"
$mgr = ".\tools\RemoteTasks\Portable.RemoteTasks.Manager.exe"
$ssl = ".\tools\RemoteTasks\ssl-cfg.yaml"
& $mgr -sslcfg $ssl -ul 505979 -up 9d7a3ade-42cd-4693-85e6-5367bbe31597 `
  -g <taskId> -r out.ptptb -o build/irq_poc.ptptb
```

### Важные баги с Manager.exe
- `-w` флаг зависает при вызове из bash → использовать `-q` + `-g` polling.
- Кириллица `СПО` ломается при передаче через bash→PowerShell inline → сохранять команду в `.ps1` файл и `powershell.exe -File`.
- После зависания: `Get-Process -Name 'Portable.RemoteTasks.Manager' | Stop-Process -Force`.

---

## Текущие файлы

| Файл | Описание |
|------|----------|
| `src/irq_poc_interrupt.asm` | PIC scan тест — требует zero-init fix |
| `src/irq_handler_once.asm` | Auto-dispatch probe |
| `src/irq_queue_probe.asm` | Queue probe (ничего не доказал) |
| `src/TacVm13.irq-debug.devices.xml` | Devices без SimplePipe (для тестов) |
| `src/TacVm13.irq-poc.devices.xml` | Devices с SimplePipe |
| `src/TacVm13.target.pdsl` | Архитектура TacVm13 |
| `build/irq_poc.ptptb` | Последний бинарь (scan тест, 585 байт) |
