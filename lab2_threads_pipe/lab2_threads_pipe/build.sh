#!/bin/bash
# Build Lab 2 pipeline binary
# Steps: compile SL → merge with runtime ASM → assemble on remote server → download
set -e
cd "$(dirname "$0")/.."

CREDS="-ul 506556 -up 1fe63b3f-271c-464f-8cb4-0bf34530bb40"
SSL='-sslcfg utility-from-teacher/RemoteTasks (1)/ssl-cfg.yaml'
MONO='mono utility-from-teacher/RemoteTasks (1)/Portable.RemoteTasks.Manager.exe'

echo "=== Step 1: Compile SL → ASM ==="
rm -f .tmp_lab2_logic.asm
./interpreter lab2_threads_pipe --teacher-core --vm --asm .tmp_lab2_logic.asm

echo "=== Step 2: Merge logic + runtime ASM ==="
python3 -c "
import re
with open('.tmp_lab2_logic.asm') as f: logic = f.read()
with open('lab2_threads_pipe/threads_runtime.asm') as f: runtime = f.read()
parts = re.split(r'(\[section [^\]]+\])', logic)
rt_parts = re.split(r'(\[section [^\]]+\])', runtime)
merged = parts[0]+parts[1]+'\n'+parts[2]+'\n; === Runtime ===\n\n'+rt_parts[2]+parts[3]+'\n'+parts[4]+rt_parts[4]+parts[5]+'\n'+parts[6]+rt_parts[6]
with open('.tmp_lab2_merged.asm','w') as f: f.write(merged)
print('Merged OK')
"

echo "=== Step 3: Assemble ==="
$MONO $CREDS -sslcfg "$SSL" \
  -s AssembleDebug -w \
  sourcesDir . \
  asmListing .tmp_lab2_merged.asm \
  definitionFile lab2_threads_pipe/stack_vm_core_threads.target.pdsl \
  archName StackVMCore

echo "=== Step 4: Download binary ==="
ID=$($MONO $CREDS -sslcfg "$SSL" -l 0 2>&1 | grep -o '[0-9a-f-]\{36\}')
$MONO $CREDS -sslcfg "$SSL" -g "$ID" -r out.ptptb -o lab2_threads_pipe/lab2.ptptb
echo "Binary: lab2_threads_pipe/lab2.ptptb"
