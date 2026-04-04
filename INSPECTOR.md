# Inspector

Памятка по лабораторной 4.

## Что уже встроено

- `remote-parser.ps1` скачивает:
  - `asm`
  - `dgml`
  - `asm.sym`
- генератор пишет в `asm`:
  - `;; source-file <index> <path>`
  - `;#src <file> <line> <column>`
- `remotetasks-assemble.ps1` после сборки `.ptptb` автоматически запускает `SpoInspector embed` и добавляет секцию `simplelang.debug.json`

## Быстрый запуск

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remote-parser.ps1 -InputFile .\src\test.txt -AsmOutput .\build\inspect_test.asm -ParseTreeOutput .\build\inspect_test.dgml -RemoteRunTimeoutSeconds 180
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-assemble.ps1 -AsmListing .\build\inspect_test.asm -BinaryOutput .\build\inspect_test.ptptb
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-inspect.ps1 -BinaryFile .\build\inspect_test.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -RunMode plain
```

## Режимы запуска

- `plain`: MI-отладка без устройств и без stdin-файла
- `inputfile`: запуск с `-InputFile`
- `withio`: запуск через `devices.xml`

Примеры:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-inspect.ps1 -BinaryFile .\build\test_echo.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -RunMode inputfile -InputFile .\build\test_echo.stdin.txt
```

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-inspect.ps1 -BinaryFile .\build\irq_poc.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -RunMode withio -DevicesFile .\src\TacVm13.devices.xml
```

## Основные команды

- `help`
- `regs`
- `mem [bank] addr n`
- `disas [addr] [n]`
- `step [n]`
- `nextsrc`
- `cont [max]`
- `break addr`
- `bline line`
- `del addr`
- `dline line`
- `breaks`
- `line`
- `locals`
- `bt`
- `run`
- `quit`

## Что показывает инспектор

- регистры и память
- дизассемблирование по адресам
- переход по исходным выражениям через `nextsrc`
- текущий фрагмент исходника через `line`
- локальные переменные и аргументы через `locals`
- стек вызовов через `bt`
- breakpoint по адресу и по строке исходника

## Ограничения

- интерактивный stdin программы не совмещён с REPL инспектора, потому что stdin занят MI-командами
- для программ с вводом используй `inputfile` или `withio`
- если `Portable.RemoteTasks.Manager.exe` завис после неудачной сессии, его нужно завершить вручную
