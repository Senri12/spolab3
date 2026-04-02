param(
    [string]$AsmListing = "build/program.asm",
    [string]$DefinitionFile = "src/TacVm13.target.pdsl",
    [string]$ArchName = "TacVm13",
    [string]$BinaryOutput = "build/program.ptptb",
    [string]$ManagerPath = "tools/RemoteTasks/Portable.RemoteTasks.Manager.exe",
    [string]$SslConfig = "tools/RemoteTasks/ssl-cfg.yaml",
    [string]$Login = "505979",
    [string]$Password = "9d7a3ade-42cd-4693-85e6-5367bbe31597"
)

$ErrorActionPreference = "Stop"
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

function Resolve-AbsolutePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$MustExist
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        $resolved = [System.IO.Path]::GetFullPath($Path)
    } else {
        $resolved = [System.IO.Path]::GetFullPath((Join-Path $projectRoot $Path))
    }

    if ($MustExist -and -not (Test-Path -LiteralPath $resolved)) {
        throw "Path not found: $resolved"
    }

    return $resolved
}

$asmPath = Resolve-AbsolutePath -Path $AsmListing -MustExist
$definitionPath = Resolve-AbsolutePath -Path $DefinitionFile -MustExist
$binaryPath = Resolve-AbsolutePath -Path $BinaryOutput
$managerExe = Resolve-AbsolutePath -Path $ManagerPath -MustExist
$sslCfgPath = Resolve-AbsolutePath -Path $SslConfig -MustExist

New-Item -ItemType Directory -Force (Split-Path -Parent $binaryPath) | Out-Null

$startOutput = & $managerExe -sslcfg $sslCfgPath -ul $Login -up $Password -q -w -s Assemble asmListing $asmPath definitionFile $definitionPath archName $ArchName 2>&1
$startText = ($startOutput | Out-String).Trim()

if ($startText -notmatch 'id ([0-9a-fA-F-]+)') {
    throw "Failed to start Assemble task.`n$startText"
}

$taskId = $matches[1]
$taskState = & $managerExe -sslcfg $sslCfgPath -ul $Login -up $Password -g $taskId 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Assemble task failed.`n$($taskState | Out-String)"
}

& $managerExe -sslcfg $sslCfgPath -ul $Login -up $Password -g $taskId -r out.ptptb -o $binaryPath | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to download out.ptptb for task $taskId"
}

Write-Host "Binary written to $binaryPath"
