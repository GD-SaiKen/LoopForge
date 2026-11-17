# Merge LoopForge default Docker Hub registry-mirrors into the active Docker Engine config.
# On Docker Desktop (Windows/macOS) this is %USERPROFILE%\.docker\daemon.json.
# On Linux it is /etc/docker/daemon.json (requires elevation).
#
# Usage:
#   .\scripts\configure-docker-registry-mirrors.ps1
#   .\scripts\configure-docker-registry-mirrors.ps1 -AliyunMirror https://xxxx.mirror.aliyuncs.com
#
# Aliyun accelerators are per-account; get yours from:
#   https://cr.console.aliyun.com/cn-hangzhou/instances/mirrors
#
# These mirrors only accelerate Docker Hub (e.g. mysql:8.4). LoopForge GHCR images
# still use MIRROR=ghcr.nju.edu.cn or LOOPFORGE_IMAGE=... — see README.zh-CN.md.
param(
    [string]$AliyunMirror = $env:LOOPFORGE_DOCKER_MIRROR_ALIYUN,
    [string]$DockerUserConfig = (Join-Path $env:USERPROFILE ".docker\daemon.json"),
    [string]$DefaultsFile = (Join-Path $PSScriptRoot "docker-registry-mirrors.defaults.json"),
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $DefaultsFile)) {
    throw "Missing defaults file: $DefaultsFile"
}

$defaults = Get-Content -Raw -Encoding UTF8 $DefaultsFile | ConvertFrom-Json
$mirrors = [System.Collections.Generic.List[string]]::new()
foreach ($m in $defaults) {
    if ($m -and $m.Trim()) { [void]$mirrors.Add($m.Trim().TrimEnd('/')) }
}
if ($AliyunMirror -and $AliyunMirror.Trim()) {
    $a = $AliyunMirror.Trim().TrimEnd('/')
    if (-not $a.StartsWith("https://") -and -not $a.StartsWith("http://")) {
        $a = "https://$a"
    }
    if ($mirrors -notcontains $a) {
        $mirrors.Insert(0, $a)
    }
}

$configDir = Split-Path -Parent $DockerUserConfig
if (-not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
}

$cfg = [ordered]@{}
if (Test-Path $DockerUserConfig) {
    $raw = Get-Content -Raw -Encoding UTF8 $DockerUserConfig
    if ($raw.Trim()) {
        $obj = $raw | ConvertFrom-Json
        foreach ($prop in $obj.PSObject.Properties) {
            if ($prop.Name -ne "registry-mirrors") {
                $cfg[$prop.Name] = $prop.Value
            }
        }
    }
}

$cfg["registry-mirrors"] = @($mirrors)

$json = $cfg | ConvertTo-Json -Depth 10
if ($WhatIf) {
    Write-Host "Would write $DockerUserConfig :"
    Write-Host $json
    exit 0
}

$backup = "$DockerUserConfig.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
if (Test-Path $DockerUserConfig) {
    Copy-Item $DockerUserConfig $backup -Force
    Write-Host "Backed up to $backup"
}

[System.IO.File]::WriteAllText($DockerUserConfig, $json + "`n", [System.Text.UTF8Encoding]::new($false))
Write-Host "Updated $DockerUserConfig with registry-mirrors:"
$mirrors | ForEach-Object { Write-Host "  $_" }
Write-Host ""
Write-Host "Restart Docker Desktop (or the Docker daemon) for mirrors to take effect."
if (Get-Command docker -ErrorAction SilentlyContinue) {
    $desktop = docker desktop version 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "On this machine you can run: docker desktop restart"
    }
}
Write-Host 'Verify: docker info -f "{{json .RegistryConfig.Mirrors}}"'