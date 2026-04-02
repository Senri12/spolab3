#include <ctype.h>
#include <errno.h>
#include <stdint.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_CODE_SIZE 32768
#define MAX_SYMBOLS 8192
#define MAX_LINE_LEN 256

// ========== Определение бинарного формата ==========

// Устанавливаем выравнивание в 1 байт для структур
#pragma pack(push, 1)

// Режимы адресации операндов
typedef enum {
  OP_NONE = 0,
  OP_REG,
  OP_IMM,
  OP_MEM,
  OP_LABEL  // В ассемблере эта метка превратится в OP_IMM с адресом
} OpKind;

// Операнд в бинарном файле
typedef struct {
  uint8_t kind;      // OpKind
  int32_t value;     // Для IMM: значение; для MEM: смещение
  int32_t base_reg;  // Для REG: номер регистра; для MEM: базовый регистр
} EncodedOperand;

// Инструкция в бинарном файле (3 операнда для общности)
typedef struct {
  uint8_t opcode;
  EncodedOperand ops[3];
} EncodedInstruction;

// --- Debug section on-disk format (packed, little-endian) ---
#define DEBUG_MAGIC 0x54444247u  // "TDBG"
#define DEBUG_VERSION 1

typedef struct {
  uint32_t magic;
  uint16_t version;
  uint16_t reserved;
  uint32_t func_count;
  uint32_t line_count;
  uint32_t var_count;
  uint32_t func_table_offset;
  uint32_t line_table_offset;
  uint32_t var_table_offset;
  uint32_t str_table_offset;
  uint32_t str_table_size;
} DebugHeader;

typedef struct {
  uint32_t name_offset;  // offset inside string table
  uint32_t start_addr;   // instruction index (inclusive)
  uint32_t end_addr;     // instruction index (exclusive)
  uint32_t first_line;   // index in line table
  uint32_t line_count;
  uint32_t first_var;  // index in var table
  uint32_t var_count;
} DebugFuncEntry;

typedef struct {
  uint32_t func_index;
  uint32_t line;
  uint32_t addr;  // instruction index
} DebugLineEntry;

typedef struct {
  uint32_t func_index;
  int32_t fp_offset;  // offset relative to FP
  uint8_t is_arg;     // 1 = arg, 0 = local
  uint8_t reserved[3];
  uint32_t name_offset;
} DebugVarEntry;

// Восстанавливаем предыдущее выравнивание
#pragma pack(pop)

// ========== Определения мнемоник и регистров ==========

// Коды операций
enum Opcodes {
  OP_NOP = 0,
  OP_MOV,
  OP_PUSH,
  OP_POP,
  OP_ADD,
  OP_SUB,
  OP_MUL,
  OP_DIV,
  OP_AND,
  OP_OR,
  OP_XOR,
  OP_NOT,
  OP_SHL,
  OP_SHR,
  OP_CMP,
  OP_JMP,
  OP_BEQ,
  OP_BNE,
  OP_BLT,
  OP_BGT,
  OP_BLE,
  OP_BGE,
  OP_CALL,
  OP_RET,
  OP_IN,
  OP_OUT,
  OP_HALT,
  OP_IRET,
  OP_TRAP
};


const char* MNEMONICS[] = {
    "nop", "mov", "push", "pop",  "add", "sub", "mul",  "div", "and",
    "or",  "xor", "not",  "shl",  "shr", "cmp", "jmp",  "beq", "bne",
    "blt", "bgt", "ble",  "bge",  "call","ret", "in",   "out", "halt",
    "iret", "trap"};


