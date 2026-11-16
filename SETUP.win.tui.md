# SETUP.win.tui.md

# Windows Setup and TUI Server

This guide installs the server and runs it in the foreground with the TUI.  
It assumes your Windows user folder is `C:\Users\user`.

## Part 1: Setup

### 1. Save the setup script

1. Open Notepad.
2. Paste the complete `setup.ps1` installation script.
3. Click **File → Save As**.
4. Save it as:

   ```text
   C:\Users\user\Desktop\setup.ps1
   ```

5. Set **Save as type** to `All Files (*.*)`.
6. Make sure the filename is `setup.ps1`, not `setup.ps1.txt`.

### 2. Open PowerShell

Press `Win + X`, then select **Terminal** or **Windows PowerShell**.

### 3. Allow script execution

Run this command. It only affects your user account:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

If prompted, type:

```text
Y
```

### 4. Run the setup script

```powershell
cd C:\Users\user\Desktop
.\setup.ps1
```

Expected result:

```text
Downloading server...
SHA256 verified successfully.
Server installed at C:\Users\user\Desktop\socks\server.exe
Installation complete!
```

You do not need to run PowerShell as Administrator because the installation directory is inside your user folder.

## Part 2: Run server in TUI

If setup is already complete, skip to this section.

### 2.1 Multi-line command

```powershell
# Go to server directory
Set-Location "C:\Users\user\Desktop\socks"

# Set environment variables
$env:RUST_LOG = "warn"
$env:SOCKS5_SIGNATURE_AUTH = "true"
$env:SOCKS5_TUNNEL_ENCRYPTION = "on"
$env:SOCKS5_RATE_MAX = "1200"
$env:SOCKS5_QUOTA_MAX = "256"
$env:SOCKS5_ALLOWED_PORTS = "22,80,443,853"
$env:HOST_IP_CHECKERS_LIST = "https://crypto-ig.com/ip,https://api.ipify.org"

# Start server in the foreground with TUI
.\server.exe
```

### 2.2 One-line command

```powershell
cd "C:\Users\user\Desktop\socks"; $env:RUST_LOG="warn"; $env:SOCKS5_SIGNATURE_AUTH="true"; $env:SOCKS5_TUNNEL_ENCRYPTION="on"; $env:SOCKS5_RATE_MAX="1200"; $env:SOCKS5_QUOTA_MAX="256"; $env:SOCKS5_ALLOWED_PORTS="22,80,443,853"; $env:HOST_IP_CHECKERS_LIST="https://crypto-ig.com/ip,https://api.ipify.org"; .\server.exe
```

## 3. Stop server

The TUI runs in the foreground. To stop it:

1. Click the PowerShell window.
2. Press `Ctrl + C`.

The server stops when the foreground process exits.

## Notes

- Keep the PowerShell window open while the TUI server is running.
- These TUI commands do not create a `server.pid` file.
- Server logs may also be written to:

  ```text
  C:\Users\user\Desktop\socks\logs\server_app.log
  ```

To follow the log file in another PowerShell window:

```powershell
Get-Content "C:\Users\user\Desktop\socks\logs\server_app.log" -Tail 100 -Wait
```
