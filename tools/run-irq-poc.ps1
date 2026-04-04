param(
    [string]$AsmSource = "src/irq_poc_interrupt.asm",
    [string]$AsmListing = "build/irq_poc_interrupt.asm",
    [string]$BinaryOutput = "build/irq_poc.ptptb",
    [string]$DefinitionFile = "src/TacVm13.target.pdsl",
    [string]$DevicesFile = "src/TacVm13.irq-poc.devices.xml",
    [string]$ArchName = "TacVm13"
)

$ErrorActionPreference = "Stop"
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

function Resolve-ProjectPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $projectRoot $Path))
}

$asmSourcePath = Resolve-ProjectPath -Path $AsmSource
$asmListingPath = Resolve-ProjectPath -Path $AsmListing

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $asmListingPath) | Out-Null
Copy-Item -LiteralPath $asmSourcePath -Destination $asmListingPath -Force

powershell -ExecutionPolicy Bypass -File (Join-Path $projectRoot "tools/remotetasks-assemble.ps1") `
  -AsmListing $asmListing `
  -DefinitionFile $DefinitionFile `
  -ArchName $ArchName `
  -BinaryOutput $BinaryOutput

powershell -ExecutionPolicy Bypass -File (Join-Path $projectRoot "tools/remotetasks-run.ps1") `
  -BinaryFile $BinaryOutput `
  -DefinitionFile $DefinitionFile `
  -DevicesFile $DevicesFile `
  -RunMode WithIo `
  -ArchName $ArchName
