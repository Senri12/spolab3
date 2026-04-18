# Q1 Complete

В папке `complete/` лежат готовые сценарии запуска варианта `q1` в двух режимах:

- обычный `complete` с подготовленным бинарным входом
- `raw200` с чтением сырого CSV напрямую

Все скрипты ниже можно запускать из корня репозитория. Они не зависят от текущего `cwd`.

## Быстрый запуск

### Бинарный вход, 50 строк

```powershell
powershell -ExecutionPolicy Bypass -File .\complete\run_q1_50.ps1
```

### Бинарный вход, 200 строк

```powershell
powershell -ExecutionPolicy Bypass -File .\complete\run_q1_200.ps1
```

### Сырой CSV, 200 строк

```powershell
powershell -ExecutionPolicy Bypass -File .\complete\run_q1_raw200.ps1
```

## Что делает каждый скрипт

- [compile_q1.ps1](/d:/ITMO/spolab3/complete/compile_q1.ps1:1) запускает только `remote-parser`
- [build_q1.ps1](/d:/ITMO/spolab3/complete/build_q1.ps1:1) запускает только `remotetasks-assemble`
- [run_q1_50.ps1](/d:/ITMO/spolab3/complete/run_q1_50.ps1:1) делает полный цикл `compile -> build -> run` для 50 строк
- [run_q1_200.ps1](/d:/ITMO/spolab3/complete/run_q1_200.ps1:1) делает полный цикл `compile -> build -> run` для 200 строк
- [run_q1_raw200.ps1](/d:/ITMO/spolab3/complete/run_q1_raw200.ps1:1) делает полный цикл `compile -> build -> run` для raw CSV-входа

## Входные данные

### Бинарный вариант `complete`

Используются уже подготовленные бинарные входы:

- `complete/data/q1.bin50.dat`
- `complete/data/q1.bin200.dat`

Они подключены через:

- [q1.devices.xml](/d:/ITMO/spolab3/complete/q1.devices.xml:1)
- [q1.devices200.xml](/d:/ITMO/spolab3/complete/q1.devices200.xml:1)

Это не сырой CSV, а нормализованный поток `int32 little-endian`.

### Raw-вариант `q1_raw200`

Используется прямое чтение CSV через:

- `complete/data/q1.types200.csv`
- `complete/data/q1.ved200.csv`

Конфигурация устройств:

- [q1.raw200.devices.xml](/d:/ITMO/spolab3/complete/q1.raw200.devices.xml:1)

Логика VM:

- [q1_raw200.txt](/d:/ITMO/spolab3/complete/q1_raw200.txt:1)

## Артефакты

### После `run_q1_50.ps1`

- `build/complete/q1_query.asm`
- `build/complete/q1_query.dgml`
- `build/complete/q1_query.ptptb`
- `complete/q1.result.txt`

### После `run_q1_200.ps1`

- `build/complete/q1_query.asm`
- `build/complete/q1_query.dgml`
- `build/complete/q1_query.ptptb`
- `complete/q1.result200.txt`

### После `run_q1_raw200.ps1`

- `build/task2_v71/q1_raw200.asm`
- `build/task2_v71/q1_raw200.dgml`
- `build/task2_v71/q1_raw200.ptptb`
- `build/task2_v71/q1.raw200.result.txt`

## Ручной запуск

### Бинарный вариант

```powershell
powershell -ExecutionPolicy Bypass -File .\complete\compile_q1.ps1
powershell -ExecutionPolicy Bypass -File .\complete\build_q1.ps1
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 -BinaryFile .\build\complete\q1_query.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -RunMode WithIo -DevicesFile .\complete\q1.devices.xml -ArchName TacVm13
```

Для `200` строк меняется только `DevicesFile`:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 -BinaryFile .\build\complete\q1_query.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -RunMode WithIo -DevicesFile .\complete\q1.devices200.xml -ArchName TacVm13
```

### Raw-вариант

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remote-parser.ps1 -InputFile .\complete\q1_raw200.txt -AsmOutput .\build\task2_v71\q1_raw200.asm -ParseTreeOutput .\build\task2_v71\q1_raw200.dgml
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-assemble.ps1 -AsmListing .\build\task2_v71\q1_raw200.asm -DefinitionFile .\src\TacVm13.target.pdsl -ArchName TacVm13 -BinaryOutput .\build\task2_v71\q1_raw200.ptptb -SkipInspectorEmbed
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 -BinaryFile .\build\task2_v71\q1_raw200.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -DevicesFile .\complete\q1.raw200.devices.xml -RunMode WithIo -ArchName TacVm13
```

## Полезные файлы

- [q1_query.txt](/d:/ITMO/spolab3/complete/q1_query.txt:1)
- [raw_pipe.empty.in](/d:/ITMO/spolab3/complete/raw_pipe.empty.in:1)
- [src/TacVm13.target.pdsl](/d:/ITMO/spolab3/src/TacVm13.target.pdsl:1)
- [tools/remote-parser.ps1](/d:/ITMO/spolab3/tools/remote-parser.ps1:1)
- [tools/remotetasks-assemble.ps1](/d:/ITMO/spolab3/tools/remotetasks-assemble.ps1:1)
- [tools/remotetasks-run.ps1](/d:/ITMO/spolab3/tools/remotetasks-run.ps1:1)

## Если RemoteTasks подвис

Посмотреть список задач:

```powershell
tools\RemoteTasks\Portable.RemoteTasks.Manager.exe -sslcfg tools\RemoteTasks\ssl-cfg.yaml -ul 505979 -up 9d7a3ade-42cd-4693-85e6-5367bbe31597 -l 0
```

Остановить локально зависшие менеджеры:

```powershell
Get-Process | Where-Object { $_.Path -like '*Portable.RemoteTasks.Manager.exe' } | Stop-Process -Force
```
