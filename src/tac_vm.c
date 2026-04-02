#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PROGRAM_MAX_BYTES (64 * 1024 * 4)  // 256 KB
#define NUM_REGISTERS 32
#define WORD_SIZE 4

#pragma pack(push, 1)

typedef enum {
  OP_NONE = 0,
  OP_REG,
  OP_IMM,
  OP_MEM,
  OP_LABEL  // labels are resolved by the assembler, treat as immediates in VM
} OpKind;

typedef struct {
  uint8_t kind;      // OpKind
  int32_t value;     // IMM: value; MEM: offset
  int32_t base_reg;  // REG: reg index; MEM: base reg (-1 = absolute)
} EncodedOperand;

typedef struct {
  uint8_t opcode;
  EncodedOperand ops[3];
} EncodedInstruction;

#define DEBUG_MAGIC 0x54444247u  // "TDBG"
#define DEBUG_VERSION 1

#pragma pack(push, 1)
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
  uint32_t name_offset;
  uint32_t start_addr;
  uint32_t end_addr;
  uint32_t first_line;
  uint32_t line_count;
  uint32_t first_var;
  uint32_t var_count;
} DebugFuncEntry;

typedef struct {
  uint32_t func_index;
  uint32_t line;
  uint32_t addr;
} DebugLineEntry;

typedef struct {
  uint32_t func_index;
  int32_t fp_offset;
  uint8_t is_arg;
  uint8_t reserved[3];
  uint32_t name_offset;
} DebugVarEntry;
#pragma pack(pop)

#pragma pack(pop)

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

#define REG_FP 29
#define REG_SP 30
#define REG_SCRATCH 31

#define MMIO_TIME_ADDR 1000000
#define MMIO_TIMER_PERIOD_ADDR 1000004
#define MMIO_HANDLER_ADDR 1000008
#define MMIO_IRQ_ENABLE_ADDR 1000012
#define MMIO_IRQ_CAUSE_ADDR 1000016
#define MMIO_FRAME_SP_ADDR 1000020

#define IRQ_CAUSE_NONE 0
#define IRQ_CAUSE_TIMER 1
#define IRQ_CAUSE_TRAP 2

typedef enum {
  VM_STATUS_OK = 0,
  VM_STATUS_HALT,
  VM_STATUS_BREAK,
  VM_STATUS_ERR
} VmStatus;

typedef struct {
  bool z;  // zero
  bool n;  // negative
  bool c;  // carry/borrow
  bool v;  // overflow
} Flags;

typedef struct {
  int32_t regs[NUM_REGISTERS];
  Flags flags;
  int pc;
} VMRegisters;

typedef struct {
  const char* func_name;
  uint32_t line;
  uint32_t addr;
} VmLineInfo;





typedef struct {
  char name[128];
  int32_t value;
  int is_arg;
} VmVarValue;

typedef struct {
  const char* name;
  uint32_t start_addr;
  uint32_t end_addr;
  uint32_t first_line;
  uint32_t line_count;
  uint32_t first_var;
  uint32_t var_count;
} DebugFuncRuntime;

typedef struct {
  uint32_t func_index;
  uint32_t line;
  uint32_t addr;
} DebugLineRuntime;

typedef struct {
  uint32_t func_index;
  int32_t fp_offset;
  uint8_t is_arg;
  const char* name;
} DebugVarRuntime;
typedef struct {
  char name[64];  // "local_4", "arg_8", или любое имя
  int offset;     // смещение от fp
  int is_arg;     // offset > 0
  char type_name[128];
  int is_object;
  int storage_offset;
  int storage_size;
} SymVar;

typedef struct {
  char name[128];
  char base[128];
  int size;
} SymType;

typedef struct {
  char owner[128];
  char name[64];
  int offset;
  char type_name[128];
} SymField;

typedef struct {
  char func[128];
  int frame_size;
  int start_addr;
  int end_addr;
  SymVar* vars;
  int vars_count;
  int vars_cap;
} FuncSym;


typedef struct {
  FuncSym* funcs;
  int count;
  int cap;
  SymType* types;
  int type_count;
  int type_cap;
  SymField* fields;
  int field_count;
  int field_cap;
} SymDB;

static Flags flags_state = {false, false, false, false};
static int32_t registers[NUM_REGISTERS];
static uint8_t unified_memory[PROGRAM_MAX_BYTES];
static int instruction_count = 0;
static int32_t code_bytes = 0;
static int pc = 0;  // instruction index of next instruction
static int32_t io_reg = 0;
static bool vm_loaded = false;
static bool vm_halted = false;
static bool* breakpoints = NULL;
static int breakpoints_count = 0;

#define CALLSTACK_MAX 256
static int callstack[CALLSTACK_MAX];
static int callstack_top = -1;
static int32_t vm_time = 0;
static int32_t timer_period = 0;
static int32_t timer_countdown = 0;
static int32_t irq_handler_pc = -1;
static int32_t irq_enabled = 0;
static int32_t irq_cause = IRQ_CAUSE_NONE;
static int32_t irq_frame_sp = 0;
static bool in_interrupt = false;

static DebugFuncRuntime* dbg_funcs = NULL;
static DebugLineRuntime* dbg_lines = NULL;
static DebugVarRuntime* dbg_vars = NULL;
static uint32_t dbg_func_count = 0;
static uint32_t dbg_line_count = 0;
static uint32_t dbg_var_count = 0;
static char* dbg_strings = NULL;
static uint32_t dbg_str_size = 0;

static VmStatus execute_one(void);
static int load_debug_section(FILE* f, long debug_offset, long file_size);
static int find_func_by_pc(uint32_t addr);
static const DebugLineRuntime* find_line_entry(uint32_t addr, int func_idx);
static bool read_word(int32_t addr, int32_t* out_value);
static bool write_word(int32_t addr, int32_t value);
static SymDB symdb = {0};

static void symdb_free(SymDB* db);
static FuncSym* symdb_find_func_by_pc(SymDB* db, int pc);
static SymType* symdb_find_type(SymDB* db, const char* name);
static int load_sym_file(const char* path);
static bool is_mmio_address(int32_t addr);
static bool read_mmio_word(int32_t addr, int32_t* out_value);
static bool write_mmio_word(int32_t addr, int32_t value);
static int32_t pack_flags(void);
static void unpack_flags(int32_t packed);
static bool enter_interrupt(int32_t cause, int32_t return_pc);

