"""LeRobot 策略(DP/ACT/pi0 等)的 WebSocket 推理服务 —— chunk-download-v1 协议。

与 serve_policy.py(G05)同一协议、同一握手,板端 policy_client 零改动:
  - 握手:{"action_steps", "protocol": "chunk-download-v1", "shape_meta"}
  - 请求:{"images": {key: uint8[C,H,W] 或 {"__jpeg__": true, "data": bytes}},
          "state": {part: float[D]}, "task": str, "frequency": 15}
  - 响应:{"action": {part: [dim]}, "need_obs": true,
          "reserved": {"action_chunk": {part: [T, dim]}}}

观测历史(n_obs_steps)复用策略自带的 _queues 机制(与 select_action 同路径,
冷启动自动复制首帧填充),服务侧不另建队列;__reset__ / 新连接都会 policy.reset()。

观测/动作的键名映射走 --mapping 指定的 JSON(默认 deploy/lerobot_a1z_mapping.json),
训练侧改了特征名只动映射文件,不动代码。

归一化:优先用 ckpt 目录里内嵌的 pre/post processor(lerobot 新版训练产物);
没有则用 --stats_path 指定的数据集 stats.json 手动归一化(均值方差)。

注意:策略的观测队列在模型对象内,本服务按单客户端设计(一块板子一个连接)。

用法:
    python scripts/serve_lerobot.py \
        --policy_path /path/to/lerobot_ckpt \
        --host 0.0.0.0 --port 8765 --action_steps 32
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import time
from pathlib import Path
from typing import Any

import numpy as np
import torch

# 协议 codec 与 G05 server 同源(仅依赖 msgpack/numpy,包 __init__ 均为空,
# 干净环境下把 src 挂上即可导入,不拖入 g05 其余依赖)
import sys as _sys

_SRC = str(Path(__file__).resolve().parent.parent / "src")
if _SRC not in _sys.path:
    _sys.path.insert(0, _SRC)

from g05.utils.websocket import packb, unpackb

import websockets

logger = logging.getLogger(__name__)


# ──────── 映射配置 ────────


class ObsActionMapping:
    """wire(板端)键名 ↔ lerobot 策略特征键名 的双向映射。"""

    def __init__(self, cfg: dict):
        # wire 图像键 → 策略输入键,如 {"head_rgb": "observation.images.head_rgb"}
        self.images: dict[str, str] = cfg["images"]
        # wire 状态部件 → (策略输入键, 维度);若策略用平铺 state,则 concat_key 非空
        self.state_parts: list[dict] = cfg["state_parts"]
        # 平铺观测键(如 "observation.state");为空表示按部件键分别喂
        self.state_concat_key: str | None = cfg.get("state_concat_key")
        # 动作平铺向量的切分布局:[[wire_part, dim], ...],顺序即拼接顺序
        self.action_layout: list[list] = cfg["action_layout"]

    @classmethod
    def load(cls, path: str | Path) -> "ObsActionMapping":
        with open(path, encoding="utf-8") as f:
            return cls(json.load(f))

    @property
    def shape_meta(self) -> dict:
        """握手用:板端只认 raw wire 维度。"""
        return {"action": [{"key": p, "raw_shape": d} for p, d in self.action_layout]}


# ──────── 观测解码 ────────


def _decode_image(v: Any) -> np.ndarray:
    """wire 图像 → uint8[C,H,W]。兼容裸数组与 {"__jpeg__": true, "data": bytes}。"""
    if isinstance(v, dict) and v.get("__jpeg__"):
        import cv2

        buf = np.frombuffer(v["data"], dtype=np.uint8)
        bgr = cv2.imdecode(buf, cv2.IMREAD_COLOR)
        if bgr is None:
            raise ValueError("JPEG 解码失败")
        return np.ascontiguousarray(bgr[:, :, ::-1].transpose(2, 0, 1))  # HWC→CHW
    arr = np.asarray(v)
    if arr.ndim != 3:
        raise ValueError(f"图像必须是 [C,H,W],实际 shape={arr.shape}")
    if arr.dtype != np.uint8:
        arr = arr.astype(np.uint8)
    return arr


# ──────── LeRobot 适配器 ────────


class LerobotAdapter:
    """把 lerobot PreTrainedPolicy 包成 chunk 推理接口。

    观测历史/动作队列一律走策略原生机制(_queues,与 select_action 同路径);
    这里只做 wire obs → 单帧 batch 的组装、归一化与动作拆分。
    """

    def __init__(
        self,
        policy_path: str,
        mapping: ObsActionMapping,
        *,
        device: str = "cuda",
        stats_path: str | None = None,
        default_task: str = "",
    ):
        from lerobot.configs.policies import PreTrainedConfig
        from lerobot.policies.factory import get_policy_class

        self.device = device
        self.mapping = mapping
        self.default_task = default_task

        cfg = PreTrainedConfig.from_pretrained(policy_path)
        cfg.device = device
        policy_cls = get_policy_class(cfg.type)
        self.policy = policy_cls.from_pretrained(policy_path, config=cfg)
        self.policy.eval()

        # 模型 chunk 能力上限(server 再按 --action_steps 截断下发)。
        # 注意 DP 类实际可执行段 = horizon - n_obs_steps + 1(观测占掉头部),
        # 不能只看 config.chunk_size。
        self.n_obs_steps = int(getattr(cfg, "n_obs_steps", 1) or 1)
        cap = int(getattr(cfg, "chunk_size", 0) or 0)
        horizon = int(getattr(cfg, "horizon", 0) or 0)
        if horizon:
            cap = min(cap, horizon - self.n_obs_steps + 1) if cap else (
                horizon - self.n_obs_steps + 1)
        self.chunk_size = cap
        # 策略声明的输入特征(预热取图像尺寸用)
        self.input_features = dict(getattr(cfg, "input_features", {}) or {})
        # 策略声明的图像输入键(保持 config 声明顺序,堆叠成 observation.images)
        self.image_keys = [
            k for k in (getattr(cfg, "input_features", {}) or {})
            if k.startswith("observation.images.")
        ]

        # ── 归一化:优先 ckpt 内嵌 processor,否则 stats.json 手动 ──
        self.preprocessor = None
        self.postprocessor = None
        pdir = Path(policy_path)
        if (pdir / "policy_preprocessor.json").exists() and (
            pdir / "policy_postprocessor.json"
        ).exists():
            from lerobot.processor import PolicyProcessorPipeline

            self.preprocessor = PolicyProcessorPipeline.from_pretrained(
                policy_path, "policy_preprocessor.json"
            )
            self.postprocessor = PolicyProcessorPipeline.from_pretrained(
                policy_path, "policy_postprocessor.json"
            )
            logger.info("使用 ckpt 内嵌 pre/post processor 做归一化")
        else:
            if not stats_path:
                raise ValueError(
                    "ckpt 目录无内嵌 processor(policy_preprocessor.json),"
                    "必须提供 --stats_path(数据集 meta/stats.json)做手动归一化"
                )
            with open(stats_path, encoding="utf-8") as f:
                self.stats = json.load(f)
            logger.info("使用 stats.json 手动归一化: %s", stats_path)

        logger.info(
            "lerobot policy 加载完成: type=%s n_obs_steps=%d chunk_size=%d device=%s",
            cfg.type, self.n_obs_steps, self.chunk_size, device,
        )

    def reset(self):
        """episode 边界/新连接:清空策略观测与动作队列。"""
        self.policy.reset()

    # ── 单帧 batch 组装 ──

    def build_batch(self, raw_obs: dict) -> dict:
        """raw_obs 单帧 → 策略 batch(无时间维;历史由策略 _queues 管)。"""
        m = self.mapping
        images = raw_obs.get("images") or {}
        state = raw_obs.get("state") or {}
        batch: dict[str, Any] = {}

        # 图像:uint8[C,H,W] → float[1,C,H,W]/255,按策略声明的键分发
        for wire_key, pol_key in m.images.items():
            if pol_key not in self.image_keys:
                continue  # 策略没声明的相机不喂
            if wire_key not in images:
                raise ValueError(f"obs 缺图像 '{wire_key}'(策略需要 {pol_key})")
            t = torch.from_numpy(_decode_image(images[wire_key])).float().div_(255.0)
            batch[pol_key] = t.unsqueeze(0).to(self.device)

        # 状态:float32;平铺拼接或按部件键分发
        if m.state_concat_key:
            order = [p["wire"] for p in m.state_parts]
            for k in order:
                if k not in state:
                    raise ValueError(f"obs 缺状态部件 '{k}'")
            vec = np.concatenate(
                [np.asarray(state[k], dtype=np.float32) for k in order]
            )
            batch[m.state_concat_key] = (
                torch.from_numpy(vec).unsqueeze(0).to(self.device)
            )
        else:
            for p in m.state_parts:
                wire_key, pol_key = p["wire"], p["policy"]
                if wire_key not in state:
                    raise ValueError(f"obs 缺状态部件 '{wire_key}'")
                t = torch.from_numpy(np.asarray(state[wire_key], dtype=np.float32))
                batch[pol_key] = t.unsqueeze(0).to(self.device)

        # VLA 类策略的 tokenizer processor 要求 task 键存在(空串也会
        # KeyError);文本缺失时回退 --default_task,都没有且策略带内嵌
        # processor 就直接报清楚的错
        task = raw_obs.get("task") or self.default_task
        if task:
            batch["task"] = [task]
        elif self.preprocessor is not None:
            raise ValueError(
                "该策略需要任务文本:obs 没带 task 且未配 --default_task")
        return batch

    # ── 推理 ──

    def infer_chunk(self, raw_obs: dict) -> np.ndarray:
        """单帧 obs → 动作 chunk np.ndarray[T, D](物理量,已反归一化)。

        两条路径按策略结构自动分流:
        - DP 类(_queues 里有观测队列):多相机堆叠成 observation.images
          入队,predict_action_chunk 从队列堆栈出 [1, n_obs_steps, ...]
        - SmolVLA 类(_queues 只有 action 队列):预处理后的 batch 直接喂,
          图像保持分键 + language tokens 由预处理器产出
        """
        from lerobot.utils.constants import ACTION, OBS_IMAGES

        batch = self.build_batch(raw_obs)
        with torch.inference_mode():
            if self.preprocessor is not None:
                batch = self.preprocessor(batch)
            else:
                batch = self._manual_normalize(batch)

            queues = getattr(self.policy, "_queues", {}) or {}
            if any(k != ACTION for k in queues):
                from lerobot.policies.utils import populate_queues

                b2 = dict(batch)
                if self.image_keys:
                    b2[OBS_IMAGES] = torch.stack(
                        [b2[k] for k in self.image_keys], dim=-4
                    )
                populate_queues(self.policy._queues, b2)
                feed = {k: b2[k] for k in b2 if k in self.policy._queues}
                chunk = self.policy.predict_action_chunk(feed)
            else:
                chunk = self.policy.predict_action_chunk(batch)

            if self.postprocessor is not None:
                chunk = self.postprocessor({"action": chunk})["action"]
            else:
                chunk = self._manual_unnormalize(chunk)
        return chunk[0].float().cpu().numpy()

    # ── 手动归一化(stats.json,无内嵌 processor 时的回退)──

    def _part_stats(self, kind: str, part: str):
        s = self.stats.get(f"{kind}.{part}")
        if not s:
            raise ValueError(f"stats.json 缺 '{kind}.{part}'")
        return (
            np.asarray(s["mean"], dtype=np.float32),
            np.asarray(s["std"], dtype=np.float32),
        )

    def _manual_normalize(self, batch: dict) -> dict:
        m = self.mapping

        def _norm(t, mean, std):
            mean_t = torch.from_numpy(mean).to(t)
            std_t = torch.from_numpy(std + 1e-8).to(t)
            return (t - mean_t) / std_t

        if m.state_concat_key:
            means, stds = [], []
            for p in m.state_parts:
                mean, std = self._part_stats("observation.state", p["wire"])
                means.append(mean)
                stds.append(std)
            batch[m.state_concat_key] = _norm(
                batch[m.state_concat_key], np.concatenate(means), np.concatenate(stds)
            )
        else:
            for p in m.state_parts:
                mean, std = self._part_stats("observation.state", p["wire"])
                batch[p["policy"]] = _norm(batch[p["policy"]], mean, std)
        return batch

    def _manual_unnormalize(self, chunk):
        means, stds = [], []
        for part, _dim in self.mapping.action_layout:
            mean, std = self._part_stats("action", part)
            means.append(mean)
            stds.append(std)
        mean = torch.from_numpy(np.concatenate(means)).to(chunk)
        std = torch.from_numpy(np.concatenate(stds) + 1e-8).to(chunk)
        return chunk * std + mean

    # ── 动作拆分 ──

    def split_parts(self, chunk: np.ndarray) -> dict[str, np.ndarray]:
        out, off = {}, 0
        for part, dim in self.mapping.action_layout:
            out[part] = chunk[:, off : off + dim]
            off += dim
        if off != chunk.shape[1]:
            raise ValueError(
                f"动作维度不匹配:映射合计 {off},模型输出 {chunk.shape[1]}"
            )
        return out


# ──────── WebSocket 服务(chunk-download-v1,与 serve_policy.py 同语义)────────


def _serialize_error(code: int, message: str) -> dict[str, Any]:
    return {"error": {"code": code, "message": message}}


async def handler(ws, adapter: LerobotAdapter, action_steps: int):
    client = ws.remote_address
    logger.info("Client connected: %s (action_steps=%d)", client, action_steps)
    await ws.send(packb({
        "action_steps": action_steps,
        "protocol": "chunk-download-v1",
        "shape_meta": adapter.mapping.shape_meta,
    }))
    adapter.reset()  # 新连接清观测/动作队列

    try:
        async for msg in ws:
            t0 = time.monotonic()
            try:
                raw_obs = unpackb(msg)
                if isinstance(raw_obs, dict) and raw_obs.get("__reset__"):
                    adapter.reset()
                    await ws.send(packb({"__reset__": True}))
                    continue
                if not raw_obs:
                    await ws.send(packb(_serialize_error(400, "chunk-download-v1: 需要 obs")))
                    continue
                chunk = await asyncio.to_thread(adapter.infer_chunk, raw_obs)
                parts = adapter.split_parts(chunk)
                resp = {
                    "action": {k: v[0] for k, v in parts.items()},
                    "need_obs": True,
                    "reserved": {"action_chunk": {
                        k: v[:action_steps] for k, v in parts.items()
                    }},
                }
                await ws.send(packb(resp))
                logger.info(
                    "Recompute: %.1fms (chunk %d 步)",
                    (time.monotonic() - t0) * 1000, chunk.shape[0],
                )
            except ValueError as exc:
                await ws.send(packb(_serialize_error(400, str(exc))))
            except Exception as exc:
                logger.exception("Inference request failed")
                await ws.send(packb(_serialize_error(500, str(exc))))
    except websockets.exceptions.ConnectionClosed:
        logger.info("Client disconnected: %s", client)


# ──────── main ────────


def main():
    parser = argparse.ArgumentParser(
        description="LeRobot policy WebSocket server (chunk-download-v1)"
    )
    parser.add_argument("--policy_path", required=True,
                        help="lerobot ckpt 目录(config.json + model.safetensors)")
    parser.add_argument("--mapping",
                        default=str(Path(__file__).resolve().parent.parent
                                    / "deploy" / "lerobot_a1z_mapping.json"),
                        help="键名映射 JSON")
    parser.add_argument("--stats_path", default=None,
                        help="数据集 meta/stats.json(ckpt 无内嵌 processor 时必填)")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--action_steps", type=int, default=32,
                        help="下发给客户端的 chunk 步数(≤ 模型 chunk_size)")
    parser.add_argument("--default_task", default="",
                        help="obs 未带 task 时的兜底任务文本(VLA 类必填)")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    mapping = ObsActionMapping.load(args.mapping)
    adapter = LerobotAdapter(
        args.policy_path, mapping, device=args.device, stats_path=args.stats_path,
        default_task=args.default_task,
    )

    # 预热:首次推理要初始化 CUDA kernel/cuDNN autotune,直接自推一帧假 obs,
    # 板端连上来就是稳态延迟
    t0 = time.monotonic()
    dummy = {"images": {}, "state": {}, "task": ""}
    for wire_key, pol_key in mapping.images.items():
        if pol_key not in adapter.image_keys:
            continue
        c, h, w = adapter.input_features[pol_key].shape
        dummy["images"][wire_key] = np.zeros((c, h, w), dtype=np.uint8)
    for p in mapping.state_parts:
        dummy["state"][p["wire"]] = np.zeros(p["dim"], dtype=np.float32)
    adapter.infer_chunk(dummy)
    logger.info("预热推理完成: %.0fms", (time.monotonic() - t0) * 1000)
    effective_steps = args.action_steps
    if adapter.chunk_size and args.action_steps > adapter.chunk_size:
        logger.warning(
            "action_steps=%d 超过模型可执行段 %d(DP 类 = horizon - n_obs_steps + 1),自动收敛",
            args.action_steps, adapter.chunk_size,
        )
        effective_steps = adapter.chunk_size
    if effective_steps < 1:
        raise ValueError(f"有效 action_steps={effective_steps},无法服务")

    async def _serve():
        import functools

        bound = functools.partial(handler, adapter=adapter, action_steps=effective_steps)
        async with websockets.serve(bound, args.host, args.port, max_size=None):
            logger.info(
                "LeRobot policy server listening on ws://%s:%d (chunk=%d, device=%s)",
                args.host, args.port, effective_steps, args.device,
            )
            await asyncio.Future()  # run forever

    asyncio.run(_serve())


if __name__ == "__main__":
    main()
