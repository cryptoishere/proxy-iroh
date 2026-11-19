
# ==========================================
# proxy-iroh v0.6.2 Windows Setup
# User: C:\Users\user
# ==========================================

$ErrorActionPreference = "Stop"

# Configuration
$Dir = "C:\Users\user\Desktop\socks"
$Version = "v0.6.2"

$ZipName = "server-v0.6.2-x86_64-windows-msvc.zip"
$ZipUrl = "https://github.com/cryptoishere/proxy-iroh/releases/download/$Version/$ZipName"

$ExpectedSHA256 = "7ad2b2ff324ee285ee68e957bcc8c6c823c677b5b8579d131402f273ce522019"

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
