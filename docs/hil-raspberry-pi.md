# microduck HIL(硬件在环)实战手册 — 树莓派 × MuJoCo 仿真

> 适用环境:Windows 训练机 + 树莓派 5(64 位 Raspberry Pi OS)+ Xbox 手柄。
> 目标:让**真实的 `robotd` 主控程序跑在树莓派上**,通过 TCP 驱动 PC 上 MuJoCo 里的仿真鸭子,
> 手柄直连树莓派——与真机部署完全同构的 HIL(硬件在环)测试。

## 0. 架构总览

```
┌────────── PC(训练机, Windows)────────────┐        ┌────────────── 树莓派 5 ──────────────┐
│ body_server.py(MuJoCo 身体孪生)           │◄─TCP──►│ robotd 0.17.8(--sim 模式, 50Hz 控制环) │
│   · BAM 执行器拟合、接触、IMU/ToF 仿真      │  7801  │  · ONNX 策略推理(velstand.onnx)      │
│   · NDJSON 协议 v1,每只鸭一个端口          │ NDJSON │  · 安全、摔倒检测、里程计              │
│ 启动:双击 duck-body.bat                   │        │ padd ← Xbox 手柄(USB /dev/input)      │
└──────────────────────────────────────────┘        │ netpadd(UDP 4210,PC 手柄备选)        │
                                                    │ 启动:~/run-sim.sh                     │
                                                    └──────────────────────────────────────┘
```

协议要点(见 `proj/src/mjlab_microduck/sim/body_server.py`):新行分隔 JSON、`protocol=1` 握手;
操作码 `hello / read / write / gain / torque / slow / tof`。`read` 响应里带 `trunk_z`——
**判断"鸭子到底站起来没有"的唯一可靠指标**(0.07=坐,0.115~0.125=站)。

## 1. PC 端:仿真身体

- 启动器:`duck-body.bat`(工作区根目录),双击即起,内容:
  - 设置 `HOME/TMP/TEMP/MPLCONFIGDIR` 到工作区可写目录(沙盒/无用户目录权限时必须);
  - `.venv\Scripts\python.exe -m mjlab_microduck.sim.body_server --host 0.0.0.0 --port 7801`。
- **防火墙(最容易踩的坑)**:`duck-firewall.bat` 以管理员运行,添加入站规则:
  `New-NetFirewallRule -DisplayName "duck-body HIL" -Direction Inbound -Protocol TCP
   -LocalPort 7801-7910 -Action Allow -Profile Any`
  - **`-Profile Any` 是重点**:家庭路由器下 Windows 常把 Wi-Fi 归为"公用网络",
    只放行 `Private` 的规则完全不生效,Pi 会一直连不上。
  - 端口:7801 起每只鸭 +1;头部相机帧 7901 起(默认不开)。
- **只能开一个 body_server 实例!** 多个实例(残留进程)会抢 CPU/GPU,导致服务响应
  超过 daemon 的读超时 → 树莓派"连接风暴" → init 永远完不成、鸭子冻结。
  检查/清理:`Get-CimInstance Win32_Process -Filter "Name='python.exe'" | where CommandLine -match body_server`
  → `Stop-Process -Id <孤儿PID>`。
- 注意:鸭子出生在 **SIT 姿势且"断电"**——和真机一样,需要上电流程(见 §4)。

## 2. 树莓派端:一次性部署(照抄可省两小时)

### 2.1 系统与工具链

- 64 位 Raspberry Pi OS(Debian 12/13),无需特殊内核;Pi 5 是"杀鸡用牛刀"
  (真机微鸭的机载电脑只是 Pi Zero 2 W)。
- 依赖:`sudo apt-get install -y pkg-config libudev-dev libasound2-dev libssl-dev git curl`。
- Rust(国内镜像,快 10 倍):
  ```bash
  export RUSTUP_DIST_SERVER=https://rsproxy.cn RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
  cat > ~/.cargo/config.toml <<'EOF'
  [source.crates-io]
  replace-with = "rsproxy-sparse"
  [source.rsproxy-sparse]
  registry = "sparse+https://rsproxy.cn/index/"
  EOF
  ```

### 2.2 编译安装(main 分支自带 `--sim`)

```bash
git clone --depth 1 https://github.com/pollen-robotics/microduck.git ~/microduck
cd ~/microduck && . "$HOME/.cargo/env"
cargo build --release -p robotd -p robotctl -p netpadd -p padd   # Pi5 约 4~10 分钟
sudo cp target/release/{robotd,robotctl,netpadd,padd} /usr/local/bin/
```

### 2.3 ONNX Runtime(robotd dlopen 加载,必需)

