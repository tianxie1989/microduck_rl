# microduck_rl 在 Windows 上的完整移植记录

> 将原本面向 Linux(GPU 服务器 / HF Jobs)的 microduck_rl + mjlab 训练栈,
> 完整跑通在 **Windows 11 25H2 + NVIDIA RTX 4060 8GB** 的消费级机器上:
> 环境搭建 → 依赖钉版 → 训练(velocity 5300 迭代、velstand 10000 迭代)→
> ONNX 导出 → 官方模型回放 → 键盘 / Xbox 手柄实时操控。
> 本目录 `windows/` 是移植的全部增量文件;其余代码为上游原样(仅 3 个文件有本地修改,见 §4)。

---

## 1. 结论摘要

| 事项 | 结果 |
|---|---|
| mjlab 1.3.0(MuJoCo Warp + rsl_rl PPO)在 Windows 原生运行 | ✅ 完全跑通 |
| GPU 训练 | ✅ RTX 4060 8GB,~26,000 步/秒(velocity 2048 envs) |
| 自训走路模型 | `windows/models/ours-5598.onnx`(0.3 m/s 命令 → 实际 0.12 m/s,超过官方 velstand 的 0.085) |
| 自训 velstand 模型(官方同款配方) | `windows/models/ours-velstand.onnx`(摔倒自恢复 100%,平均 2.2s,与官方 2.3s 持平) |
| 可视化 | 原生 MuJoCo 窗口 + viser 网页(http://localhost:8080)+ 键盘/手柄操控 |

---

## 2. 安装了哪些软件(完整清单)

### 2.1 工具链

| 软件 | 版本 | 来源 / 说明 |
|---|---|---|
| **uv**(Python 包管理器) | 0.13.1 | GitHub 官方发布包 `uv-x86_64-pc-windows-msvc.zip`,解压到任意目录(本机 `tools\uv\`),无安装器 |
| **CPython** | 3.12.15 | 由 uv 自动下载管理(`uv sync --python 3.12`;项目要求 `>=3.12,<3.13`,系统自带 3.13/3.14 不符合) |
| **Git** | 系统自带 | 用于 uv 拉取 BAM 的 git 依赖 |

> 不需要安装 CUDA Toolkit!warp-lang 自带 CUDA 12.9 运行时,GPU 驱动 ≥ 580 即可(本机 610.88)。

### 2.2 Python 依赖(135 包,重点钉版)

上游 `uv.lock` 是为 Linux 生成的,在 Windows 上必须**手工钉版**以下四个,否则装出来是坏的:

| 包 | Linux lock 版本 | **Windows 必须改用** | 原因 |
|---|---|---|---|
| torch | 2.9.1 | **2.9.0+cu129** | PyPI 的 Windows torch 2.9.1 是 **CPU 版**;且 download.pytorch.org 的 cu129 索引里 2.9.1 **没有 Windows 轮子**(只有 manylinux)。2.9.0+cu129 是 Windows 最新的 CUDA 构建 |
| mujoco | (新解析会漂到 3.16) | **3.10.0** | 上游 lock 钉的就是 3.10.0;新版本 API 与 mjlab 1.3.0 不兼容 |
| wandb | (新解析会漂到 0.31) | **0.24.0**(已 yanked,但正是上游钉的) | rsl_rl 5.0.1 向 wandb 传 `start_method="thread"`,0.31 已删除该字段 → 直接崩溃 |
| better-actuator-models(BAM) | git `62bd8ce` | **保持 62bd8ce** | `mjlab_frictionloss` 分支头(57d13ead)改了执行器参数名(`vin_drop_gain_range` 不存在)→ 任务注册失败 |

CUDA torch 的下载与校验:

```powershell
# 上海交大镜像(官方源在境内很慢);SHA256 与官方索引一致:
# https://mirror.sjtu.edu.cn/pytorch-wheels/cu129/torch-2.9.0%2Bcu129-cp312-cp312-win_amd64.whl
# SHA256 = 890c0d395c529f8161b4e6423e5b2f758984721705cc6895aa3c3852da424d87
uv pip install "C:\...\torch-2.9.0+cu129-cp312-cp312-win_amd64.whl" --python .venv\Scripts\python.exe --reinstall
```

> ⚠️ **绝对不要再跑 `uv sync`**:它会按 uv.lock 把 torch 退回 CPU 版、mujoco/wandb/BAM 全部冲掉。
> 日常运行永远直接用 `.venv` 里的可执行文件(见 §5)。

### 2.3 网络与镜像(境内直连 GitHub/PyPI 不稳定)

| 目标 | 方案 |
|---|---|
| PyPI 依赖 | `UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple`(清华 TUNA) |
| GitHub git 仓库(BAM) | git URL 重写:`git config url."https://ghfast.top/https://github.com/".insteadOf "https://github.com/"` |
| Hugging Face | `hf-mirror.com`(`https://hf-mirror.com/<repo>/resolve/main/<file>`) |
| CUDA torch 大轮子 | `mirror.sjtu.edu.cn/pytorch-wheels/cu129/` |
| wandb | 本机无账号 → 训练全部 `WANDB_MODE=offline`;官方教师检查点改用 ONNX 反解(§4.2) |

---

## 3. Linux → Windows 的逐步映射

| 上游(Linux)做法 | Windows 等价做法 |
|---|---|
| `uv run train <TASK> --env.scene.num-envs 4096` | `.venv\Scripts\train.exe <TASK> --env.scene.num-envs 2048`(8GB 显存上限;**不要用 `uv run`**) |
| 系统可写 `~/.cache`、`/tmp` | 全部重定向到工作区:`WARP_CACHE_PATH`、`TMP/TEMP`、`MPLCONFIGDIR`、`HOME`(§5) |
| GPU 4096 envs(A100 级) | velocity 最多 2048;velstand(全碰撞+回差+粗糙地形)最多 **1024**,2048 会 OOM(差 668MB) |
| `uv run play` + wandb 检查点 | 本地检查点:`play <TASK> --checkpoint-file <model_N.pt>`;ONNX 走 `scripts/infer_policy.py` |
| `uv run scripts/export.py` + wandb | `python scripts\export.py <TASK> --checkpoint-file <pt> --onnx-file <out.onnx>` |
| 终端键盘控制(termios/cbreak) | **msvcrt 键盘读取 + MuJoCo viewer key_callback**(§4.1);另加 XInput Xbox 手柄 |
| 批量训练脚本(.sh) | `windows\run-train.ps1`(PowerShell,已封装全部环境变量) |
| 桌面回放 | 双击 `windows\play-duck.bat`(自带自训模型) |

---

## 4. 修改了哪些文件(逐文件清单)

### 4.1 `scripts/infer_policy.py` — 5 处 Windows 兼容补丁

| 补丁 | 位置 | 说明 |
|---|---|---|
| ① termios/tty 条件导入 | 文件头部 | `try: import termios, tty / except ImportError: termios=None`(Windows 无此模块) |
| ② `TerminalInput` 的 Windows 键盘 | `_read1()` | `sys.platform=="win32"` 时用 `msvcrt.kbhit()/getwch()` 轮询;方向键扩展码 `\x00/\xe0 + H/P/M/K` 映射为 up/down/right/left;`enabled = isatty() and (msvcrt or termios)` |
| ③ MuJoCo viewer 按键注入 | `viewer_key_cb()` + `launch_passive(..., key_callback=...)` | **关键修复**:原设计只从终端读键,但用户会点 3D 窗口打字 → 键被 viewer 吞掉变视图切换。GLFW 键码(↑265 ↓264 ←263 →262 空格32 字母65-90)映射成命令名,入队由主循环消费 |
| ④ `--auto-push-interval N` | argparse + 主循环 | 无终端时自动每 N 秒推搡一次,用于批量测摔倒恢复 |
| ⑤ `XboxController`(XInput) | 新增类 | ctypes 直调 `xinput1_4.dll`(零依赖):左摇杆=前进/横移、右摇杆X=转向、A推/B坐立/X滚翻/Y停/BACK退出/START暂停;50Hz 轮询线程,按键边沿入队;摇杆活动 5s 窗口内写命令,不抢键盘 |

### 4.2 `scripts/onnx_to_checkpoint.py` — 新增

wandb API 不可用时,把**官方发布的 ONNX 反解回 rsl_rl 教师检查点**(用于 velstand 的 BC 蒸馏):

- ONNX 是 `actor(normalizer(obs))` 的确定性图,其初始化器恰为 `actor_state_dict` 的键(obs_normalizer._mean、mlp.0/2/4/6.weight/bias + 一个除法常数=std);
- 缺失键伪造:`_var = std²`、`count = 1.0`、`distribution.std_param = 0.19`(推理只用均值,std 无关);
- 内置 onnxruntime 数值校验(误差 < 1e-5)。
- 用法:`python scripts\onnx_to_checkpoint.py alpha_stand.onnx stand_expert.pt --iter 9750`

### 4.3 `src/mjlab_microduck/tasks/microduck_velstand_env_cfg.py` — 2 处

1. 顶部新增常量:`STAND_EXPERT_PT`(由 §4.2 从官方 `alpha_stand.onnx` 反解)、`WALK_ANCHOR_PT`(本地走路检查点);
2. `MicroduckVelStandRlCfg.algorithm.bc_cfg` 中把 `checkpoint_path` / `anchor_checkpoint_path` 指到这两个本地文件(替代默认的 wandb 路径)。

### 4.4 `AGENTS.md` — 追加 "LOCAL MACHINE NOTES" 一节

本机环境事实(钉版清单、检查点位置、实测数据、OOM 上限、蓝牙修复),上游内容未动。

### 4.5 `windows/` 本目录 — 新增

| 文件 | 用途 |
|---|---|
| `WINDOWS_PORT.md` | 本文档 |
| `run-train.ps1` | 训练启动(含全部环境变量;`-Task/-Envs/-Iters` 参数) |
| `play-duck.bat` | 双击回放(默认自训 velstand;`play-duck.bat official` 用官方) |
| `fix-bluetooth.ps1` | Xbox 手柄蓝牙修复(管理员;重启 bthserv、清幽灵 HID、禁用故障 CSR 蓝牙棒) |
| `models/ours-5598.onnx` | 自训走路策略(velocity 2048env×5300it) |
| `models/ours-velstand.onnx` | 自训 velstand 策略(1024env×10000it,官方同款配方) |

---

## 5. 运行环境变量(训练/回放每次都要设,已封装进脚本)

```powershell
$env:WANDB_MODE      = "offline"      # 无 wandb 账号
$env:WARP_CACHE_PATH = "<ws>\.warp-cache"   # 注意是 WARP_CACHE_PATH 不是 WARP_CACHE_DIR
$env:MPLCONFIGDIR    = "<ws>\.matplotlib"
$env:TMP = $env:TEMP = "<ws>\.tmp"    # NVRTC 编译临时文件,不设报 "cannot build temporary file name"
$env:HOME            = "<ws>\git-home"      # 让 ~ 落在可写区 + git 镜像 URL 重写
$env:PATH            = ".venv\Scripts;<uv 目录>;" + $env:PATH
```

## 6. 训练实录(本机 RTX 4060 8GB)

| 参数 | 走路(Velocity) | velstand(VelStand-Rough-Backlash) |
|---|---|---|
| 任务 ID | `Mjlab-Velocity-Flat-MicroDuck` | `Mjlab-VelStand-Rough-Backlash-MicroDuck` |
| 并行环境 | 2048 | 1024(2048 OOM) |
| 迭代 | 5300(含 300 起步) | 10000(从走路策略热启动) |
| 耗时 | 2h41m | 10h53m |
| 吞吐 | ~26,000 步/秒 | ~6,200 步/秒 |
| 额外参数 | — | `MICRODUCK_WARM_START=1` + BC 双教师(§4.2/4.3) |
| 结果 | 奖励 0.1→110;摔倒 24→0.3 次/迭代 | 摔倒恢复 100%;恢复均时 2.2s(官方 2.3s) |

同条件对比(0.3 m/s 命令、无推搡、同一场景):

| 指标 | ours-velstand | 官方 velstand v8 |
|---|---|---|
| 实际前进速度 | **0.12 m/s** | 0.085 m/s |
| 直行偏航摆动 | ±0.2~0.4 rad/s | **±0.15 rad/s** |
| 1.0 m/s 推搡摔倒率 | 48% | **16%** |
| 摔倒后恢复率 | 100%(2.2s) | 100%(2.3s) |

## 7. 常见问题 FAQ

- **`Failed to allocate ... bytes on device 'cuda:0'`** → 环境数超显存,减半(见 §6 上限)。
- **`vin_drop_gain_range got an unexpected keyword argument`** → BAM 装到了分支头,钉回 git 62bd8ce。
- **`start_method ... extra_forbidden`(pydantic)** → wandb 版本漂移,钉 0.24.0。
- **`NVRTC ... cannot build temporary file name`** → 设 `TMP/TEMP` 到可写目录。
- **按键只改变视图颜色** → 点的是 3D 窗口且没打 ③ 号补丁;本仓库已修,直接点 3D 窗口按方向键即可。
- **`uv run` 后 CUDA 消失** → 被 lock 同步回退了,重装 §2.2 的 CUDA torch,以后直调 `.venv` 可执行文件。
- **bat 双击乱执行** → bat 必须 CRLF 行尾 + 纯 ASCII 注释(cmd 解析器的坑)。