static void canonical_type_name(const char* type_name, char* out,
                                size_t out_size) {
  size_t written = 0;
  if (!out || out_size == 0) return;
  out[0] = '\0';
  if (!type_name) return;

  while (*type_name == ' ' || *type_name == '\t') type_name++;
  while (*type_name && *type_name != '<' && *type_name != '[' &&
         *type_name != ' ' && *type_name != '\t' && written + 1 < out_size) {
    out[written++] = *type_name++;
  }
  out[written] = '\0';
}




static void symdb_free(SymDB* db) {
  if (!db) return;
  for (int i = 0; i < db->count; ++i) {
    free(db->funcs[i].vars);
  }
  free(db->funcs);
  free(db->types);
  free(db->fields);
  db->funcs = NULL;
  db->types = NULL;
  db->fields = NULL;
  db->count = db->cap = 0;
  db->type_count = db->type_cap = 0;
  db->field_count = db->field_cap = 0;
}

static FuncSym* symdb_add_func(SymDB* db, const char* name, int frame) {
  if (db->count >= db->cap) {
    int new_cap = db->cap ? db->cap * 2 : 8;
    FuncSym* nf =
        (FuncSym*)realloc(db->funcs, (size_t)new_cap * sizeof(FuncSym));
    if (!nf) return NULL;
    db->funcs = nf;
    db->cap = new_cap;
  }
  FuncSym* f = &db->funcs[db->count++];
  memset(f, 0, sizeof(*f));
  strncpy(f->func, name ? name : "unknown", sizeof(f->func) - 1);
  f->frame_size = frame;
  return f;
}

static SymType* symdb_add_type(SymDB* db, const char* name, int size,
                               const char* base) {
  if (!db || !name) return NULL;
  if (db->type_count >= db->type_cap) {
    int new_cap = db->type_cap ? db->type_cap * 2 : 8;
    SymType* nt =
        (SymType*)realloc(db->types, (size_t)new_cap * sizeof(SymType));
    if (!nt) return NULL;
    db->types = nt;
    db->type_cap = new_cap;
  }
  SymType* t = &db->types[db->type_count++];
  memset(t, 0, sizeof(*t));
  strncpy(t->name, name, sizeof(t->name) - 1);
  strncpy(t->base, base ? base : "-", sizeof(t->base) - 1);
  t->size = size;
  return t;
}

static int symdb_add_field(SymDB* db, const char* owner, const char* name,
                           int offset, const char* type_name) {
  if (!db || !owner || !name) return -1;
  if (db->field_count >= db->field_cap) {
    int new_cap = db->field_cap ? db->field_cap * 2 : 16;
    SymField* nf =
        (SymField*)realloc(db->fields, (size_t)new_cap * sizeof(SymField));
    if (!nf) return -1;
    db->fields = nf;
    db->field_cap = new_cap;
  }
  SymField* f = &db->fields[db->field_count++];
  memset(f, 0, sizeof(*f));
  strncpy(f->owner, owner, sizeof(f->owner) - 1);
  strncpy(f->name, name, sizeof(f->name) - 1);
  strncpy(f->type_name, type_name ? type_name : "int",
          sizeof(f->type_name) - 1);
  f->offset = offset;
  return 0;
}

static void funcsym_add_var(FuncSym* f, const char* name, int off, int is_arg,
                            const char* type_name, int is_object,
                            int storage_offset, int storage_size) {
  if (!f || !name) return;
  // дедуп по offset+is_arg
  for (int i = 0; i < f->vars_count; ++i) {
    if (f->vars[i].offset == off && f->vars[i].is_arg == is_arg) return;
  }
  if (f->vars_count >= f->vars_cap) {
    int new_cap = f->vars_cap ? f->vars_cap * 2 : 16;
    SymVar* nv = (SymVar*)realloc(f->vars, (size_t)new_cap * sizeof(SymVar));
    if (!nv) return;
    f->vars = nv;
    f->vars_cap = new_cap;
  }
  SymVar* v = &f->vars[f->vars_count++];
  memset(v, 0, sizeof(*v));
  strncpy(v->name, name, sizeof(v->name) - 1);
  v->offset = off;
  v->is_arg = is_arg;
  strncpy(v->type_name, type_name ? type_name : "int",
          sizeof(v->type_name) - 1);
  v->is_object = is_object;
  v->storage_offset = storage_offset;
  v->storage_size = storage_size;
}

static FuncSym* symdb_find_func_by_pc(SymDB* db, int pc) {
  if (!db) return NULL;
  for (int i = 0; i < db->count; ++i) {
    if (pc >= db->funcs[i].start_addr && pc < db->funcs[i].end_addr)
      return &db->funcs[i];
  }
  return NULL;
}

static SymType* symdb_find_type(SymDB* db, const char* name) {
  char needle[128];
  if (!db || !name) return NULL;
  canonical_type_name(name, needle, sizeof(needle));
  if (!needle[0]) return NULL;
  for (int i = 0; i < db->type_count; ++i) {
    char cur[128];
    canonical_type_name(db->types[i].name, cur, sizeof(cur));
    if (strcmp(cur, needle) == 0) return &db->types[i];
  }
  return NULL;
}

static int append_vm_var(VmVarValue* out_vars, int max_vars, int written,
                         const char* name, int32_t value, int is_arg) {
  if (!out_vars || written >= max_vars) return written;
  memset(&out_vars[written], 0, sizeof(out_vars[written]));
  snprintf(out_vars[written].name, sizeof(out_vars[written].name), "%s",
           name ? name : "<anon>");
  out_vars[written].value = value;
  out_vars[written].is_arg = is_arg;
  return written + 1;
}

static int append_object_fields(const char* prefix, const char* type_name,
                                int32_t base_addr, int is_arg,
                                VmVarValue* out_vars, int max_vars, int written,
                                int depth) {
  if (depth > 4) return written;
  SymType* type = symdb_find_type(&symdb, type_name);
  if (!type) return written;
  if (type->base[0] && strcmp(type->base, "-") != 0) {
    written = append_object_fields(prefix, type->base, base_addr, is_arg,
                                   out_vars, max_vars, written, depth + 1);
  }
  for (int i = 0; i < symdb.field_count && written < max_vars; ++i) {
    SymField* field = &symdb.fields[i];
    if (strcmp(field->owner, type->name) != 0) continue;
    int32_t val = 0;
    if (!read_word(base_addr + field->offset, &val)) continue;
    char full_name[128];
    snprintf(full_name, sizeof(full_name), "%s.%s", prefix, field->name);
    written = append_vm_var(out_vars, max_vars, written, full_name, val, is_arg);
    if (val > 0 && symdb_find_type(&symdb, field->type_name)) {
      written = append_object_fields(full_name, field->type_name, val, is_arg,
                                     out_vars, max_vars, written, depth + 1);
    }
  }
  return written;
}


