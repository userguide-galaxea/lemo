# LEMO - 双臂采训推一体化平台

[English](README.md) | [简体中文](README_zh.md)

LEMO 将双臂遥操作、相机采集、数据录制和策略推理接入整合为一个 ROS2 Humble 工作空间，面向机器人遥操作与具身智能数据采集，并集数据采集、训练、推理等功能于一体，便于用户开展多种具身智能开发任务。

本文将运行遥操作、数据采集及 Policy 客户端的 RK3588 设备称为“LEMO平台”，将运行模型推理服务的 GPU 服务器称为“算力平台”。

## 目录介绍
```bash
~/lemo/
├── lemo-server/            # 采、训、推流程中部署推理的server端，位于算力平台中
├── README.md               # 英文说明
├── README_zh.md            # 中文说明
├── ethernet_setup.sh       # 配置以太网网络连接的快捷脚本
└── lemo_1.x.x.x            # lemo软件包，项目主要实现代码，位于LEMO平台中
```
后文的举例，将会假设将lemo_1.x.x.x目录放置到LEMO平台的~/目录下。

## 主要功能

- **双臂遥操作**：将 Leader 输入转换为左右机械臂与夹爪目标，支持单臂或双臂运行。
- **硬件配置**：通过 profile 进行配置，支持保存本机配置和启动时临时覆盖。
- **相机采集**：独立相机节点接入三路相机，支持硬触发，以及帧率、旋转角度和曝光时间配置。
- **数据采集与管理**：录制 MCAP 数据，通过 Web 仪表盘查看、回放和下载 episode；LeRobot 转换需要额外的转换工具及依赖。
- **Web 仪表盘**：查看关节、夹爪、相机与运行状态，控制遥操作和录制，管理本地采集任务及日志。
- **策略推理接入**：通过 WebSocket 连接兼容的外部推理服务，支持暂停、回零和人工接管；LEMO平台无需加载模型。

## 系统架构

```text
Leader → g4_spi → teleop_bridge → /motion_target/* → arm_bridge → SDK → CAN → 电机
                                       ↑
                              policy_client（可选）

camera_publisher → 相机图像
关节反馈 / 相机图像 / 运行状态 → Dashboard / 数据录制 / 策略观测
```

完整工作空间的主要组件：

| 组件 | 用途 |
| --- | --- |
| `g4_spi` | SPI 与 CAN之间的通信桥及 Leader 数据采集 |
| `camera_publisher` | 独立三路相机采集与硬触发 |
| `teleop_bridge`（ROS 包名 `lemo`） | 遥操作映射、运行模式管理及统一启动入口 |
| `a1z_arm_bridge_sdk` | 左右臂与夹爪控制、反馈及可选轨迹平滑 |
| `lemo_dashboard` | Web 状态监控、录制控制和数据管理 |
| `policy_client` | 外部策略推理服务客户端 |
| `data_collection` | 预编译录制组件，作为运行时 overlay 使用，不参与源码编译 |
| `profiles/` | 夹爪、Leader 和本机配置模板 |
| `scripts/` | 部署、环境配置和硬件 profile 管理工具 |

## 环境要求

### LEMO平台

- Ubuntu 22.04 ARM64，已安装 ROS 2 Humble 并配置其官方软件源。
- 与实际硬件匹配的 SPI、CAN、相机及 GPIO 接口。
- 完整的运行包及匹配的机械臂 SDK 资源、硬件 profile、系统和 Python 运行依赖。录制功能需要预编译的 `data_collection` 组件。
- 使用启用重力补偿的机械臂桥接程序时，需要匹配的 Pinocchio 运行库。开发版验证版本为 Pinocchio 3.4.0，同时需确认 NumPy 与系统 OpenCV 兼容。

下文使用预编译运行包部署，无需源码编译。只有从源码构建时，才需要 Git、CMake、colcon 等编译依赖。源码构建未检测到 Pinocchio 时，可能生成不含重力补偿的版本；已经链接 Pinocchio 的预编译程序仍需要匹配的运行库。

### 算力平台

