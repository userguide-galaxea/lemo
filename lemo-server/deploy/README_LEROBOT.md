# LeRobot 算法训练与推理指南(SmolVLA / DP / ACT / π0)

本文档覆盖 LEMO 采训推链路的 **LeRobot 生态支线**:用 mcap2lerobot 转出的
数据集训练 lerobot 系算法,并通过 `serve_lerobot.py` 上桌推理。
与 G05 主线并存,板端 policy_client **零改动**。

实机验证记录:2026-10-12,4090(RTX 4090 24G),数据集 LEMO4-Pick_And_Place2
(188 episodes / 33k 帧 / 15Hz),SmolVLA 冒烟 200 步 + 全量 30k 步通过。

---

## 0. 全流程一览

```
板端数采(mcap)
  → dashboard 一键转 lerobot(v2.1,分部件键)
  → tools/flatten_lerobot_dataset.py(补平铺 observation.state[14]/action[14])
  → lerobot v2.1→v3.0 转换(官方转换器)
  → 检查任务文本(见 §2.3 已知坑)
  → lerobot-train(SmolVLA/DP/…)
  → serve.env 切 MODEL_TYPE=lerobot → bash deploy/start_serve.sh
  → 板端 start_policy:=true,前端点推理
```

## 1. 环境准备(4090 / GPU 服务器)

独立 conda 环境,与 G05 的 efmnode 隔离:

```bash
conda create -n lerobot-serve python=3.10 -y
~/miniconda3/envs/lerobot-serve/bin/pip install \
  lerobot==0.4.2 msgpack websockets opencv-python-headless \
  "transformers==4.52.4" "huggingface-hub>=0.34.2,<0.36.0" num2words
```

**版本是钉死的,别随手升**:

| 依赖 | 版本 | 原因 |
|---|---|---|
| lerobot | 0.4.2 | python3.10 能装的最后一版(0.5+ 要 3.12) |
| transformers | 4.52.4 | 新版会拖入 huggingface-hub 2.x,与 lerobot 冲突 |
| huggingface-hub | 0.35.x | 同上 |
| num2words | 任意 | SmolVLM processor 的隐藏依赖,缺了报 ImportError |
| torch | 2.7.1 **+cu128** | **Blackwell(RTX 5080/5090, sm_120)必须 cu128 轮子**;pip 默认装的 +cu126 只到 sm_90,能 import 但 kernel 全挂。装法:`pip install --force-reinstall --no-deps torch==2.7.1 torchvision==0.22.1 --index-url https://download.pytorch.org/whl/cu128`(同名版本 pip 会当已满足,必须 force) |

**HuggingFace 直连不通时走镜像**(4090 现状):

```bash
export HF_ENDPOINT=https://hf-mirror.com
```

## 2. 数据准备

### 2.1 平铺化(必做)

mcap2lerobot 转出的数据集是分部件键(`observation.state.left_arm` 等),
而 lerobot 全系算法只吃平铺 `observation.state` / `action`:

```bash
python tools/flatten_lerobot_dataset.py <原数据集目录> <输出目录>
```

- 拼接顺序**显式锚定**为 `left_arm, left_gripper, right_arm, right_gripper`,
  与推理侧 `deploy/lerobot_a1z_mapping.json` 的 `action_layout` 严格一致
  (info.json 的 features 字典序不可信,别按它排)
- 同时聚合生成 `meta/stats.json`(训练归一化用)

### 2.2 v2.1 → v3.0 转换(lerobot 0.4.x 只认 v3)

```python
from lerobot.datasets.v30.convert_dataset_v21_to_v30 import convert_dataset
# 注意:root 是父目录,repo_id 是数据集目录名
convert_dataset("<数据集目录名>", root="<父目录>", push_to_hub=False)
```

### 2.3 已知坑:任务文本可能是 "null" ⚠️

**2026-10-12 实测**:LEMO4 数据集的 tasks 表里混入了 `"null"`、`"qualified"`
(质量字段串入),且全部帧的 task_index 指向 "null"——不修的话 VLA 学不到
语言条件。检查与修复:

