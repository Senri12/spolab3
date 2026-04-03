param(
    [string]$InputFile = "input.txt",
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

$sessionId = [guid]::NewGuid().ToString("N")
$remoteDir = "/home/user/projects/spo3_parseonly_$sessionId"
$remoteInputName = [System.IO.Path]::GetFileName($inputPath)
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
    & ssh -p $RemotePort $sshTarget "mkdir -p '$remoteDir/build/src'"
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
        "java -cp /usr/local/lib/antlr-3.4-complete.jar org.antlr.Tool -o build/src src/SimpleLang.g",
        "gcc -o build/src/parse_only src/parse_only_main.c build/src/src/*.c -O0 -g -I/usr/local/include -Isrc -Ibuild/src/src -L/usr/local/lib -lantlr3c",
        "./build/src/parse_only '$remoteInputName'"
    ) -join " && "

    & ssh -p $RemotePort $sshTarget $remoteCommand
    if ($LASTEXITCODE -ne 0) {
        throw "Remote parse-only run failed"
    }
}
finally {
    $env:SSH_ASKPASS = $oldAskPass
    $env:SSH_ASKPASS_REQUIRE = $oldAskPassRequire
    $env:DISPLAY = $oldDisplay

    if (Test-Path -LiteralPath $askPassPath) {
        Remove-Item -LiteralPath $askPassPath -Force
    }
}