const int MNEMONIC_COUNT = sizeof(MNEMONICS) / sizeof(char*);
// Количество операндов для каждой инструкции
const int OPERAND_COUNTS[] = {
    /* nop */ 0,
    /* mov */ 2,
    /* push */ 1,
    /* pop */ 1,
    /* add */ 3,
    /* sub */ 3,
    /* mul */ 3,
    /* div */ 3,
    /* and */ 3,
    /* or */ 3,
    /* xor */ 3,
    /* not */ 2,
    /* shl */ 3,
    /* shr */ 3,
    /* cmp */ 2,
    /* jmp */ 1,
    /* beq */ 1,
    /* bne */ 1,
    /* blt */ 1,
    /* bgt */ 1,
    /* ble */ 1,
    /* bge */ 1,
    /* call */ 1,
    /* ret */ 0,
    /* in */ 1,
    /* out */ 1,
    /* halt */ 0,
    /* iret */ 0,
    /* trap */ 0};

static int32_t parse_int_literal(const char* text) {
  char* end = NULL;
  long value;
  errno = 0;
  value = strtol(text, &end, 0);
  if (errno != 0 || end == text) {
    return 0;
  }
  return (int32_t)value;
}


// ========== Таблица символов (меток) ==========

typedef struct {
  char name[MAX_LINE_LEN];
  int address;
} Symbol;

Symbol symtab[MAX_SYMBOLS];
int symbol_count = 0;

int find_symbol(const char* name) {
  for (int i = 0; i < symbol_count; i++) {
    if (strcmp(symtab[i].name, name) == 0) {
      return symtab[i].address;
    }
  }
  return -1;
}

int add_symbol(const char* name, int address) {
  if (symbol_count >= MAX_SYMBOLS) {
    fprintf(stderr, "Ошибка: слишком много меток\n");
    return -1;
  }
  strcpy(symtab[symbol_count].name, name);
  symtab[symbol_count].address = address;
  symbol_count++;
  return 0;
}

// ========== Сбор отладочной информации ==========
typedef struct {
  char name[64];
  int start_addr;
  int end_addr;
  int first_line;
  int line_count;
  int first_var;
  int var_count;
} DebugFunc;

typedef struct {
  int func_index;
  int line;
  int addr;
} DebugLine;

typedef struct {
  int func_index;
  char name[64];
  int fp_offset;
  int is_arg;
} DebugVar;

static DebugFunc* dbg_funcs = NULL;
static DebugLine* dbg_lines = NULL;
static DebugVar* dbg_vars = NULL;
static int dbg_func_count = 0;
static int dbg_line_count = 0;
static int dbg_var_count = 0;

static int add_debug_func(const char* name, int start_addr) {
  DebugFunc* tmp =
      realloc(dbg_funcs, sizeof(DebugFunc) * (size_t)(dbg_func_count + 1));
  if (!tmp) return -1;
  dbg_funcs = tmp;
  DebugFunc* f = &dbg_funcs[dbg_func_count];
  memset(f, 0, sizeof(*f));
  strncpy(f->name, name, sizeof(f->name) - 1);
  f->start_addr = start_addr;
  f->end_addr = -1;
  f->first_line = -1;
  f->first_var = -1;
  return dbg_func_count++;
}

static void close_current_func(int current_instr) {
  if (dbg_func_count == 0) return;
  DebugFunc* f = &dbg_funcs[dbg_func_count - 1];
  if (f->end_addr < 0) {
    f->end_addr = current_instr;
  }
}

static int add_debug_line(int func_index, int line, int addr) {
  DebugLine* tmp =
      realloc(dbg_lines, sizeof(DebugLine) * (size_t)(dbg_line_count + 1));
  if (!tmp) return -1;
  dbg_lines = tmp;
  DebugLine* dl = &dbg_lines[dbg_line_count];
  dl->func_index = func_index;
  dl->line = line;
  dl->addr = addr;
  if (func_index >= 0 && func_index < dbg_func_count) {
    DebugFunc* f = &dbg_funcs[func_index];
    if (f->first_line < 0) f->first_line = dbg_line_count;
    f->line_count++;
  }
  return dbg_line_count++;
}

