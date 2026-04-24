#!/bin/bash
# Run Lab 2 pipeline on remote VM
# Requires: /tmp/test_vedmosti.csv (created by prepare_data.sh)
# Output: /tmp/lab2_output.txt
set -e
cd "$(dirname "$0")/.."

CREDS="-ul 506556 -up 1fe63b3f-271c-464f-8cb4-0bf34530bb40"
SSL='-sslcfg utility-from-teacher/RemoteTasks (1)/ssl-cfg.yaml'
MONO='mono utility-from-teacher/RemoteTasks (1)/Portable.RemoteTasks.Manager.exe'

rm -f /tmp/lab2_output.txt
echo "" | $MONO $CREDS -sslcfg "$SSL" \
  -s ExecuteBinaryWithIo -w -ip \
  devices.xml lab2_threads_pipe/devices.xml \
  definitionFile lab2_threads_pipe/stack_vm_core_threads.target.pdsl \
  archName StackVMCore \
  binaryFileToRun lab2_threads_pipe/lab2.ptptb \
  codeRamBankName CODE \
  ipRegStorageName PC \
  finishMnemonicName hlt 2>&1 || true

echo "=== Result ==="
wc -l /tmp/lab2_output.txt
head -5 /tmp/lab2_output.txt
echo "..."
tail -5 /tmp/lab2_output.txt