- Linux x86_64、受支持的 NVIDIA GPU 及正常工作的 NVIDIA 驱动。显存需求取决于模型和运行配置。
- 系统 Python 3、用于下载依赖和模型关联资源的网络，以及安装系统依赖所需的 sudo 权限。
- 足够的磁盘空间，用于 Python 环境、下载缓存和模型文件。
- 能够与LEMO平台通信。本文使用的 WebSocket 推理服务无需在算力平台安装 ROS 2 或 ARM64 运行包。

`server_setup.sh` 负责安装编译工具和所选后端的 Python 环境，无需手动安装 Conda 或 uv。训练权重及匹配的模型资源需另行准备。

## 部署与配置


### 1. 部署工作空间
首先解压软件压缩包
```bash
cd ~/
# 假设lemo_1.x.x.x.tar.gz位于~/
tar -zxvf lemo_1.x.x.x.tar.gz
# 输入对应的版本号包名
```
环境配置
```bash
cd ~/lemo_1.x.x.x/
./run.sh --check 
source install/setup.bash
sudo ./deploy.sh
```

运行包需预先具备匹配的系统及 Python 运行依赖。`deploy.sh` 负责检查运行包、安装系统服务、配置 GPIO/SPI 权限及 shell 环境，并设置日志轮转，不下载源码或执行编译。


### 2. 设置本机硬件

您可以在 `/etc/lemo/machine.yaml`中，按需求进行配置，主要进行配置相机的参数以及推理时板端policy的配置，其他参数可不进行变动。

```yaml
robot_sn: YOUR_ROBOT_SN
ros_domain_id: 26
gripper_profile: g1z
leader_profile: dvt
camera:
  hz: 15
  wrist_rotation_deg: 180
  exposure_us: 20000
policy:
  server_url: ws://192.168.88.1:8765
  task: The_first_task
  embodiment: galaxea_a1z
  send_raw_jpeg: false
  smoothing: bcubic
  smooth_vmax: 3.5
  smooth_amax: 50
  smooth_jerk: 400
```
- robot_sn: 设备唯一识别码
- ros_domain_id: ROS的通信域，保持默认无需配置
- gripper_profile: 夹爪版本，保持默认无需配置
- leader_profile: 遥操臂版本，保持默认无需配置
- camera: 相机配置
- policy: 模型推理相关的配置

> 建议为每台设备设置唯一且固定的 SN 编码，便于后续设备识别、数据追溯与维护管理。当前系统采用中心化发现机制，日常使用无需调整 Domain ID，保持默认配置即可。在这里您主要需要进行编辑的为`camera`相机配置和`policy`模型配置。


### 3. 启动前检查

- 确认硬件配置、夹爪标定和重力补偿状态符合实际设备。
- 确认没有其他遥操作实例或旧服务占用同一组 SPI/CAN 设备。
- 确认三路相机、双臂反馈正常，以及录制目录可写、空间充足。


## 遥操作与数据采集

```bash
source ~/lemo_1.x.x.x/install/setup.bash
# 后续每次打开新的终端，都需要执行该source指令
ros2 launch lemo lemo.launch.py # 一键启动数据采集系统
```

默认启动双臂控制、G4SPI、相机、录制组件和 Dashboard，控制频率为 200 Hz。启动录制组件不等于立即开始录制。

在浏览器访问 `http://<LEMO平台IP>:8000`（适用于同一局域网的另一台设备）
或者在浏览器中输入`http://localhost:8000`进行访问（适用于在LEMO平台本机的浏览器）
1. 检查硬件在线状态与相机画面。
2. 按下右手柄上位于摇杆下方的按钮，开启遥操作，或通过网页执行对应操作。
3. 按下左手柄上位于摇杆下方的按钮，开始 / 停止录制，或在网页控制录制。
4. 在数据管理页查看、回放或下载已保存的 episode。

**需要注意，录制功能需要在遥操作开启的情况下才能开启录制；遥操作需要在录制结束的时候才能结束遥操作**

下文的“右手柄按钮”和“左手柄按钮”均指对应手柄上位于摇杆下方的按钮，不是摇杆的左右方向。

