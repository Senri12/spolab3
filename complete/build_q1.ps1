param()

$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$assembleScript = Join-Path $projectRoot "tools\remotetasks-assemble.ps1"
$asmListing = Join-Path $projectRoot "build\complete\q1_query.asm"
$definitionFile = Join-Path $projectRoot "src\TacVm13.target.pdsl"
$binaryOutput = Join-Path $projectRoot "build\complete\q1_query.ptptb"

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $binaryOutput) | Out-Null

powershell -ExecutionPolicy Bypass -File $assembleScript `
  -AsmListing $asmListing `
  -DefinitionFile $definitionFile `
  -ArchName TacVm13 `
  -BinaryOutput $binaryOutput