static int add_debug_var(int func_index, const char* name, int fp_offset,
                         int is_arg) {
  DebugVar* tmp =
      realloc(dbg_vars, sizeof(DebugVar) * (size_t)(dbg_var_count + 1));
  if (!tmp) return -1;
  dbg_vars = tmp;
  DebugVar* dv = &dbg_vars[dbg_var_count];
  memset(dv, 0, sizeof(*dv));
  dv->func_index = func_index;
  dv->fp_offset = fp_offset;
  dv->is_arg = is_arg;
  strncpy(dv->name, name, sizeof(dv->name) - 1);
  if (func_index >= 0 && func_index < dbg_func_count) {
    DebugFunc* f = &dbg_funcs[func_index];
    if (f->first_var < 0) f->first_var = dbg_var_count;
    f->var_count++;
  }
  return dbg_var_count++;
}

static int copy_optional_sym_file(const char* input_tac,
                                  const char* output_bin) {
  char src_path[1024];
  char dst_path[1024];
  FILE* src = NULL;
  FILE* dst = NULL;
  int status = -1;
  unsigned char buffer[4096];

  if (!input_tac || !output_bin) return -1;

  if (snprintf(src_path, sizeof(src_path), "%s.sym", input_tac) >=
          (int)sizeof(src_path) ||
      snprintf(dst_path, sizeof(dst_path), "%s.sym", output_bin) >=
          (int)sizeof(dst_path)) {
    fprintf(stderr, "Ошибка: слишком длинный путь к sym-файлу\n");
    return -1;
  }

  src = fopen(src_path, "rb");
  if (!src) {
    return errno == ENOENT ? 0 : -1;
  }

  dst = fopen(dst_path, "wb");
  if (!dst) goto cleanup;

  while (!feof(src)) {
    size_t nread = fread(buffer, 1, sizeof(buffer), src);
    if (nread > 0 && fwrite(buffer, 1, nread, dst) != nread) goto cleanup;
    if (ferror(src)) goto cleanup;
  }

  status = 0;

cleanup:
  if (dst) fclose(dst);
  if (src) fclose(src);
  return status;
}

static void finalize_debug_ranges(int current_instr) {
  if (dbg_func_count == 0) return;
  DebugFunc* f = &dbg_funcs[dbg_func_count - 1];
  if (f->end_addr < 0) f->end_addr = current_instr;
}

static void free_debug_info(void) {
  free(dbg_funcs);
  free(dbg_lines);
  free(dbg_vars);
  dbg_funcs = NULL;
  dbg_lines = NULL;
  dbg_vars = NULL;
  dbg_func_count = dbg_line_count = dbg_var_count = 0;
}

static int add_string(char** table, uint32_t* cur_size, const char* s) {
  if (!s) s = "";
  size_t len = strlen(s) + 1;
  if (*cur_size > UINT32_MAX - len) return -1;
  char* tmp = realloc(*table, *cur_size + len);
  if (!tmp) return -1;
  memcpy(tmp + *cur_size, s, len);
  int offset = (int)(*cur_size);
  *table = tmp;
  *cur_size += (uint32_t)len;
  return offset;
}

