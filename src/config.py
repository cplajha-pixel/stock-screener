"""config.yaml 로더 + 공통 경로."""
from __future__ import annotations

import os
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
OUTPUT_DIR = ROOT / "output"
CONFIG_PATH = ROOT / "config.yaml"

DATA_DIR.mkdir(exist_ok=True)
OUTPUT_DIR.mkdir(exist_ok=True)

_cfg_cache: dict | None = None


def load_config(path: Path | None = None) -> dict:
    """config.yaml 을 읽어 dict 로 돌려준다 (한 번 읽으면 캐시)."""
    global _cfg_cache
    if _cfg_cache is not None and path is None:
        return _cfg_cache
    p = path or CONFIG_PATH
    with open(p, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    if path is None:
        _cfg_cache = cfg
    return cfg


def env_flag(name: str, default: bool = False) -> bool:
    v = os.environ.get(name)
    if v is None:
        return default
    return v.strip().lower() in ("1", "true", "yes", "y", "on")
