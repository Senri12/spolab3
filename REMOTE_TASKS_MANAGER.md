# Portable.RemoteTasks.Manager.exe

Памятка по тулзе:

- файл: `tools/RemoteTasks/Portable.RemoteTasks.Manager.exe`
- ssl-конфиг: `tools/RemoteTasks/ssl-cfg.yaml`

Это клиент к удаленному сервису RemoteTasks. В проекте он используется только для:

- сборки `asm -> ptptb`
- запуска `ptptb`

Рекомендуемый способ работы не через ручной вызов `.exe`, а через скрипты:

- `tools/remotetasks-assemble.ps1`
- `tools/remotetasks-run.ps1`

## Основные task names

Подтверждённые задачи:

- `Assemble`
- `ExecuteBinaryWithInteractiveInput`
- `ExecuteBinaryWithInput`
- `ExecuteBinaryWithIo`

## Полезные ключи менеджера

Ключи самого менеджера:

- `-sslcfg`
- `-ul`
- `-up`
- `-s`
- `-g`
- `-r`
- `-o`
- `-w`
- `-q`
- `-ib`

Что они значат у нас:

- `-sslcfg <path>`: путь к `ssl-cfg.yaml`
- `-ul <login>`: логин
- `-up <password>`: пароль
- `-s <TaskName>`: запуск удалённой задачи
- `-g <taskId>`: получить состояние задачи
- `-r <resultName>`: запросить артефакт результата
- `-o <file>`: сохранить артефакт локально
- `-w`: дождаться завершения
- `-q`: не печатать лишний итоговый вывод
- `-ib`: byte-oriented interactive mode

## Параметры задач после `-s`

Это уже не ключи менеджера, а параметры конкретной удалённой задачи.

Чаще всего используются:

- `asmListing`
- `definitionFile`
- `archName`
- `binaryFileToRun`
- `codeRamBankName`
- `ipRegStorageName`
- `finishMnemonicName`
- `stdinRegStName`
- `stdoutRegStName`
- `inputFile`
- `devices.xml`

## Как у нас устроена сборка

Скрипт `tools/remotetasks-assemble.ps1` делает следующее:

1. удаляет старый выходной `.ptptb`, если он уже есть
2. запускает `Assemble`
3. достаёт `taskId`
4. ждёт завершения задачи
5. скачивает `out.ptptb` в нужный файл

Рабочая команда:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-assemble.ps1 -AsmListing .\build\classTest.asm -DefinitionFile .\src\TacVm13.target.pdsl -ArchName TacVm13 -BinaryOutput .\build\classTest.ptptb
```

Почему важно удаление старого бинарника:

- если новая сборка упала, в `build` не останется старого `.ptptb`
- это защищает от ложного запуска устаревшего бинарника

## Как у нас устроен запуск

Основной режим:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 -BinaryFile .\build\classTest.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -RunMode InteractiveInput -StdinRegStorage INPUT -StdoutRegStorage OUTPUT -ArchName TacVm13
```

Режимы `RunMode`:

- `InteractiveInput`
- `InputFile`
- `WithIo`

Семантика:

- `InteractiveInput`: hidden `INPUT/OUTPUT`, ручной ввод
- `InputFile`: hidden `INPUT/OUTPUT`, ввод из файла
- `WithIo`: запуск через `vm0device` и `TacVm13.devices.xml`

## Эквивалентные ручные вызовы

### Assemble

```powershell
Portable.RemoteTasks.Manager.exe -sslcfg tools/RemoteTasks/ssl-cfg.yaml -ul LOGIN -up PASSWORD -q -w -s Assemble asmListing build/classTest.asm definitionFile src/TacVm13.target.pdsl archName TacVm13
```

### ExecuteBinaryWithInteractiveInput

```powershell
Portable.RemoteTasks.Manager.exe -sslcfg tools/RemoteTasks/ssl-cfg.yaml -ul LOGIN -up PASSWORD -s ExecuteBinaryWithInteractiveInput -ib stdinRegStName INPUT stdoutRegStName OUTPUT definitionFile src/TacVm13.target.pdsl archName TacVm13 binaryFileToRun build/classTest.ptptb codeRamBankName ram ipRegStorageName ip finishMnemonicName halt
```

### ExecuteBinaryWithInput

```powershell
Portable.RemoteTasks.Manager.exe -sslcfg tools/RemoteTasks/ssl-cfg.yaml -ul LOGIN -up PASSWORD -s ExecuteBinaryWithInput -ib stdinRegStName INPUT stdoutRegStName OUTPUT inputFile build/test_echo.stdin.txt definitionFile src/TacVm13.target.pdsl archName TacVm13 binaryFileToRun build/test_echo.ptptb codeRamBankName ram ipRegStorageName ip finishMnemonicName halt
```

### ExecuteBinaryWithIo

```powershell
Portable.RemoteTasks.Manager.exe -sslcfg tools/RemoteTasks/ssl-cfg.yaml -ul LOGIN -up PASSWORD -s ExecuteBinaryWithIo -ib devices.xml src/TacVm13.devices.xml definitionFile src/TacVm13.target.pdsl archName TacVm13 binaryFileToRun build/test_echo.ptptb codeRamBankName ram ipRegStorageName ip finishMnemonicName halt
```

## Типичные ошибки

### `Assemble task failed`

Проверь:

- существует ли `asmListing`
- существует ли `definitionFile`
- правильный ли `archName`
- нет ли дублирующихся меток в `asm`

### После неудачной сборки запускается старая программа

Такого в текущем скрипте быть не должно: `remotetasks-assemble.ps1` удаляет старый выходной файл до сборки.

### `ExecuteBinaryWithInput failed` или `ExecuteBinaryWithInteractiveInput failed`

Проверь:

- правильный ли `RunMode`
- совпадают ли `stdinRegStName` / `stdoutRegStName` с `INPUT` / `OUTPUT`
- тот ли `definitionFile` используется
- есть ли нужный `.ptptb`

## Источник правды

Если что-то расходится, верить в таком порядке:

1. `tools/remotetasks-assemble.ps1`
2. `tools/remotetasks-run.ps1`
3. `tools/launch.example.json`
4. реальному поведению `Portable.RemoteTasks.Manager.exe`
5. этому файлу