```bash
cd /tmp
curl -fsSL -o ort.tgz https://github.com/microsoft/onnxruntime/releases/download/v1.28.0/onnxruntime-linux-aarch64-1.28.0.tgz
tar -xzf ort.tgz
f=$(find /tmp/onnxruntime-linux-aarch64-1.28.0 -name 'libonnxruntime.so*' -type f | head -1)
sudo install -m 0644 "$f" /usr/local/lib/$(basename "$f")
sudo ln -sfn $(basename "$f") /usr/local/lib/libonnxruntime.so && sudo ldconfig
```

### 2.4 官方策略集 v8(机器人从 `/opt/robot/policies/current` 读策略)

HuggingFace 直连国内不通,用 **hf-mirror**;注意其懒缓存:**首次请求可能 404,重试即好**。
脚本 `seed-policies.sh` 内置 8 秒超时容易失败,直接手动播种更稳:

```bash
sudo mkdir -p /opt/robot && sudo chown -R zs:zs /opt/robot
DEST=/opt/robot/policies/releases/seed-v8 && mkdir -p $DEST && cd $DEST
BASE=https://hf-mirror.com/pollen-robotics/microduck-policies/resolve/v8
for f in $(curl -sL $BASE/manifest.json | grep -o '"file": "[^"]*"' | cut -d'"' -f4); do
  for t in 1 2 3 4 5; do curl -sL --max-time 30 -o "$f" "$BASE/$f" && break; sleep 2; done
done
cp /tmp/m.json manifest.json 2>/dev/null || curl -sL -o manifest.json $BASE/manifest.json
printf 'repo=pollen-robotics/microduck-policies\nversion=v8\nfetched=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > .source
sudo ln -sfn $DEST /opt/robot/policies/current
```

### 2.5 参数文件与 LAN 手柄(netpadd 可选)

```bash
sudo mkdir -p /etc/robot
sudo cp ~/microduck/deploy/robotd.toml /etc/robot/robotd.toml
# 若要用 PC 端 duckctl udp-pad,追加:
#   [netpad]
#   enabled = true
#   port = 4210
```

### 2.6 ⚠️ 关键补丁:读超时 30ms → 100ms(Wi-Fi 抖动)

daemon 把 TCP 当串口用,`duck-control/src/bus.rs` 的 `READ_TIMEOUT = 30ms` 是真机串口的值。
Wi-Fi 抖动(本机实测 avg 52ms / max 272ms)会打爆它 → 事务失败 → 断连风暴 → 摔倒爬不起。
```bash
sed -i 's/const READ_TIMEOUT: Duration = Duration::from_millis(30);/const READ_TIMEOUT: Duration = Duration::from_millis(100);/' ~/microduck/duck-control/src/bus.rs
cargo build --release -p robotd && sudo cp target/release/robotd /usr/local/bin/   # 先 pkill robotd 再 cp,否则 Text file busy
```

## 3. Xbox 手柄连接方式

**推荐:USB 线直插树莓派**(最稳,链路最短,与真机架构一致):

- 手柄 → Pi 的 `padd` 守护进程(gilrs 在 Linux 走 **evdev**,`/dev/input/eventX` 即插即用,
  不需要任何配对)。
- 验证:`lsusb | grep -i 045e` 应见 `Xbox Controller`;`grep -B2 -A4 -i xbox /proc/bus/input/devices`。
- padd 日志出现 `Gamepad /dev/input/event6 (...) connected.` + `pad connected — driving` 即成功。

**不推荐:手柄连 PC 走 duckctl udp-pad**(Windows 上的坑,记录备查):

- duckctl 的 gilrs 默认后端是 **Windows.Gaming.Input(WGI)**;Xbox 手柄经**蓝牙 BLE**
  连接时只对 **XInput** 可见,WGI 枚举不到 → "press a button" 永远没反应。
  实测 XInput 直测(slot 0 在线)与 WGI 枚举(空)对比可确诊。
- 手柄改插 USB 线后 WGI 才可见(系统里出现 `Xbox Controller`/`XINPUT compatible HID device`);
  且 duckctl 启动时枚举手柄,**换连接方式后要重启 duckctl**。
- duckctl 会在系统临时目录建 `duckctl-udp-pad` 登记手柄归属,用户目录权限异常时报
  `cannot share pads ... 拒绝访问`,在 bat 里把 `TMP/TEMP` 重定向到可写目录即可。

**按键映射(padd 官方绑定)**:左摇杆 前进/后退/横移;右摇杆左右 原地转向;
A 坐/立切换;B 低头捡物;扳机 嘴巴;十字键 头/身体姿态;**Start 站起+切换策略**,
Start 长按 1.5s 回 home;Select 长按 2-4s 休息、4s+ 断电。

## 4. 日常启动 + 鸭子重启上电(重点)

### 启动顺序

