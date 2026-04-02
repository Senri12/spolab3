# Testing

Ниже рабочая инструкция для проверки всей цепочки:

```text
simpleLang -> удалённый ANTLR/parser -> .asm -> Portable.RemoteTasks -> .ptptb -> запуск через hidden INPUT/OUTPUT
```

Для первой проверки используй [src/test_echo.txt](d:/ITMO/СПО/SPO%203/src/test_echo.txt). Этот тест конечный и сейчас подтверждён.

## 1. Сгенерировать `asm` и `dgml`

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remote-parser.ps1 -InputFile .\src\test_echo.txt -AsmOutput .\build\test_echo.asm -ParseTreeOutput .\build\test_echo.dgml
```

Результат:

- [build/test_echo.asm](d:/ITMO/СПО/SPO%203/build/test_echo.asm)
- [build/test_echo.dgml](d:/ITMO/СПО/SPO%203/build/test_echo.dgml)

## 2. Собрать `asm` в `.ptptb`

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-assemble.ps1 -AsmListing .\build\test_echo.asm -DefinitionFile .\src\TacVm13.target.pdsl -ArchName TacVm13 -BinaryOutput .\build\test_echo.ptptb
```

Результат:

- [build/test_echo.ptptb](d:/ITMO/СПО/SPO%203/build/test_echo.ptptb)

## 3. Рекомендуемый запуск без интерактива

Входной файл уже подготовлен:

- [build/test_echo.stdin.txt](d:/ITMO/СПО/SPO%203/build/test_echo.stdin.txt)

Запуск:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 -BinaryFile .\build\test_echo.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -RunMode InputFile -InputFile .\build\test_echo.stdin.txt -StdinRegStorage INPUT -StdoutRegStorage OUTPUT -ArchName TacVm13
```

Ожидаемый вывод:

```text
BEGIN
GOT=x
```

## 4. Интерактивный запуск

Если хочется вводить руками:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 -BinaryFile .\build\test_echo.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -RunMode InteractiveInput -StdinRegStorage INPUT -StdoutRegStorage OUTPUT -ArchName TacVm13
```

Потом ввести один символ, например:

```text
X
```

Ожидаемый вывод:

```text
BEGIN
GOT=X
```

## 5. Проверка через `make`

Только генерация:

```powershell
make asm INPUT_FILE=src/test_echo.txt ASM_FILE=build/test_echo.asm DGML_FILE=build/test_echo.dgml
```

Генерация и сборка:

```powershell
make assemble INPUT_FILE=src/test_echo.txt ASM_FILE=build/test_echo.asm DGML_FILE=build/test_echo.dgml BINARY_FILE=build/test_echo.ptptb
```

Генерация, сборка и запуск без интерактива:

```powershell
make run INPUT_FILE=src/test_echo.txt ASM_FILE=build/test_echo.asm DGML_FILE=build/test_echo.dgml BINARY_FILE=build/test_echo.ptptb RUN_MODE=InputFile STDIN_FILE=build/test_echo.stdin.txt STDIN_REG=INPUT STDOUT_REG=OUTPUT
```

## 6. Про `src/test.txt`

[src/test.txt](d:/ITMO/СПО/SPO%203/src/test.txt) это интерактивный калькулятор с бесконечным циклом.

Формат ввода:

```text
<оператор><цифра><цифра>
```

Примеры:

```text
+23
-84
*56
/82
```

Особенности:

- программа сама не завершится
- в интерактивной консоли Windows ввод обычно уходит после `Enter`
- для smoke-test лучше сначала проверить [src/test_echo.txt](d:/ITMO/СПО/SPO%203/src/test_echo.txt)

## 7. Полезные файлы

- [src/TacVm13.target.pdsl](d:/ITMO/СПО/SPO%203/src/TacVm13.target.pdsl)
- [src/TacVm13.devices.xml](d:/ITMO/СПО/SPO%203/src/TacVm13.devices.xml)
- [build/test_echo.asm](d:/ITMO/СПО/SPO%203/build/test_echo.asm)
- [build/test_echo.dgml](d:/ITMO/СПО/SPO%203/build/test_echo.dgml)
- [build/test_echo.ptptb](d:/ITMO/СПО/SPO%203/build/test_echo.ptptb)
