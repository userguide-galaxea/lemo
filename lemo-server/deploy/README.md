# 算力平台推理服务部署

`lemo-server` 提供 G0.5 与 LeRobot 两种模型后端，通过 WebSocket 与LEMO平台的 `policy_client` 通信。

## 1. 目录与环境安装

将服务端代码放在 `~/workspace/lemo-server`，模型资源放在 `~/workspace/lemo-models`：

```text
~/workspace/
├── lemo-server/
│   ├── server_setup.sh
│   └── deploy/start_serve.sh
└── lemo-models/
    ├── g05/my_model/
    │   ├── checkpoints/step_35000.pt
    │   ├── action_tokenizer.pt
    │   └── dataset_stats.json
    ├── qwen3_5_2b_base_processor/
    └── lerobot/my_model/checkpoints/025000/pretrained_model/
```

在算力平台上选择一个后端安装：

```bash
cd ~/workspace/lemo-server
bash server_setup.sh --backend g05
# 或：bash server_setup.sh --backend lerobot
```

安装脚本只准备环境，不要求模型文件，也不修改模型配置或启动服务。G0.5 使用 `.venv`，LeRobot 使用 `.venv-lerobot`。

## 2. 配置模型

```bash
cd ~/workspace/lemo-server
[ -f deploy/serve.env.local ] || cp deploy/serve.env.local.example deploy/serve.env.local
nano deploy/serve.env.local
```

选择一组配置，替换实际模型路径和任务。

### G0.5

```bash
MODEL_TYPE=g05
G05_CHECKPOINT=$HOME/workspace/lemo-models/g05/my_model/checkpoints/step_35000.pt
G05_TOKENIZER=$HOME/workspace/lemo-models/g05/my_model/action_tokenizer.pt
G05_PROCESSOR=$HOME/workspace/lemo-models/qwen3_5_2b_base_processor
EMBODIMENT=galaxea_a1z
SERVE_PORT=8765
ACTION_STEPS=32
DEVICE=cuda
```

模型应包含匹配的训练配置、数据统计、动作分词器和 processor。也可以通过 `G05_WORKSPACE`（默认 `~/workspace/lemo-models`）、`MODEL_RUN` 和 `MODEL_STEP` 组合定位 `g05/<MODEL_RUN>/checkpoints/<MODEL_STEP>.pt`；显式的文件路径优先。

### LeRobot

```bash
MODEL_TYPE=lerobot
LEROBOT_POLICY_PATH=$HOME/workspace/lemo-models/lerobot/my_model/checkpoints/025000/pretrained_model
LEROBOT_DEFAULT_TASK="pick up the red cube"
SERVE_PORT=8765
ACTION_STEPS=32
DEVICE=cuda
```

使用完整的 `pretrained_model` 目录，包括模型配置、权重及配套预处理/后处理文件。无内嵌 processor 时需设置 `LEROBOT_STATS_PATH`。特征映射与数据格式见 [README_LEROBOT.md](README_LEROBOT.md)。

默认选择项目内对应的 Python 环境；自定义环境时可设置 `EFMNODE_PYTHON` 或 `LEROBOT_PYTHON`。

## 3. 启动服务

```bash
cd ~/workspace/lemo-server
bash deploy/start_serve.sh
```

确认模型加载、预热成功以及服务监听 `0.0.0.0:8765`。配置改变后重新启动服务。

## 4. LEMO平台连接

在LEMO平台的 `/etc/lemo/machine.yaml` 中设置：

```yaml
policy:
  server_url: "ws://<算力平台IP>:8765"
  task: "pick up the red cube"
  embodiment: galaxea_a1z
  send_raw_jpeg: false
  smoothing: bcubic
```

保留其他配置，任务和动作量纲需与模型匹配。服务就绪后启动客户端：

```bash
ros2 launch lemo lemo.launch.py start_policy:=true
```

连接成功后，在 Dashboard 点击“推理”才会执行动作。目录布局、网络配置和完整使用流程见[项目 README](../../README_zh.md#推理部署)。
