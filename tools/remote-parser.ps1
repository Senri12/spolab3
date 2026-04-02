param(
    [string]$InputFile = "input.txt",
    [string]$AsmOutput = "build/program.asm",
    [string]$ParseTreeOutput = "build/parse_tree.dgml",
    [string]$RemoteHost = "localhost",
    [int]$RemotePort = 5555,
    [string]$RemoteUser = "user",
    [string]$RemotePassword = "student"
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

$inputPath = Resolve-AbsolutePath -Path $InputFile -MustExist
$asmPath = Resolve-AbsolutePath -Path $AsmOutput
$dgmlPath = Resolve-AbsolutePath -Path $ParseTreeOutput

New-Item -ItemType Directory -Force (Split-Path -Parent $asmPath) | Out-Null
New-Item -ItemType Directory -Force (Split-Path -Parent $dgmlPath) | Out-Null

$sessionId = [guid]::NewGuid().ToString("N")
$remoteDir = "/home/user/projects/spo3_remote_$sessionId"
$remoteInputName = [System.IO.Path]::GetFileName($inputPath)
$remoteAsmPath = "out/program.asm"
$remoteDgmlPath = "out/parse_tree.dgml"
$sshTarget = "$RemoteUser@$RemoteHost"
$askPassPath = Join-Path $env:TEMP "codex-ssh-askpass-$sessionId.bat"

@"
@echo off
echo $RemotePassword
"@ | Set-Content -LiteralPath $askPassPath -Encoding ASCII

$oldAskPass = $env:SSH_ASKPASS
$oldAskPassRequire = $env:SSH_ASKPASS_REQUIRE
$oldDisplay = $env:DISPLAY

$env:SSH_ASKPASS = $askPassPath
$env:SSH_ASKPASS_REQUIRE = "force"
$env:DISPLAY = "dummy"

try {
    & ssh -p $RemotePort $sshTarget "mkdir -p '$remoteDir/out'"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create remote workdir $remoteDir"
    }

    & scp -P $RemotePort -r (Join-Path $projectRoot "src") "$sshTarget`:$remoteDir/"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to upload src/ to $remoteDir"
    }

    & scp -P $RemotePort $inputPath "$sshTarget`:$remoteDir/$remoteInputName"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to upload input file to $remoteDir"
    }

    $remoteCommand = @(
        "cd '$remoteDir'",
        "mkdir -p build/src out",
        "java -cp /usr/local/lib/antlr-3.4-complete.jar org.antlr.Tool -o build/src src/SimpleLang.g",
        "gcc -o build/src/parser src/main.c src/cfg_builder.c build/src/src/*.c -O0 -g -I/usr/local/include -Isrc -Ibuild/src/src -L/usr/local/lib -lantlr3c",
        "./build/src/parser '$remoteInputName' '$remoteAsmPath' '$remoteDgmlPath'"
    ) -join " && "

    & ssh -p $RemotePort $sshTarget $remoteCommand
    if ($LASTEXITCODE -ne 0) {
        throw "Remote parser build/run failed"
    }

    & scp -P $RemotePort "$sshTarget`:$remoteDir/$remoteAsmPath" $asmPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to download generated assembly"
    }

    & scp -P $RemotePort "$sshTarget`:$remoteDir/$remoteDgmlPath" $dgmlPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to download parse tree DGML"
    }

    Write-Host "Assembly written to $asmPath"
    Write-Host "Parse tree written to $dgmlPath"
}
finally {
    $env:SSH_ASKPASS = $oldAskPass
    $env:SSH_ASKPASS_REQUIRE = $oldAskPassRequire
    $env:DISPLAY = $oldDisplay

    if (Test-Path -LiteralPath $askPassPath) {
        Remove-Item -LiteralPath $askPassPath -Force
    }
}