一次数采动作流程为以下操作：
```bash
按下右手柄按钮[开启遥操作]->按下左手柄按钮[开始录制]->遥操作并记录当前动作和相机数据->按下左手柄按钮[结束录制并保存]->按下右手柄按钮结束遥操作
```
当需要连续采集时结束录制后不需要进行第二次按下右手柄按钮结束遥操作，在录制完之后，再次按下左手柄按钮开始新的录制，如此循环进行连续录制动作


本地任务中，将某个任务设为「当前任务」后，后续录制的 episode 会自动归属该任务。

加上参数的启动方式示例：

```bash
# 只启动左臂，不启动录制组件
ros2 launch lemo lemo.launch.py arm:=left start_recording:=false

# 不启动相机
ros2 launch lemo lemo.launch.py start_camera:=false
```

查看全部启动参数：

```bash
ros2 launch lemo lemo.launch.py --show-args
```

| 参数 | 用途 |
| --- | --- |
| `arm` | `left`、`right` 或 `both` |
| `ctrl_hz` | 控制频率，默认 200 Hz |
| `gripper` / `leader` | 硬件 profile，默认自动读取本机配置 |
| `start_g4spi` / `start_camera` | 是否启动采集桥 / 相机 |
| `start_recording` / `start_dashboard` | 是否启动录制组件 / 仪表盘 |
| `camera_hz` / `camera_rotation_deg` / `camera_exposure_us` | 相机帧率、旋转角度、曝光时间 |
| `arm_smoothing` | 遥操作等目标的轨迹平滑，默认 `legacy` |
| `arm_smoothing_policy` | 推理 / 回放专用平滑；为空时沿用 `arm_smoothing` |
| `start_policy` | 是否启动策略客户端，默认关闭 |
| `data_collection_install` | 预编译录制组件路径 |
| `log_dir` | 日志目录 |

保持 G4SPI 轮询频率 `g4spi_poll_hz` 为默认 2000 Hz，降低该值可能造成反馈积压或断流。

## Web 仪表盘与数据管理

Dashboard 可随统一入口启动，也可单独运行：

```bash
ros2 run lemo_dashboard lemo-dashboard
```

支持实时关节与夹爪反馈、相机预览、Leader 只读监看、录制控制、episode 管理及日志查看。Leader 仅监看模式需在遥操作结束并回到 HOME 后开启；开启期间屏蔽遥操作、录制及接管按键。

录制数据的默认目录为：

```text
~/GalaxeaDataset/<YYYYMMDD>/<名称>_RAW/
```

目录包含 MCAP 文件及可选元数据。自定义 Dashboard 扫描目录：

```bash
DASHBOARD_DATASET_ROOT=/path/to/dataset ros2 run lemo_dashboard lemo-dashboard
```

该变量只指定 Dashboard 查找数据的位置，录制落盘路径需在录制组件中对应配置。使用外部存储时，先确认已挂载且可写。

Dashboard 默认监听 `0.0.0.0:8000`，应在可信网络使用。可通过环境变量 `DASHBOARD_TOKEN` 设置访问令牌；请求需携带 `X-Dashboard-Token` 请求头或 `token` 查询参数。单独运行时可用 `--port`、`--no-camera`、`--no-episodes` 调整端口及资源使用，例如：

```bash
ros2 run lemo_dashboard lemo-dashboard --port 9000
# 此时连接dashboard应使用的端口为9000
```

缺少 ROS、OpenCV 或 rosbag2 运行环境时，Dashboard 会降级为本地预览模式，演示值不代表实机反馈，录制和 MCAP 回放不可用。

云端上传需单独配置设备身份和服务凭证，不是本地采集的前置条件。

## 推理部署

推理分为两端：lemo-server/中的**Server 端**运行在算力平台上，负责加载模型并生成动作；lemo_1.x.x.x/中的**Policy 端**运行在LEMO平台上，通过 `policy_client` 上传相机和关节观测，接收动作并执行。先准备并启动 Server 端，再配置、启动 Policy 端，最后在 Dashboard 中开始推理。

### 1. Server 端：部署推理服务

按“放置代码与模型 → 安装环境 → 配置服务 → 启动验证”的顺序操作。环境安装与模型配置相互独立。

#### 1.1 放置代码与模型

