param()

$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$compileScript = Join-Path $projectRoot "complete\compile_q1.ps1"
$buildScript = Join-Path $projectRoot "complete\build_q1.ps1"
$runScript = Join-Path $projectRoot "tools\remotetasks-run.ps1"
$binaryFile = Join-Path $projectRoot "build\complete\q1_query.ptptb"
$definitionFile = Join-Path $projectRoot "src\TacVm13.target.pdsl"
$devicesFile = Join-Path $projectRoot "complete\q1.devices.xml"
$resultFile = Join-Path $projectRoot "complete\q1.result.txt"

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

  $decoded = [System.Text.Encoding]::ASCII.GetString($raw).Replace("`0", '')
  Write-Host "Result file: $Path"
  Write-Host $decoded
}

Write-Host "Step 1/3: compiling query..."
& $compileScript
Write-Host "Step 2/3: building binary..."
& $buildScript

Set-Content -Encoding ASCII $resultFile ""

Write-Host "Step 3/3: running binary with IO..."
powershell -ExecutionPolicy Bypass -File $runScript `
  -BinaryFile $binaryFile `
  -DefinitionFile $definitionFile `
  -RunMode WithIo `
  -DevicesFile $devicesFile `
  -ArchName TacVm13

Show-ResultFile -Path $resultFile
