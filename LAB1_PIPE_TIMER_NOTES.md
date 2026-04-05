# Lab 1: Real Timer + SimplePipe Notes

Краткая сводка по тому, как был доведён `lab1` до рабочего состояния с:

- реальным таймером через `SimplePic` / `SimpleClock`
- текстовым выводом через `SimplePipe`

## Что в итоге работает

Итоговый сценарий:

- `src/lab1.txt` использует реальный таймер:
  - `initTimer()`
  - `waitForTick()`
- вывод идёт через `pipeOut(...)`
- запуск выполняется через:
  - `ExecuteBinaryWithIo`
  - `src/TacVm13.irq-poc.devices.xml`

Фактически удалось получить вывод программы вида:

```text
VAR=11
ALG=SPN
TRACE=...
AVG_TA=42.81
AVG_WT=38.33

ALG=RR1
TRACE=...
AVG_TA=75.19
AVG_WT=70.71

CRIT=TA
BEST=SPN
```

## Какие файлы были задействованы

- [src/lab1.txt](/d:/ITMO/СПО/SPO%203/src/lab1.txt)
- [src/runtime/timer.asm](/d:/ITMO/СПО/SPO%203/src/runtime/timer.asm)
- [src/runtime/pipe_out.asm](/d:/ITMO/СПО/SPO%203/src/runtime/pipe_out.asm)
- [src/runtime/pipe_in.asm](/d:/ITMO/СПО/SPO%203/src/runtime/pipe_in.asm)
- [src/cfg_builder.c](/d:/ITMO/СПО/SPO%203/src/cfg_builder.c)
- [src/TacVm13.irq-poc.devices.xml](/d:/ITMO/СПО/SPO%203/src/TacVm13.irq-poc.devices.xml)
- [src/pipe_probe.asm](/d:/ITMO/СПО/SPO%203/src/pipe_probe.asm)

## Что именно было сделано

### 1. Реальный таймер

В рантайм добавлен `timer.asm`:

- `initTimer()`:
  - включает `QueueInterrupts`
  - включает `InterruptsAllowed`
- `waitForTick()`:
  - повторно включает `InterruptsAllowed`
  - делает blocking-read из `NextInterrupt`

Использованные MMIO-адреса `SimplePic`:

- `1000212` = `InterruptsAllowed`
- `1000216` = `QueueInterrupts`
- `1000240` = `NextInterrupt`

Это даёт не фейковый `time = time + 1`, а реальный шаг времени от clock interrupt.

### 2. Подключение runtime в компилятор

В [src/cfg_builder.c](/d:/ITMO/СПО/SPO%203/src/cfg_builder.c) список runtime ASM расширен.

Важно: у сборочной утилиты действительно есть режим подключения дополнительных ASM файлов через `-ExtraAsmFiles`, но он работает на этапе assemble/link. В случае `lab1.txt` этого было недостаточно, потому что вызовы `pipeOut`, `pipeIn`, `initTimer`, `waitForTick` должны быть уже известны генератору на этапе построения `build/lab1.asm`.

Поэтому для этого сценария runtime-файлы были добавлены именно в список runtime генератора, чтобы компилятор автоматически дописывал:

- `src/runtime/in.asm`
- `src/runtime/out.asm`
- `src/runtime/pipe_in.asm`
- `src/runtime/pipe_out.asm`
- `src/runtime/timer.asm`

Для ручных `.asm` файлов можно использовать и обычную сборку с дополнительными ASM-модулями. Но для вызовов из SimpleLanguage-исходника здесь понадобилось именно расширение runtime в генераторе.

### 3. Вывод через SimplePipe

Сначала был сделан `pipeOut()` через прямую абсолютную запись:

```asm
mov [1000032], r2
```

Это не работало.

Причина оказалась в особенностях TacVm13:

- абсолютная адресация в этой форме теряет младшие 8 бит адреса
- адрес `1000032` в коде превращался в `1000000`
- запись уходила не в `SimplePipe`, а мимо него

Рабочий вариант оказался таким:

```asm
mov r3, #1000032
mov [r3 + 0], r2
```

То есть для `SimplePipe` нужен register-relative MMIO access.

Аналогично для `pipeIn()`:

```asm
mov r3, #1000040
mov r1, [r3 + 0]
```

### 4. Перевод `lab1` на pipe output

В [src/lab1.txt](/d:/ITMO/СПО/SPO%203/src/lab1.txt) печать была переведена с `out(...)` на `pipeOut(...)`.

Это нужно потому, что:

- `out()` пишет в регистр `OUTPUT`
- `ExecuteBinaryWithIo` работает через `devices.xml`
- для `irq-poc.devices.xml` текст должен идти через `SimplePipe`

## Что использовалось для диагностики

### 1. Inspector

