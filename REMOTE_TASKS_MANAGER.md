# Portable.RemoteTasks.Manager.exe

Памятка по тулзе:

- файл: `tools/RemoteTasks/Portable.RemoteTasks.Manager.exe`
- рядом с ней:
  - `tools/RemoteTasks/ssl-cfg.yaml`
  - `tools/RemoteTasks/Portable.Common.dll`
  - `tools/RemoteTasks/Portable.RemoteTasks.Interaction.dll`
  - `tools/RemoteTasks/websocket-sharp.dll`

Это не локальный assembler и не локальная VM. Это клиент к удалённому сервису RemoteTasks, который:

- принимает задачу
- запускает её на стороне сервиса
- возвращает статус
- даёт скачать результаты
- умеет интерактивно прокидывать ввод-вывод

## 1. Что он делает у нас в проекте

В проекте `Portable.RemoteTasks.Manager.exe` используется в двух местах:

- сборка `asm -> ptptb`
- запуск `.ptptb`

Скрипты:

- `tools/remotetasks-assemble.ps1`
- `tools/remotetasks-run.ps1`

То есть руками его обычно вызывать не нужно: проще использовать эти два PowerShell-скрипта.

## 2. Что удалось подтвердить

По фактическому использованию в проекте и по строкам, вшитым в `Portable.RemoteTasks.Manager.exe`, подтверждены такие ключи:

- `-sslcfg`
- `-sh`
- `-sp`
- `-ul`
- `-up`
- `-h`
- `-v`
- `-vv`
- `-a`
- `-t`
- `-g`
- `-r`
- `-o`
- `-k`
- `-l`
- `-s`
- `-id`
- `-w`
- `-q`
- `-ib`
- `-ik`
- `-il`
- `-is`
- `-ip`

Важно:

- нормальная консольная справка у бинарника неудобная
- без `-ul` / `-up` менеджер пытается спрашивать логин и пароль интерактивно
- если запускать его из неподходящего контекста, можно получить ошибки вроде `Неверный дескриптор` или сообщение про невозможность считывать клавиши

## 3. Основные ключи

Ниже то, что реально полезно для работы.

### 3.1. Подключение и авторизация

- `-sslcfg <path>`
  - путь к SSL-конфигу
  - у нас это `tools/RemoteTasks/ssl-cfg.yaml`
- `-sh <host>`
  - host сервиса
- `-sp <port>`
  - port сервиса
  - в строках бинарника видно `default 10000`
- `-ul <login>`
  - логин пользователя
- `-up <password>`
  - пароль пользователя

Полезно:

- в бинарнике видны env-переменные
  - `Portable.RemoteTasks.Manager.Login`
  - `Portable.RemoteTasks.Manager.Password`
  - `Portable.RemoteTasks.Manager.Host`
  - `Portable.RemoteTasks.Manager.Port`

То есть логин, пароль, host и port можно задавать не только флагами, но и через переменные окружения.

### 3.2. Сервисные действия

- `-a`
  - получить список доступных задач
- `-t`
  - получить информацию о параметрах задачи
- `-l`
  - список последних task instances
- `-g <taskId>`
  - получить состояние задачи по ID
- `-k <taskId>`
  - убить задачу по ID
- `-r <resultName>`
  - запросить результат задачи
- `-o <file>`
  - записать скачанный результат в файл

### 3.3. Запуск задачи

- `-s <TaskName>`
  - старт задачи по имени

После `-s` идут параметры задачи:

```text
param1 value1 param2 value2 ...
```

Пример из проекта:

```powershell
Portable.RemoteTasks.Manager.exe -sslcfg tools/RemoteTasks/ssl-cfg.yaml -ul LOGIN -up PASSWORD -s ExecuteBinaryWithInput -ib stdinRegStName INPUT stdoutRegStName OUTPUT inputFile build/test_echo.stdin.txt definitionFile src/TacVm13.target.pdsl archName TacVm13 binaryFileToRun build/test_echo.ptptb codeRamBankName ram ipRegStorageName ip finishMnemonicName halt
```

## 4. Полезные task names

### 4.1. Точно используемые у нас

- `Assemble`
- `ExecuteBinaryWithInteractiveInput`
- `ExecuteBinaryWithInput`
- `ExecuteBinaryWithIo`

### 4.2. Ещё замеченные в проекте

В `tools/launch.example.json` есть пример с:

