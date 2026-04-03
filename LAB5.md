# Лабораторная 5

Этот файл фиксирует рабочее состояние лабораторной 5 в текущем репозитории.

## Что проверяет текущий тест

Основной файл:

- `src/classTest.txt`

Он проверяет:

- шаблонный класс `List<T>`
- специализации `List<int>` и `List<Vec2i>`
- методы классов
- поля классов
- массивы как поля объекта
- перегруженные функции
- возврат объекта из функции

## Какая цепочка нужна

1. Сгенерировать `asm` и `dgml` удалённым парсером
2. Собрать `asm` в `.ptptb` через RemoteTasks
3. Запустить `.ptptb` на `TacVm13`

## Команды

### Генерация

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remote-parser.ps1 -InputFile .\src\classTest.txt -AsmOutput .\build\classTest.asm -ParseTreeOutput .\build\classTest.dgml -RemoteRunTimeoutSeconds 180
```

### Сборка

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-assemble.ps1 -AsmListing .\build\classTest.asm -DefinitionFile .\src\TacVm13.target.pdsl -ArchName TacVm13 -BinaryOutput .\build\classTest.ptptb
```

### Запуск

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\remotetasks-run.ps1 -BinaryFile .\build\classTest.ptptb -DefinitionFile .\src\TacVm13.target.pdsl -RunMode InteractiveInput -StdinRegStorage INPUT -StdoutRegStorage OUTPUT -ArchName TacVm13
```

## Ожидаемый результат

У свежей сборки должен быть вывод:

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

## Что уже исправлено под эту лабу

- классовые входы больше не зависят от `toStringTree()`
- поля внутри методов больше не путаются с локальными переменными
- heap-метки в `asm` теперь уникальны
- bootstrap всегда инициализирует heap-pointer
- скрипт сборки удаляет старый `.ptptb` перед новой сборкой

## Полезные артефакты

- `build/classTest.asm`
- `build/classTest.dgml`
- `build/classTest.ptptb`

## Связанные документы

- `TESTING.md`
- `VIRTUAL_MACHINE.md`
- `REMOTE_TASKS_MANAGER.md`
- `programm.md`