static int load_sym_file(const char* path) {
  FILE* f = fopen(path, "r");
  if (!f) return -1;

  symdb_free(&symdb);

  char line[256];
  FuncSym* cur = NULL;

  while (fgets(line, sizeof(line), f)) {
    // trim \n
    size_t n = strlen(line);
    while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;

    if (line[0] == 0) {
      cur = NULL;
      continue;
    }

    char func[128];
    int frame = 0, start = 0, end = 0;
    char type_name[128], base[128];
    int size = 0;

    if (sscanf(line, "type %127s size %d base %127s", type_name, &size, base) ==
        3) {
      symdb_add_type(&symdb, type_name, size, base);
      continue;
    }

    char owner[128], field_name[64], field_type[128];
    int field_off = 0;
    if (sscanf(line, "field %127s %63s %d %127s", owner, field_name,
               &field_off, field_type) == 4) {
      symdb_add_field(&symdb, owner, field_name, field_off, field_type);
      continue;
    }

    if (sscanf(line, "func %127s start %d end %d frame %d", func, &start, &end,
               &frame) == 4) {
      cur = symdb_add_func(&symdb, func, frame);
      if (cur) {
        cur->start_addr = start;
        cur->end_addr = end;
      }
      continue;
    }


    if (!cur) continue;

    char kind[8], name[64], var_type[128];
    int off = 0, obj_off = 0, obj_size = 0;
    int matched =
        sscanf(line, "%7s %63s %d type %127s obj %d %d", kind, name, &off,
               var_type, &obj_off, &obj_size);
    if (matched >= 4) {
      int is_arg = strcmp(kind, "arg") == 0;
      int is_object = matched == 6;
      funcsym_add_var(cur, name, off, is_arg, var_type, is_object, obj_off,
                      obj_size);
      continue;
    }
    if (sscanf(line, "%7s %63s %d", kind, name, &off) == 3) {
      if (strcmp(kind, "arg") == 0)
        funcsym_add_var(cur, name, off, 1, "int", 0, 0, 0);
      else if (strcmp(kind, "var") == 0)
        funcsym_add_var(cur, name, off, 0, "int", 0, 0, 0);
    }
  }

  fclose(f);
  return 0;
}

static bool is_mmio_address(int32_t addr) {
  switch (addr) {
    case MMIO_TIME_ADDR:
    case MMIO_TIMER_PERIOD_ADDR:
    case MMIO_HANDLER_ADDR:
    case MMIO_IRQ_ENABLE_ADDR:
    case MMIO_IRQ_CAUSE_ADDR:
    case MMIO_FRAME_SP_ADDR:
      return true;
    default:
      return false;
  }
}

static bool read_mmio_word(int32_t addr, int32_t* out_value) {
  if (!out_value) return false;
  switch (addr) {
    case MMIO_TIME_ADDR:
      *out_value = vm_time;
      return true;
    case MMIO_TIMER_PERIOD_ADDR:
      *out_value = timer_period;
      return true;
    case MMIO_HANDLER_ADDR:
      *out_value = irq_handler_pc;
      return true;
    case MMIO_IRQ_ENABLE_ADDR:
      *out_value = irq_enabled;
      return true;
    case MMIO_IRQ_CAUSE_ADDR:
      *out_value = irq_cause;
      return true;
    case MMIO_FRAME_SP_ADDR:
      *out_value = irq_frame_sp;
      return true;
    default:
      return false;
  }
}

static bool write_mmio_word(int32_t addr, int32_t value) {
  switch (addr) {
    case MMIO_TIMER_PERIOD_ADDR:
      timer_period = value < 0 ? 0 : value;
      timer_countdown = timer_period;
      return true;
    case MMIO_HANDLER_ADDR:
      irq_handler_pc = value;
      return true;
    case MMIO_IRQ_ENABLE_ADDR:
      irq_enabled = value ? 1 : 0;
      return true;
    case MMIO_IRQ_CAUSE_ADDR:
    case MMIO_FRAME_SP_ADDR:
    case MMIO_TIME_ADDR:
      return false;
    default:
      return false;
  }
}

static int32_t pack_flags(void) {
  int32_t packed = 0;
  if (flags_state.z) packed |= 1 << 0;
  if (flags_state.n) packed |= 1 << 1;
  if (flags_state.c) packed |= 1 << 2;
  if (flags_state.v) packed |= 1 << 3;
  return packed;
}

static void unpack_flags(int32_t packed) {
  flags_state.z = (packed & (1 << 0)) != 0;
  flags_state.n = (packed & (1 << 1)) != 0;
  flags_state.c = (packed & (1 << 2)) != 0;
  flags_state.v = (packed & (1 << 3)) != 0;
}

static bool enter_interrupt(int32_t cause, int32_t return_pc) {
  int32_t saved_regs[NUM_REGISTERS];
  int32_t frame_base = 0;
  int offset = 0;

  if (in_interrupt) return false;
  if (cause != IRQ_CAUSE_TRAP && !irq_enabled) return false;
  if (irq_handler_pc < 0 || irq_handler_pc >= instruction_count) {
    fprintf(stderr, "VM Error: invalid interrupt handler pc=%d\n",
            irq_handler_pc);
    return false;
  }

  memcpy(saved_regs, registers, sizeof(saved_regs));

  frame_base = saved_regs[REG_SP] - (32 * WORD_SIZE);
  if (frame_base < code_bytes) {
    fprintf(stderr,
            "VM Error: interrupt frame overflow into code area (SP=%d)\n",
            frame_base);
    return false;
  }

  if (!write_word(frame_base + offset, return_pc)) return false;
  offset += WORD_SIZE;
  if (!write_word(frame_base + offset, pack_flags())) return false;
  offset += WORD_SIZE;

  for (int reg = 1; reg < NUM_REGISTERS; ++reg) {
    if (reg == REG_SP) continue;
    if (!write_word(frame_base + offset, saved_regs[reg])) return false;
    offset += WORD_SIZE;
  }

  registers[REG_SP] = frame_base;
  irq_frame_sp = frame_base;
  irq_cause = cause;
  in_interrupt = true;
  pc = irq_handler_pc;
  return true;
}