- `MachineDebugBinary`

Ранее в проекте также использовались и упоминались debug-варианты наподобие:

- `MachineDebugBinaryWithInteractiveInput`

Но для текущей сборки и обычного запуска нам они не нужны.

## 5. Режимы интерактивности

По строкам бинарника видны такие режимы:

- `-ib`
  - interactive byte mode
- `-ik`
  - interactive key mode
- `-il`
  - interactive line mode
- `-is`
  - interactive stream mode
- `-ip`
  - interactive pipe mode

Что используем мы:

- почти везде `-ib`

Почему:

- наша VM работает с байтовым вводом-выводом
- `INPUT` и `OUTPUT` тоже используются как байтовый канал
- `vm0device` в режиме `WithIo` тоже по сути ведёт себя как byte stream

## 6. Наши рабочие сценарии

### 6.1. Сборка asm в ptptb

Это делает `tools/remotetasks-assemble.ps1`.

По сути внутри вызывается что-то такое:

```powershell
Portable.RemoteTasks.Manager.exe `
  -sslcfg tools/RemoteTasks/ssl-cfg.yaml `
  -ul LOGIN `
  -up PASSWORD `
  -q -w `
  -s Assemble `
  asmListing build/test_program.asm `
  definitionFile src/TacVm13.target.pdsl `
  archName TacVm13
```

Потом скрипт:

- вытаскивает `taskId` из вывода
- делает `-g <taskId>`
- скачивает `out.ptptb` через `-g <taskId> -r out.ptptb -o <local file>`

То есть для `Assemble` важны:

- `asmListing`
- `definitionFile`
- `archName`

### 6.2. Запуск бинарника с hidden INPUT/OUTPUT

Это основной путь у нас.

Интерактивно:

```powershell
Portable.RemoteTasks.Manager.exe `
  -sslcfg tools/RemoteTasks/ssl-cfg.yaml `
  -ul LOGIN `
  -up PASSWORD `
  -s ExecuteBinaryWithInteractiveInput `
  -ib `
  stdinRegStName INPUT `
  stdoutRegStName OUTPUT `
  definitionFile src/TacVm13.target.pdsl `
  archName TacVm13 `
  binaryFileToRun build/test_program.ptptb `
  codeRamBankName ram `
  ipRegStorageName ip `
  finishMnemonicName halt
```

С входным файлом:

```powershell
Portable.RemoteTasks.Manager.exe `
  -sslcfg tools/RemoteTasks/ssl-cfg.yaml `
  -ul LOGIN `
  -up PASSWORD `
  -s ExecuteBinaryWithInput `
  -ib `
  stdinRegStName INPUT `
  stdoutRegStName OUTPUT `
  inputFile build/test_program_plus12.stdin.txt `
  definitionFile src/TacVm13.target.pdsl `
  archName TacVm13 `
  binaryFileToRun build/test_program.ptptb `
  codeRamBankName ram `
  ipRegStorageName ip `
  finishMnemonicName halt
```

Что здесь важно:

- `stdinRegStName INPUT`
- `stdoutRegStName OUTPUT`
- `codeRamBankName ram`
- `ipRegStorageName ip`
- `finishMnemonicName halt`

### 6.3. Запуск через vm0device

Это запасной режим.

```powershell
Portable.RemoteTasks.Manager.exe `
  -sslcfg tools/RemoteTasks/ssl-cfg.yaml `
  -ul LOGIN `
  -up PASSWORD `
  -s ExecuteBinaryWithIo `
  -ib `
  devices.xml src/TacVm13.devices.xml `
  definitionFile src/TacVm13.target.pdsl `
  archName TacVm13 `
  binaryFileToRun build/test_program.ptptb `
  codeRamBankName ram `
  ipRegStorageName ip `
  finishMnemonicName halt
