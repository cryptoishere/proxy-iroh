# SETUP.win.daemon.md

# Windows Setup and Service Server

This guide installs the server and registers it as a Windows Service. The service starts automatically on boot and runs without a console.
It assumes your Windows user folder is `C:\Users\user`.

## Requirements

- A Windows build of `server.exe` compiled with `--features daemonize`. The pre-built release archives ship with the feature enabled; self-built binaries must include it explicitly (`cargo build --release --features daemonize`).
- An elevated PowerShell or Command Prompt for install, uninstall, start, and stop.
- The account must be registered with the central hub **before** the service starts, or on the first run of the service. See [Part 4](#part-4-account-registration).

If the binary was built without the feature, `server install` prints:

```text
This command requires a Windows build with --features daemonize.
```

and exits without touching the system.

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

## Part 2: Register the service

Open an **elevated** PowerShell (`Win + X` → **Terminal (Admin)**).

### 2.1 Install

```powershell
Set-Location "C:\Users\user\Desktop\socks"
.\server.exe install
```

Expected output:

```text
Service `proxy-iroh` installed.
Start with: sc start proxy-iroh
```

What `install` does:

- Opens the SCM with `ServiceManagerAccess::CONNECT | CREATE_SERVICE`.
- Creates a service named `proxy-iroh`, display name `proxy-iroh SOCKS5 proxy`.
- Sets start type to `AutoStart`, error control to `Normal`, account to `LocalSystem`.
- Sets the launch command to `"<exe-path>" service` so SCM invokes the service dispatch path on start.
- Sets the description to a link to the repository.

The service reads its configuration from the environment, not from files. To set env vars for the service, use `sc`:

```powershell
sc.exe config proxy-iroh obj= "LocalSystem"
# Environment variables are inherited from the LocalSystem account's
# registry environment. Set them under
# HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment
# or, more practically, use a wrapper .bat (see Part 3).
```

### 2.2 Start

```powershell
sc.exe start proxy-iroh
```

Expected:

```text
SERVICE_NAME: proxy-iroh
        TYPE               : 10  WIN32_OWN_PROCESS
        STATE              : 4  RUNNING
                                (STOPPABLE, NOT_PAUSABLE, IGNORES_SHUTDOWN)
        WIN32_EXIT_CODE    : 0  (0x0)
        SERVICE_EXIT_CODE  : 0  (0x0)
        CHECKPOINT         : 0x0
        WAIT_HINT          : 0x0
        PID                : <pid>
        FLAGS              :
```

## Part 3: Environment variables for the service

Services launched by SCM start with the environment of the service account, not your user shell. A wrapper `.bat` is the simplest way to inject the SOCKS5 configuration without editing the registry.

### 3.1 Create the wrapper

Save the following as `C:\Users\user\Desktop\socks\service.bat`:

```bat
@echo off
set RUST_LOG=info
set SOCKS5_SIGNATURE_AUTH=true
set SOCKS5_TUNNEL_ENCRYPTION=on
set SOCKS5_RATE_MAX=1200
set SOCKS5_QUOTA_MAX=256
set SOCKS5_ALLOWED_PORTS=22,80,443,8080,8443,853
set SOCKS5_BLOCK_PRIVATE_IPS=on
set HOST_IP_CHECKERS_LIST=https://crypto-ig.com/ip,https://api.ipify.org
set RELAY_URL_PUBLIC=https://smartholdem-block.duckdns.org:3341
set ENDPOINT_BIND_ADDRESS=0.0.0.0:44444
set ENDPOINT_BIND_ADDRESS_CENTRAL_HUB=0.0.0.0:44445

"C:\Users\user\Desktop\socks\server.exe" service
```

### 3.2 Point the service at the wrapper

```powershell
# Elevated prompt required
sc.exe config proxy-iroh binPath= "C:\Users\user\Desktop\socks\service.bat"
```

`binPath=` takes the entire command line verbatim, so `service` must be present as the final argument — otherwise the binary launches in interactive mode, fails to find a console, and SCM reports a start failure.

### 3.3 Alternative: environment via the registry

If a wrapper is undesirable, set the variables in the LocalSystem environment:

```powershell
[Environment]::SetEnvironmentVariable(
    "SOCKS5_SIGNATURE_AUTH", "true", "Machine")
[Environment]::SetEnvironmentVariable(
    "SOCKS5_TUNNEL_ENCRYPTION", "on", "Machine")
# ... and so on for each variable
```

Restart the service after changing values:

```powershell
sc.exe stop proxy-iroh
sc.exe start proxy-iroh
```

The registry approach affects every process launched under the machine context, not just `proxy-iroh`. The wrapper approach limits the blast radius to the service. Prefer the wrapper.

## Part 4: Account registration

`SOCKS5_SIGNATURE_AUTH=true` requires the local account store to contain a registered proxy. Registration happens on the first run of `PeerSetup::enable` when no account exists, and requires a working connection to the central hub.

For a service-mode first run:

1. Confirm the service is **stopped**.
2. Confirm `RELAY_URL_PUBLIC`, `CENTRAL_ENDPOINT_SNI`, and `TARGET_ENDPOINT_X1_CENTRAL_HUB_13` are correct in `service.bat`.
3. Start the service. The first-run log will show `Account Setup register` followed by the hub response.
4. Confirm the account persisted:

   ```powershell
   Get-Content "C:\Windows\System32\config\systemprofile\AppData\Local\CiGPeerApp\server_app.log" -Tail 20
   ```

   Expect `SOCKS5 signature authentication enabled (address = ...)`.

If registration fails because the hub is unreachable, the server logs `central hub unreachable or internet connection problems` and exits. Fix the hub connectivity and restart. Do not repeatedly restart — the hub's rate limiter will apply.

## Part 5: Monitoring

### 5.1 Service status

```powershell
sc.exe query proxy-iroh
```

### 5.2 Logs

The service account's log path:

```powershell
Get-Content "C:\Windows\System32\config\systemprofile\AppData\Local\CiGPeerApp\server_app.log" -Tail 100 -Wait
```

If the service was reconfigured to run under a different account, replace the path with that account's `%LOCALAPPDATA%\CiGPeerApp\server_app.log`.

### 5.3 Restart on failure

By default SCM does not restart a crashed service. Configure it to:

```powershell
sc.exe failure proxy-iroh reset= 86400 actions= restart/5000/restart/10000/restart/30000
```

This tells SCM: reset the failure counter after 24 hours, restart 5 seconds after the first crash, 10 seconds after the second, 30 seconds after the third and subsequent. Any subsequent crash within 24 hours does not count toward a permanent stop.

### 5.4 Event viewer

SCM reports start, stop, and failure events to the **System** log. Filter by source `Service Control Manager` and the service name `proxy-iroh`:

```powershell
Get-WinEvent -FilterHashtable @{
    LogName='System'
    ProviderName='Service Control Manager'
} | Where-Object { $_.Message -like '*proxy-iroh*' } | Select-Object -First 20
```

## Part 6: Stop and remove

### 6.1 Stop

```powershell
sc.exe stop proxy-iroh
```

SCM sends `ServiceControl::Stop` to the handler. The server transitions to `StopPending`, drains connections for up to `SHUTDOWN_GRACE_PERIOD` (30 s), reports `Stopped`, and exits.

SCM's own stop timeout is 20 s by default. If the drain exceeds that, SCM kills the process. To raise the timeout:

```powershell
sc.exe control proxy-iroh paramchange
```

or set `SERVICE_STOP_TIMEOUT` via registry. Alternatively, reduce `SHUTDOWN_GRACE_PERIOD` in the binary if a 30 s drain is longer than the deployment requires.

### 6.2 Uninstall

```powershell
sc.exe stop proxy-iroh
Set-Location "C:\Users\user\Desktop\socks"
.\server.exe uninstall
```

Expected:

```text
Service `proxy-iroh` removed.
```

The sled database and logs are **not** removed. They live under the service account's `%LOCALAPPDATA%\CiGPeerApp`. Delete manually if the account is being fully decommissioned.

## Part 7: Troubleshooting

### `service dispatcher failed — this binary must be launched by the Service Control Manager`

The `service` subcommand was invoked from a user shell. It only works when the process is launched by SCM. Use `sc.exe start proxy-iroh` instead of `server.exe service` from a prompt.

### Service starts and stops immediately, exit code `1066` (`ERROR_SERVICE_SPECIFIC_ERROR`)

The server started but `run_server` returned an error before reaching the `Running` state. Look at `server_app.log` for the cause — usually a bad env var (`RELAY_URL_PUBLIC` malformed, `TARGET_ENDPOINT_X1_CENTRAL_HUB_13` invalid) or hub unreachability during first-run registration.

### Service starts and stops immediately, exit code `1053` (`ERROR_SERVICE_DID_NOT_RESPOND_IN_TIME`)

The service exceeded the `wait_hint` of 30 s without reporting `Running`. The cause is almost always a slow sled open — check the disk the data directory resides on. Or the `binPath=` does not end in `service`, so the binary is running in interactive mode without a console and blocking on TUI init.

Verify the binPath:

```powershell
sc.exe qc proxy-iroh
```

`BINARY_PATH_NAME` must end with ` service`.

### Service is running but no client traffic passes

The client-facing listener binds `0.0.0.0:1082` from `LISTEN_ADDR`. If the service account cannot bind (port in use, permission denied), `server_app.log` shows `SOCKS5 proxy listening on ...` missing. Check:

```powershell
netstat -ano | findstr :1082
```

If a stale process owns the port, identify and stop it before restarting the service.

### Clients connect but immediately get `closed by peer: 0`

`CONN_HARD_IDLE_SECS` is 300 s by default; anything shorter than the client's keepalive interval will close clients that are idle. Do not set `CONN_HARD_IDLE_SECS` below 60 s.

### Hub connection failed but SYSTEM clients work

Expected. `SYSTEM_TYPE` handshakes do not require hub interaction; only `CLIENT_TYPE` does. If the hub is down, SYSTEM clients continue to operate normally. Check `server_app.log` for `starting tunnel with Central Hub failed` to confirm the cause.

## Part 8: Comparison with other launch modes

| Property | Interactive | Background | Service |
|---|---|---|---|
| Survives user logoff | no | no | **yes** |
| Auto-start on boot | no | no | **yes** |
| SCM-managed restart | no | no | **yes** (with `sc failure`) |
| TUI | yes | no | no |
| Console output | yes | no | no |
| Requires admin for setup | no | no | **yes** |
| Requires `--features daemonize` | no | no | **yes** |

For a desktop deployment where the operator is present, interactive mode is simpler. For a headless host that must survive logout and reboot, service mode is the only option. Background mode is useful when a persistent process is needed without the SCM overhead — for example, a development host where the operator wants to see log output without keeping a terminal open.

## Reverting to interactive or background

The service and the interactive/background modes are mutually exclusive for a given port. If the service is installed and running, `server.exe` cannot bind port 1082.

Before switching modes:

```powershell
sc.exe stop proxy-iroh
```

Then either start interactively, start in background, or leave the service installed and stopped. Reinstall with `server.exe install` after uninstalling if the binary was replaced by a newer build.