static bool read_word(int32_t addr, int32_t* out_value) {
  if (is_mmio_address(addr)) {
    return read_mmio_word(addr, out_value);
  }
  if (addr < 0 || addr > (int32_t)(PROGRAM_MAX_BYTES - WORD_SIZE) ||
      (addr % WORD_SIZE != 0)) {
    fprintf(stderr, "VM Error: invalid read address %d\n", addr);
    return false;
  }
  *out_value = *((int32_t*)&unified_memory[addr]);
  return true;
}

static bool write_word(int32_t addr, int32_t value) {
  if (is_mmio_address(addr)) {
    return write_mmio_word(addr, value);
  }
  if (addr < 0 || addr > (int32_t)(PROGRAM_MAX_BYTES - WORD_SIZE) ||
      (addr % WORD_SIZE != 0)) {
    fprintf(stderr, "VM Error: invalid write address %d\n", addr);
    return false;
  }
  *((int32_t*)&unified_memory[addr]) = value;
  return true;
}

static bool check_reg_index(int idx) {
  return idx >= 0 && idx < NUM_REGISTERS;
}

static bool get_operand_value(const EncodedOperand* op, int32_t* out) {
  switch (op->kind) {
    case OP_REG:
      if (!check_reg_index(op->base_reg)) {
        fprintf(stderr, "VM Error: invalid register index %d\n", op->base_reg);
        return false;
      }
      *out = registers[op->base_reg];
      return true;
    case OP_IMM:
    case OP_LABEL:
      *out = op->value;
      return true;
    case OP_MEM: {
      int32_t base = 0;
      if (op->base_reg >= 0) {
        if (!check_reg_index(op->base_reg)) {
          fprintf(stderr, "VM Error: invalid base register %d\n",
                  op->base_reg);
          return false;
        }
        base = registers[op->base_reg];
      }
      int32_t addr = base + op->value;
      return read_word(addr, out);
    }
    case OP_NONE:
    default:
      {
        int instr_pc = pc > 0 ? pc - 1 : 0;
        EncodedInstruction* cur =
            instruction_count > 0
                ? (EncodedInstruction*)&unified_memory[instr_pc *
                                                       sizeof(EncodedInstruction)]
                : NULL;
        fprintf(stderr,
                "VM Error: unsupported operand kind %d at pc=%d opcode=%d",
                op->kind, pc, cur ? cur->opcode : -1);
        if (cur) {
          fprintf(stderr,
                  " ops=[(%d,%d,%d),(%d,%d,%d),(%d,%d,%d)]",
                  cur->ops[0].kind, cur->ops[0].value, cur->ops[0].base_reg,
                  cur->ops[1].kind, cur->ops[1].value, cur->ops[1].base_reg,
                  cur->ops[2].kind, cur->ops[2].value, cur->ops[2].base_reg);
        }
        fputc('\n', stderr);
      }
      return false;
  }
}

static bool resolve_memory_address(const EncodedOperand* op, int32_t* out_addr) {
  int32_t base = 0;
  if (!op || !out_addr || op->kind != OP_MEM) return false;
  if (op->base_reg >= 0) {
    if (!check_reg_index(op->base_reg)) {
      fprintf(stderr, "VM Error: invalid base register %d\n", op->base_reg);
      return false;
    }
    base = registers[op->base_reg];
  }
  *out_addr = base + op->value;
  return true;
}

static bool get_operand_ptr(const EncodedOperand* op, uint8_t opcode_for_debug,
                            int32_t** out) {
  if (op->kind == OP_REG) {
    if (!check_reg_index(op->base_reg)) {
      fprintf(stderr, "VM Error: invalid destination register %d for opcode %d\n",
              op->base_reg, opcode_for_debug);
      return false;
    }
    *out = &registers[op->base_reg];
    return true;
  }
  if (op->kind == OP_MEM) {
    int32_t addr = 0;
    if (!resolve_memory_address(op, &addr)) {
      return false;
    }
    if (is_mmio_address(addr)) {
      fprintf(stderr,
              "VM Error: MMIO destination requires explicit opcode handling (addr=%d)\n",
              addr);
      return false;
    }
    if (addr < 0 || addr > (int32_t)(PROGRAM_MAX_BYTES - WORD_SIZE) ||
        (addr % WORD_SIZE != 0)) {
      fprintf(stderr,
              "VM Error: Memory access out of bounds at addr %d (base %d+%d). PC=%d OP=%d\n",
              addr, op->base_reg, op->value, pc, opcode_for_debug);
      return false;
    }
    *out = (int32_t*)&unified_memory[addr];
    return true;
  }

  fprintf(stderr,
          "VM Error: Invalid destination operand mode (%d) for opcode %d at pc=%d\n",
          op->kind, opcode_for_debug, pc);
  return false;
}

static void update_flags_from_sub(int32_t lhs, int32_t rhs) {
  int32_t result = lhs - rhs;
  flags_state.z = (result == 0);
  flags_state.n = (result < 0);
  flags_state.c = ((uint32_t)lhs < (uint32_t)rhs);  // borrow on subtract
  int32_t lhs_sign = lhs >> 31;
  int32_t rhs_sign = rhs >> 31;
  int32_t res_sign = result >> 31;
  flags_state.v = (lhs_sign != rhs_sign) && (lhs_sign != res_sign);
}

static bool branch_take(uint8_t opcode) {
  switch (opcode) {
    case OP_BEQ:
      return flags_state.z;
    case OP_BNE:
      return !flags_state.z;
    case OP_BLT:
      return flags_state.n != flags_state.v;
    case OP_BGE:
      return flags_state.n == flags_state.v;
    case OP_BLE:
      return flags_state.z || (flags_state.n != flags_state.v);
    case OP_BGT:
      return !flags_state.z && (flags_state.n == flags_state.v);
    default:
      return false;
  }
}

static void free_debug_tables(void) {
  free(dbg_funcs);
  free(dbg_lines);
  free(dbg_vars);
  free(dbg_strings);
  dbg_funcs = NULL;
  dbg_lines = NULL;
  dbg_vars = NULL;
  dbg_strings = NULL;
  dbg_func_count = dbg_line_count = dbg_var_count = dbg_str_size = 0;
}

static void reset_vm_state(void) {
  vm_loaded = false;
  vm_halted = false;
  instruction_count = 0;
  code_bytes = 0;
  pc = 0;
  io_reg = 0;
  flags_state = (Flags){false, false, false, false};
  memset(registers, 0, sizeof(registers));
  memset(unified_memory, 0, sizeof(unified_memory));
  free(breakpoints);
  breakpoints = NULL;
  breakpoints_count = 0;
  callstack_top = -1;
  vm_time = 0;
  timer_period = 0;
  timer_countdown = 0;
  irq_handler_pc = -1;
  irq_enabled = 0;
  irq_cause = IRQ_CAUSE_NONE;
  irq_frame_sp = 0;
  in_interrupt = false;
  free_debug_tables();
  symdb_free(&symdb);
}