```

Главное отличие:

- вместо `stdinRegStName` / `stdoutRegStName` используется `devices.xml`

## 7. Что означают часто встречающиеся параметры задач

Эти параметры не являются ключами самого менеджера. Это параметры конкретной удалённой задачи после `-s`.

У нас чаще всего встречаются:

- `asmListing`
  - путь к `.asm`
- `definitionFile`
  - путь к `.target.pdsl`
- `archName`
  - имя архитектуры, у нас `TacVm13`
- `binaryFileToRun`
  - путь к `.ptptb`
- `codeRamBankName`
  - имя code bank, у нас `ram`
- `ipRegStorageName`
  - имя регистра instruction pointer, у нас `ip`
- `finishMnemonicName`
  - имя инструкции завершения, у нас `halt`
- `stdinRegStName`
  - storage для входа, у нас `INPUT`
- `stdoutRegStName`
  - storage для выхода, у нас `OUTPUT`
- `inputFile`
  - файл входа для режима `ExecuteBinaryWithInput`
- `devices.xml`
  - XML устройств для режима `ExecuteBinaryWithIo`

## 8. Что значат флаги `-q`, `-w`, `-id`

По встроенным строкам бинарника:

- `-w`
  - ждать завершения запущенной задачи
- `-q`
  - не печатать итоговый вывод задачи при завершении
- `-id`
  - печатать только ID задачи

Практически у нас:

- при `Assemble` используется `-q -w`
- потом скрипт отдельно делает `-g` и скачивает артефакт

## 9. Конфиг SSL

Файл:

- `tools/RemoteTasks/ssl-cfg.yaml`

Он нужен, потому что менеджер подключается к удалённому сервису по защищённому соединению.

Что видно по бинарнику:

- он умеет грузить SSL-конфигурацию из `ssl-cfg.yaml`
- без неё может не подняться соединение
- внутри конфига лежит CA certificate

То есть для проекта этот файл обязателен.

## 10. Типичные ошибки

### 10.1. `Неверный дескриптор`

Обычно появляется, когда менеджер запущен не в том режиме интерактива или пытается читать консоль там, где её нет.

### 10.2. Ошибка про невозможность считывать клавиши

Типично возникает, если не передать `-ul` / `-up`, и менеджер пытается спросить логин и пароль вручную.

### 10.3. `Failed to start Assemble task`

Смотри:

- правильный ли `-sslcfg`
- верны ли логин и пароль
- существует ли `asmListing`
- существует ли `definitionFile`
- совпадает ли `archName`

### 10.4. `ExecuteBinaryWithInput failed`

Смотри:

- существует ли `inputFile`
- правильно ли указаны `stdinRegStName` / `stdoutRegStName`
- совпадает ли `finishMnemonicName`
- собран ли бинарник под тот же `definitionFile`

### 10.5. Бинарник “запускается”, но вывода нет

Проверяй:

- используется ли правильный режим:
  - `ExecuteBinaryWithInteractiveInput`
  - `ExecuteBinaryWithInput`
  - `ExecuteBinaryWithIo`
- совпадает ли схема I/O у программы и у запуска
- не бесконечный ли сам тест

Например:

- `test_echo` удобен как smoke-test
- `test.txt` это бесконечный калькулятор

## 11. Что использовать руками, а что нет

Рекомендация для проекта:

- для повседневной работы использовать:
  - `tools/remotetasks-assemble.ps1`
  - `tools/remotetasks-run.ps1`
- `Portable.RemoteTasks.Manager.exe` напрямую вызывать только если:
  - надо диагностировать проблему
  - надо подобрать другой task name
  - надо скачать результаты вручную
  - надо дебажить нестандартный сценарий

## 12. Минимальные рабочие команды для проекта

### Сборка

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-assemble.ps1 -AsmListing .\build\test_program.asm -DefinitionFile .\src\TacVm13.target.pdsl -ArchName TacVm13 -BinaryOutput .\build\test_program.ptptb
```

### Запуск с файлом ввода

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 -BinaryFile .\build\test_program.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -RunMode InputFile -InputFile .\build\test_program_plus12.stdin.txt -StdinRegStorage INPUT -StdoutRegStorage OUTPUT -ArchName TacVm13
```

### Интерактивный запуск

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 -BinaryFile .\build\test_program.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -RunMode InteractiveInput -StdinRegStorage INPUT -StdoutRegStorage OUTPUT -ArchName TacVm13
```

### Запуск через vm0device

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 -BinaryFile .\build\test_program.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -DevicesFile .\src\TacVm13.devices.xml -RunMode WithIo -ArchName TacVm13
```

## 13. Что считать источником правды

Если что-то расходится:

1. `tools/remotetasks-assemble.ps1`
2. `tools/remotetasks-run.ps1`
3. `tools/launch.example.json`
4. встроенные строки `Portable.RemoteTasks.Manager.exe`
5. эта памятка
