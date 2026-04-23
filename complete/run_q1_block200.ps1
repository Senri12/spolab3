param()

$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$parserScript = Join-Path $projectRoot "tools\remote-parser.ps1"
$assembleScript = Join-Path $projectRoot "tools\remotetasks-assemble.ps1"
$runScript = Join-Path $projectRoot "tools\remotetasks-run.ps1"
$inputFile = Join-Path $projectRoot "complete\q1_block200.txt"
$asmOutput = Join-Path $projectRoot "build\task2_v71\q1_block200.asm"
$parseTreeOutput = Join-Path $projectRoot "build\task2_v71\q1_block200.dgml"
$binaryFile = Join-Path $projectRoot "build\task2_v71\q1_block200.ptptb"
$definitionFile = Join-Path $projectRoot "src\TacVm13.target.pdsl"
$devicesFile = Join-Path $projectRoot "complete\q1.block200.devices.xml"
$resultFile = Join-Path $projectRoot "build\task2_v71\q1.block200.result.txt"
$outputDir = Split-Path -Parent $binaryFile

function Show-ResultFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Result file was not created: $Path"
  }

  $raw = [System.IO.File]::ReadAllBytes($Path)
  if ($raw.Length -eq 0) {
    Write-Warning "Result file is empty: $Path"
    return
  }

  $decoded = [System.Text.Encoding]::UTF32.GetString($raw).TrimEnd([char]0, [char]10, [char]13)
  Write-Host "Result file: $Path"
  Write-Host $decoded
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
Set-Content -Encoding ASCII $resultFile ""

Write-Host "Step 1/3: compiling block query..."
powershell -ExecutionPolicy Bypass -File $parserScript `
  -InputFile $inputFile `
  -AsmOutput $asmOutput `
  -ParseTreeOutput $parseTreeOutput

Write-Host "Step 2/3: building block binary..."
powershell -ExecutionPolicy Bypass -File $assembleScript `
  -AsmListing $asmOutput `
  -DefinitionFile $definitionFile `
  -ArchName TacVm13 `
  -BinaryOutput $binaryFile `
  -SkipInspectorEmbed

Write-Host "Step 3/3: running block binary with IO..."
$sw = [System.Diagnostics.Stopwatch]::StartNew()
powershell -ExecutionPolicy Bypass -File $runScript `
  -BinaryFile $binaryFile `
  -DefinitionFile $definitionFile `
  -DevicesFile $devicesFile `
  -RunMode WithIo `
  -ArchName TacVm13
$sw.Stop()
Write-Host "Execution time: $($sw.Elapsed.TotalSeconds.ToString('F1'))s"

Show-ResultFile -Path $resultFile