```python
import pyarrow.parquet as pq, pandas as pd, pyarrow as pa
from pathlib import Path
p = Path("<数据集>/meta/tasks.parquet")
df = pq.read_table(p).to_pandas()
print(df)   # 看 task_index→任务文本映射是否正确
# 修复示例:task_index 1 指到真实任务(任务文本作 pandas 索引,别用默认 RangeIndex)
df = pd.DataFrame({"task_index": [0, 1]},
                  index=pd.Index(["placeholder", "<真实任务文本>"], name="__index_level_0__"))
pq.write_table(pa.Table.from_pandas(df), p)
```

验证:`ds[0]["task"]` 应返回真实任务文本,而不是 "null" 或数字。
**长期修复应落在 mcap2lerobot 或数采 meta 链路(待办)。**

## 3. 训练

```bash
HF_ENDPOINT=https://hf-mirror.com lerobot-train \
  --dataset.repo_id=<数据集目录名> --dataset.root=<数据集绝对路径> \
  --policy.type=smolvla --policy.device=cuda --policy.push_to_hub=false \
  --output_dir=<输出目录> --job_name=<任务名> \
  --steps=30000 --batch_size=16 --save_freq=5000 --wandb.enable=false
```

参考实测(4090,LEMO4 33k 帧):

- 速度 ~0.36s/step(计算)+ 数据加载 ~0.29s/step,墙钟约 0.6s/step,
  **30k 步 ≈ 5 小时**;瓶颈在数据加载不在 GPU(显存只占 ~8.5G/24G)
- 每 5000 步存 ckpt,早期 ckpt 可提前上桌试
- 训练前确认显存空闲(G05 推理 server 占 18G,训前先停)

ckpt 结构(`checkpoints/NNNNNN/pretrained_model/`):`config.json` +
`model.safetensors` + `policy_preprocessor.json` + `policy_postprocessor.json`
——内嵌归一化 processor,推理侧零配置。

## 4. 推理部署

```bash
# deploy/serve.env:
MODEL_TYPE=lerobot
LEROBOT_POLICY_PATH=<run>/checkpoints/0030000/pretrained_model
# LEROBOT_STATS_PATH 不用配(ckpt 已内嵌 processor)

bash deploy/start_serve.sh
```

- 协议与 G05 完全一致(chunk-download-v1),板端不用动
- 自检覆盖:ckpt 有效性、映射文件、归一化来源、端口占用
- `action_steps` 超模型可执行段(如 DP 的 horizon−n_obs_steps+1)自动收敛
- 板端照常:`ros2 launch lemo lemo.launch.py start_policy:=true`,前端点推理

## 5. 排障 FAQ

| 现象 | 处理 |
|---|---|
| `No module named 'transformers'` / `num2words` | 按 §1 装全,SmolVLA 的依赖 lerobot 基础包不带 |
| `huggingface-hub 2.x incompatible` | 钉 `huggingface-hub<0.36` + `transformers==4.52.4` |
| HF 下载 Network is unreachable | `export HF_ENDPOINT=https://hf-mirror.com` |
| `BackwardCompatibilityError` | 数据集是 v2.1,走 §2.2 转 v3 |
| 训练时 `ds[0]["task"]` 是 null/数字 | 任务表坏了,走 §2.3 |
| 推理维度不匹配报错 | 查 mapping 的 `action_layout` 顺序是否与训练数据拼接顺序一致 |
| 推理缺图像/状态报错 | 报错信息会指明缺哪个键,对照 mapping 与板端相机/反馈配置 |

## 6. 与 G05 主线的关系

- 两条线共用同一块板、同一 policy_client、同一 run_mode 状态机;
  server 侧切换就是 `serve.env` 里 `MODEL_TYPE` 改一下
- 同一数据集可以分别训 G05(finetune.py)和 SmolVLA,做 A/B 对比
- 已知差异:G05 走 VQ tokenizer + 自回归,SmolVLA 走 flow matching;
  SmolVLA 单 chunk 推理延迟显著更低(百 ms 级),chunk 边界抖动更小