1. PC:双击 `duck-body.bat`(只开一个窗口,黑色控制台别关);
2. Pi:`ssh zs@<pi-ip>` → `~/run-sim.sh`(自动重启 robotd+padd+netpadd 三件套);
3. 上电(见下)。

`~/run-sim.sh`(Pi 上):
```sh
#!/bin/sh
PC="${1:-192.168.31.188:7801}"
sudo pkill -f "robotd --sim" 2>/dev/null; sudo pkill -f "^padd" 2>/dev/null; sudo pkill -f "^netpadd" 2>/dev/null
sleep 2
sudo sh -c "nohup robotd --sim $PC > /tmp/robotd.log 2>&1 &"
sleep 3
sudo sh -c "nohup padd > /tmp/padd.log 2>&1 &"
sudo sh -c "nohup netpadd > /tmp/netpadd.log 2>&1 &"
```

### 上电三步曲(踩坑核心,照做)

```bash
sudo robotctl robot relax --yes    # 状态机回 Limp(鸭子会瘫倒,正常)
sudo robotctl robot enable         # 触发真正的 torque-on + 策略接管
sudo robotctl robot do sit_toggle  # 坐→站;或直接按手柄 Start
```

**为什么不能只 `init`?**
- `torque on` 只在 daemon 状态机 **Limp→上电** 这一次转换里发送;body_server 重启后
  daemon 重连成功但**不会重发 torque-on**(它以为扭矩还开着),仿真鸭子永远冻结在 SIT 出生点。
- 此时 daemon 内部姿态记忆是"seated",`robotctl robot init` 会走
  "the robot is sitting — holding the seat, not re-homing" 分支,是个空操作。
- 所以必须先 `relax --yes`(回到 Limp),再 `enable`(Limp 分支才发 torque-on)。
- 手柄 Start 键就是官方的"站起+启用"快捷键,普通场景按它即可。

## 5. 故障排查速查表

| 症状 | 原因 | 处置 |
|---|---|---|
| 鸭子坐着不动,health 却 healthy/driving | torque-on 未重发(见 §4) | relax --yes → enable → sit_toggle / Start |
| Pi 日志疯狂 connect/disconnect | ① PC 开了多个 body_server;② 防火墙规则没含 Public 配置文件;③ Wi-Fi 抖动 >100ms(未打 §2.6 补丁) | 杀多余 python;`duck-firewall.bat`(-Profile Any);打超时补丁;`ping <pc>` 看抖动 |
| health 显示 `unhealthy: N consecutive bus read failures` | PC 端 body_server 没开/已崩 | 重启 duck-body.bat → 走 §4 上电三步曲 |
| 手柄无反应 | padd 死了(robotd 重启会断它管道) | `sudo pkill -f "^padd" && sudo sh -c "nohup padd > /tmp/padd.log 2>&1 &"`,看日志确认 pad connected |
| "the policy is not driving — press Start on the pad" | 策略被手柄切到禁用 | 按手柄 Start,或 `robotctl robot enable` |
| duckctl udp-pad 报 `cannot share pads ... 拒绝访问` | 用户临时目录权限 | bat 里重定向 TMP/TEMP 到可写目录 |

**探针验证**(PC 上,只读、不影响 daemon):
```python
# .tmp/body_probe.py:向 127.0.0.1:7801 发 {"op":"hello","protocol":1} 再 {"op":"read"}
# 看 trunk_z:0.07=坐 / 0.115~0.125=站;positions 冻结不动=还没被 torque-on 释放
```

## 6. 常用命令速查(均在 Pi 上)

```bash
sudo robotctl health               # 整机状态(loop 50Hz / bus ok / 电压温度)
sudo robotctl policy list          # 策略槽位(walk=velstand.onnx 等)
sudo robotctl robot do roulade     # 前滚翻
sudo robotctl robot do kick_left   # 左脚踢球
sudo robotctl monitor              # 实时监视(按 t 看 ToF)
sudo robotctl robot relax --yes    # 断电瘫倒
~/run-sim.sh                       # 重启 HIL 三件套
```

## 7. 与真机的区别(本 HIL 测不到什么)

- 不测:真实舵机电气(压降/总线延迟/堵转)、IMU 硬件噪声谱、机载传感器硬件。
- 保真:执行器用对真实 XL330 拟合的 BAM 模型、50Hz 步长、IMU 重力投影与真机
  SFLP 滤波同款算术、摔倒检测/里程计/IPC 全是真机代码。
- 扩展:body_server 支持 `--ducks N`(多鸭共处一室)、`--scene`(可换 2x 鸭子等模型,
  但需对应训练策略)、`--keyframe HOME|STAND|SIT|FOLD`、`--limp`(模拟瘫鸭坐姿启动)。
