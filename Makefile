POWERSHELL = powershell -ExecutionPolicy Bypass -File

INPUT_FILE ?= input.txt
ASM_FILE ?= build/program.asm
DGML_FILE ?= build/parse_tree.dgml
BINARY_FILE ?= build/program.ptptb
TARGET_DEF ?= src/TacVm13.target.pdsl
DEVICES_XML ?= src/TacVm13.devices.xml
ARCH_NAME ?= TacVm13
RUN_MODE ?= InteractiveInput
STDIN_FILE ?= build/empty.stdin.txt
STDIN_REG ?= INPUT
STDOUT_REG ?= OUTPUT
EXTRA_ASM_FILES ?=

IRQ_POC_ASM    = build/irq_poc_interrupt.asm
IRQ_POC_BINARY = build/irq_poc.ptptb
IRQ_POC_DEVICES = src/TacVm13.irq-poc.devices.xml

.PHONY: all asm assemble run clean poc-assemble poc-run

all: assemble

asm:
	$(POWERSHELL) tools/remote-parser.ps1 -InputFile "$(INPUT_FILE)" -AsmOutput "$(ASM_FILE)" -ParseTreeOutput "$(DGML_FILE)"

assemble: asm
	$(POWERSHELL) tools/remotetasks-assemble.ps1 -AsmListing "$(ASM_FILE)" -ExtraAsmFiles "$(EXTRA_ASM_FILES)" -DefinitionFile "$(TARGET_DEF)" -ArchName "$(ARCH_NAME)" -BinaryOutput "$(BINARY_FILE)"

run: assemble
	$(POWERSHELL) tools/remotetasks-run.ps1 -BinaryFile "$(BINARY_FILE)" -DefinitionFile "$(TARGET_DEF)" -DevicesFile "$(DEVICES_XML)" -RunMode "$(RUN_MODE)" -InputFile "$(STDIN_FILE)" -StdinRegStorage "$(STDIN_REG)" -StdoutRegStorage "$(STDOUT_REG)" -ArchName "$(ARCH_NAME)"

clean:
	powershell -ExecutionPolicy Bypass -Command "$$ErrorActionPreference='Stop'; if (Test-Path 'build') { Get-ChildItem 'build' -File -Include '*.asm','*.dgml','*.ptptb','*.txt' -Recurse | Remove-Item -Force }"

build/irq_poc_interrupt.asm: src/irq_poc_interrupt.asm
	powershell -ExecutionPolicy Bypass -Command "Copy-Item -LiteralPath 'src/irq_poc_interrupt.asm' -Destination 'build/irq_poc_interrupt.asm' -Force"

poc-assemble: build/irq_poc_interrupt.asm
	$(POWERSHELL) tools/remotetasks-assemble.ps1 -AsmListing "$(IRQ_POC_ASM)" -DefinitionFile "$(TARGET_DEF)" -ArchName "$(ARCH_NAME)" -BinaryOutput "$(IRQ_POC_BINARY)"

poc-run: poc-assemble
	$(POWERSHELL) tools/remotetasks-run.ps1 -BinaryFile "$(IRQ_POC_BINARY)" -DefinitionFile "$(TARGET_DEF)" -DevicesFile "$(IRQ_POC_DEVICES)" -RunMode "WithIo" -ArchName "$(ARCH_NAME)"
