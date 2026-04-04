param(
    [string]$BinaryFile = "build/program.ptptb",
    [string]$DefinitionFile = "src/TacVm13.target.pdsl",
    [string]$InspectorProject = "tools/SpoInspector/SpoInspector.csproj",
    [ValidateSet("plain", "inputfile", "withio")]
    [string]$RunMode = "plain",
    [string]$InputFile = "",
    [string]$DevicesFile = "src/TacVm13.devices.xml",
    [string]$Script = "",
    [string]$ManagerPath = "tools/RemoteTasks/Portable.RemoteTasks.Manager.exe",
    [string]$SslConfig = "tools/RemoteTasks/ssl-cfg.yaml",
    [string]$Login = "505979",
    [string]$Password = "9d7a3ade-42cd-4693-85e6-5367bbe31597",
    [string]$CodeBankName = "ram",
    [string]$IpRegisterName = "ip",
    [string]$FinishMnemonicName = "halt",
    [string]$ArchName = "TacVm13",
    [string]$InspectorSectionName = "simplelang.debug.json"
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
$inspectorProjectPath = Resolve-AbsolutePath -Path $InspectorProject -MustExist
$managerExe = Resolve-AbsolutePath -Path $ManagerPath -MustExist
$sslPath = Resolve-AbsolutePath -Path $SslConfig -MustExist

$inspectorArgs = @(
    "run",
    "--project", $inspectorProjectPath,
    "--",
    "inspect",
    "--binary", $binaryPath,
    "--definition", $definitionPath,
    "--manager", $managerExe,
    "--sslcfg", $sslPath,
    "--login", $Login,
    "--password", $Password,
    "--code-bank", $CodeBankName,
    "--ip-reg", $IpRegisterName,
    "--finish-mnemonic", $FinishMnemonicName,
    "--arch", $ArchName,
    "--run-mode", $RunMode,
    "--section-name", $InspectorSectionName
)

if ($RunMode -eq "inputfile") {
    if ([string]::IsNullOrWhiteSpace($InputFile)) {
        throw "-InputFile is required when -RunMode inputfile"
    }
    $inputPath = Resolve-AbsolutePath -Path $InputFile -MustExist
    $inspectorArgs += @("--input-file", $inputPath)
}

if ($RunMode -eq "withio") {
    $devicesPath = Resolve-AbsolutePath -Path $DevicesFile -MustExist
    $inspectorArgs += @("--devices", $devicesPath)
}

if (-not [string]::IsNullOrWhiteSpace($Script)) {
    $scriptPath = Resolve-AbsolutePath -Path $Script -MustExist
    $inspectorArgs += @("--script", $scriptPath)
}

$dotnetCliHome = Join-Path $projectRoot ".dotnet-cli"
New-Item -ItemType Directory -Force -Path $dotnetCliHome | Out-Null

$oldDotnetCliHome = $env:DOTNET_CLI_HOME
$oldDotnetSkip = $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE
$oldDotnetNoLogo = $env:DOTNET_NOLOGO
$oldDotnetTelemetry = $env:DOTNET_CLI_TELEMETRY_OPTOUT
$oldDotnetCert = $env:DOTNET_GENERATE_ASPNET_CERTIFICATE

try {
    $env:DOTNET_CLI_HOME = $dotnetCliHome
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = "1"
    $env:DOTNET_NOLOGO = "1"
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
    $env:DOTNET_GENERATE_ASPNET_CERTIFICATE = "false"
    & dotnet @inspectorArgs
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
finally {
    $env:DOTNET_CLI_HOME = $oldDotnetCliHome
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = $oldDotnetSkip
    $env:DOTNET_NOLOGO = $oldDotnetNoLogo
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = $oldDotnetTelemetry
    $env:DOTNET_GENERATE_ASPNET_CERTIFICATE = $oldDotnetCert
}