static int find_func_by_pc(uint32_t addr) {
  for (uint32_t i = 0; i < dbg_func_count; ++i) {
    if (addr >= dbg_funcs[i].start_addr && addr < dbg_funcs[i].end_addr) {
      return (int)i;
    }
  }
  return -1;
}

static const DebugLineRuntime* find_line_entry(uint32_t addr, int func_idx) {
  if (func_idx < 0 || func_idx >= (int)dbg_func_count) return NULL;
  const DebugFuncRuntime* f = &dbg_funcs[func_idx];
  if (f->line_count == 0 || !dbg_lines) return NULL;
  uint32_t start = f->first_line;
  uint32_t count = f->line_count;
  const DebugLineRuntime* best = NULL;
  for (uint32_t i = 0; i < count; ++i) {
    const DebugLineRuntime* cur = &dbg_lines[start + i];
    if (cur->addr <= addr) {
      best = cur;
    } else {
      break;
    }
  }
  return best;
}

int vm_instruction_count(void) { return instruction_count; }

int vm_get_instruction(int addr, EncodedInstruction* out) {
  if (!out || addr < 0 || addr >= instruction_count) return -1;
  memcpy(out, &unified_memory[addr * (int)sizeof(EncodedInstruction)],
         sizeof(EncodedInstruction));
  return 0;
}

int vm_read_mem(const char* bank, int32_t addr, int32_t n, uint8_t* out) {
  if (!bank || !out || n < 0) return -1;
  if (!(strcmp(bank, "ram") == 0 || strcmp(bank, "RAM") == 0)) return -1;
  if (addr < 0 || (int64_t)addr + n > PROGRAM_MAX_BYTES) return -1;
  memcpy(out, unified_memory + addr, (size_t)n);
  return 0;
}

int vm_read_regs(VMRegisters* out) {
  if (!out) return -1;
  memcpy(out->regs, registers, sizeof(registers));
  out->flags = flags_state;
  out->pc = pc;
  return 0;
}

int vm_set_break(int addr) {
  if (!breakpoints || addr < 0 || addr >= breakpoints_count) return -1;
  breakpoints[addr] = true;
  return 0;
}

int vm_del_break(int addr) {
  if (!breakpoints || addr < 0 || addr >= breakpoints_count) return -1;
  breakpoints[addr] = false;
  return 0;
}

int vm_debug_resolve(uint32_t addr, VmLineInfo* out) {
  if (!out) return -1;
  int func_idx = find_func_by_pc(addr);
  if (func_idx < 0) return -1;
  const DebugFuncRuntime* f = &dbg_funcs[func_idx];
  const DebugLineRuntime* line = find_line_entry(addr, func_idx);
  out->func_name = f->name;
  out->line = line ? line->line : 0;
  out->addr = addr;
  return 0;
}

int vm_debug_near_lines(VmLineInfo* out, int max_entries, int* out_count) {
  if (!out || max_entries <= 0) return -1;
  int func_idx = find_func_by_pc((uint32_t)pc);
  if (func_idx < 0) return -1;
  const DebugFuncRuntime* f = &dbg_funcs[func_idx];
  if (!dbg_lines || f->line_count == 0) {
    if (out_count) *out_count = 0;
    return 0;
  }
  uint32_t start = f->first_line;
  uint32_t count = f->line_count;
  int pivot = 0;
  for (uint32_t i = 0; i < count; ++i) {
    if (dbg_lines[start + i].addr <= (uint32_t)pc) {
      pivot = (int)i;
    } else {
      break;
    }
  }
  int from = pivot - 2;
  if (from < 0) from = 0;
  int to = pivot + 2;
  if (to >= (int)count) to = (int)count - 1;
  int written = 0;
  for (int i = from; i <= to && written < max_entries; ++i) {
    out[written].func_name = f->name;
    out[written].line = dbg_lines[start + i].line;
    out[written].addr = dbg_lines[start + i].addr;
    written++;
  }
  if (out_count) *out_count = written;
  return 0;
}




int vm_debug_locals(VmVarValue* out_vars, int max_vars, int* out_count) {
  if (!out_vars || max_vars <= 0) return -1;
  int written = 0;

  if (symdb.count > 0) {
    FuncSym* sf = symdb_find_func_by_pc(&symdb, pc);
    if (sf) {
      for (int i = 0; i < sf->vars_count && written < max_vars; ++i) {
        SymVar* sv = &sf->vars[i];
        int32_t addr = registers[REG_FP] + sv->offset;
        int32_t val = 0;
        if (!read_word(addr, &val)) continue;
        written = append_vm_var(out_vars, max_vars, written, sv->name, val,
                                sv->is_arg);
        if (sv->is_object && sv->type_name[0] && val > 0) {
          written = append_object_fields(sv->name, sv->type_name, val,
                                         sv->is_arg, out_vars, max_vars,
                                         written, 0);
        }
      }
      if (out_count) *out_count = written;
      return 0;
    }
  }

  int func_idx = find_func_by_pc((uint32_t)pc);
  if (func_idx >= 0) {
    const DebugFuncRuntime* f = &dbg_funcs[func_idx];
    if (dbg_vars && f->var_count) {
      for (uint32_t i = 0; i < f->var_count && written < max_vars; ++i) {
        const DebugVarRuntime* v = &dbg_vars[f->first_var + i];
        if (!v->name) continue;
        int32_t addr = registers[REG_FP] + v->fp_offset;
        int32_t val = 0;
        if (!read_word(addr, &val)) continue;
        written = append_vm_var(out_vars, max_vars, written, v->name, val,
                                v->is_arg ? 1 : 0);
      }
      if (out_count) *out_count = written;
      return 0;
    }
  }

  if (out_count) *out_count = written;
  return 0;
}




int vm_debug_backtrace(uint32_t* addrs, int max_frames, int* out_count) {
  if (!addrs || max_frames <= 0) return -1;
  int written = 0;
  addrs[written++] = (uint32_t)pc;
  for (int i = callstack_top; i >= 0 && written < max_frames; --i) {
    addrs[written++] = (uint32_t)callstack[i];
  }
  if (out_count) *out_count = written;
  return 0;
}