Использовался:

- [tools/remotetasks-inspect.ps1](/d:/ITMO/СПО/SPO%203/tools/remotetasks-inspect.ps1)

Через него удалось увидеть:

- что старый `pipe_probe.ptptb` вообще состоял из `nop`
- что проблема была не только в pipe, но и в формате ASM файла
- что после фикса код действительно стал:

```text
mov r10, #1000032
mov r1, #65
mov [r10 + 0], r1
```

### 2. Пробный файл `pipe_probe.asm`

Для проверки `SimplePipe` был сделан отдельный минимальный probe:

- [src/pipe_probe.asm](/d:/ITMO/СПО/SPO%203/src/pipe_probe.asm)

Он позволил изолированно проверить pipe без влияния логики `lab1`.

### 3. `ExecuteBinaryWithIo`

Запуск итоговой программы делался через:

```powershell
.\tools\RemoteTasks\Portable.RemoteTasks.Manager.exe `
  -sslcfg '.\tools\RemoteTasks\ssl-cfg.yaml' `
  -ul 505979 -up 9d7a3ade-42cd-4693-85e6-5367bbe31597 `
  -s ExecuteBinaryWithIo -ip `
  devices.xml src/TacVm13.irq-poc.devices.xml `
  definitionFile src/TacVm13.target.pdsl `
  archName TacVm13 `
  binaryFileToRun build/lab1.ptptb `
  codeRamBankName ram `
  ipRegStorageName ip `
  finishMnemonicName halt
```

## Важные нюансы

### 1. Для `irq-poc.devices.xml` нужен interactive session

При запуске с `SimplePipe` возникает требование:

```text
Pipe redirection requires interaction session!
```

Это означает:

- обычный quiet/background запуск не подходит
- нужен запуск с `-ip`

### 2. `irq-debug.devices.xml` не подходит для текстового вывода

В `irq-debug.devices.xml` есть:

- `SimplePic`
- `SimpleClock`

Но там нет `SimplePipe`.

Поэтому:

- таймер там работает
- текстовый вывод через pipe там не появится

### 3. Абсолютные MMIO-адреса опасны

Для TacVm13 важный практический вывод:

- абсолютная адресация годится не для всех устройств одинаково
- `SimplePic` с абсолютными адресами у нас работал
- `SimplePipe` пришлось переводить на register-relative доступ

Безопасное правило:

- для чувствительных MMIO-адресов лучше использовать базовый регистр + смещение

### 4. Голый `.asm` файл должен иметь секцию

Прямой ASM probe без строки:

```asm
[section ram, code]
```

собирался в бинарник, который в inspector выглядел как набор `nop`.

Для самостоятельных ASM-файлов нужно явно указывать секцию.

### 5. В pipe сейчас пишется 32-битное значение

Сейчас `pipeOut` уже рабочий, но в выводе видны байты вида:

```text
A\0\0\0
```

То есть в pipe уходит 32-битное значение символа, а не один чистый байт.

Практически это не мешает подтвердить работу программы, но для аккуратного вывода стоит отдельно доработать `pipeOut` до byte-exact записи.

## Какие команды использовались

### Перегенерация `lab1.asm`

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remote-parser.ps1 `
  -InputFile .\src\lab1.txt `
  -AsmOutput .\build\lab1.asm `
  -ParseTreeOutput .\build\lab1.dgml
```

### Сборка бинарника

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-assemble.ps1 `
  -AsmListing .\build\lab1.asm `
  -DefinitionFile .\src\TacVm13.target.pdsl `
  -ArchName TacVm13 `
  -BinaryOutput .\build\lab1.ptptb
```

### Запуск итогового `lab1`

```powershell
.\tools\RemoteTasks\Portable.RemoteTasks.Manager.exe `
  -sslcfg '.\tools\RemoteTasks\ssl-cfg.yaml' `
  -ul 505979 -up 9d7a3ade-42cd-4693-85e6-5367bbe31597 `
  -s ExecuteBinaryWithIo -ip `
  devices.xml src/TacVm13.irq-poc.devices.xml `
  definitionFile src/TacVm13.target.pdsl `
  archName TacVm13 `
  binaryFileToRun build/lab1.ptptb `
  codeRamBankName ram `
  ipRegStorageName ip `
  finishMnemonicName halt
```

## Вывод

Рабочая схема для Lab 1:

- реальный таймер через `timer.asm`
- алгоритм из `lab1.txt`
- вывод через `SimplePipe`
- запуск через `ExecuteBinaryWithIo` на `TacVm13.irq-poc.devices.xml`

Главный технический вывод:

- `SimplePipe` заработал только после перехода на register-relative MMIO access
- `pipeOut/pipeIn` через абсолютные адреса в TacVm13 были некорректны
