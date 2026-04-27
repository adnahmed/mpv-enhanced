param(
    # Re-download/re-run steps even when they look current.
    [switch]$Force,

    # Re-run the vs-rife model bootstrap even if it completed before.
    [switch]$RefreshModels,

    # Do not pause at the end. Useful when running from an existing terminal.
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# These may need updating over time.
$VapourSynthScriptUrl = "https://github.com/vapoursynth/vapoursynth/releases/download/R70/Install-Portable-VapourSynth-R70.ps1"
$PytorchUrl = "https://download.pytorch.org/whl/cu126"

# Use GitHub instead of SourceForge to avoid Cloudflare challenge HTML downloads.
$MpvGitHubLatestReleaseApiUrl = "https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/latest"
$MpvGitHubAssetPattern = "^mpv-x86_64-v3-\d{8}-git-[^.]+\.7z$"

$InstallRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$StateDir = Join-Path $InstallRoot ".install-state"
$DownloadDir = Join-Path $StateDir "downloads"

function Initialize-InstallState {
    New-Item -ItemType Directory -Force -Path $StateDir, $DownloadDir | Out-Null
}

function Enable-StrongTls {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.SecurityProtocolType]::Tls12 -bor `
        [Net.SecurityProtocolType]::Tls11 -bor `
        [Net.SecurityProtocolType]::Tls
}

function Get-StatePath {
    param([Parameter(Mandatory)][string]$Name)
    return (Join-Path $StateDir $Name)
}

function Get-StateValue {
    param([Parameter(Mandatory)][string]$Name)

    $path = Get-StatePath $Name
    if (Test-Path -LiteralPath $path) {
        return (Get-Content -LiteralPath $path -Raw).Trim()
    }

    return $null
}

function Set-StateValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    $path = Get-StatePath $Name
    Set-Content -LiteralPath $path -Value $Value -Encoding UTF8
}

function Assert-NativeExitCode {
    param([Parameter(Mandatory)][string]$StepName)

    if ($LASTEXITCODE -ne 0) {
        throw "$StepName failed with exit code $LASTEXITCODE."
    }
}

function Download-File {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Uri,
        [switch]$AlwaysDownload
    )

    if ((Test-Path -LiteralPath $Destination) -and -not $AlwaysDownload) {
        Write-Host "Already downloaded: $([IO.Path]::GetFileName($Destination))" -ForegroundColor DarkGray
        return
    }

    $parent = Split-Path -Parent $Destination
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    Write-Host "Downloading $([IO.Path]::GetFileName($Destination))" -ForegroundColor Green
    Invoke-WebRequest `
        -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36" `
        -Uri $Uri `
        -OutFile $Destination `
        -UseBasicParsing
}

function Test-SevenZipArchiveFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt 1MB) {
        return $false
    }

    $expected = [byte[]](0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C)
    $actual = New-Object byte[] 6
    $stream = [System.IO.File]::OpenRead($Path)

    try {
        [void]$stream.Read($actual, 0, 6)
    }
    finally {
        $stream.Dispose()
    }

    for ($i = 0; $i -lt $expected.Length; $i++) {
        if ($actual[$i] -ne $expected[$i]) {
            return $false
        }
    }

    return $true
}

