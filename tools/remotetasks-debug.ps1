param(
    [string]$BinaryFile = "build/program.ptptb",
    [string]$DefinitionFile = "src/TacVm13.target.pdsl",
    [string]$DevicesFile = "src/TacVm13.devices.xml",
    [ValidateSet("WithIo")]
    [string]$RunMode = "WithIo",
    [int]$WithIoInteractiveSession = 1,
    [string]$ArchName = "TacVm13",
    [string]$OutputDir = "build/debug",
    [int]$PollIntervalSeconds = 2,
    [int]$TaskTimeoutSeconds = 300,
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

function Quote-CmdArgument {
    param(
        [Parameter(Mandatory = $true)][string]$Value
    )

    return '"' + $Value.Replace('"', '""') + '"'
}

function Invoke-ManagerText {
    param(
        [Parameter(Mandatory = $true)][string]$ManagerExePath,
        [Parameter(Mandatory = $true)][object[]]$Arguments
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add((Quote-CmdArgument -Value $ManagerExePath))
    foreach ($argument in $Arguments) {
        $parts.Add((Quote-CmdArgument -Value ([string]$argument)))
    }

    $commandText = [string]::Join(' ', $parts)
    return cmd /c $commandText 2>&1
}

function Invoke-ManagerQuiet {
    param(
        [Parameter(Mandatory = $true)][string]$ManagerExePath,
        [Parameter(Mandatory = $true)][object[]]$Arguments
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add((Quote-CmdArgument -Value $ManagerExePath))
    foreach ($argument in $Arguments) {
        $parts.Add((Quote-CmdArgument -Value ([string]$argument)))
    }

    $commandText = [string]::Join(' ', $parts)
    cmd /c "$commandText >nul 2>nul" | Out-Null
    return $LASTEXITCODE
}

function Save-ArtifactIfPresent {
    param(
        [string]$ManagerExe,
        [object[]]$ManagerBaseArgs,
        [string]$TaskId,
        [string]$Name,
        [string]$TargetPath,
        [string]$LoginValue,
        [string]$PasswordValue
    )

    $exitCode = Invoke-ManagerQuiet -ManagerExePath $ManagerExe -Arguments ($ManagerBaseArgs + @("-g", $TaskId, "-r", $Name, "-o", $TargetPath))
    return ($exitCode -eq 0)
}

$binaryPath = Resolve-AbsolutePath -Path $BinaryFile -MustExist
$definitionPath = Resolve-AbsolutePath -Path $DefinitionFile -MustExist
$devicesPath = Resolve-AbsolutePath -Path $DevicesFile -MustExist
$managerExe = Resolve-AbsolutePath -Path $ManagerPath -MustExist
$managerBaseArgs = Get-ManagerBaseArgs -SslCfg $SslConfig -LoginValue $Login -PasswordValue $Password
$outDir = Resolve-AbsolutePath -Path $OutputDir
$binaryManagerPath = Convert-ToManagerPath -AbsolutePath $binaryPath
$definitionManagerPath = Convert-ToManagerPath -AbsolutePath $definitionPath
$devicesManagerPath = Convert-ToManagerPath -AbsolutePath $devicesPath

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$debugArgs = @("-q")
if ($WithIoInteractiveSession -ne 0) {
    $debugArgs += "-ib"
}
$debugArgs += @("-s", "DebugBinaryWithIo", "devices.xml", $devicesManagerPath, "definitionFile", $definitionManagerPath, "archName", $ArchName, "binaryFileToRun", $binaryManagerPath, "codeRamBankName", "ram", "ipRegStorageName", "ip", "finishMnemonicName", "halt")
$startOutput = Invoke-ManagerText -ManagerExePath $managerExe -Arguments ($managerBaseArgs + $debugArgs)
$startText = ($startOutput | Out-String).Trim()

if ($startText -notmatch 'id ([0-9a-fA-F-]+)') {
    throw "Failed to start DebugBinaryWithIo task.`n$startText"
}

$taskId = $matches[1]
$deadline = (Get-Date).AddSeconds($TaskTimeoutSeconds)
$taskStateText = ""
$finished = $false

$taskInfoPath = Join-Path $outDir "task_info.txt"
[System.IO.File]::WriteAllText($taskInfoPath, "taskName=DebugBinaryWithIo`ntaskId=$taskId`nbinaryFile=$binaryPath`ndevicesFile=$devicesPath")

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $PollIntervalSeconds
    $taskState = Invoke-ManagerText -ManagerExePath $managerExe -Arguments ($managerBaseArgs + @("-g", $taskId))
    $taskStateText = ($taskState | Out-String)
    if ($taskStateText -match 'Task state:\s*Finished') {
        $finished = $true
        break
    }
}

$statePath = Join-Path $outDir "task_state.txt"
[System.IO.File]::WriteAllText($statePath, $taskStateText)

if (-not $finished) {
    throw "DebugBinaryWithIo timed out after $TaskTimeoutSeconds seconds. Last state saved to $statePath"
}

$saved = @()
foreach ($artifact in @("trace.txt", "stdout.txt", "stderr.txt", "stdin.txt")) {
    $targetPath = Join-Path $outDir $artifact
    if (Save-ArtifactIfPresent -ManagerExe $managerExe -ManagerBaseArgs $managerBaseArgs -TaskId $taskId -Name $artifact -TargetPath $targetPath -LoginValue $Login -PasswordValue $Password) {
        $saved += $targetPath
    }
}

Write-Host "Debug task id: $taskId"
Write-Host "Task state saved to $statePath"
if ($saved.Count -gt 0) {
    Write-Host "Artifacts:"
    foreach ($item in $saved) {
        Write-Host "  $item"
    }
} else {
    Write-Host "No downloadable artifacts were found for task $taskId"
}
