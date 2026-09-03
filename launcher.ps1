[CmdletBinding()]
param(
  [ValidateSet('client', 'server')]
  [string]$Component = 'client',
  [switch]$SkipSelfUpdate,
  [string]$ApiBaseUrl = 'https://api.github.com'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepositoryRoot = Split-Path -Parent $PSCommandPath
$script:RuntimeRoot = Join-Path $script:RepositoryRoot '.runtime'
$script:ClientPort = 5722
$script:ServerPort = 45679
$script:GitHubApiVersion = '2022-11-28'

function Write-Info([string]$Message) {
  Write-Host "[daily-assistant] $Message"
}

function Write-WarningMessage([string]$Message) {
  Write-Warning "[daily-assistant] $Message"
}

function Invoke-Git {
  param([Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowFailure)
  $output = & git -C $script:RepositoryRoot @Arguments 2>&1
  if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
    throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
  }
  return @($output)
}

function Update-LauncherRepository {
  if ($SkipSelfUpdate -or -not (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.git'))) {
    return $false
  }
  try {
    $before = (Invoke-Git -Arguments @('rev-parse', 'HEAD'))[0].Trim()
    Invoke-Git -Arguments @('pull', '--ff-only') | Out-Null
    $after = (Invoke-Git -Arguments @('rev-parse', 'HEAD'))[0].Trim()
    return $before -ne $after
  } catch {
    Write-WarningMessage "Launcher update was skipped: $($_.Exception.Message)"
    return $false
  }
}

function Get-ReleaseRepository {
  if ($env:DAILY_ASSISTANT_RELEASE_REPOSITORY) {
    if ($env:DAILY_ASSISTANT_RELEASE_REPOSITORY -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
      throw 'DAILY_ASSISTANT_RELEASE_REPOSITORY must be OWNER/REPOSITORY'
    }
    return $env:DAILY_ASSISTANT_RELEASE_REPOSITORY
  }
  $remote = ((Invoke-Git -Arguments @('remote', 'get-url', 'origin'))[0]).Trim()
  if ($remote -match 'github\.com[/:](?<owner>[^/]+?)/(?<repo>[^/]+?)(?:\.git)?$') {
    return "$($Matches.owner)/$($Matches.repo)"
  }
  throw "Could not determine a GitHub repository from origin: $remote"
}

function Get-GitHubCredential {
  $lines = @("protocol=https", "host=github.com", "") | & git credential fill 2>$null
  if ($LASTEXITCODE -ne 0) { throw 'Git Credential Manager could not provide GitHub credentials' }
  $credential = @{}
  foreach ($line in @($lines)) {
    if ($line -match '^(?<key>[^=]+)=(?<value>.*)$') { $credential[$Matches.key] = $Matches.value }
  }
  if (-not $credential.ContainsKey('password') -or -not $credential.password) {
    throw 'GitHub credential is unavailable; authenticate Git for Windows against the private release repository'
  }
  return [string]$credential.password
}

function Get-GitHubHeaders([string]$Token, [string]$Accept = 'application/vnd.github+json') {
  return @{
    Accept = $Accept
    Authorization = "Bearer $Token"
    'X-GitHub-Api-Version' = $script:GitHubApiVersion
    'User-Agent' = 'daily-assistant-release-launcher'
  }
}

function Get-LatestRelease([string]$Repository, [string]$Token) {
  $uri = "$($ApiBaseUrl.TrimEnd('/'))/repos/$Repository/releases/latest"
  $release = Invoke-RestMethod -Uri $uri -Headers (Get-GitHubHeaders $Token) -Method Get
  if ($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^v\d+\.\d+\.\d+$') {
    throw "Latest release is not a stable vX.Y.Z release: $($release.tag_name)"
  }
  return $release
}

function Get-ReleaseAsset($Release, [string]$Name) {
  $asset = @($Release.assets) | Where-Object { $_.name -eq $Name } | Select-Object -First 1
  if (-not $asset) { throw "Release $($Release.tag_name) does not contain $Name" }
  return $asset
}

function Save-ReleaseAsset($Asset, [string]$Token, [string]$Destination) {
  Invoke-WebRequest -UseBasicParsing -Uri $Asset.url -Headers (Get-GitHubHeaders $Token 'application/octet-stream') -OutFile $Destination
}

function Read-JsonFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-JsonAtomic([string]$Path, $Value) {
  $directory = Split-Path -Parent $Path
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
  $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
  $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporary -Encoding UTF8
  Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-ComponentPaths([string]$Name) {
  if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable' }
  $componentRoot = Join-Path $script:RuntimeRoot $Name
  $profileRoot = if ($Name -eq 'client') {
    Join-Path $env:LOCALAPPDATA 'DailyAssistant'
  } else {
    Join-Path $env:LOCALAPPDATA 'DailyAssistant\server'
  }
  return @{
    Root = $componentRoot
    Versions = Join-Path $componentRoot 'versions'
    State = Join-Path $componentRoot 'current.json'
    Logs = Join-Path $profileRoot 'logs'
  }
}

function Get-CurrentInstallation([string]$Name) {
  $paths = Get-ComponentPaths $Name
  $state = Read-JsonFile $paths.State
  if (-not $state -or -not $state.tag -or $state.tag -notmatch '^v\d+\.\d+\.\d+$') { return $null }
  $root = Join-Path $paths.Versions $state.tag
  $manifest = Read-JsonFile (Join-Path $root 'build-manifest.json')
  if (-not $manifest -or $manifest.component -ne $Name -or "v$($manifest.version)" -ne $state.tag) { return $null }
  return @{ Tag = [string]$state.tag; Root = $root; Manifest = $manifest }
}

function Assert-PortableInstallation([string]$Root, [string]$Name, [string]$Tag) {
  $manifestPath = Join-Path $Root 'build-manifest.json'
  $manifest = Read-JsonFile $manifestPath
  if (-not $manifest) { throw 'The archive does not contain build-manifest.json' }
  if ($manifest.schemaVersion -ne 1 -or $manifest.product -ne 'daily-assistant' -or $manifest.component -ne $Name) {
    throw 'The archive build manifest has an unexpected product, component, or schema'
  }
  if ("v$($manifest.version)" -ne $Tag -or $manifest.platform -ne 'win32' -or $manifest.arch -ne 'x64') {
    throw 'The archive build manifest does not match the selected release or platform'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $Root 'runtime\node.exe') -PathType Leaf)) {
    throw 'The archive does not contain its portable Node.js runtime'
  }
  $forbidden = Get-ChildItem -LiteralPath $Root -Recurse -Force | Where-Object {
    ($_.PSIsContainer -and $_.Name -eq 'node_modules') -or
    (-not $_.PSIsContainer -and ($_.Extension -in @('.ts', '.tsx', '.map') -or $_.Name -eq 'package.json' -or $_.Name -match '(^|[.-])(test|spec)\.[cm]?js$'))
  } | Select-Object -First 1
  if ($forbidden) { throw "Forbidden content in release archive: $($forbidden.FullName)" }

  $entryName = if ($Name -eq 'client') { 'daemon' } else { 'server' }
  $entry = [string]$manifest.entrypoints.$entryName
  if (-not $entry -or -not (Test-Path -LiteralPath (Join-Path $Root $entry) -PathType Leaf)) {
    throw "The archive entrypoint $entryName is missing"
  }
  if ($Name -eq 'client') {
    foreach ($required in @([string]$manifest.entrypoints.mcp, [string]$manifest.entrypoints.web)) {
      if (-not $required -or -not (Test-Path -LiteralPath (Join-Path $Root $required))) {
        throw "The client archive path is missing: $required"
      }
    }
  }
  return $manifest
}

function Install-ReleaseAsset($Release, $ReleaseManifest, [string]$Name, [string]$Token) {
  $assetProperty = $ReleaseManifest.assets.PSObject.Properties[$Name]
  $assetInfo = if ($assetProperty) { $assetProperty.Value } else { $null }
  if (-not $assetInfo -or $assetInfo.platform -ne 'win32' -or $assetInfo.arch -ne 'x64') {
    throw "release-manifest.json has no Windows x64 $Name asset"
  }
  if ($assetInfo.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Invalid SHA-256 for $Name asset" }
  $asset = Get-ReleaseAsset $Release ([string]$assetInfo.name)
  $paths = Get-ComponentPaths $Name
  $versionRoot = Join-Path $paths.Versions $Release.tag_name
  if (Test-Path -LiteralPath $versionRoot) {
    Assert-PortableInstallation $versionRoot $Name $Release.tag_name | Out-Null
    return $versionRoot
  }

  New-Item -ItemType Directory -Path $paths.Versions -Force | Out-Null
  $stagingRoot = Join-Path $script:RuntimeRoot ("staging-" + [Guid]::NewGuid().ToString('N'))
  $archive = Join-Path $stagingRoot ([string]$assetInfo.name)
  $expanded = Join-Path $stagingRoot 'expanded'
  try {
    New-Item -ItemType Directory -Path $expanded -Force | Out-Null
    Write-Info "Downloading $($assetInfo.name) from $($Release.tag_name)..."
    Save-ReleaseAsset $asset $Token $archive
    $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne ([string]$assetInfo.sha256).ToLowerInvariant()) {
      throw "SHA-256 mismatch for $($assetInfo.name)"
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded -Force
    Assert-PortableInstallation $expanded $Name $Release.tag_name | Out-Null
    Move-Item -LiteralPath $expanded -Destination $versionRoot
    return $versionRoot
  } finally {
    if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
  }
}

function Invoke-JsonRequest {
  param(
    [Parameter(Mandatory)][string]$Uri,
    [ValidateSet('GET', 'POST')][string]$Method = 'GET',
    [hashtable]$Headers = @{},
    [int]$TimeoutSec = 2
  )
  return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -TimeoutSec $TimeoutSec
}

function Get-ServiceHealth([string]$Name) {
  $port = if ($Name -eq 'client') { $script:ClientPort } else { $script:ServerPort }
  try { return Invoke-JsonRequest -Uri "http://127.0.0.1:$port/health" } catch { return $null }
}

function Test-LocalPort([int]$Port) {
  $client = New-Object Net.Sockets.TcpClient
  try {
    $result = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
    if (-not $result.AsyncWaitHandle.WaitOne(500)) { return $false }
    $client.EndConnect($result)
    return $true
  } catch {
    return $false
  } finally {
    $client.Dispose()
  }
}

function Wait-ServiceState([string]$Name, [string]$Version, [bool]$Running, [int]$TimeoutSeconds = 20) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $port = if ($Name -eq 'client') { $script:ClientPort } else { $script:ServerPort }
  do {
    $health = Get-ServiceHealth $Name
    if ($Running) {
      $expectedService = if ($Name -eq 'client') { 'daily-assistant-daemon' } else { 'daily-assistant-sync-server' }
      if ($health -and $health.ok -eq $true -and $health.service -eq $expectedService -and $health.version -eq $Version) {
        return $health
      }
    } elseif (-not (Test-LocalPort $port)) {
      return $null
    }
    Start-Sleep -Milliseconds 150
  } while ((Get-Date) -lt $deadline)
  $state = if ($Running) { 'start' } else { 'stop' }
  throw "$Name did not $state within $TimeoutSeconds seconds"
}

function Get-ClientCapability {
  if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable' }
  $configPath = Join-Path $env:LOCALAPPDATA 'DailyAssistant\daemon-config.json'
  $config = Read-JsonFile $configPath
  if (-not $config -or $config.browserCapability -notmatch '^[A-Za-z0-9_-]{43}$') {
    throw "Could not read the client capability from $configPath"
  }
  return [string]$config.browserCapability
}

function Stop-RunningComponent([string]$Name, [string]$NextTag) {
  $health = Get-ServiceHealth $Name
  $port = if ($Name -eq 'client') { $script:ClientPort } else { $script:ServerPort }
  if (-not $health) {
    if (Test-LocalPort $port) { throw "Port $port is occupied by an unexpected service" }
    return $null
  }
  $expectedService = if ($Name -eq 'client') { 'daily-assistant-daemon' } else { 'daily-assistant-sync-server' }
  if ($health.service -ne $expectedService) {
    throw "Port $port is occupied by an unexpected service"
  }

  $backupPath = $null
  if ($Name -eq 'client') {
    $capability = Get-ClientCapability
    $headers = @{ 'x-daily-assistant-capability' = $capability }
    try {
      $backup = Invoke-JsonRequest -Uri "http://127.0.0.1:$($script:ClientPort)/backup/export" -Method POST -Headers $headers -TimeoutSec 15
      $backupPath = [string]$backup.filePath
    } catch {
      throw "Could not create the pre-update client backup: $($_.Exception.Message)"
    }
    Invoke-JsonRequest -Uri "http://127.0.0.1:$($script:ClientPort)/lifecycle/shutdown" -Method POST -Headers $headers | Out-Null
  } else {
    $settings = Get-ServerSettings
    Invoke-JsonRequest -Uri "http://127.0.0.1:$($script:ServerPort)/internal/lifecycle/shutdown" -Method POST -Headers @{
      'x-daily-assistant-launcher-token' = $settings.controlToken
    } | Out-Null
  }
  Wait-ServiceState $Name '' $false | Out-Null
  if ($Name -eq 'server') {
    $dataPath = Join-Path $env:LOCALAPPDATA 'DailyAssistant\server\daily-assistant-server.sqlite'
    if (Test-Path -LiteralPath $dataPath) {
      $backupDirectory = Join-Path $env:LOCALAPPDATA 'DailyAssistant\server\backups'
      New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
      $backupPath = Join-Path $backupDirectory "pre-update-$NextTag.sqlite"
      Copy-Item -LiteralPath $dataPath -Destination $backupPath -Force
    }
  }
  return $backupPath
}

function Get-ServerSettings {
  if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable' }
  $dataDirectory = Join-Path $env:LOCALAPPDATA 'DailyAssistant\server'
  $settingsPath = Join-Path $dataDirectory 'launcher-settings.json'
  $settings = Read-JsonFile $settingsPath
  if ($settings -and $settings.controlToken -and $settings.setupCode) { return $settings }
  New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
  $bytes = New-Object byte[] 32
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $controlToken = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
  $setupBytes = New-Object byte[] 5
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($setupBytes)
  $setupCode = ([BitConverter]::ToString($setupBytes)).Replace('-', '')
  $settings = [pscustomobject]@{ controlToken = $controlToken; setupCode = $setupCode }
  Write-JsonAtomic $settingsPath $settings
  return $settings
}

function Start-PortableProcess([string]$Name, [string]$Root, $Manifest) {
  $paths = Get-ComponentPaths $Name
  New-Item -ItemType Directory -Path $paths.Logs -Force | Out-Null
  Get-ChildItem -LiteralPath $paths.Logs -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 20 |
    Remove-Item -Force -ErrorAction SilentlyContinue

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $stdout = Join-Path $paths.Logs "$stamp-$($Manifest.version)-stdout.log"
  $stderr = Join-Path $paths.Logs "$stamp-$($Manifest.version)-stderr.log"
  $node = Join-Path $Root 'runtime\node.exe'
  $entryName = if ($Name -eq 'client') { 'daemon' } else { 'server' }
  $entry = Join-Path $Root ([string]$Manifest.entrypoints.$entryName)
  $variables = @{}

  if ($Name -eq 'client') {
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable' }
    $origin = "http://127.0.0.1:$($script:ClientPort)"
    $variables = @{
      DAILY_ASSISTANT_DAEMON_APP_ROOT = (Join-Path $env:LOCALAPPDATA 'DailyAssistant')
      DAILY_ASSISTANT_DAEMON_HOST = '127.0.0.1'
      DAILY_ASSISTANT_DAEMON_PORT = [string]$script:ClientPort
      DAILY_ASSISTANT_DAEMON_WEB_DIR = (Join-Path $Root ([string]$Manifest.entrypoints.web))
      DAILY_ASSISTANT_DAEMON_WEB_ORIGIN = $origin
      DAILY_ASSISTANT_DAEMON_CORS_ORIGINS = $origin
      DAILY_ASSISTANT_MCP_ENTRY = (Join-Path $Root ([string]$Manifest.entrypoints.mcp))
      DAILY_ASSISTANT_RELEASE_VERSION = [string]$Manifest.version
    }
  } else {
    $settings = Get-ServerSettings
    $variables = @{
      DAILY_ASSISTANT_SERVER_HOST = '0.0.0.0'
      DAILY_ASSISTANT_SERVER_PORT = [string]$script:ServerPort
      DAILY_ASSISTANT_SERVER_DATA_DIR = (Join-Path $env:LOCALAPPDATA 'DailyAssistant\server')
      DAILY_ASSISTANT_SERVER_CORS_ORIGINS = 'http://127.0.0.1:5722'
      DAILY_ASSISTANT_SERVER_SETUP_CODE = [string]$settings.setupCode
      DAILY_ASSISTANT_SERVER_CONTROL_TOKEN = [string]$settings.controlToken
      DAILY_ASSISTANT_RELEASE_VERSION = [string]$Manifest.version
    }
  }

  $previous = @{}
  try {
    foreach ($name in $variables.Keys) {
      $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
      [Environment]::SetEnvironmentVariable($name, [string]$variables[$name], 'Process')
    }
    $process = Start-Process -FilePath $node -ArgumentList @("`"$entry`"") -WorkingDirectory $Root `
      -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
  } finally {
    foreach ($name in $variables.Keys) {
      [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
    }
  }
  return @{ Process = $process; Stdout = $stdout; Stderr = $stderr }
}

function Assert-ClientWeb([string]$Version) {
  $origin = "http://127.0.0.1:$($script:ClientPort)"
  $response = Invoke-WebRequest -UseBasicParsing -Uri "$origin/" -TimeoutSec 5
  if (-not $response.Content.Contains('<title>Daily Assistant</title>')) {
    throw 'The updated daemon did not serve the Daily Assistant web UI'
  }
  $capability = Get-ClientCapability
  $runtime = Invoke-JsonRequest -Uri "$origin/__daily-assistant/runtime-config" -Headers @{
    Origin = $origin
    'Sec-Fetch-Site' = 'same-origin'
    'x-daily-assistant-runtime-request' = '1'
  }
  if ($runtime.capability -ne $capability) { throw 'The updated web UI is connected to the wrong local profile' }
}

function Open-ClientBrowser {
  $url = "http://127.0.0.1:$($script:ClientPort)/"
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Vivaldi\Application\vivaldi.exe'),
    (Join-Path $env:ProgramFiles 'Vivaldi\Application\vivaldi.exe'),
    (if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Vivaldi\Application\vivaldi.exe' } else { $null })
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
  if ($candidates.Count -gt 0) {
    Start-Process -FilePath $candidates[0] -ArgumentList "--app=$url"
  } else {
    Start-Process $url
  }
}

function Set-CurrentInstallation([string]$Name, [string]$Tag) {
  $paths = Get-ComponentPaths $Name
  Write-JsonAtomic $paths.State ([pscustomobject]@{ tag = $Tag; updatedAt = (Get-Date).ToUniversalTime().ToString('o') })
  $versions = Get-ChildItem -LiteralPath $paths.Versions -Directory -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending
  foreach ($old in @($versions | Select-Object -Skip 2)) {
    Remove-Item -LiteralPath $old.FullName -Recurse -Force
  }
}

function Start-AndValidate([string]$Name, [string]$Root, $Manifest) {
  $started = Start-PortableProcess $Name $Root $Manifest
  try {
    Wait-ServiceState $Name ([string]$Manifest.version) $true | Out-Null
    if ($Name -eq 'client') { Assert-ClientWeb ([string]$Manifest.version) }
    return $started
  } catch {
    if ($started.Process -and -not $started.Process.HasExited) { Stop-Process -Id $started.Process.Id -Force -ErrorAction SilentlyContinue }
    throw "$($_.Exception.Message). Logs: $($started.Stdout), $($started.Stderr)"
  }
}

function Resolve-LatestRelease {
  $repository = Get-ReleaseRepository
  $token = Get-GitHubCredential
  $release = Get-LatestRelease $repository $token
  $manifestAsset = Get-ReleaseAsset $release 'release-manifest.json'
  $manifestTemp = Join-Path $script:RuntimeRoot ("manifest-" + [Guid]::NewGuid().ToString('N') + '.json')
  try {
    Save-ReleaseAsset $manifestAsset $token $manifestTemp
    $releaseManifest = Read-JsonFile $manifestTemp
  } finally {
    if (Test-Path -LiteralPath $manifestTemp) { Remove-Item -LiteralPath $manifestTemp -Force }
  }
  if (
    -not $releaseManifest -or
    $releaseManifest.schemaVersion -ne 1 -or
    $releaseManifest.product -ne 'daily-assistant' -or
    $releaseManifest.tag -ne $release.tag_name -or
    "v$($releaseManifest.version)" -ne $release.tag_name
  ) {
    throw 'release-manifest.json does not match the selected GitHub release'
  }
  return @{ Release = $release; Manifest = $releaseManifest; Token = $token }
}

function Invoke-LauncherMain {
  New-Item -ItemType Directory -Path $script:RuntimeRoot -Force | Out-Null
  if (Update-LauncherRepository) {
    Write-Info 'Launcher was updated; restarting it once.'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Component $Component -SkipSelfUpdate -ApiBaseUrl $ApiBaseUrl
    return $LASTEXITCODE
  }

  $current = Get-CurrentInstallation $Component
  $release = $null
  $releaseManifest = $null
  $token = $null
  try {
    $latest = Resolve-LatestRelease
    $release = $latest.Release
    $releaseManifest = $latest.Manifest
    $token = $latest.Token
  } catch {
    if (-not $current) { throw "No installed release is available and update check failed: $($_.Exception.Message)" }
    Write-WarningMessage "Update check failed; starting installed $($current.Tag): $($_.Exception.Message)"
  }

  $target = $current
  if ($release -and (-not $current -or $current.Tag -ne $release.tag_name)) {
    $root = Install-ReleaseAsset $release $releaseManifest $Component $token
    $target = @{ Tag = [string]$release.tag_name; Root = $root; Manifest = (Read-JsonFile (Join-Path $root 'build-manifest.json')) }
  }
  if (-not $target) { throw "No $Component release is installed" }

  $health = Get-ServiceHealth $Component
  $expectedService = if ($Component -eq 'client') { 'daily-assistant-daemon' } else { 'daily-assistant-sync-server' }
  if ($health -and $health.ok -eq $true -and $health.service -eq $expectedService -and $health.version -eq $target.Manifest.version) {
    Set-CurrentInstallation $Component $target.Tag
    if ($Component -eq 'client') { Open-ClientBrowser }
    else {
      $settings = Get-ServerSettings
      Write-Info "Sync-server $($target.Tag) is already running on port $($script:ServerPort)."
      Write-Info "Owner setup code: $($settings.setupCode)"
    }
    return 0
  }

  $backupPath = Stop-RunningComponent $Component $target.Tag
  try {
    Start-AndValidate $Component $target.Root $target.Manifest | Out-Null
    Set-CurrentInstallation $Component $target.Tag
  } catch {
    if ($current -and $current.Tag -ne $target.Tag) {
      Write-WarningMessage "Update to $($target.Tag) failed; restarting $($current.Tag)."
      Start-AndValidate $Component $current.Root $current.Manifest | Out-Null
    }
    $backupMessage = if ($backupPath) { " Backup: $backupPath" } else { '' }
    throw "$($_.Exception.Message)$backupMessage"
  }

  if ($Component -eq 'client') {
    Open-ClientBrowser
    Write-Info "Daily Assistant $($target.Tag) is ready at http://127.0.0.1:$($script:ClientPort)/"
  } else {
    $settings = Get-ServerSettings
    Write-Info "Sync-server $($target.Tag) is ready on port $($script:ServerPort)."
    Write-Info "Owner setup code: $($settings.setupCode)"
    Write-Info 'Allow inbound TCP 45679 in Windows Firewall only on the trusted private network.'
  }
  return 0
}

if ($MyInvocation.InvocationName -ne '.') {
  try {
    exit (Invoke-LauncherMain)
  } catch {
    Write-Error $_.Exception.Message
    exit 1
  }
}
