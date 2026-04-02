#include <ctype.h>

#include <stdbool.h>

#include <stdint.h>

#include <stdio.h>

#include <stdlib.h>

#include <string.h>



#define NUM_REGISTERS 32

#define MAX_DISAS 16

#define MAX_BT 32

#define MAX_LOCALS 64



#pragma pack(push, 1)

typedef enum {

  OP_NONE = 0,

  OP_REG,

  OP_IMM,

  OP_MEM,

  OP_LABEL

} OpKind;



typedef struct {

  uint8_t kind;

  int32_t value;

  int32_t base_reg;

} EncodedOperand;



typedef struct {

  uint8_t opcode;

  EncodedOperand ops[3];

} EncodedInstruction;

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

  OP_HALT

};



typedef enum {

  VM_STATUS_OK = 0,

  VM_STATUS_HALT,

  VM_STATUS_BREAK,

  VM_STATUS_ERR

} VmStatus;



typedef struct {

  bool z;

  bool n;

  bool c;

  bool v;

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



// --- VM API (implemented in tac_vm.c) ---

int vm_load(const char* path);

VmStatus vm_step(void);

VmStatus vm_continue(void);

int vm_instruction_count(void);

int vm_get_instruction(int addr, EncodedInstruction* out);

int vm_read_mem(const char* bank, int32_t addr, int32_t n, uint8_t* out);

int vm_read_regs(VMRegisters* out);

int vm_set_break(int addr);

int vm_del_break(int addr);

int vm_debug_resolve(uint32_t addr, VmLineInfo* out);

int vm_debug_near_lines(VmLineInfo* out, int max_entries, int* out_count);

int vm_debug_locals(VmVarValue* out_vars, int max_vars, int* out_count);

int vm_debug_backtrace(uint32_t* addrs, int max_frames, int* out_count);



static const char* MNEMONICS[] = {

    "nop", "mov", "push", "pop",  "add", "sub", "mul",  "div", "and",

    "or",  "xor", "not",  "shl",  "shr", "cmp", "jmp",  "beq", "bne",

    "blt", "bgt", "ble",  "bge",  "call", "ret", "in",  "out", "halt"};



static void trim(char* s) {

  if (!s) return;

  size_t len = strlen(s);

  while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r')) {

    s[--len] = '\0';

  }

  size_t start = 0;

  while (s[start] && isspace((unsigned char)s[start])) start++;

  if (start > 0) memmove(s, s + start, len - start + 1);

}



static int parse_int(const char* s, int* out) {

  if (!s || !out) return -1;

  char* end = NULL;

  long v = strtol(s, &end, 0);

  if (end == s || *end != '\0') return -1;

  *out = (int)v;

  return 0;

}



static void format_operand(const EncodedOperand* op, char* buf, size_t sz) {

  if (!op || !buf || sz == 0) return;

  buf[0] = '\0';

  switch (op->kind) {

    case OP_REG:

      if (op->base_reg == 29)

        snprintf(buf, sz, "fp");

      else if (op->base_reg == 30)

        snprintf(buf, sz, "sp");

      else

        snprintf(buf, sz, "r%d", op->base_reg);

      break;

    case OP_IMM:

    case OP_LABEL:

      snprintf(buf, sz, "#%d", op->value);

      break;

    case OP_MEM: {

      char base[32] = {0};

      if (op->base_reg == 29)

        snprintf(base, sizeof(base), "fp");

      else if (op->base_reg == 30)

        snprintf(base, sizeof(base), "sp");

      else if (op->base_reg >= 0)

        snprintf(base, sizeof(base), "r%d", op->base_reg);

      if (op->base_reg >= 0)

        snprintf(buf, sz, "[%s%+d]", base, op->value);

      else

        snprintf(buf, sz, "[%d]", op->value);

      break;

    }

    default:

      break;

  }

}



static void print_instruction(int addr, const EncodedInstruction* instr) {

  if (!instr) return;

  const char* mnem = (instr->opcode < (sizeof(MNEMONICS) / sizeof(char*)))

                         ? MNEMONICS[instr->opcode]

                         : "???";

  char opbuf[3][64];

  for (int i = 0; i < 3; ++i) {

    format_operand(&instr->ops[i], opbuf[i], sizeof(opbuf[i]));

  }

  printf("%04d: %-5s", addr, mnem);

  int printed = 0;

  for (int i = 0; i < 3; ++i) {

    if (opbuf[i][0] == '\0') continue;

    printf("%s%s", printed ? ", " : " ", opbuf[i]);

    printed++;

  }

  printf("\n");

}