static int load_debug_section(FILE* f, long debug_offset, long file_size) {
  long available = file_size - debug_offset;
  free_debug_tables();
  if (available < (long)sizeof(DebugHeader)) {
    return 0;  // нет debug-секции
  }

  if (fseek(f, debug_offset, SEEK_SET) != 0) return -1;

  DebugHeader hdr;
  if (fread(&hdr, sizeof(hdr), 1, f) != 1) return -1;
  if (hdr.magic != DEBUG_MAGIC) {
    return 0;  // нет нашей секции
  }
  if (hdr.version != DEBUG_VERSION) {
    fprintf(stderr, "VM Error: unsupported debug version %u\n", hdr.version);
    return -1;
  }

  uint64_t debug_size = (uint64_t)available;
  uint64_t funcs_bytes = (uint64_t)hdr.func_count * sizeof(DebugFuncEntry);
  uint64_t lines_bytes = (uint64_t)hdr.line_count * sizeof(DebugLineEntry);
  uint64_t vars_bytes = (uint64_t)hdr.var_count * sizeof(DebugVarEntry);

  if (hdr.func_table_offset + funcs_bytes > debug_size ||
      hdr.line_table_offset + lines_bytes > debug_size ||
      hdr.var_table_offset + vars_bytes > debug_size ||
      hdr.str_table_offset + hdr.str_table_size > debug_size) {
    fprintf(stderr, "VM Error: truncated debug section\n");
    return -1;
  }

  DebugFuncRuntime* new_funcs = NULL;
  DebugLineRuntime* new_lines = NULL;
  DebugVarRuntime* new_vars = NULL;
  DebugFuncEntry* file_funcs = NULL;
  DebugLineEntry* file_lines = NULL;
  DebugVarEntry* file_vars = NULL;
  char* new_strings = NULL;

  if (hdr.func_count) {
    new_funcs = calloc(hdr.func_count, sizeof(DebugFuncRuntime));
    file_funcs = calloc(hdr.func_count, sizeof(DebugFuncEntry));
    if (!new_funcs || !file_funcs) goto dbg_fail;
    if (fseek(f, debug_offset + (long)hdr.func_table_offset, SEEK_SET) != 0)
      goto dbg_fail;
    if (fread(file_funcs, sizeof(DebugFuncEntry), hdr.func_count, f) !=
        hdr.func_count)
      goto dbg_fail;
  }

  if (hdr.line_count) {
    new_lines = calloc(hdr.line_count, sizeof(DebugLineRuntime));
    file_lines = calloc(hdr.line_count, sizeof(DebugLineEntry));
    if (!new_lines || !file_lines) goto dbg_fail;
    if (fseek(f, debug_offset + (long)hdr.line_table_offset, SEEK_SET) != 0)
      goto dbg_fail;
    if (fread(file_lines, sizeof(DebugLineEntry), hdr.line_count, f) !=
        hdr.line_count)
      goto dbg_fail;
  }

  if (hdr.var_count) {
    new_vars = calloc(hdr.var_count, sizeof(DebugVarRuntime));
    file_vars = calloc(hdr.var_count, sizeof(DebugVarEntry));
    if (!new_vars || !file_vars) goto dbg_fail;
    if (fseek(f, debug_offset + (long)hdr.var_table_offset, SEEK_SET) != 0)
      goto dbg_fail;
    if (fread(file_vars, sizeof(DebugVarEntry), hdr.var_count, f) !=
        hdr.var_count)
      goto dbg_fail;
  }

  if (hdr.str_table_size) {
    new_strings = malloc(hdr.str_table_size);
    if (!new_strings) goto dbg_fail;
    if (fseek(f, debug_offset + (long)hdr.str_table_offset, SEEK_SET) != 0)
      goto dbg_fail;
    if (fread(new_strings, 1, hdr.str_table_size, f) != hdr.str_table_size)
      goto dbg_fail;
  }

  for (uint32_t i = 0; i < hdr.func_count; ++i) {
    new_funcs[i].start_addr = file_funcs[i].start_addr;
    new_funcs[i].end_addr = file_funcs[i].end_addr;
    new_funcs[i].first_line = file_funcs[i].first_line;
    new_funcs[i].line_count = file_funcs[i].line_count;
    new_funcs[i].first_var = file_funcs[i].first_var;
    new_funcs[i].var_count = file_funcs[i].var_count;
    if (file_funcs[i].name_offset < hdr.str_table_size && new_strings) {
      new_funcs[i].name = new_strings + file_funcs[i].name_offset;
    } else {
      new_funcs[i].name = NULL;
    }
  }

  for (uint32_t i = 0; i < hdr.line_count; ++i) {
    new_lines[i].addr = file_lines[i].addr;
    new_lines[i].func_index = file_lines[i].func_index;
    new_lines[i].line = file_lines[i].line;
  }

  for (uint32_t i = 0; i < hdr.var_count; ++i) {
    new_vars[i].fp_offset = file_vars[i].fp_offset;
    new_vars[i].func_index = file_vars[i].func_index;
    new_vars[i].is_arg = file_vars[i].is_arg;
    if (file_vars[i].name_offset < hdr.str_table_size && new_strings) {
      new_vars[i].name = new_strings + file_vars[i].name_offset;
    } else {
      new_vars[i].name = NULL;
    }
  }

  free(file_funcs);
  free(file_lines);
  free(file_vars);
  free_debug_tables();

  dbg_funcs = new_funcs;
  dbg_lines = new_lines;
  dbg_vars = new_vars;
  dbg_strings = new_strings;
  dbg_func_count = hdr.func_count;
  dbg_line_count = hdr.line_count;
  dbg_var_count = hdr.var_count;
  dbg_str_size = hdr.str_table_size;

  return 0;

dbg_fail:
  free(new_funcs);
  free(new_lines);
  free(new_vars);
  free(file_funcs);
  free(file_lines);
  free(file_vars);
  free(new_strings);
  free_debug_tables();
  return -1;
}

