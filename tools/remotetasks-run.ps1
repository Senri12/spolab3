param(
    [string]$BinaryFile = "build/program.ptptb",
    [string]$DefinitionFile = "src/TacVm13.target.pdsl",
    [string]$DevicesFile = "src/TacVm13.devices.xml",
    [ValidateSet("InteractiveInput", "InputFile", "WithIo")]
    [string]$RunMode = "InteractiveInput",
    [string]$InputFile = "build/empty.stdin.txt",
    [string]$StdinRegStorage = "INPUT",
    [string]$StdoutRegStorage = "OUTPUT",
    [string]$ArchName = "TacVm13",
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

$binaryPath = Resolve-AbsolutePath -Path $BinaryFile -MustExist
$definitionPath = Resolve-AbsolutePath -Path $DefinitionFile -MustExist
$managerExe = Resolve-AbsolutePath -Path $ManagerPath -MustExist
$sslCfgPath = Resolve-AbsolutePath -Path $SslConfig -MustExist

if ($RunMode -eq "WithIo") {
    $devicesPath = Resolve-AbsolutePath -Path $DevicesFile -MustExist
    & $managerExe -sslcfg $sslCfgPath -ul $Login -up $Password -s ExecuteBinaryWithIo -ib devices.xml $devicesPath definitionFile $definitionPath archName $ArchName binaryFileToRun $binaryPath codeRamBankName ram ipRegStorageName ip finishMnemonicName halt
    if ($LASTEXITCODE -ne 0) {
        throw "ExecuteBinaryWithIo failed"
    }
}
elseif ($RunMode -eq "InputFile") {
    $inputPath = Resolve-AbsolutePath -Path $InputFile -MustExist
    & $managerExe -sslcfg $sslCfgPath -ul $Login -up $Password -s ExecuteBinaryWithInput -ib stdinRegStName $StdinRegStorage stdoutRegStName $StdoutRegStorage inputFile $inputPath definitionFile $definitionPath archName $ArchName binaryFileToRun $binaryPath codeRamBankName ram ipRegStorageName ip finishMnemonicName halt
    if ($LASTEXITCODE -ne 0) {
        throw "ExecuteBinaryWithInput failed"
    }
}
else {
    & $managerExe -sslcfg $sslCfgPath -ul $Login -up $Password -s ExecuteBinaryWithInteractiveInput -ib stdinRegStName $StdinRegStorage stdoutRegStName $StdoutRegStorage definitionFile $definitionPath archName $ArchName binaryFileToRun $binaryPath codeRamBankName ram ipRegStorageName ip finishMnemonicName halt
    if ($LASTEXITCODE -ne 0) {
        throw "ExecuteBinaryWithInteractiveInput failed"
    }
}
