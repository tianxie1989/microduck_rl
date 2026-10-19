# Windows 训练启动脚本(仓库可移植版)
# 用法(普通 PowerShell 窗口):
#   .\windows\run-train.ps1                                    # 冒烟测试(64 env x 5 iters)
#   .\windows\run-train.ps1 -Task Mjlab-Velocity-Flat-MicroDuck -Envs 2048 -Iters 3000
#   .\windows\run-train.ps1 -Task Mjlab-VelStand-Rough-Backlash-MicroDuck -Envs 1024 -Iters 10000
param(
    [string]$Task = "Mjlab-Velocity-Flat-MicroDuck",
    [int]$Envs = 64,
    [int]$Iters = 5
)

$Root  = Split-Path -Parent $PSScriptRoot          # 仓库根
$Cache = Join-Path $Root ".windows-cache"
New-Item -ItemType Directory -Force -Path $Cache | Out-Null

# --- 环境变量(Windows 移植必备,详见 windows/WINDOWS_PORT.md §5) ---
$env:WANDB_MODE      = "offline"
$env:WARP_CACHE_PATH = Join-Path $Cache "warp"
$env:MPLCONFIGDIR    = Join-Path $Cache "matplotlib"
$env:TMP             = Join-Path $Cache "tmp"
$env:TEMP            = Join-Path $Cache "tmp"
$env:PATH            = (Join-Path $Root ".venv\Scripts") + ";" + $env:PATH

Set-Location $Root
& (Join-Path $Root ".venv\Scripts\train.exe") $Task --env.scene.num-envs $Envs --agent.max_iterations $Iters
exit $LASTEXITCODE