以下统一使用 `~/workspace` 作为算力平台部署工作目录，代码放在 `lemo-server/`，模型资源放在与其并列的 `lemo-models/`。建议目录结构如下，代码可以独立更新，模型资源无需放入代码目录：

```text
~/workspace/
├── lemo-server/
│   ├── server_setup.sh                  # 仅安装和检查环境
│   ├── deploy/
│   │   ├── start_serve.sh                # 读取配置并启动服务
│   │   ├── serve.env                     # 默认配置
│   │   └── serve.env.local.example       # 本机配置模板
│   ├── scripts/
│   └── src/
└── lemo-models/
    ├── g05/my_model/                     # G0.5 示例
    │   ├── checkpoints/step_35000.pt
    │   ├── action_tokenizer.pt
    │   ├── dataset_stats.json            # 配套数据统计
    │   └── ...                          # 训练配置等配套文件
    ├── qwen3_5_2b_base_processor/        # G0.5 的完整 processor
    └── lerobot/my_model/                # LeRobot 示例
        └── checkpoints/025000/pretrained_model/
            ├── config.json
            ├── model.safetensors
            ├── policy_preprocessor.json
            ├── policy_postprocessor.json
            └── ...                      # 配套归一化参数等文件
```

只需准备所选后端对应的文件。`my_model`、`step_35000` 和 `025000` 均为示例，需替换为实际名称。G0.5 的权重、动作分词器和 processor 必须配套。这里的 G0.5 processor 是模型预处理与分词配置及资源目录，不是硬件处理器；请复制完整目录，包括配置文件和分词器文件，并保留模型对应的训练配置与 `dataset_stats.json`。LeRobot 的 processor 文件包含预处理、后处理和归一化设置，也需保留其关联参数文件。LeRobot 需复制完整 `pretrained_model/` 目录。若没有内嵌 processor，按 `lemo-server/deploy/README_LEROBOT.md` 准备数据集统计文件。

#### 1.2 安装运行环境

进入上一步准备的代码目录。需要 Linux x86_64、系统 Python 3 和可用的 NVIDIA 驱动，安装时需要网络及 sudo 权限。

```bash
cd ~/workspace/lemo-server
nvidia-smi
```

选择与模型对应的后端，只执行其中一条：

```bash
# G0.5
bash server_setup.sh --backend g05

# 或 LeRobot
bash server_setup.sh --backend lerobot
```

脚本自动安装编译依赖、创建 Python 3.10 环境并安装依赖，最后检查 CUDA 和基础导入。无需手动安装 Conda 或 uv，也不需要传入模型路径。G0.5 环境位于 `.venv/`，LeRobot 环境位于 `.venv-lerobot/`。

首次安装会下载较大的 PyTorch 与 CUDA 依赖，请等待脚本完整结束。只有输出 `Environment ready` 才表示安装和验证通过；出现错误或中断后应修复原因并重新执行同一安装命令，下载缓存会复用。`--check` 仅验证已有环境，不会补装依赖。

脚本不下载用户训练权重、不修改服务配置、不启动推理。验证已安装环境时，可使用 `bash server_setup.sh --backend g05 --check`（LeRobot 将后端改为 `lerobot`）。其他选项可执行 `bash server_setup.sh --help` 查看。

#### 1.3 配置模型与服务

首次配置时，在算力平台执行：

```bash
cd ~/workspace/lemo-server
# 仅在本机配置不存在时复制，避免覆盖已有设置
[ -f deploy/serve.env.local ] || cp deploy/serve.env.local.example deploy/serve.env.local
# 编辑server端配置
nano deploy/serve.env.local
```

按所选后端填写以下一组配置。文件中的名称与上方模型目录一一对应；配置文件不应提交到仓库。

G0.5：

```bash
MODEL_TYPE=g05
G05_CHECKPOINT=$HOME/workspace/lemo-models/g05/my_model/checkpoints/step_35000.pt
G05_TOKENIZER=$HOME/workspace/lemo-models/g05/my_model/action_tokenizer.pt
G05_PROCESSOR=$HOME/workspace/lemo-models/qwen3_5_2b_base_processor
SERVE_PORT=8765
ACTION_STEPS=32
EMBODIMENT=galaxea_a1z
DEVICE=cuda
```

