# 校园门户自动登录

## 功能与行为总结

本程序用于在电脑已经连接校园 Wi-Fi 并取得 IP 后，自动登录校园门户。

- `login.ps1` 负责向校园门户提交账号密码。
- `watch-network.ps1` 负责监控网络；网络恢复、IP 变化或会话失效时自动重新登录。
- 登录请求会绑定到校园 WLAN 的本地 IP，避免手机热点抢占默认路由后导致门户登录失败。
- 本程序不会打开无线网卡，也不会主动搜索或连接校园 Wi-Fi。
- 如果 Windows 将校园 Wi-Fi 设置为“自动连接”，断线后 Windows 重新连接成功，本程序会自动登录门户。
- 如果 Windows 没有自动重连校园 Wi-Fi，本程序不会强行连接。
- 暂时关闭自动登录使用 `Disable-ScheduledTask`；彻底关闭使用 `uninstall-autostart.ps1`。
- 如果不希望 Windows 自动重连校园 Wi-Fi，还需将该 Wi-Fi 配置改为手动连接。

快速查看运行状态：

```powershell
Get-Content "E:\codexppt\campus-auto-login\logs\network-watch.log" -Tail 10
Get-Content "E:\codexppt\campus-auto-login\logs\auto-login.log" -Tail 10
```

关闭、恢复与卸载的完整操作见文末“关闭、恢复与卸载”章节。

## 文件说明

- `config.example.json`：GitHub 中提供的配置模板，不包含真实账号。
- `config.json`：本机实际配置，包含门户地址、账号和 AC IP，已加入 `.gitignore`。
- `credential.dpapi`：使用当前 Windows 用户 DPAPI 加密的密码，仅保存在本机。
- `login.ps1`：实际登录脚本，自动读取当前 WLAN 的 IP 和 MAC。
- `watch-network.ps1`：常驻网络监控，网络恢复或 IP 变化时自动触发登录。
- `install-autostart.ps1`：注册登录自启任务。
- `uninstall-autostart.ps1`：删除登录自启任务，但不会立即结束后台监控进程。
- `logs\auto-login.log`：登录运行日志，不记录密码，已加入 `.gitignore`。
- `logs\network-watch.log`：网络监控日志，不记录密码，已加入 `.gitignore`。

## 首次安装

从 GitHub 下载项目后，先创建本机配置：

```powershell
Copy-Item ".\config.example.json" ".\config.json"
```

然后编辑 `config.json`，填写校园门户地址、账号、AC IP 和网卡名称。

注册自启动时，如果本机不存在 `credential.dpapi`，安装脚本会提示输入校园门户密码。密码只会以当前 Windows 用户可解密的形式保存在本机：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\install-autostart.ps1" -RunNow
```

不要把真实的 `config.json` 或 `credential.dpapi` 提交到 GitHub。

## 自动启动行为

计划任务在用户登录 Windows 后约 2 秒启动 `watch-network.ps1`。监控程序会：

1. 每 2 秒检查一次可用网络和 IP。
2. Wi-Fi/网线重新连接或 IP 变化时，立即触发一次登录。
3. 登录失败时每 5 秒重试。
4. 已登录时每 5 分钟复查一次，防止会话失效。
5. 网络不可用时继续等待，不会尝试打开被禁用的无线网卡。

## 手动测试登录

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "E:\codexppt\campus-auto-login\login.ps1" -Once
```

## 修改密码

```powershell
$secure = Read-Host "New portal password" -AsSecureString
$secure | ConvertFrom-SecureString | Set-Content "E:\codexppt\campus-auto-login\credential.dpapi" -Encoding ascii
```

## 注册或重新注册自启动

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "E:\codexppt\campus-auto-login\install-autostart.ps1"
```

注册后立即启动监控：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "E:\codexppt\campus-auto-login\install-autostart.ps1" -RunNow
```

## 查看日志

```powershell
Get-Content "E:\codexppt\campus-auto-login\logs\auto-login.log" -Tail 30
Get-Content "E:\codexppt\campus-auto-login\logs\network-watch.log" -Tail 30
```

## 关闭、恢复与卸载

### 暂时关闭自动登录

以管理员身份打开 PowerShell，执行：

```powershell
Stop-ScheduledTask -TaskName CampusPortalAutoLogin -ErrorAction SilentlyContinue
Disable-ScheduledTask -TaskName CampusPortalAutoLogin
```

关闭后：

- Windows 不再自动登录校园门户。
- Windows 仍可能自动连接校园 Wi-Fi。
- 重新启动 Windows 后任务也不会自动运行。

### 恢复自动登录

```powershell
Enable-ScheduledTask -TaskName CampusPortalAutoLogin
Start-ScheduledTask -TaskName CampusPortalAutoLogin
```

也可以重新注册并立即启动：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "E:\codexppt\campus-auto-login\install-autostart.ps1" -RunNow
```

### 彻底卸载自启动

以管理员身份运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "E:\codexppt\campus-auto-login\uninstall-autostart.ps1"
```

该命令会删除计划任务 `CampusPortalAutoLogin`，但不会立即结束已经运行的 `watch-network.ps1` 或 `login.ps1` 进程。

### 立即结束后台监控

如果只想立即停止当前后台脚本：

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'watch-network\.ps1|login\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

也可以直接重启电脑。重启后，只要计划任务已被删除或禁用，脚本就不会再次启动。

### 关闭校园 Wi-Fi 自动连接

将校园 Wi-Fi 配置改为手动连接：

```powershell
netsh wlan set profileparameter name="你的校园WiFi名称" connectionmode=manual
```

例如：

```powershell
netsh wlan set profileparameter name="NCWU" connectionmode=manual
```

也可以进入：

```text
设置 → 网络和 Internet → WLAN → 管理已知网络
→ 选择校园 Wi-Fi → 关闭“自动连接”
```

### 立即断开当前校园 Wi-Fi

```powershell
netsh wlan disconnect
```

如果没有关闭“自动连接”，Windows 稍后可能再次连接该 Wi-Fi。


