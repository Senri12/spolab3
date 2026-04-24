# Лабораторная работа 2 — Синхронизация и потоки данных

## Описание

Многопоточный pipeline для обработки CSV данных на StackVMCore.

**Запрос (вариант 68):** RIGHT JOIN Н_ТИПЫ_ВЕДОМОСТЕЙ и Н_ВЕДОМОСТИ
**Фильтр:** НАИМЕНОВАНИЕ > 'Ведомость' (ТВ_ИД ≥ 2) AND ЧЛВК_ИД > 153285
**Вывод:** ТВ_ИД;ДАТА(YYYYMMDD)

## Архитектура

3 потока, связанные software pipe'ами (lock-free ring buffer):

```
[CSV file] → parseVedmosti → pipe1 → filterRows → pipe2 → formatOutput → [result file]
```

- **parseVedmosti** — парсит CSV из SimplePipe (SyncReceive), извлекает ЧЛВК_ИД, ДАТА, ТВ_ИД
- **filterRows** — фильтрует: ЧЛВК_ИД > 153285 AND ТВ_ИД ≥ 2
- **formatOutput** — форматирует результат как "ТВ_ИД;ДАТА\n", пишет в SimplePipe (SyncSend)

## Реализация

- **Кооперативная многозадачность** — `rtYield` переключает контекст между потоками
- **Software Pipe** — lock-free ring buffer в ASM (swPipeCreate/Write/Read/Close)
  - Writer модифицирует только tail, Reader только head — нет race conditions
  - При full → yield, при empty → yield или EOF
- **Пассивное ожидание** — state=WAITING(4) в TCB, ISR пропускает спящие потоки
- **Device I/O** — два SimplePipe: fifo:in для CSV, fifo:out для результата

## Файлы

| Файл | Описание |
|------|----------|
| `pipeline.sl` | SL программа: потоки-обработчики, CSV парсинг |
| `threads_runtime.asm` | ASM runtime: yield, pipe API, thread management |
| `stack_vm_core_threads.target.pdsl` | PDSL архитектура (getsp/setsp/getrp/setrp) |
| `devices.xml` | SimplePipe devices (fifo:in + fifo:out) |
| `lab2.ptptb` | Собранный бинарник |

## Сборка и запуск

### 1. Подготовить входные данные

```bash
# Все matching строки (~1171)
./lab2_threads_pipe/prepare_data.sh

# Или ограничить N строк
./lab2_threads_pipe/prepare_data.sh 50
```

### 2. Собрать бинарник

```bash
./lab2_threads_pipe/build.sh
```

### 3. Запустить

```bash
./lab2_threads_pipe/run.sh
```

Результат в `/tmp/lab2_output.txt`.

### Ручной запуск

```bash
# Подготовить CSV (4 столбца: ID;CHELVK;DATA;TV + sentinel "0")
(echo "ID;CHELVK;DATA;TV"
 awk -F';' 'NR>1 && $2+0 > 153285 && $8+0 >= 2 { print $1";"$2";"$6";"$8 }' \
   "dump_db/_Н_ВЕДОМОСТИ__202603141056_postgres_2.csv"
 echo "0") > /tmp/test_vedmosti.csv

# Запустить
rm -f /tmp/lab2_output.txt
echo "" | mono "utility-from-teacher/RemoteTasks (1)/Portable.RemoteTasks.Manager.exe" \
  -ul 506556 -up 1fe63b3f-271c-464f-8cb4-0bf34530bb40 \
  -sslcfg "utility-from-teacher/RemoteTasks (1)/ssl-cfg.yaml" \
  -s ExecuteBinaryWithIo -w -ip \
  devices.xml lab2_threads_pipe/devices.xml \
  definitionFile lab2_threads_pipe/stack_vm_core_threads.target.pdsl \
  archName StackVMCore \
  binaryFileToRun lab2_threads_pipe/lab2.ptptb \
  codeRamBankName CODE \
  ipRegStorageName PC \
  finishMnemonicName hlt

# Проверить результат
wc -l /tmp/lab2_output.txt
cat /tmp/lab2_output.txt
```

## Результат

На полном наборе (~1171 предфильтрованных строк):
- **1170 строк** корректного вывода
- Формат: `ТВ_ИД;ДАТА` (например `2;20100611`, `3;20101126`)
- Время обработки: ~15 минут на remote VM
