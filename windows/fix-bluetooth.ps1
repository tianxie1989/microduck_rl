# 修复 Xbox 手柄蓝牙连接(需管理员权限运行)
# 用法: 右键本文件 -> "使用 PowerShell 运行";或在管理员 PowerShell 里:
#   powershell -ExecutionPolicy Bypass -File C:\ZS\MicroDuck-RL\fix-bluetooth.ps1
$ErrorActionPreference = "Continue"

Write-Host "=== 1/4 重启蓝牙服务 ===" -ForegroundColor Cyan
Restart-Service bthserv -Force -ErrorAction SilentlyContinue
Restart-Service BTAGService -Force -ErrorAction SilentlyContinue
Write-Host "bthserv 已重启"

Write-Host "=== 2/4 卸载状态异常的手柄残留条目 ===" -ForegroundColor Cyan
$ghosts = Get-PnpDevice -Class HIDClass -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -eq "HID-compliant game controller" -and $_.Status -ne "OK" }
if ($ghosts) {
    foreach ($g in $ghosts) {
        Write-Host ("  移除: {0} ({1})" -f $g.FriendlyName, $g.Status)
        Remove-PnpDevice -InstanceId $g.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
    }
} else { Write-Host "  没有发现异常手柄条目" }

Write-Host "=== 3/4 禁用故障的外接蓝牙适配器 (CSR 4.0) ===" -ForegroundColor Cyan
$csr = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match "VID_0A12&PID_0001" }
if ($csr) {
    if ($csr.Status -ne "OK") {
        Disable-PnpDevice -InstanceId $csr.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host ("  已禁用: {0} (之前状态 {1})。建议直接把它从 USB 口拔掉" -f $csr.FriendlyName, $csr.Status)
    } else { Write-Host "  外接蓝牙棒状态正常,无需处理" }
} else { Write-Host "  未检测到外接蓝牙棒" }

Write-Host "=== 4/4 重新扫描硬件 ===" -ForegroundColor Cyan
pnputil /scan-devices

Write-Host ""
Write-Host "接下来请手动操作:" -ForegroundColor Yellow
Write-Host "  1. 设置 > 蓝牙和其他设备 > 找到 Xbox Wireless Controller > 删除设备"
Write-Host "  2. 长按手柄顶部配对键 3 秒(Logo 快速闪烁),在蓝牙列表里重新添加"
Write-Host "  3. 若仍失败: 设备管理器 > 蓝牙 > Intel Wireless Bluetooth > 更新驱动程序"
Write-Host "  4. 手柄固件更新: 微软商店安装 Xbox Accessories,USB 线连手柄后更新"

Write-Host "按任意键退出..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