LeRobot：

```bash
MODEL_TYPE=lerobot
LEROBOT_POLICY_PATH=$HOME/workspace/lemo-models/lerobot/my_model/checkpoints/025000/pretrained_model
LEROBOT_DEFAULT_TASK="pick up the red cube"
SERVE_PORT=8765
ACTION_STEPS=32
DEVICE=cuda
```

任务描述应与训练数据一致。没有内嵌 processor 的 LeRobot 模型，还需设置 `LEROBOT_STATS_PATH=/实际路径/stats.json`。默认使用程序自带的关节及图像映射；自定义特征名时需配置对应的 `LEROBOT_MAPPING`。

Python 路径无需填写：启动脚本默认选择本程序目录下的 `.venv/bin/python` 或 `.venv-lerobot/bin/python`。若旧的本机配置指定了 `EFMNODE_PYTHON` 或 `LEROBOT_PYTHON`，请移除旧覆盖或改为对应的新环境路径。

#### 1.4 算力平台与LEMO平台有线直连配置（可选）

**如果两台设备已通过现有网络互通，可跳过本节**。若是在连接网线情况下，仍然无法相互ping通，可以使用以下方式进行尝试。以下脚本自动配置IP地址：
| 设备 | ip地址 |
| --- | --- |
|server端|192.168.88.1|
|policy端|192.168.88.2|


适用条件：两端为使用 NetworkManager 的 Linux，具备系统 Python 3、`nmcli`、`ip`、`ping` 和 sudo 权限。先连接好网线；可使用板载网口或 USB 转网口。请在本机终端或通过独立 Wi-Fi SSH 执行，避免通过正在配置的有线网口操作。

**1.4.1 在算力平台执行**

脚本```ethernet_setup.sh```位于 `lemo/` 根目录，与 `README.md` 并列。可以将脚本拷贝至对应机器中，无需特定路径进行：

```bash
# 前往脚本所在目录：
cd /path/to/script-directory
chmod +x ethernet_setup.sh
bash ./ethernet_setup.sh --role server
```

**1.4.2 在 LEMO 平台执行**

将同一个脚本复制到 LEMO 平台即可，不需要在 LEMO 平台安装服务端环境，并前往所在目录执行：

```bash
# 前往脚本所在目录：
cd /path/to/script-directory
chmod +x ethernet_setup.sh
bash ./ethernet_setup.sh --role lemo
```

第一台配置时，另一台可能尚未就绪；此时会提示无法连接对端，退出码为 2。本端配置已保存，继续配置另一台后，再完成下面的验证。

**1.4.3 验证两端通信**

两台设备分别进入 `ethernet_setup.sh` 所在目录，再执行各自对应的命令，只检查、不修改配置：

```bash
# 算力平台
bash ./ethernet_setup.sh --role server --check

# LEMO 平台
bash ./ethernet_setup.sh --role lemo --check
```

两端均显示“有线通信验证通过”后，继续下一节启动服务。若是使用本小节配置方式，算力平台端也就是server端的通讯ip自动设为192.168.88.1，因此后续的配置中server_url应为：```server_url: ws://192.168.88.1:8765```


**遇到提示时如何处理**

| 提示或现象 | 操作 |
| --- | --- |
| 排除 SSH 和上网网口后仍有多个候选网口 | 按脚本列出的名称添加 `--interface 实际网口名`，选择连接另一台设备的网口 |
| 未检测到物理链路 | 运行 `--diagnose` 查看具体网口；区分网口未启用、`NO-CARRIER` 和转接口未被识别，再检查网线、转接口及对端供电；不要选择 Wi-Fi 网口 |
| 网段冲突 | 两端命令均添加相同的其他私有网段，例如 `--subnet 192.168.89.0/24`；服务地址相应改为 `192.168.89.1` |
| 想先查看脚本会做什么 | 添加 `--dry-run`，预览网口和地址，不修改网络 |
| 显示 `disconnected` 或正在获取 IP | 不一定是网线故障；直连通常没有 DHCP 服务，运行本节脚本配置静态地址 |
| 两端配置完成仍不通 | 核对接线和两端网段；尝试换线、换网口或 USB 转接口，然后重新运行配置脚本。物理链路正常不保证报文能双向传输 |
| 换了网口或转接口 | 重新运行配置命令；脚本会按当前网口更新专用连接，剩余候选网口不唯一时需显式指定 |
| 有线通信通过，但推理连接失败 | 继续检查 Server 是否启动、监听地址、服务端口及防火墙 |