static void cmd_regs(void) {

  VMRegisters r;

  if (vm_read_regs(&r) != 0) {

    printf("cannot read registers\n");

    return;

  }

  printf("PC=%d  Z=%d N=%d C=%d V=%d\n", r.pc, r.flags.z, r.flags.n,

         r.flags.c, r.flags.v);

  for (int i = 0; i < NUM_REGISTERS; ++i) {

    printf("r%-2d=%-10d%s", i, r.regs[i], ((i + 1) % 4 == 0) ? "\n" : "  ");

  }

  if ((NUM_REGISTERS % 4) != 0) printf("\n");

}



static void cmd_mem(char* bank_tok, char* addr_tok, char* n_tok) {

  int addr = 0, n = 0;

  if (parse_int(addr_tok, &addr) != 0 || parse_int(n_tok, &n) != 0 || n <= 0) {

    printf("usage: mem <bank> <addr> <n>\n");

    return;

  }

  uint8_t* buf = malloc((size_t)n);

  if (!buf) {

    printf("oom\n");

    return;

  }

  if (vm_read_mem(bank_tok, addr, n, buf) != 0) {

    printf("mem read failed\n");

    free(buf);

    return;

  }

  for (int i = 0; i < n; ++i) {

    if (i % 16 == 0) printf("%08X: ", addr + i);

    printf("%02X ", buf[i]);

    if (i % 16 == 15 || i == n - 1) printf("\n");

  }

  free(buf);

}



static void cmd_disas(char* addr_tok, char* count_tok) {

  int addr = 0, count = 0;

  if (parse_int(addr_tok, &addr) != 0) {

    printf("usage: disas <addr> <count>\n");

    return;

  }

  if (count_tok && parse_int(count_tok, &count) == 0 && count > 0) {

    // ok

  } else {

    count = 8;

  }

  int max = vm_instruction_count();

  if (addr < 0 || addr >= max) {

    printf("address out of range (0..%d)\n", max - 1);

    return;

  }

  if (addr + count > max) count = max - addr;

  EncodedInstruction instr;

  for (int i = 0; i < count; ++i) {

    if (vm_get_instruction(addr + i, &instr) != 0) break;

    print_instruction(addr + i, &instr);

  }

}



static const char* status_str(VmStatus st) {

  switch (st) {

    case VM_STATUS_OK:

      return "ok";

    case VM_STATUS_HALT:

      return "halt";

    case VM_STATUS_BREAK:

      return "breakpoint";

    default:

      return "error";

  }

}



static void cmd_line(void) {

  VMRegisters r;

  VmLineInfo ctx[5];

  int count = 0;

  if (vm_read_regs(&r) != 0 ||

      vm_debug_near_lines(ctx, 5, &count) != 0 || count == 0) {

    printf("no line info\n");

    return;

  }

  printf("PC=%d\n", r.pc);

  for (int i = 0; i < count; ++i) {

    printf("%c %s: line %u (addr %u)\n",

           (ctx[i].addr == (uint32_t)r.pc) ? '>' : ' ',

           ctx[i].func_name ? ctx[i].func_name : "<unknown>", ctx[i].line,

           ctx[i].addr);

  }

}



static void cmd_locals(void) {

  VmVarValue vars[MAX_LOCALS];

  int count = 0;

  if (vm_debug_locals(vars, MAX_LOCALS, &count) != 0) {

    printf("no locals info\n");

    return;

  }

  if (count == 0) {

    printf("no locals/args\n");

    return;

  }

  for (int i = 0; i < count; ++i) {

    printf("%s (%s) = %d\n", vars[i].name[0] ? vars[i].name : "<anon>",

           vars[i].is_arg ? "arg" : "local", vars[i].value);

  }

}



static void cmd_bt(void) {

  uint32_t addrs[MAX_BT];

  int frames = 0;

  if (vm_debug_backtrace(addrs, MAX_BT, &frames) != 0) {

    printf("backtrace unavailable\n");

    return;

  }

  for (int i = 0; i < frames; ++i) {

    VmLineInfo info;

    if (vm_debug_resolve(addrs[i], &info) == 0) {

      printf("#%-2d %s @%u line %u\n", i,

             info.func_name ? info.func_name : "<func>", info.addr, info.line);

    } else {

      printf("#%-2d <addr %u>\n", i, addrs[i]);

    }

  }

}



static void print_help(void) {

  printf("commands:\n");

  printf("  regs                     - show registers\n");

  printf("  mem <bank> <addr> <n>    - dump memory\n");

  printf("  disas <addr> <count>     - disassemble\n");

  printf("  step [n]                 - execute 1 or n instructions\n");

  printf("  cont                     - run until halt/break\n");

  printf("  break <addr>             - set breakpoint\n");

  printf("  del <addr>               - delete breakpoint\n");

  printf("  line                     - show current line mapping\n");

  printf("  locals                   - print locals/args\n");

  printf("  bt                       - backtrace\n");

  printf("  quit                     - exit\n");

}



