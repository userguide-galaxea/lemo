# flatten_lerobot.py —— 把 mcap2lerobot 的分部件数据集转成平铺 observation.state/action
# 用法: python flatten_lerobot.py <src_dir> <dst_dir>
# 处理: ① parquet 增加平铺列(float32) ② info.json 特征表更新 ③ 聚合 stats.json
import json
import shutil
import sys
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq

STATE_PARTS = ["left_arm", "right_arm", "left_gripper", "right_gripper"]
SRC = Path(sys.argv[1])
DST = Path(sys.argv[2])

info = json.loads((SRC / "meta/info.json").read_text())
feats = info["features"]

# 平铺拼接顺序:显式固定,必须与 serve_lerobot 的 action_layout /
# 映射表 state_parts 顺序一致(info.json 的 features 字典序不可信)
ACTION_ORDER = ["action.left_arm", "action.left_gripper",
                "action.right_arm", "action.right_gripper"]
STATE_ORDER = ["observation.state.left_arm", "observation.state.left_gripper",
               "observation.state.right_arm", "observation.state.right_gripper"]
state_keys = [k for k in STATE_ORDER if k in feats]
action_keys = [k for k in ACTION_ORDER if k in feats]
assert len(state_keys) == 4 and len(action_keys) == 4, "数据集缺部件特征"
print("state parts:", state_keys)
print("action parts:", action_keys)

(DST / "meta").mkdir(parents=True, exist_ok=True)

# ── ① parquet 增列 ──
n_files = 0
for src_pf in sorted(SRC.glob("data/**/*.parquet")):
    rel = src_pf.relative_to(SRC)
    dst_pf = DST / rel
    dst_pf.parent.mkdir(parents=True, exist_ok=True)
    t = pq.read_table(src_pf)
    import pyarrow as pa

    def concat_col(keys):
        cols = []
        for k in keys:
            c = np.stack(t.column(k).to_numpy())
            if c.ndim == 1:  # 标量部件(夹爪)升维到 [N,1]
                c = c[:, None]
            cols.append(c)
        return np.concatenate(cols, axis=1).astype(np.float32)

    s = concat_col(state_keys)
    a = concat_col(action_keys)
    t = t.append_column(
        "observation.state",
        pa.array([row.tolist() for row in s], type=pa.list_(pa.float32())),
    )
    t = t.append_column(
        "action",
        pa.array([row.tolist() for row in a], type=pa.list_(pa.float32())),
    )
    pq.write_table(t, dst_pf)
    n_files += 1
print(f"parquet 转换 {n_files} 个")

# ── ② 视频/meta 复制 ──
if (SRC / "videos").exists():
    shutil.copytree(SRC / "videos", DST / "videos", dirs_exist_ok=True)
for mf in ("episodes.jsonl", "tasks.jsonl", "episodes_stats.jsonl"):
    p = SRC / "meta" / mf
    if p.exists():
        shutil.copy2(p, DST / "meta" / mf)

# ── ③ info.json 特征表更新 ──
def flat_feature(keys, out_name):
    dim = sum(feats[k]["shape"][0] for k in keys)
    names = []
    for k in keys:
        names.extend(feats[k].get("names") or [f"{k}[{i}]" for i in range(feats[k]["shape"][0])])
    return {
        "dtype": "float32",
        "shape": [dim],
        "names": names,
    }

feats["observation.state"] = flat_feature(state_keys, "observation.state")
feats["action"] = flat_feature(action_keys, "action")
info["features"] = feats
(DST / "meta/info.json").write_text(json.dumps(info, indent=2, ensure_ascii=False))

# ── ④ 聚合 stats.json(读 parquet 实算,与平铺列同口径)──
import pandas as pd

sums, sqsums, counts = {}, {}, {}
mins, maxs = {}, {}
for pf in sorted(DST.glob("data/**/*.parquet")):
    df = pq.read_table(pf, columns=["observation.state", "action"]).to_pandas()
    for col in ("observation.state", "action"):
        m = np.stack(df[col].to_numpy()).astype(np.float64)
        sums[col] = sums.get(col, 0) + m.sum(axis=0)
        sqsums[col] = sqsums.get(col, 0) + (m**2).sum(axis=0)
        counts[col] = counts.get(col, 0) + len(m)
        mn, mx = m.min(axis=0), m.max(axis=0)
        mins[col] = np.minimum(mins[col], mn) if col in mins else mn
        maxs[col] = np.maximum(maxs[col], mx) if col in maxs else mx

stats = {}
for col in ("observation.state", "action"):
    n = counts[col]
    mean = sums[col] / n
    var = sqsums[col] / n - mean**2
    stats[col] = {
        "mean": mean.tolist(),
        "std": np.sqrt(np.maximum(var, 1e-12)).tolist(),
        "min": mins[col].tolist(),
        "max": maxs[col].tolist(),
        "count": [n],
    }
(DST / "meta/stats.json").write_text(json.dumps(stats, indent=2))
print("stats.json 聚合完成")
print(f"输出: {DST}")
