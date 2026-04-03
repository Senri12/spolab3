# Testing

Этот файл содержит короткие рабочие сценарии проверки проекта.

## Цепочка

```text
simpleLang source
-> remote-parser.ps1
-> asm + dgml
-> remotetasks-assemble.ps1
-> ptptb
-> remotetasks-run.ps1
```

## 1. Smoke-test: `test_echo`

Это самый короткий тест всей цепочки.

### Сгенерировать `asm`

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remote-parser.ps1 -InputFile .\src\test_echo.txt -AsmOutput .\build\test_echo.asm -ParseTreeOutput .\build\test_echo.dgml
```

### Собрать бинарник

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-assemble.ps1 -AsmListing .\build\test_echo.asm -DefinitionFile .\src\TacVm13.target.pdsl -ArchName TacVm13 -BinaryOutput .\build\test_echo.ptptb
```

### Запустить с файлом ввода

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 -BinaryFile .\build\test_echo.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -RunMode InputFile -InputFile .\build\test_echo.stdin.txt -StdinRegStorage INPUT -StdoutRegStorage OUTPUT -ArchName TacVm13
```

Ожидаемый вывод:

```text
BEGIN
GOT=x
```

## 2. Интерактивный калькулятор: `test.txt`

Это бесконечный цикл, поэтому тестировать его надо интерактивно.

### Сгенерировать и собрать

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remote-parser.ps1 -InputFile .\src\test.txt -AsmOutput .\build\test_program.asm -ParseTreeOutput .\build\test_program.dgml
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-assemble.ps1 -AsmListing .\build\test_program.asm -DefinitionFile .\src\TacVm13.target.pdsl -ArchName TacVm13 -BinaryOutput .\build\test_program.ptptb
```

### Запустить интерактивно

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 -BinaryFile .\build\test_program.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -RunMode InteractiveInput -StdinRegStorage INPUT -StdoutRegStorage OUTPUT -ArchName TacVm13
```

Ввод:

```text
+12
*34
-84
/82
```

Ожидаемо:

```text
>3
>12
>4
>4
>
```

Последний `>` нормален: программа уже начала следующую итерацию, потом увидела EOF или ждёт новый ввод.

## 3. Лабораторная 5: `classTest.txt`

Текущий `src/classTest.txt` проверяет:

- шаблонный класс `List<T>`
- специализации `List<int>` и `List<Vec2i>`
- массивы в полях класса
- методы классов
- перегруженные функции `printValue(int)` и `printValue(Vec2i)`
- возврат объекта из функции `makeVec2i`

### Сгенерировать `asm`

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remote-parser.ps1 -InputFile .\src\classTest.txt -AsmOutput .\build\classTest.asm -ParseTreeOutput .\build\classTest.dgml -RemoteRunTimeoutSeconds 180
```

### Собрать бинарник

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-assemble.ps1 -AsmListing .\build\classTest.asm -DefinitionFile .\src\TacVm13.target.pdsl -ArchName TacVm13 -BinaryOutput .\build\classTest.ptptb
```

### Запустить

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 -BinaryFile .\build\classTest.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -RunMode InteractiveInput -StdinRegStorage INPUT -StdoutRegStorage OUTPUT -ArchName TacVm13
```

Ожидаемый вывод свежей сборки:

```text
vn
0
1
2
3
4
5
6
7
8
9
10
11
12
13
14
15
16
17
18
19
S=190
vec2
x=190
y=-170
vv
x=0
y=20
x=1
y=19
x=2
y=18
x=3
y=17
x=4
y=16
x=5
y=15
x=6
y=14
x=7
y=13
x=8
y=12
x=9
y=11
x=10
y=10
x=11
y=9
x=12
y=8
x=13
y=7
x=14
y=6
x=15
y=5
x=16
y=4
x=17
y=3
x=18
y=2
x=19
y=1
```

## 4. Полезные замечания

- `remote-parser.ps1` использует удалённый сервер по `ssh` и ANTLR jar `/usr/local/lib/antlr-3.4-complete.jar`
- для длинных программ у `remote-parser.ps1` полезен `-RemoteRunTimeoutSeconds 180`
- `remotetasks-assemble.ps1` теперь удаляет старый выходной `.ptptb` перед новой сборкой, чтобы нельзя было случайно запустить устаревший бинарник
- если нужен запасной режим запуска через устройства, используй `-RunMode WithIo` и `src/TacVm13.devices.xml`

## 5. Через `make`

### Только `asm`

```powershell
make asm INPUT_FILE=src/classTest.txt ASM_FILE=build/classTest.asm DGML_FILE=build/classTest.dgml
```

### `asm + ptptb`

```powershell
make assemble INPUT_FILE=src/classTest.txt ASM_FILE=build/classTest.asm DGML_FILE=build/classTest.dgml BINARY_FILE=build/classTest.ptptb
```

### Полный запуск

```powershell
make run INPUT_FILE=src/classTest.txt ASM_FILE=build/classTest.asm DGML_FILE=build/classTest.dgml BINARY_FILE=build/classTest.ptptb RUN_MODE=InteractiveInput STDIN_REG=INPUT STDOUT_REG=OUTPUT
```