int main(int argc, char* argv[]) {

  if (argc < 2 || argc > 3) {

    fprintf(stderr, "Usage: %s <program.bin> [end_pc]\n", argv[0]);

    return 1;

  }



  if (vm_load(argv[1]) != 0) {

    fprintf(stderr, "cannot load program\n");

    return 1;

  }





  if (argc == 3) {

    int end_pc = 0;

    if (parse_int(argv[2], &end_pc) != 0) {

      fprintf(stderr, "bad end pc: %s\n", argv[2]);

      return 1;

    }



    if (vm_set_break(end_pc) != 0) {

      fprintf(stderr, "cannot set breakpoint at %d\n", end_pc);

      return 1;

    }



    VmStatus st = vm_continue();



    if (st == VM_STATUS_ERR) {

      fprintf(stderr, "vm error during run\n");

      return 1;

    }



    if (st == VM_STATUS_HALT) {

      return 0;  // программа закончилась раньше

    }



    if (st == VM_STATUS_BREAK) {

      vm_del_break(end_pc);  // ВАЖНО!

      VMRegisters r;

      vm_read_regs(&r);

      fprintf(stderr, "Reached end point at pc=%d, switching to step mode\n",

              r.pc);

    }

  }





  printf("Inspector ready. Type 'help' for commands.\n");



  char buf[256];

  while (1) {

    printf("(dbg) ");

    if (!fgets(buf, sizeof(buf), stdin)) break;

    trim(buf);

    if (buf[0] == '\0') continue;



    char* cmd = strtok(buf, " \t");

    if (!cmd) continue;



    if (strcmp(cmd, "quit") == 0 || strcmp(cmd, "exit") == 0) {

      break;

    } else if (strcmp(cmd, "help") == 0) {

      print_help();

    } else if (strcmp(cmd, "regs") == 0) {

      cmd_regs();

    } else if (strcmp(cmd, "mem") == 0) {

      char *bank = strtok(NULL, " \t"), *addr = strtok(NULL, " \t"),

           *n = strtok(NULL, " \t");

      if (!bank || !addr || !n) {

        printf("usage: mem <bank> <addr> <n>\n");

      } else {

        cmd_mem(bank, addr, n);

      }

    } else if (strcmp(cmd, "disas") == 0) {

      char *addr = strtok(NULL, " \t"), *cnt = strtok(NULL, " \t");

      if (!addr) {

        printf("usage: disas <addr> <count>\n");

      } else {

        cmd_disas(addr, cnt);

      }

    } else if (strcmp(cmd, "step") == 0) {

      char* n_tok = strtok(NULL, " \t");

      int n = 1;

      if (n_tok) {

        if (parse_int(n_tok, &n) != 0 || n <= 0) {

          printf("usage: step [n]\n");

          continue;

        }

      }



      VmStatus st = VM_STATUS_OK;

      for (int i = 0; i < n; ++i) {

        st = vm_step();

        if (st != VM_STATUS_OK) break;  // halt/break/error — остановиться

      }



      VMRegisters r;

      vm_read_regs(&r);

      printf("%s (pc=%d)\n", status_str(st), r.pc);

    } else if (strcmp(cmd, "cont") == 0) {

      VmStatus st = vm_continue();

      VMRegisters r;

      vm_read_regs(&r);

      printf("%s (pc=%d)\n", status_str(st), r.pc);

    } else if (strcmp(cmd, "break") == 0) {

      char* addr = strtok(NULL, " \t");

      int a = 0;

      if (!addr || parse_int(addr, &a) != 0) {

        printf("usage: break <addr>\n");

      } else if (vm_set_break(a) != 0) {

        printf("failed to set breakpoint\n");

      } else {

        printf("breakpoint set at %d\n", a);

      }

    } else if (strcmp(cmd, "del") == 0) {

      char* addr = strtok(NULL, " \t");

      int a = 0;

      if (!addr || parse_int(addr, &a) != 0) {

        printf("usage: del <addr>\n");

      } else if (vm_del_break(a) != 0) {

        printf("failed to delete breakpoint\n");

      } else {

        printf("breakpoint deleted at %d\n", a);

      }

    } else if (strcmp(cmd, "line") == 0) {

      cmd_line();

    } else if (strcmp(cmd, "locals") == 0) {

      cmd_locals();

    } else if (strcmp(cmd, "bt") == 0) {

      cmd_bt();

    } else {

      printf("unknown command: %s\n", cmd);

    }

  }

  return 0;

}