脚本在网段冲突、目标网口承载当前 SSH 或当前实际上网路由时停止配置，并给出提示。若有线网口只是带有旧配置的备用默认路由、实际上网及 SSH 均通过其他网口，脚本允许切换为专用直连配置，原配置保留。不要为了消除提示关闭 Wi-Fi 或清空其他网络配置。

#### 1.5 启动与验证

> 首次启动可能需要从Hugging Face中加载配置，因此若未对机器配置访问外网的环境，可能回遇到网络问题而导致的报错可以执行下面的指令配置国内镜像地址：
```bash
export HF_ENDPOINT=https://hf-mirror.com
```

同一个终端中执行推理server端节点：
```bash
cd ~/workspace/lemo-server
bash deploy/start_serve.sh
```

server端若为正常运行，注意终端会输出如下内容，若有则证明目前server端节点启动完成。
```bash
INFO | >> Policy server listening on 0.0.0.0:8765
```

启动入口检查模型路径、Python 和端口占用，再加载模型。确认日志显示模型加载、预热成功以及监听 `0.0.0.0:8765` 后，保持服务运行，再配置LEMO平台的 `policy.server_url` 为 `ws://<算力平台IP>:8765`。

首次加载可能需要获取模型关联的基础资源。服务器监听成功仅表示 Server 就绪，仍需验证LEMO平台客户端连接与实机动作。更换权重或任务只需修改服务配置并重启服务；更换后端时需先安装对应环境。

### 2. Policy 端：配置机器人并启动推理客户端

先完成LEMO平台的部署与硬件配置，并确认相机和关节反馈正常。首次使用前，在LEMO平台上的 `/etc/lemo/machine.yaml` 中添加或修改顶层 `policy:` 配置段，与硬件配置并列。将服务地址和任务描述替换为实际值，例如：

```yaml
policy:
  server_url: "ws://<算力平台IP>:8765"
  task: "pick up the red cube"
  embodiment: galaxea_a1z
  send_raw_jpeg: false
  smoothing: bcubic
  smooth_vmax: 3.5
  smooth_amax: 50
  smooth_jerk: 400
```

- `server_url`: 算力平台的 WebSocket 地址，例如 ws://<算力平台IP>:8765。LEMO平台通过它上传观测、接收模型输出的动作。
- `task`: 发给模型的任务描述，例如 pick up the red cube，应与训练时使用的任务描述保持一致。
- `embodiment`: LEMO平台配置标识，例如 galaxea_a1z，让服务端选择对应的观测、动作和模型适配配置，需与服务端约定一致。
- `send_raw_jpeg`: 图像传输方式。true：直接发送相机 JPEG，由算力平台解码；false：LEMO平台先解码、缩放，再发送图像数组。应根据服务端协议选择。
- `smoothing`: 推理和回放动作使用的轨迹平滑方式。bcubic 会根据近期目标点进行三次样条插值，让稀疏的目标动作过渡得更连续，同时引入一定延迟。遥操作仍使用独立的 arm_smoothing 设置。
- `smooth_vmax`: 平滑轨迹的关节速度上限，单位 rad/s。示例 3.5 约为 201°/s。
- `smooth_amax`: 平滑轨迹的关节加速度上限，单位 rad/s²。限制速度变化的快慢。
- `smooth_jerk`: 平滑轨迹的关节加加速度上限，单位 rad/s³。限制加速度变化的快慢，影响动作起停和转折时的柔和程度。

保存配置并启动推理服务后，在LEMO平台执行：

