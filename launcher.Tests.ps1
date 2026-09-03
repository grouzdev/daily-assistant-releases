BeforeAll {
  . "$PSScriptRoot\launcher.ps1"

  function New-TestInstallation([string]$Root, [string]$Component, [string]$Version) {
    New-Item -ItemType Directory -Path (Join-Path $Root 'runtime') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Root 'runtime\node.exe') -Value 'node'
    $entrypoints = if ($Component -eq 'client') {
      New-Item -ItemType Directory -Path (Join-Path $Root 'app\daemon'), (Join-Path $Root 'app\mcp'), (Join-Path $Root 'web') -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $Root 'app\daemon\index.mjs') -Value 'daemon'
      Set-Content -LiteralPath (Join-Path $Root 'app\mcp\index.mjs') -Value 'mcp'
      @{ daemon = 'app/daemon/index.mjs'; mcp = 'app/mcp/index.mjs'; web = 'web' }
    } else {
      New-Item -ItemType Directory -Path (Join-Path $Root 'app\server') -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $Root 'app\server\index.mjs') -Value 'server'
      @{ server = 'app/server/index.mjs' }
    }
    $manifest = @{
      schemaVersion = 1
      product = 'daily-assistant'
      component = $Component
      version = $Version
      platform = 'win32'
      arch = 'x64'
      entrypoints = $entrypoints
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Root 'build-manifest.json')
    return Get-Content -LiteralPath (Join-Path $Root 'build-manifest.json') -Raw | ConvertFrom-Json
  }

  function New-Latest([string]$Version = '2.0.0') {
    return @{
      Release = [pscustomobject]@{ tag_name = "v$Version"; assets = @() }
      Manifest = [pscustomobject]@{
        schemaVersion = 1
        product = 'daily-assistant'
        version = $Version
        tag = "v$Version"
        assets = [pscustomobject]@{}
      }
      Token = 'credential-must-not-be-printed'
    }
  }
}

Describe 'portable archive validation' {
  BeforeEach {
    $script:RuntimeRoot = Join-Path $TestDrive 'runtime-state'
    New-Item -ItemType Directory -Path $script:RuntimeRoot -Force | Out-Null
    Mock Update-LauncherRepository { $false }
  }

  It 'accepts a valid client tree and rejects forbidden content' {
    $root = Join-Path $TestDrive 'valid-client'
    New-TestInstallation $root client '1.2.3' | Out-Null
    { Assert-PortableInstallation $root client 'v1.2.3' } | Should -Not -Throw

    New-Item -ItemType Directory -Path (Join-Path $root 'node_modules') | Out-Null
    { Assert-PortableInstallation $root client 'v1.2.3' } | Should -Throw '*Forbidden content*'
  }

  It 'rejects an asset whose SHA-256 does not match' {
    $release = [pscustomobject]@{
      tag_name = 'v1.0.0'
      assets = @([pscustomobject]@{ name = 'client.zip'; url = 'asset-url' })
    }
    $manifest = [pscustomobject]@{
      assets = [pscustomobject]@{
        client = [pscustomobject]@{ name = 'client.zip'; sha256 = ('0' * 64); platform = 'win32'; arch = 'x64' }
      }
    }
    Mock Save-ReleaseAsset { param($Asset, $Token, $Destination); Set-Content -LiteralPath $Destination -Value 'tampered' }

    { Install-ReleaseAsset $release $manifest client 'secret' } | Should -Throw '*SHA-256 mismatch*'
  }

  It 'rejects a corrupt ZIP even when its hash matches' {
    $bytes = [Text.Encoding]::UTF8.GetBytes('not-a-zip')
    $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    $release = [pscustomobject]@{
      tag_name = 'v1.0.0'
      assets = @([pscustomobject]@{ name = 'client.zip'; url = 'asset-url' })
    }
    $manifest = [pscustomobject]@{
      assets = [pscustomobject]@{
        client = [pscustomobject]@{ name = 'client.zip'; sha256 = $hash; platform = 'win32'; arch = 'x64' }
      }
    }
    Mock Save-ReleaseAsset { param($Asset, $Token, $Destination); [IO.File]::WriteAllBytes($Destination, $bytes) }

    { Install-ReleaseAsset $release $manifest client 'secret' } | Should -Throw
  }
}