int vm_load(const char* path) {
  reset_vm_state();
  if (!path) return 1;

  FILE* f = fopen(path, "rb");
  if (!f) {
    perror("Cannot open binary file");
    return 1;
  }

  if (fread(&instruction_count, sizeof(int), 1, f) != 1) {
    fprintf(stderr, "VM Error: cannot read instruction count\n");
    fclose(f);
    reset_vm_state();
    return 1;
  }

  if (instruction_count <= 0) {
    fprintf(stderr, "VM Error: empty program\n");
    fclose(f);
    reset_vm_state();
    return 1;
  }

  long code_bytes_long = instruction_count * (long)sizeof(EncodedInstruction);
  if (code_bytes_long > PROGRAM_MAX_BYTES) {
    fprintf(stderr, "VM Error: program too large (%ld bytes)\n",
            code_bytes_long);
    fclose(f);
    reset_vm_state();
    return 1;
  }
  code_bytes = (int32_t)code_bytes_long;

  if (fread(unified_memory, sizeof(EncodedInstruction), instruction_count, f) !=
      (size_t)instruction_count) {
    fprintf(stderr, "VM Error: cannot read instructions\n");
    fclose(f);
    reset_vm_state();
    return 1;
  }

  long debug_offset = ftell(f);
  long file_size = debug_offset;
  if (fseek(f, 0, SEEK_END) == 0) {
    file_size = ftell(f);
  }
  if (load_debug_section(f, debug_offset, file_size) != 0) {
    fclose(f);
    reset_vm_state();
    return 1;
  }
  // Попробуем загрузить символьный файл рядом: program.bin -> program.bin.sym
  char sym_path[1024];
  snprintf(sym_path, sizeof(sym_path), "%s.sym", path);
  if (load_sym_file(sym_path) == 0) {
    // ок, symdb заполнен
  } else {
    // если .sym нет — это не ошибка
  }

  fclose(f);

  for (int i = 0; i < NUM_REGISTERS; ++i) registers[i] = 0;
  registers[0] = 0;
  registers[REG_SP] = PROGRAM_MAX_BYTES;
  registers[REG_FP] = registers[REG_SP];
  pc = 0;
  vm_halted = false;
  vm_loaded = true;
  callstack_top = -1;
  flags_state = (Flags){false, false, false, false};
  vm_time = 0;
  timer_period = 0;
  timer_countdown = 0;
  irq_handler_pc = -1;
  irq_enabled = 0;
  irq_cause = IRQ_CAUSE_NONE;
  irq_frame_sp = 0;
  in_interrupt = false;

  free(breakpoints);
  breakpoints = NULL;
  breakpoints_count = instruction_count;
  if (instruction_count > 0) {
    breakpoints = calloc((size_t)instruction_count, sizeof(bool));
    if (!breakpoints) {
      fprintf(stderr, "VM Error: cannot allocate breakpoints table\n");
      reset_vm_state();
      return 1;
    }
  }

  return 0;
}

