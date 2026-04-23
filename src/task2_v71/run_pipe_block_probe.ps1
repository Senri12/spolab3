param()
$ErrorActionPreference = "Stop"
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$parserScript   = Join-Path $projectRoot "tools\remote-parser.ps1"
$assembleScript = Join-Path $projectRoot "tools\remotetasks-assemble.ps1"
$runScript      = Join-Path $projectRoot "tools\remotetasks-run.ps1"
$inputFile      = Join-Path $projectRoot "src\task2_v71\pipe_block_probe.txt"
$asmOutput      = Join-Path $projectRoot "build\task2_v71\pipe_block_probe.asm"
$parseTreeOutput= Join-Path $projectRoot "build\task2_v71\pipe_block_probe.dgml"
$binaryFile     = Join-Path $projectRoot "build\task2_v71\pipe_block_probe.ptptb"
$definitionFile = Join-Path $projectRoot "src\TacVm13.target.pdsl"
$devicesFile    = Join-Path $projectRoot "src\task2_v71\pipe_block_probe.devices.xml"
$resultFile     = Join-Path $projectRoot "build\task2_v71\pipe_block_probe.result.txt"
$outputDir = Split-Path -Parent $binaryFile

function Show-ResultFile {
  param([Parameter(Mandatory=$true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "Result file not created: $Path" }
  $raw = [System.IO.File]::ReadAllBytes($Path)
  if ($raw.Length -eq 0) { Write-Warning "Result file is empty"; return }
  $decoded = [System.Text.Encoding]::UTF32.GetString($raw).TrimEnd([char]0,[char]10,[char]13)
  Write-Host "Result: $decoded"
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
Set-Content -Encoding ASCII $resultFile ""

Write-Host "Step 1: compile..."
powershell -ExecutionPolicy Bypass -File $parserScript `
  -InputFile $inputFile -AsmOutput $asmOutput -ParseTreeOutput $parseTreeOutput

Write-Host "Step 2: assemble..."
powershell -ExecutionPolicy Bypass -File $assembleScript `
  -AsmListing $asmOutput -DefinitionFile $definitionFile `
  -ArchName TacVm13 -BinaryOutput $binaryFile -SkipInspectorEmbed

Write-Host "Step 3: run..."
powershell -ExecutionPolicy Bypass -File $runScript `
  -BinaryFile $binaryFile -DefinitionFile $definitionFile `
  -DevicesFile $devicesFile -RunMode WithIo -ArchName TacVm13

Show-ResultFile -Path $resultFile
