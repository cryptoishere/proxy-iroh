
# ==========================================
# proxy-iroh v0.7.1 Windows Setup
# User: C:\Users\user
# ==========================================

$ErrorActionPreference = "Stop"

# Configuration
$Dir = "C:\Users\user\Desktop\socks"
$Version = "v0.7.1"

$ZipName = "server-v0.7.1-x86_64-windows-msvc.zip"
$ZipUrl = "https://github.com/cryptoishere/proxy-iroh/releases/download/$Version/$ZipName"

$ExpectedSHA256 = "fb8d701159657f0d5257578ab7d4c077e1f7c19ee160f7bbd5cdd4475ee7ce8b"

# Create directory
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Set-Location $Dir

Write-Host "Downloading server..." -ForegroundColor Cyan

# Download ZIP
Invoke-WebRequest -Uri $ZipUrl -OutFile "$Dir\$ZipName"

# Verify SHA256
$ActualSHA256 = (Get-FileHash "$Dir\$ZipName" -Algorithm SHA256).Hash.ToLower()

if ($ActualSHA256 -ne $ExpectedSHA256) {
    throw "SHA256 verification FAILED! Download may be corrupted."
}

Write-Host "SHA256 verified successfully." -ForegroundColor Green

# Extract ZIP
$ExtractDir = "$Dir\extracted"

Expand-Archive -Path "$Dir\$ZipName" -DestinationPath $ExtractDir -Force

# Locate server.exe
$ServerExe = Get-ChildItem -Path $ExtractDir -Filter "server.exe" -Recurse |
    Select-Object -First 1

if (-not $ServerExe) {
    throw "server.exe was not found in the ZIP archive."
}

# Install executable
Copy-Item -Path $ServerExe.FullName -Destination "$Dir\server.exe" -Force

Write-Host "Server installed at $Dir\server.exe" -ForegroundColor Green

# Cleanup extracted files
Remove-Item $ExtractDir -Recurse -Force

Write-Host "Installation complete!" -ForegroundColor Green
