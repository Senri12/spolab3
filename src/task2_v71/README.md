# Task 2, variant 71

Реализация первого запроса варианта 71 на урезанных CSV для отладки.

- `q1_query.txt` — побайтово читает два CSV из отдельных `SimplePipe`, разбирает нужные числовые поля и выполняет первый запрос.
- `q1.devices.xml` — конфигурация трёх устройств: два входных pipe с урезанными CSV и один выходной pipe.
- `raw_pipe.empty.in` — пустой вход для выходного pipe.

Тестовые CSV лежат в `build/task2_v71/`:

- `q1.types50.csv`
- `q1.ved50.csv`

Команды:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remote-parser.ps1 -InputFile .\src\task2_v71\q1_byte_debug.txt -AsmOutput .\build\task2_v71\q1_byte_debug.asm -ParseTreeOutput .\build\task2_v71\q1_byte_debug.dgml -RemoteRunTimeoutSeconds 180
powershell -ExecutionPolicy Bypass -File .\tools\remote-parser.ps1 -InputFile .\src\task2_v71\q1_query.txt -AsmOutput .\build\task2_v71\q1_query.asm -ParseTreeOutput .\build\task2_v71\q1_query.dgml -RemoteRunTimeoutSeconds 180
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-assemble.ps1 -AsmListing .\build\task2_v71\q1_query.asm -DefinitionFile .\src\TacVm13.target.pdsl -ArchName TacVm13 -BinaryOutput .\build\task2_v71\q1_query.ptptb -SkipInspectorEmbed
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 -BinaryFile .\build\task2_v71\q1_query.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -RunMode WithIo -DevicesFile .\src\task2_v71\q1.devices.xml -ArchName TacVm13
```

После запуска результат появится в `build/task2_v71/q1.result.txt`.