function Get-ExistingPath {
    param([Parameter(Mandatory)][string[]]$RelativePaths)

    foreach ($relativePath in $RelativePaths) {
        $candidate = Join-Path $InstallRoot $relativePath
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-PythonPath {
    $python = Get-ExistingPath @("python.exe", "python", "python\python.exe")
    if (-not $python) {
        throw "Python was not found in '$InstallRoot'. Re-run with -Force to reinstall VapourSynth/Python."
    }

    return $python
}

function Get-VsRepoPath {
    $vsRepo = Get-ExistingPath @("vsrepo.py", "vsrepo\vsrepo.py")
    if (-not $vsRepo) {
        throw "vsrepo.py was not found in '$InstallRoot'. Re-run with -Force to reinstall VapourSynth."
    }

    return $vsRepo
}

function Get-SevenZipPath {
    $sevenZip = Get-ExistingPath @("7z.exe", "7za.exe", "7zip\7z.exe")
    if (-not $sevenZip) {
        throw "7z.exe was not found in '$InstallRoot'. VapourSynth's installer normally downloads it; re-run with -Force if needed."
    }

    return $sevenZip
}

function Invoke-Python {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$StepName
    )

    $python = Get-PythonPath
    & $python @Arguments
    Assert-NativeExitCode $StepName
}

function Test-PythonImport {
    param([Parameter(Mandatory)][string]$ModuleName)

    $python = Get-PythonPath
    & $python -c "import $ModuleName" *> $null
    return ($LASTEXITCODE -eq 0)
}

function Install-OrUpdateVapourSynth {
    # This upstream script does most of the heavy lifting, including downloading 7zip and Python.
    $scriptDest = Join-Path $DownloadDir "install_vs.ps1"
    $savedScriptUrl = Get-StateValue "vapoursynth-script-url.txt"
    $pythonExists = [bool](Get-ExistingPath @("python.exe", "python", "python\python.exe"))
    $vsRepoExists = [bool](Get-ExistingPath @("vsrepo.py", "vsrepo\vsrepo.py"))

    $needsInstall = $Force -or -not $pythonExists -or -not $vsRepoExists -or ($savedScriptUrl -ne $VapourSynthScriptUrl)

    if ($needsInstall) {
        Write-Host "Installing or refreshing VapourSynth..." -ForegroundColor Green
        Download-File `
            -Destination $scriptDest `
            -Uri $VapourSynthScriptUrl `
            -AlwaysDownload:([bool]($Force -or ($savedScriptUrl -ne $VapourSynthScriptUrl)))

        Push-Location $InstallRoot
        try {
            & $scriptDest -Unattended -TargetFolder $InstallRoot
            if (-not $?) {
                throw "VapourSynth install failed."
            }
        }
        finally {
            Pop-Location
        }

        Set-StateValue "vapoursynth-script-url.txt" $VapourSynthScriptUrl
    }
    else {
        Write-Host "VapourSynth appears to be installed; skipping installer." -ForegroundColor DarkGray
    }

    Write-Host "Updating VapourSynth plugin index and ensuring misc plugins are installed..." -ForegroundColor Green
    Push-Location $InstallRoot
    try {
        $vsRepoScript = Get-VsRepoPath
        Invoke-Python @($vsRepoScript, "update") "vsrepo update"
        Invoke-Python @($vsRepoScript, "install", "com.vapoursynth.misc") "vsrepo misc plugin install"
    }
    finally {
        Pop-Location
    }
}

function Get-LatestMpvArchiveInfo {
    Enable-StrongTls
    Write-Host "Checking latest mpv build from GitHub releases..." -ForegroundColor Green

    $headers = @{
        "Accept" = "application/vnd.github+json"
        "User-Agent" = "mpv-enhanced-installer"
    }

    $release = Invoke-RestMethod `
        -Uri $MpvGitHubLatestReleaseApiUrl `
        -Headers $headers `
        -ErrorAction Stop

    $asset = @($release.assets) |
        Where-Object { $_.name -match $MpvGitHubAssetPattern } |
        Sort-Object -Property name -Descending |
        Select-Object -First 1

    if (-not $asset) {
        throw "Could not find a matching mpv v3 x86_64 .7z asset in GitHub release '$($release.tag_name)'. Pattern: $MpvGitHubAssetPattern"
    }

    return [pscustomobject]@{
        ReleaseTag = [string]$release.tag_name
        ArchiveName = [string]$asset.name
        DownloadLink = [string]$asset.browser_download_url
    }
}

function Install-OrUpdateMpv {
    $latest = Get-LatestMpvArchiveInfo
    $installedArchive = Get-StateValue "mpv-archive.txt"
    $mpvExe = Join-Path $InstallRoot "mpv.exe"
    $alreadyCurrent = (Test-Path -LiteralPath $mpvExe) -and ($installedArchive -eq $latest.ArchiveName)

    if ($alreadyCurrent -and -not $Force) {
        Write-Host "mpv is already current: $($latest.ArchiveName)" -ForegroundColor DarkGray
        return
    }

    if (Test-Path -LiteralPath $mpvExe) {
        if ($installedArchive) {
            Write-Host "Updating mpv from $installedArchive to $($latest.ArchiveName)..." -ForegroundColor Green
        }
        else {
            Write-Host "mpv exists, but no version marker was found; refreshing to latest build..." -ForegroundColor Green
        }
    }
    else {
        Write-Host "Installing mpv $($latest.ArchiveName)..." -ForegroundColor Green
    }

    $archivePath = Join-Path $DownloadDir $latest.ArchiveName
    $sevenZip = Get-SevenZipPath
    $tries = 0

    while ($true) {
        try {
            $cachedArchiveIsValid = Test-SevenZipArchiveFile -Path $archivePath
            if ((Test-Path -LiteralPath $archivePath) -and -not $cachedArchiveIsValid) {
                Write-Host "Removing invalid cached mpv archive: $([IO.Path]::GetFileName($archivePath))" -ForegroundColor Yellow
                Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
            }

            Download-File `
                -Destination $archivePath `
                -Uri $latest.DownloadLink `
                -AlwaysDownload:([bool]($Force -or -not (Test-SevenZipArchiveFile -Path $archivePath)))

            if (-not (Test-SevenZipArchiveFile -Path $archivePath)) {
                Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
                throw "Downloaded mpv file is not a valid .7z archive. The server may have returned HTML instead of the archive."
            }

            & $sevenZip -y x $archivePath "-o$InstallRoot"
            Assert-NativeExitCode "mpv archive extraction"

            Set-StateValue "mpv-archive.txt" $latest.ArchiveName
            Set-StateValue "mpv-release-tag.txt" $latest.ReleaseTag
            Set-StateValue "mpv-source.txt" "github:shinchiro/mpv-winbuild-cmake"
            Write-Host "mpv installed/current: $($latest.ArchiveName)" -ForegroundColor Green
            break
        }
        catch {
            $tries++
            if ($tries -ge 5) {
                throw "Could not download and extract mpv archive after $tries tries. Last error: $_"
            }

            Write-Host "mpv download/extract failed; retrying..." -ForegroundColor Yellow
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 15
        }
    }
}

function Install-OrUpdateVSRife {
    Write-Host "Updating pip tooling..." -ForegroundColor Green
    Invoke-Python @("-m", "pip", "install", "-U", "pip", "packaging", "setuptools", "wheel") "pip tooling update"

    Write-Host "Installing/updating PyTorch and Torch-TensorRT..." -ForegroundColor Green
    Invoke-Python @(
        "-m", "pip", "install", "-U",
        "torch", "torchvision", "torch_tensorrt",
        "--index-url", $PytorchUrl,
        "--extra-index-url", "https://pypi.nvidia.com"
    ) "PyTorch/Torch-TensorRT install"

    Write-Host "Installing/updating vs-rife..." -ForegroundColor Green
    Invoke-Python @("-m", "pip", "install", "-U", "git+https://github.com/adnahmed/vs-rife") "vs-rife install"

    if (-not (Test-PythonImport "vsrife")) {
        throw "vs-rife was installed, but Python cannot import the 'vsrife' module."
    }

    $modelMarker = Get-StatePath "vsrife-model-bootstrap-complete.txt"
    if ($Force -or $RefreshModels -or -not (Test-Path -LiteralPath $modelMarker)) {
        Write-Host "Running vs-rife model bootstrap..." -ForegroundColor Green
        Invoke-Python @("-m", "vsrife") "vs-rife model bootstrap"
        Set-Content -LiteralPath $modelMarker -Value (Get-Date -Format o) -Encoding UTF8
    }
    else {
        Write-Host "vs-rife model bootstrap already completed; skipping." -ForegroundColor DarkGray
    }
}

function Wait-BeforeExit {
    param([bool]$Failed)

    if ($NoPause) {
        return
    }

    if ($Failed) {
        Write-Host "Press any key to exit..." -NoNewline
        [void][System.Console]::ReadKey($true)
    }
    else {
        Write-Host "Closing in 5 seconds..." -ForegroundColor White -BackgroundColor Green
        Start-Sleep -Seconds 5
    }
}

try {
    Initialize-InstallState
    Install-OrUpdateVapourSynth
    Install-OrUpdateMpv
    Install-OrUpdateVSRife

    Write-Host
    Write-Host "All done!" -ForegroundColor White -BackgroundColor Green
    Wait-BeforeExit -Failed:$false
}
catch {
    Write-Host
    Write-Host "Installation failed!" -ForegroundColor Red
    Write-Output $_
    Wait-BeforeExit -Failed:$true
    exit 1
}