static int append_debug_section(FILE* outfile) {
  if (!outfile) return -1;
  if (dbg_func_count == 0 && dbg_line_count == 0 && dbg_var_count == 0) {
    return 0;  // нет отладочной информации
  }

  DebugFuncEntry* ftab = NULL;
  DebugLineEntry* ltab = NULL;
  DebugVarEntry* vtab = NULL;
  char* str_table = NULL;
  uint32_t str_size = 0;
  int status = -1;

  ftab = calloc((size_t)dbg_func_count, sizeof(DebugFuncEntry));
  ltab = calloc((size_t)dbg_line_count, sizeof(DebugLineEntry));
  vtab = calloc((size_t)dbg_var_count, sizeof(DebugVarEntry));
  if ((dbg_func_count && !ftab) || (dbg_line_count && !ltab) ||
      (dbg_var_count && !vtab)) {
    fprintf(stderr, "Ошибка: не удалось выделить память под debug-секцию\n");
    goto cleanup_dbg;
  }

  for (int i = 0; i < dbg_func_count; ++i) {
    DebugFunc* src = &dbg_funcs[i];
    DebugFuncEntry* dst = &ftab[i];
    int name_off = add_string(&str_table, &str_size, src->name);
    if (name_off < 0) goto cleanup_dbg;
    dst->name_offset = (uint32_t)name_off;
    dst->start_addr = (uint32_t)(src->start_addr < 0 ? 0 : src->start_addr);
    dst->end_addr = (uint32_t)(src->end_addr < 0 ? src->start_addr : src->end_addr);
    dst->first_line = (uint32_t)((src->first_line < 0) ? 0 : src->first_line);
    dst->line_count = (uint32_t)((src->line_count < 0) ? 0 : src->line_count);
    dst->first_var = (uint32_t)((src->first_var < 0) ? 0 : src->first_var);
    dst->var_count = (uint32_t)((src->var_count < 0) ? 0 : src->var_count);
  }

  for (int i = 0; i < dbg_line_count; ++i) {
    DebugLine* src = &dbg_lines[i];
    DebugLineEntry* dst = &ltab[i];
    dst->func_index =
        src->func_index >= 0 ? (uint32_t)src->func_index : UINT32_MAX;
    dst->line = (uint32_t)src->line;
    dst->addr = (uint32_t)src->addr;
  }

  for (int i = 0; i < dbg_var_count; ++i) {
    DebugVar* src = &dbg_vars[i];
    DebugVarEntry* dst = &vtab[i];
    int name_off = add_string(&str_table, &str_size, src->name);
    if (name_off < 0) goto cleanup_dbg;
    dst->name_offset = (uint32_t)name_off;
    dst->func_index =
        src->func_index >= 0 ? (uint32_t)src->func_index : UINT32_MAX;
    dst->fp_offset = src->fp_offset;
    dst->is_arg = src->is_arg ? 1 : 0;
    dst->reserved[0] = dst->reserved[1] = dst->reserved[2] = 0;
  }

  uint64_t func_off = sizeof(DebugHeader);
  uint64_t line_off = func_off + (uint64_t)dbg_func_count * sizeof(DebugFuncEntry);
  uint64_t var_off = line_off + (uint64_t)dbg_line_count * sizeof(DebugLineEntry);
  uint64_t str_off = var_off + (uint64_t)dbg_var_count * sizeof(DebugVarEntry);

  if (func_off > UINT32_MAX || line_off > UINT32_MAX || var_off > UINT32_MAX ||
      str_off > UINT32_MAX) {
    fprintf(stderr, "Ошибка: debug-секция слишком большая\n");
    goto cleanup_dbg;
  }

  DebugHeader hdr;
  hdr.magic = DEBUG_MAGIC;
  hdr.version = DEBUG_VERSION;
  hdr.reserved = 0;
  hdr.func_count = (uint32_t)dbg_func_count;
  hdr.line_count = (uint32_t)dbg_line_count;
  hdr.var_count = (uint32_t)dbg_var_count;
  hdr.func_table_offset = (uint32_t)func_off;
  hdr.line_table_offset = (uint32_t)line_off;
  hdr.var_table_offset = (uint32_t)var_off;
  hdr.str_table_offset = (uint32_t)str_off;
  hdr.str_table_size = str_size;

  if (fwrite(&hdr, sizeof(hdr), 1, outfile) != 1) goto cleanup_dbg;
  if (dbg_func_count &&
      fwrite(ftab, sizeof(DebugFuncEntry), (size_t)dbg_func_count, outfile) !=
          (size_t)dbg_func_count)
    goto cleanup_dbg;
  if (dbg_line_count &&
      fwrite(ltab, sizeof(DebugLineEntry), (size_t)dbg_line_count, outfile) !=
          (size_t)dbg_line_count)
    goto cleanup_dbg;
  if (dbg_var_count &&
      fwrite(vtab, sizeof(DebugVarEntry), (size_t)dbg_var_count, outfile) !=
          (size_t)dbg_var_count)
    goto cleanup_dbg;
  if (str_size && fwrite(str_table, 1, str_size, outfile) != str_size)
    goto cleanup_dbg;

  status = 0;

cleanup_dbg:
  free(ftab);
  free(ltab);
  free(vtab);
  free(str_table);
  return status;
}

