param()

$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$parserScript = Join-Path $projectRoot "tools\remote-parser.ps1"
$inputFile = Join-Path $projectRoot "complete\q1_query.txt"
$outputDir = Join-Path $projectRoot "build\complete"
$asmOutput = Join-Path $outputDir "q1_query.asm"
$parseTreeOutput = Join-Path $outputDir "q1_query.dgml"

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

powershell -ExecutionPolicy Bypass -File $parserScript `
  -InputFile $inputFile `
  -AsmOutput $asmOutput `
  -ParseTreeOutput $parseTreeOutput `
  -RemoteRunTimeoutSeconds 180
