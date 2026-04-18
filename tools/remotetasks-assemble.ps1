param(
    [string]$AsmListing = "build/program.asm",
    [string[]]$ExtraAsmFiles = @(),
    [string]$DefinitionFile = "src/TacVm13.target.pdsl",
    [string]$ArchName = "TacVm13",
    [string]$BinaryOutput = "build/program.ptptb",
    [switch]$SkipInspectorEmbed,
    [string]$InspectorProject = "tools/SpoInspector/SpoInspector.csproj",
    [string]$InspectorSectionName = "simplelang.debug.json",
    [string]$InspectorArtifactsRoot = "build/spoinspector",
    [string]$TaskInfoOutput = "build/remote_tasks/last_assemble_task.txt",
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
        [string]$ManagerExePath,
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

function Resolve-AbsolutePathList {
    param(
        [string[]]$Paths
    )

    $items = @()
    foreach ($entry in $Paths) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }

        $parts = $entry.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
        foreach ($part in $parts) {
            $trimmed = $part.Trim()
            if ($trimmed.Length -eq 0) {
                continue
            }
            $items += Resolve-AbsolutePath -Path $trimmed -MustExist
        }
    }

    return $items
}

$asmPath = Resolve-AbsolutePath -Path $AsmListing -MustExist
$extraAsmPaths = Resolve-AbsolutePathList -Paths $ExtraAsmFiles
$definitionPath = Resolve-AbsolutePath -Path $DefinitionFile -MustExist
$binaryPath = Resolve-AbsolutePath -Path $BinaryOutput
$inspectorProjectPath = Resolve-AbsolutePath -Path $InspectorProject -MustExist
$inspectorArtifactsPath = Resolve-AbsolutePath -Path $InspectorArtifactsRoot
$taskInfoPath = Resolve-AbsolutePath -Path $TaskInfoOutput
$managerExe = Resolve-AbsolutePath -Path $ManagerPath -MustExist
$managerBaseArgs = Get-ManagerBaseArgs -ManagerExePath $managerExe -SslCfg $SslConfig -LoginValue $Login -PasswordValue $Password

New-Item -ItemType Directory -Force (Split-Path -Parent $binaryPath) | Out-Null
New-Item -ItemType Directory -Force (Split-Path -Parent $taskInfoPath) | Out-Null
if (Test-Path -LiteralPath $binaryPath) {
    Remove-Item -LiteralPath $binaryPath -Force
}

$assembleAsmPath = $asmPath
if ($extraAsmPaths.Count -gt 0) {
    $linkedAsmPath = [System.IO.Path]::ChangeExtension($binaryPath, ".linked.asm")
    $chunks = New-Object System.Collections.Generic.List[string]
    $chunks.Add([System.IO.File]::ReadAllText($asmPath))
    foreach ($extraAsmPath in $extraAsmPaths) {
        $chunks.Add("")
        $chunks.Add([System.IO.File]::ReadAllText($extraAsmPath))
    }
    [System.IO.File]::WriteAllText($linkedAsmPath, [string]::Join([Environment]::NewLine, $chunks))
    $assembleAsmPath = $linkedAsmPath
}

$assembleAsmManagerPath = Convert-ToManagerPath -AbsolutePath $assembleAsmPath
$definitionManagerPath = Convert-ToManagerPath -AbsolutePath $definitionPath

$startOutput = Invoke-ManagerText -ManagerExePath $managerExe -Arguments ($managerBaseArgs + @("-q", "-s", "Assemble", "asmListing", $assembleAsmManagerPath, "definitionFile", $definitionManagerPath, "archName", $ArchName))
$startText = ($startOutput | Out-String).Trim()

if ($startText -notmatch 'id ([0-9a-fA-F-]+)') {
    throw "Failed to start Assemble task.`n$startText"
}

$taskId = $matches[1]
[System.IO.File]::WriteAllText($taskInfoPath, "taskName=Assemble`ntaskId=$taskId`nasmListing=$assembleAsmPath`nbinaryOutput=$binaryPath")
$deadline = (Get-Date).AddSeconds($TaskTimeoutSeconds)
$taskState = $null
$taskStateText = ""
$finished = $false

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $PollIntervalSeconds
    $taskState = Invoke-ManagerText -ManagerExePath $managerExe -Arguments ($managerBaseArgs + @("-g", $taskId))
    $taskStateText = ($taskState | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Assemble task failed.`n$taskStateText"
    }
    if ($taskStateText -match 'Task state:\s*Finished') {
        $finished = $true
        break
    }
}

if (-not $finished) {
    throw "Assemble task timed out after $TaskTimeoutSeconds seconds.`n$taskStateText"
}

$downloadExitCode = Invoke-ManagerQuiet -ManagerExePath $managerExe -Arguments ($managerBaseArgs + @("-g", $taskId, "-r", "out.ptptb", "-o", $binaryPath))
if ($downloadExitCode -ne 0) {
    throw "Failed to download out.ptptb for task $taskId"
}

if (-not $SkipInspectorEmbed) {
    $symPath = "$asmPath.sym"
    if (Test-Path -LiteralPath $symPath) {
        $dotnetCliHome = Join-Path $projectRoot ".dotnet-cli"
        $inspectorObjPath = Join-Path $inspectorArtifactsPath "obj"
        $inspectorBinPath = Join-Path $inspectorArtifactsPath "bin"
        New-Item -ItemType Directory -Force -Path $dotnetCliHome | Out-Null
        New-Item -ItemType Directory -Force -Path $inspectorObjPath | Out-Null
        New-Item -ItemType Directory -Force -Path $inspectorBinPath | Out-Null

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

            $embedOutput = & dotnet run `
                --project $inspectorProjectPath `
                --property:BaseIntermediateOutputPath="$inspectorObjPath\" `
                --property:BaseOutputPath="$inspectorBinPath\" `
                -- embed `
                --binary $binaryPath `
                --asm $asmPath `
                --sym $symPath `
                --section-name $InspectorSectionName 2>&1

            if ($LASTEXITCODE -ne 0) {
                $embedText = ($embedOutput | Out-String).Trim()
                Write-Warning "Failed to embed inspector metadata into $binaryPath"
                if (-not [string]::IsNullOrWhiteSpace($embedText)) {
                    Write-Warning $embedText
                }
            }
            elseif ($embedOutput) {
                $embedOutput | ForEach-Object { Write-Host $_ }
            }
        }
        finally {
            $env:DOTNET_CLI_HOME = $oldDotnetCliHome
            $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = $oldDotnetSkip
            $env:DOTNET_NOLOGO = $oldDotnetNoLogo
            $env:DOTNET_CLI_TELEMETRY_OPTOUT = $oldDotnetTelemetry
            $env:DOTNET_GENERATE_ASPNET_CERTIFICATE = $oldDotnetCert
        }
    }
    else {
        Write-Warning "Skipping inspector embed because sym file was not found: $symPath"
    }
}

Write-Host "Binary written to $binaryPath"