Describe 'launcher update behavior' {
  BeforeEach {
    $script:RuntimeRoot = Join-Path $TestDrive 'runtime-state'
    New-Item -ItemType Directory -Path $script:RuntimeRoot -Force | Out-Null
    Mock Update-LauncherRepository { $false }
  }

  It 'installs and starts the first available release' {
    $newRoot = Join-Path $TestDrive 'new-client'
    New-TestInstallation $newRoot client '2.0.0' | Out-Null
    Mock Get-CurrentInstallation { $null }
    Mock Resolve-LatestRelease { New-Latest '2.0.0' }
    Mock Install-ReleaseAsset { $newRoot }
    Mock Get-ServiceHealth { $null }
    Mock Stop-RunningComponent { $null }
    Mock Start-AndValidate {}
    Mock Set-CurrentInstallation {}
    Mock Open-ClientBrowser {}

    Invoke-LauncherMain | Should -Be 0
    Should -Invoke Start-AndValidate -Times 1 -ParameterFilter { $Root -eq $newRoot }
    Should -Invoke Set-CurrentInstallation -Times 1 -ParameterFilter { $Tag -eq 'v2.0.0' }
  }

  It 'keeps an already running current release without reinstalling it' {
    $root = Join-Path $TestDrive 'current-client'
    $manifest = New-TestInstallation $root client '2.0.0'
    Mock Get-CurrentInstallation { @{ Tag = 'v2.0.0'; Root = $root; Manifest = $manifest } }
    Mock Resolve-LatestRelease { New-Latest '2.0.0' }
    Mock Get-ServiceHealth { [pscustomobject]@{ ok = $true; service = 'daily-assistant-daemon'; version = '2.0.0' } }
    Mock Set-CurrentInstallation {}
    Mock Open-ClientBrowser {}
    Mock Install-ReleaseAsset {}
    Mock Start-AndValidate {}

    Invoke-LauncherMain | Should -Be 0
    Should -Invoke Install-ReleaseAsset -Times 0
    Should -Invoke Start-AndValidate -Times 0
  }

  It 'updates an installed release after the candidate passes validation' {
    $oldRoot = Join-Path $TestDrive 'old-client-success'
    $newRoot = Join-Path $TestDrive 'new-client-success'
    $oldManifest = New-TestInstallation $oldRoot client '1.0.0'
    New-TestInstallation $newRoot client '2.0.0' | Out-Null
    Mock Get-CurrentInstallation { @{ Tag = 'v1.0.0'; Root = $oldRoot; Manifest = $oldManifest } }
    Mock Resolve-LatestRelease { New-Latest '2.0.0' }
    Mock Install-ReleaseAsset { $newRoot }
    Mock Get-ServiceHealth { $null }
    Mock Stop-RunningComponent { 'backup.json' }
    Mock Start-AndValidate {}
    Mock Set-CurrentInstallation {}
    Mock Open-ClientBrowser {}

    Invoke-LauncherMain | Should -Be 0
    Should -Invoke Start-AndValidate -Times 1 -ParameterFilter { $Root -eq $newRoot }
    Should -Invoke Set-CurrentInstallation -Times 1 -ParameterFilter { $Tag -eq 'v2.0.0' }
  }

  It 'uses the installed release when the update check is offline' {
    $root = Join-Path $TestDrive 'installed-client'
    $manifest = New-TestInstallation $root client '1.0.0'
    Mock Get-CurrentInstallation { @{ Tag = 'v1.0.0'; Root = $root; Manifest = $manifest } }
    Mock Resolve-LatestRelease { throw 'network unavailable' }
    Mock Get-ServiceHealth { [pscustomobject]@{ ok = $true; service = 'daily-assistant-daemon'; version = '1.0.0' } }
    Mock Set-CurrentInstallation {}
    Mock Open-ClientBrowser {}

    Invoke-LauncherMain -WarningAction SilentlyContinue | Should -Be 0
    Should -Invoke Open-ClientBrowser -Times 1
  }

  It 'does not kill an unknown service occupying the client port' {
    Mock Get-ServiceHealth { $null }
    Mock Test-LocalPort { $true }
    { Stop-RunningComponent client 'v2.0.0' } | Should -Throw '*occupied by an unexpected service*'
  }

  It 'restarts the previous version when the candidate healthcheck fails' {
    $oldRoot = Join-Path $TestDrive 'old-client'
    $newRoot = Join-Path $TestDrive 'new-client'
    $oldManifest = New-TestInstallation $oldRoot client '1.0.0'
    New-TestInstallation $newRoot client '2.0.0' | Out-Null
    Mock Get-CurrentInstallation { @{ Tag = 'v1.0.0'; Root = $oldRoot; Manifest = $oldManifest } }
    Mock Resolve-LatestRelease { New-Latest '2.0.0' }
    Mock Install-ReleaseAsset { $newRoot }
    Mock Get-ServiceHealth { $null }
    Mock Stop-RunningComponent { 'backup.json' }
    Mock Start-AndValidate {
      if ($Root -eq $newRoot) { throw 'candidate healthcheck failed' }
    }
    Mock Set-CurrentInstallation {}

    { Invoke-LauncherMain } | Should -Throw '*candidate healthcheck failed*Backup: backup.json*'
    Should -Invoke Start-AndValidate -Times 1 -ParameterFilter { $Root -eq $oldRoot }
    Should -Invoke Set-CurrentInstallation -Times 0
  }
}
