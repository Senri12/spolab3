param(
    [string]$BinaryFile = "build/program.ptptb",
    [string]$DefinitionFile = "src/TacVm13.target.pdsl",
    [string]$DevicesFile = "src/TacVm13.devices.xml",
    [ValidateSet("InteractiveInput", "InputFile", "WithIo")]
    [string]$RunMode = "InteractiveInput",
    [int]$WithIoInteractiveSession = 1,
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

function Convert-ToManagerPath {
    param(
        [Parameter(Mandatory = $true)][string]$AbsolutePath
    )

    $projectPrefix = $projectRoot.TrimEnd('\') + '\'
    if ($AbsolutePath.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $AbsolutePath.Substring($projectPrefix.Length)
    }
    return $AbsolutePath
}

function Get-ManagerBaseArgs {
    param(
        [string]$SslCfg,
        [string]$LoginValue,
        [string]$PasswordValue
    )

    $args = @()
    if (-not [string]::IsNullOrWhiteSpace($SslCfg)) {
        $resolvedSsl = Resolve-AbsolutePath -Path $SslCfg -MustExist
        $args += @("-sslcfg", (Convert-ToManagerPath -AbsolutePath $resolvedSsl))
    }
    $args += @("-ul", $LoginValue, "-up", $PasswordValue)
    return $args
}

$binaryPath = Resolve-AbsolutePath -Path $BinaryFile -MustExist
$definitionPath = Resolve-AbsolutePath -Path $DefinitionFile -MustExist
$managerExe = Resolve-AbsolutePath -Path $ManagerPath -MustExist
$managerBaseArgs = Get-ManagerBaseArgs -SslCfg $SslConfig -LoginValue $Login -PasswordValue $Password
$binaryManagerPath = Convert-ToManagerPath -AbsolutePath $binaryPath
$definitionManagerPath = Convert-ToManagerPath -AbsolutePath $definitionPath

if ($RunMode -eq "WithIo") {
    $devicesPath = Resolve-AbsolutePath -Path $DevicesFile -MustExist
    $devicesManagerPath = Convert-ToManagerPath -AbsolutePath $devicesPath
    $withIoArgs = @()
    if ($WithIoInteractiveSession -eq 0) {
        $withIoArgs += "-w"
    }
    $withIoArgs += @("-s", "ExecuteBinaryWithIo")
    if ($WithIoInteractiveSession -ne 0) {
        $withIoArgs += "-ip"
    }
    $withIoArgs += @("devices.xml", $devicesManagerPath, "definitionFile", $definitionManagerPath, "archName", $ArchName, "binaryFileToRun", $binaryManagerPath, "codeRamBankName", "ram", "ipRegStorageName", "ip", "finishMnemonicName", "halt")
    & $managerExe @managerBaseArgs @withIoArgs
    if ($LASTEXITCODE -ne 0) {
        throw "ExecuteBinaryWithIo failed"
    }
}
elseif ($RunMode -eq "InputFile") {
    $inputPath = Resolve-AbsolutePath -Path $InputFile -MustExist
    $inputManagerPath = Convert-ToManagerPath -AbsolutePath $inputPath
    & $managerExe @managerBaseArgs -s ExecuteBinaryWithInput -ib stdinRegStName $StdinRegStorage stdoutRegStName $StdoutRegStorage inputFile $inputManagerPath definitionFile $definitionManagerPath archName $ArchName binaryFileToRun $binaryManagerPath codeRamBankName ram ipRegStorageName ip finishMnemonicName halt
    if ($LASTEXITCODE -ne 0) {
        throw "ExecuteBinaryWithInput failed"
    }
}
else {
    & $managerExe @managerBaseArgs -s ExecuteBinaryWithInteractiveInput -ib stdinRegStName $StdinRegStorage stdoutRegStName $StdoutRegStorage definitionFile $definitionManagerPath archName $ArchName binaryFileToRun $binaryManagerPath codeRamBankName ram ipRegStorageName ip finishMnemonicName halt
    if ($LASTEXITCODE -ne 0) {
        throw "ExecuteBinaryWithInteractiveInput failed"
    }
}