// ========== Функции парсинга ==========

// Убирает пробелы в начале и конце строки
char* trim(char* s) {
  char* end;
  while (isspace((unsigned char)*s)) s++;
  if (*s == 0) return s;
  end = s + strlen(s) - 1;
  while (end > s && isspace((unsigned char)*end)) end--;
  *(end + 1) = 0;
  return s;
}

// Парсинг операнда (например, "r5", "#123", "[fp-8]")
int parse_operand(const char* s, EncodedOperand* op) {
  char str[MAX_LINE_LEN];
  strncpy(str, s, MAX_LINE_LEN - 1);
  str[MAX_LINE_LEN - 1] = '\0';  // Убедимся, что строка завершается нулем
  char* token = trim(str);

  op->kind = OP_NONE;
  op->value = 0;
  op->base_reg = -1;

  if (strlen(token) == 0) return 0;

  // 1. Регистр (rX, fp, sp)
  if (token[0] == 'r' && isdigit(token[1])) {
    op->kind = OP_REG;
    op->base_reg = parse_int_literal(&token[1]);
  } else if (strcmp(token, "fp") == 0) {
    op->kind = OP_REG;
    op->base_reg = 29;  // FP
  } else if (strcmp(token, "sp") == 0) {
    op->kind = OP_REG;
    op->base_reg = 30;  // SP
  }
  // 2. Непосредственное значение (#X)
  else if (token[0] == '#') {
    op->kind = OP_IMM;
    op->value = parse_int_literal(&token[1]);
  }
  // 3. Память ([...])
  else if (token[0] == '[') {
    op->kind = OP_MEM;
    char cleaned_token[MAX_LINE_LEN];
    // Копируем содержимое скобок, убирая '[' и ']'
    strncpy(cleaned_token, token + 1, strlen(token) - 2);
    cleaned_token[strlen(token) - 2] = '\0';

    char base_name[MAX_LINE_LEN];
    char offset_val_str[MAX_LINE_LEN] = "0";  // Смещение по умолчанию

    char* sign_pos = strpbrk(cleaned_token, "+-");  // Ищем первый '+' или '-'

    if (sign_pos) {
      // Есть и базовый регистр, и смещение
      size_t base_len = sign_pos - cleaned_token;
      strncpy(base_name, cleaned_token, base_len);
      base_name[base_len] = '\0';
      strcpy(offset_val_str, sign_pos);  // Копируем знак и число
    } else {
      // Только базовый регистр или только абсолютный адрес
      strcpy(base_name, cleaned_token);
      // offset_val_str остается "0"
    }

    char* trimmed_base = trim(base_name);

    if (strcmp(trimmed_base, "fp") == 0) {
      op->base_reg = 29;
    } else if (strcmp(trimmed_base, "sp") == 0) {
      op->base_reg = 30;
    } else if (trimmed_base[0] == 'r' && isdigit(trimmed_base[1])) {
      op->base_reg = parse_int_literal(&trimmed_base[1]);
    } else if (isdigit((unsigned char)trimmed_base[0]) ||
               (trimmed_base[0] == '-' &&
                isdigit((unsigned char)trimmed_base[1]))) {
      // Если это просто число, это абсолютный адрес
      op->base_reg = -1;  // -1 означает абсолютный адрес или базовый регистр не
                          // используется
      op->value = parse_int_literal(trimmed_base);
      return 0;  // Обработано полностью, выходим
    } else {
      // Неопознанный базовый регистр или некорректная запись
      op->base_reg = -1;
      fprintf(stderr, "Ошибка: Неизвестный базовый регистр в '%s'\n", s);
      return -1;
    }

    op->value = parse_int_literal(trim(offset_val_str));
  }
  // 4. Метка (для переходов)
  else {
    op->kind = OP_LABEL;
    op->value = find_symbol(token);
    if (op->value == -1) {
      fprintf(stderr, "Ошибка: неопределенная метка '%s'\n", token);
      return -1;
    }
  }

  return 0;
}