```bash
ros2 launch lemo lemo.launch.py start_policy:=true
```
也可以通过命令行快速临时配置使用的url：
```bash
ros2 launch lemo lemo.launch.py start_policy:=true policy_server_url:=ws://<算力平台有线网口IP>:8765
```
启动时会自动读取 `policy:` 中的参数，无需每次重复填写。修改配置后需重启 launch 才能生效；命令行显式参数优先于配置文件，若是有调试需求也可以直接在命令行中添加参数执行。

上述平滑参数为配置示例，需结合实际硬件和模型验证。首次实机运行前，必须核对模型的关节、夹爪量纲及数据归一化约定；夹爪默认按百分比传递。

**连接确认与开始推理**

启动后，先确认LEMO平台日志显示已连接到配置的 WebSocket 地址，再在浏览器访问 `http://<LEMO平台IP>:8000`。在 Dashboard 点击「推理」后，客户端才开始输出动作；仅启动客户端不会立即执行推理动作。暂停、回零、停止及人工接管通过对应操作触发。

排查推理问题时，可在 Dashboard 开启「自动录推理」（默认关闭），保存包含原始动作、控制目标和反馈的调试数据。推理连接断开时，客户端清空队列并停止发送动作，随后尝试重连。

可通过 `/policy_client/status` 查看连接、动作队列和限幅状态。



## 运行模式与数据标记

`teleop_bridge` 统一管理待机、遥操作、推理、人工接管、暂停、回零和回放等模式，通过 `/run_mode/state` 发布当前状态。启动和回零后的待机状态不会自动放行推理；模式管理节点失联时，策略客户端停止发送动作。

录制保存后，可在 episode 目录生成 `run_mode_timeline.json`，记录控制来源、模式持续时间和切换时间，便于区分遥操作、策略执行与人工接管数据。

## 日志管理

统一启动默认将运行日志写入 `/dev/shm/ros_log`，后台定期将静置日志归档到 `~/.ros/log`。内存中的未归档日志会在掉电后丢失；Dashboard 的日志页面可能要等会话结束并归档后才显示当前日志。

需要直接保存到磁盘时：

```bash
ros2 launch lemo lemo.launch.py log_dir:=~/.ros/log
```

## 检查与停止

```bash
ros2 node list
```

正常运行应包含遥操作桥接、左右臂桥接和 G4SPI 节点，以及启用的相机、录制和仪表盘节点。同名节点重复出现时，应检查是否存在重复启动或残留实例。

正常停机使用运行包中附带的停止脚本，将 `1.x.x.x` 替换为实际安装的版本号：

```bash
sudo ~/lemo_1.x.x.x/scripts/lemo_setup.sh stop
```

该命令先停止机械臂桥接并等待失能帧发送完成，再停止通信桥和其他节点。直接对统一 launch 按 Ctrl+C 可能导致通信桥先退出，使电机失能指令无法送达；正常停机应使用上述顺序停止流程。

硬件异常或紧急情况按设备急停流程处理。若重力补偿出现下垂、偏转或姿态异常，应立即关闭并停止使用，检查模型与标定后再启用。

---

## 常见问题

**推理启动常见问题**

| 现象 | 检查方式 |
| --- | --- |
| Server 启动报 `[FATAL]` | 按提示检查模型文件、Python 路径及服务配置 |
| 端口被占用 | 根据自检提示确认占用进程，停止旧服务或调整端口，同时更新LEMO平台地址 |
| Policy 端无法连接 | 检查算力平台 IP、端口、网络连通性、防火墙及 VPN 路由 |
| 已连接但不执行 | 确认已在 Dashboard 进入推理模式，两端 `embodiment` 一致，并检查客户端状态与日志 |
| LeRobot 依赖或数据格式问题 | 参见 server 目录中的 `deploy/README_LEROBOT.md` |


**启动Policy节点出现权限问题**
```bash
PermissionError: [Errno 13] Permission denied: '/dev/shm/ros_log/2026-10-21-16-02-16-383730-lubancat-9832'
```
这是因为用户权限问题导致无法写入对应文件夹，执行以下指令进行增加权限以解决：
```bash
mkdir -p "$HOME/.ros/log"
export ROS_LOG_DIR="$HOME/.ros/log"
sudo chown "$(id -u):$(id -g)" /dev/shm/ros_log
chmod u+rwx /dev/shm/ros_log
```