static VmStatus execute_one(void) {
  bool was_in_interrupt = in_interrupt;
  bool irq_enabled_before = irq_enabled != 0;
  if (vm_halted) return VM_STATUS_HALT;
  if (!vm_loaded) return VM_STATUS_ERR;
  if (pc < 0 || pc >= instruction_count) {
    fprintf(stderr, "VM Error: PC out of bounds %d\n", pc);
    vm_halted = true;
    return VM_STATUS_ERR;
  }

  EncodedInstruction* instr =
      (EncodedInstruction*)&unified_memory[pc * sizeof(EncodedInstruction)];
  int cur_pc = pc;

  pc++;
  registers[0] = 0;

  switch (instr->opcode) {
    case OP_NOP:
      break;
    case OP_MOV: {
      int32_t val = 0;
      int32_t* dst = NULL;
      if (!get_operand_value(&instr->ops[1], &val)) {
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      if (instr->ops[0].kind == OP_MEM) {
        int32_t addr = 0;
        if (!resolve_memory_address(&instr->ops[0], &addr)) {
          vm_halted = true;
          return VM_STATUS_ERR;
        }
        if (is_mmio_address(addr)) {
          if (!write_mmio_word(addr, val)) {
            fprintf(stderr, "VM Error: cannot write MMIO addr %d\n", addr);
            vm_halted = true;
            return VM_STATUS_ERR;
          }
          break;
        }
      }
      if (!get_operand_ptr(&instr->ops[0], instr->opcode, &dst)) {
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      *dst = val;
      break;
    }
    case OP_PUSH: {
      int32_t val = 0;
      if (!get_operand_value(&instr->ops[0], &val)) {
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      registers[REG_SP] -= WORD_SIZE;
      if (registers[REG_SP] < code_bytes) {
        fprintf(stderr, "VM Error: stack overflow into code area (SP=%d)\n",
                registers[REG_SP]);
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      if (!write_word(registers[REG_SP], val)) {
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      break;
    }
    case OP_POP: {
      if (registers[REG_SP] > PROGRAM_MAX_BYTES - WORD_SIZE) {
        fprintf(stderr, "VM Error: stack underflow (SP=%d)\n",
                registers[REG_SP]);
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      int32_t val = 0;
      if (!read_word(registers[REG_SP], &val)) {
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      int32_t* dst = NULL;
      if (!get_operand_ptr(&instr->ops[0], instr->opcode, &dst)) {
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      *dst = val;
      registers[REG_SP] += WORD_SIZE;
      break;
    }
    case OP_ADD:
    case OP_SUB:
    case OP_MUL:
    case OP_AND:
    case OP_OR:
    case OP_XOR:
    case OP_SHL:
    case OP_SHR: {
      int32_t* dst = NULL;
      int32_t lhs = 0;
      int32_t rhs = 0;
      if (!get_operand_ptr(&instr->ops[0], instr->opcode, &dst) ||
          !get_operand_value(&instr->ops[1], &lhs) ||
          !get_operand_value(&instr->ops[2], &rhs)) {
        vm_halted = true;
        return VM_STATUS_ERR;
      }

      switch (instr->opcode) {
        case OP_ADD:
          *dst = lhs + rhs;
          break;
        case OP_SUB:
          *dst = lhs - rhs;
          break;
        case OP_MUL:
          *dst = lhs * rhs;
          break;
        case OP_AND:
          *dst = lhs & rhs;
          break;
        case OP_OR:
          *dst = lhs | rhs;
          break;
        case OP_XOR:
          *dst = lhs ^ rhs;
          break;
        case OP_SHL:
          *dst = lhs << (rhs & 31);
          break;
        case OP_SHR:
          *dst = lhs >> (rhs & 31);
          break;
        default:
          break;
      }
      break;
    }
    case OP_DIV: {
      int32_t* dst = NULL;
      int32_t lhs = 0;
      int32_t rhs = 0;
      if (!get_operand_ptr(&instr->ops[0], instr->opcode, &dst) ||
          !get_operand_value(&instr->ops[1], &lhs) ||
          !get_operand_value(&instr->ops[2], &rhs)) {
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      if (rhs == 0) {
        fprintf(stderr, "VM Error: division by zero at pc=%d\n", cur_pc);
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      *dst = lhs / rhs;
      break;
    }
    case OP_NOT: {
      int32_t* dst = NULL;
      int32_t val = 0;
      if (!get_operand_ptr(&instr->ops[0], instr->opcode, &dst) ||
          !get_operand_value(&instr->ops[1], &val)) {
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      *dst = ~val;
      break;
    }
    case OP_CMP: {
      int32_t lhs = 0;
      int32_t rhs = 0;
      if (!get_operand_value(&instr->ops[0], &lhs) ||
          !get_operand_value(&instr->ops[1], &rhs)) {
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      update_flags_from_sub(lhs, rhs);
      break;
    }
    case OP_JMP: {
      int32_t target = 0;
      if (!get_operand_value(&instr->ops[0], &target)) {
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      if (target < 0 || target >= instruction_count) {
        fprintf(stderr, "VM Error: JMP target %d out of bounds\n", target);
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      pc = target;
      break;
    }
    case OP_BEQ:
    case OP_BNE:
    case OP_BLT:
    case OP_BGT:
    case OP_BLE:
    case OP_BGE: {
      if (branch_take(instr->opcode)) {
        int32_t target = 0;
        if (!get_operand_value(&instr->ops[0], &target)) {
          vm_halted = true;
          return VM_STATUS_ERR;
        }
        if (target < 0 || target >= instruction_count) {
          fprintf(stderr, "VM Error: branch target %d out of bounds\n",
                  target);
          vm_halted = true;
          return VM_STATUS_ERR;
        }
        pc = target;
      }
      break;
    }
    case OP_CALL: {
      int32_t target = 0;
      if (!get_operand_value(&instr->ops[0], &target)) {
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      if (target < 0 || target >= instruction_count) {
        fprintf(stderr, "VM Error: CALL target %d out of bounds\n", target);
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      if (callstack_top < CALLSTACK_MAX - 1) {
        callstack[++callstack_top] = cur_pc;
      }
      registers[REG_SP] -= WORD_SIZE;
      if (registers[REG_SP] < code_bytes) {
        fprintf(stderr, "VM Error: stack overflow on call (SP=%d)\n",
                registers[REG_SP]);
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      if (!write_word(registers[REG_SP], pc)) {
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      pc = target;
      break;
    }
    case OP_RET: {
      if (registers[REG_SP] > PROGRAM_MAX_BYTES - WORD_SIZE) {
        vm_halted = true;
        return VM_STATUS_HALT;
      }
      int32_t target = 0;
      if (!read_word(registers[REG_SP], &target)) {
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      registers[REG_SP] += WORD_SIZE;
      if (target < 0 || target >= instruction_count) {
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      pc = target;
      if (callstack_top >= 0) callstack_top--;
      break;
    }
    case OP_IN: {
      int c = getchar();
      if (c == EOF) {
        vm_halted = true;
        return VM_STATUS_HALT;
      }
      io_reg = (int32_t)c;
      int32_t* dst = NULL;
      if (!get_operand_ptr(&instr->ops[0], instr->opcode, &dst)) {
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      *dst = io_reg;
      break;
    }
    case OP_OUT: {
      if (!get_operand_value(&instr->ops[0], &io_reg)) {
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      putchar((char)(io_reg & 0xFF));
      fflush(stdout);
      break;
    }
    case OP_HALT:
      vm_halted = true;
      return VM_STATUS_HALT;
    case OP_IRET: {
      int32_t frame_base = registers[REG_SP];
      int32_t target = 0;
      int32_t packed_flags = 0;
      int offset = 2 * WORD_SIZE;
      if (!in_interrupt) {
        fprintf(stderr, "VM Error: IRET outside of interrupt handler\n");
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      if (!read_word(frame_base, &target) ||
          !read_word(frame_base + WORD_SIZE, &packed_flags)) {
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      for (int reg = 1; reg < NUM_REGISTERS; ++reg) {
        if (reg == REG_SP) continue;
        if (!read_word(frame_base + offset, &registers[reg])) {
          vm_halted = true;
          return VM_STATUS_ERR;
        }
        offset += WORD_SIZE;
      }
      registers[REG_SP] = frame_base + (32 * WORD_SIZE);
      unpack_flags(packed_flags);
      if (target < 0 || target >= instruction_count) {
        fprintf(stderr, "VM Error: IRET target %d out of bounds\n", target);
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      pc = target;
      in_interrupt = false;
      irq_cause = IRQ_CAUSE_NONE;
      irq_frame_sp = 0;
      break;
    }
    case OP_TRAP:
      if (!enter_interrupt(IRQ_CAUSE_TRAP, pc)) {
        fprintf(stderr, "VM Error: TRAP could not enter interrupt handler\n");
        vm_halted = true;
        return VM_STATUS_ERR;
      }
      break;
    default:
      fprintf(stderr, "VM Error: Unknown opcode %d at pc=%d\n",
              instr->opcode, cur_pc);
      vm_halted = true;
      return VM_STATUS_ERR;
  }

  if (!vm_halted && !was_in_interrupt && instr->opcode != OP_TRAP) {
    if (timer_period > 0 && irq_enabled_before) {
      vm_time += 1;
      if (timer_countdown > 0) {
        timer_countdown -= 1;
      }
      if (timer_countdown <= 0) {
        timer_countdown = timer_period;
        if (irq_enabled &&
            !enter_interrupt(IRQ_CAUSE_TIMER, pc)) {
          vm_halted = true;
          return VM_STATUS_ERR;
        }
      }
    }
  }

  return vm_halted ? VM_STATUS_HALT : VM_STATUS_OK;
}

VmStatus vm_step(void) { return execute_one(); }

VmStatus vm_continue(void) {
  if (!vm_loaded) return VM_STATUS_ERR;
  while (true) {
    if (vm_halted) return VM_STATUS_HALT;
    if (pc < 0 || pc >= instruction_count) {
      vm_halted = true;
      return VM_STATUS_ERR;
    }
    if (breakpoints && breakpoints_count > pc && breakpoints[pc]) {
      return VM_STATUS_BREAK;
    }
    VmStatus st = execute_one();
    if (st != VM_STATUS_OK) return st;
  }
}

#ifndef TAC_VM_NO_MAIN
int main(int argc, char* argv[]) {
  if (argc != 2) {
    fprintf(stderr, "Usage: %s <program.bin>\n", argv[0]);
    return 1;
  }

  if (vm_load(argv[1]) != 0) {
    return 1;
  }

  VmStatus st = vm_continue();
  if (st == VM_STATUS_ERR) return 1;
  if (st == VM_STATUS_BREAK) {
    fprintf(stderr,
            "VM hit a breakpoint at pc=%d (use inspector for interactive debug)\n",
            pc);
  }
  return 0;
}
#endif