int main(int argc, char* argv[]) {
  if (argc != 3) {
    fprintf(stderr, "Использование: %s <input.tac> <output.bin>\n", argv[0]);
    return 1;
  }

  FILE* infile = NULL;
  FILE* outfile = NULL;
  EncodedInstruction* program = NULL;
  int status = 1;

  infile = fopen(argv[1], "r");
  if (!infile) {
    perror("Не удалось открыть входной файл");
    return 1;
  }

  char line[MAX_LINE_LEN];
  int instruction_count_pass1 = 0;

  // --- Первый проход: сбор меток ---
  while (fgets(line, sizeof(line), infile)) {
    char* token = strchr(line, ';');  // Игнорировать комментарии
    if (token) *token = '\0';

    char* label = trim(line);
    if (strlen(label) == 0) continue;

    if (strncmp(label, ".dbg_", 5) == 0) {
      continue;  // директивы отладки не увеличивают адреса
    }

    char* colon = strchr(label, ':');
    if (colon) {
      *colon = '\0';
      if (add_symbol(trim(label), instruction_count_pass1) != 0) {
        goto cleanup;
      }
    } else {
      instruction_count_pass1++;
    }
  }

  // Теперь, когда мы знаем instruction_count_pass1, выделяем память
  program = calloc(instruction_count_pass1, sizeof(EncodedInstruction));
  if (!program) {
    perror("Не удалось выделить память для программы");
    goto cleanup;
  }

  // --- Второй проход: генерация кода ---
  fseek(infile, 0, SEEK_SET);  // Возвращаемся в начало файла
  int instruction_count_pass2 = 0;
  int current_func = -1;
  while (fgets(line, sizeof(line), infile)) {
    char* comment = strchr(line, ';');
    if (comment) *comment = '\0';

    char* trimmed_line = trim(line);
    if (strlen(trimmed_line) == 0)
      continue;  // Пропускаем пустые строки

    if (strncmp(trimmed_line, ".dbg_", 5) == 0) {
      if (strncmp(trimmed_line, ".dbg_func", 9) == 0) {
        char name[64];
        if (sscanf(trimmed_line, ".dbg_func %63s", name) != 1) {
          fprintf(stderr, "Ошибка в .dbg_func: %s\n", trimmed_line);
          goto cleanup;
        }
        close_current_func(instruction_count_pass2);
        current_func = add_debug_func(name, instruction_count_pass2);
        if (current_func < 0) {
          fprintf(stderr, "Ошибка: не удалось добавить функцию '%s'\n", name);
          goto cleanup;
        }
      } else if (strncmp(trimmed_line, ".dbg_endfunc", 12) == 0) {
        close_current_func(instruction_count_pass2);
        current_func = -1;
      } else if (strncmp(trimmed_line, ".dbg_line", 9) == 0) {
        int ln = 0;
        if (sscanf(trimmed_line, ".dbg_line %d", &ln) != 1) {
          fprintf(stderr, "Ошибка в .dbg_line: %s\n", trimmed_line);
          goto cleanup;
        }
        if (add_debug_line(current_func, ln, instruction_count_pass2) < 0) {
          fprintf(stderr, "Ошибка: не удалось сохранить dbg_line\n");
          goto cleanup;
        }
      } else if (strncmp(trimmed_line, ".dbg_var", 8) == 0) {
        char name[64];
        int off = 0;
        char kind[16] = {0};
        int scanned =
            sscanf(trimmed_line, ".dbg_var %63s %d %15s", name, &off, kind);
        if (scanned < 2) {
          fprintf(stderr, "Ошибка в .dbg_var: %s\n", trimmed_line);
          goto cleanup;
        }
        int is_arg = 0;
        if (scanned >= 3) {
          if (strcmp(kind, "arg") == 0 || strcmp(kind, "param") == 0) {
            is_arg = 1;
          }
        }
        if (add_debug_var(current_func, name, off, is_arg) < 0) {
          fprintf(stderr, "Ошибка: не удалось сохранить dbg_var\n");
          goto cleanup;
        }
      } else {
        fprintf(stderr, "Неизвестная директива отладки: %s\n", trimmed_line);
        goto cleanup;
      }
      continue;
    }

    if (strchr(trimmed_line, ':'))
      continue;  // Пропускаем метки

    // Создаем копию строки для strtok, так как он модифицирует ее
    char line_copy[MAX_LINE_LEN];
    strncpy(line_copy, trimmed_line, MAX_LINE_LEN - 1);
    line_copy[MAX_LINE_LEN - 1] = '\0';

    char* mnemonic = strtok(line_copy, " \t");
    if (!mnemonic) continue;

    int opcode = -1;
    for (int i = 0; i < MNEMONIC_COUNT; ++i) {
      if (strcmp(mnemonic, MNEMONICS[i]) == 0) {
        opcode = i;
        break;
      }
    }

      if (opcode == -1) {
        fprintf(stderr, "Ошибка на строке '%s': неизвестная мнемоника '%s'\n",
                trimmed_line, mnemonic);
        goto cleanup;
      }

    EncodedInstruction* instr = &program[instruction_count_pass2];
    instr->opcode = opcode;

    char* operands_str =
        strtok(NULL, "");  // Все, что осталось после мнемоники - это операнды

    // Инициализируем все операнды значениями по умолчанию
    for (int i = 0; i < 3; ++i) {
      instr->ops[i].kind = OP_NONE;
      instr->ops[i].value = 0;
      instr->ops[i].base_reg = -1;
    }

    if (operands_str) {
      char operands_copy[MAX_LINE_LEN];
      strncpy(operands_copy, operands_str, MAX_LINE_LEN - 1);
      operands_copy[MAX_LINE_LEN - 1] = '\0';

      char* op_tok = strtok(operands_copy, ",");
      for (int i = 0; i < OPERAND_COUNTS[opcode]; ++i) {
        if (!op_tok) {
          fprintf(stderr,
                  "Ошибка на строке '%s': недостаточно операндов для %s\n",
                  trimmed_line, mnemonic);
          goto cleanup;
        }
        if (parse_operand(op_tok, &instr->ops[i]) != 0) {
          goto cleanup;
        }
        op_tok = strtok(NULL, ",");
      }
    }
    instruction_count_pass2++;
  }

  finalize_debug_ranges(instruction_count_pass2);

  // --- Запись в бинарный файл ---
  outfile = fopen(argv[2], "wb");
  if (!outfile) {
    perror("Не удалось открыть выходной файл");
    goto cleanup;
  }

  // Записываем количество инструкций, затем сами инструкции
  if (fwrite(&instruction_count_pass2, sizeof(int), 1, outfile) != 1 ||
      fwrite(program, sizeof(EncodedInstruction), instruction_count_pass2,
             outfile) != (size_t)instruction_count_pass2) {
    fprintf(stderr, "Не удалось записать выходной файл\n");
    goto cleanup;
  }

  if (append_debug_section(outfile) != 0) {
    fprintf(stderr, "Не удалось записать debug-секцию\n");
    goto cleanup;
  }

  if (copy_optional_sym_file(argv[1], argv[2]) != 0) {
    fprintf(stderr, "Не удалось скопировать sym-файл рядом с бинарником\n");
    goto cleanup;
  }

  printf("Ассемблирование успешно завершено. %d инструкций записано в %s\n",
         instruction_count_pass2, argv[2]);
  status = 0;

cleanup:
  if (outfile) fclose(outfile);
  if (infile) fclose(infile);
  free(program);  // Освобождаем выделенную память
  free_debug_info();
  return status;
}
