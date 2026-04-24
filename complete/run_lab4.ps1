param()

$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$parserScript = Join-Path $projectRoot "tools\remote-parser.ps1"
$assembleScript = Join-Path $projectRoot "tools\remotetasks-assemble.ps1"
$runScript = Join-Path $projectRoot "tools\remotetasks-run.ps1"
$inputFile = Join-Path $projectRoot "src\6.txt"
$asmOutput = Join-Path $projectRoot "build\lab4\6.asm"
$parseTreeOutput = Join-Path $projectRoot "build\lab4\6.dgml"
$binaryFile = Join-Path $projectRoot "build\lab4\6.ptptb"
$definitionFile = Join-Path $projectRoot "src\TacVm13.target.pdsl"
$stdinFile = Join-Path $projectRoot "build\lab4\empty.stdin.txt"
$resultFile = Join-Path $projectRoot "build\lab4\6.result.txt"
$outputDir = Split-Path -Parent $binaryFile

function Show-ResultFile {
  param([Parameter(Mandatory = $true)][string]$Path)
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
if (-not (Test-Path -LiteralPath $stdinFile)) {
  Set-Content -Encoding ASCII $stdinFile ""
}

Write-Host "Step 1/3: compiling src/6.txt..."
powershell -ExecutionPolicy Bypass -File $parserScript `
  -InputFile $inputFile `
  -AsmOutput $asmOutput `
  -ParseTreeOutput $parseTreeOutput

Write-Host "Step 2/3: assembling (no rt_threads.asm, 6.txt has no threads)..."
powershell -ExecutionPolicy Bypass -File $assembleScript `
  -AsmListing $asmOutput `
  -DefinitionFile $definitionFile `
  -ArchName TacVm13 `
  -BinaryOutput $binaryFile `
  -SkipInspectorEmbed

Write-Host "Step 3/3: running binary in InputFile mode (captures raw 'out' instruction)..."
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$runOutput = & $runScript `
  -BinaryFile $binaryFile `
  -DefinitionFile $definitionFile `
  -RunMode InputFile `
  -InputFile $stdinFile `
  -StdinRegStorage INPUT `
  -StdoutRegStorage OUTPUT `
  -ArchName TacVm13
$sw.Stop()
Write-Host "Execution time: $($sw.Elapsed.TotalSeconds.ToString('F1'))s"

Set-Content -Encoding UTF8 -LiteralPath $resultFile -Value ($runOutput -join "`n")
Write-Host "Result captured to $resultFile"
Write-Host "---"
$runOutput | ForEach-Object { Write-Host $_ }
