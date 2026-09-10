"""미국 중기 (몇 주 ~ 몇 달): 추세 눌림목 (미너비니 트렌드 템플릿 + 눌림 + 반등 첫날)."""
from __future__ import annotations

import logging

import numpy as np
import pandas as pd

from .config import load_config
from .sizing import position_qty

log = logging.getLogger(__name__)


def universe_mask(ind: dict, pos: int, cfg: dict) -> pd.Series:
    u = cfg["universe"]
    close = ind["close"].iloc[pos]
    adr = ind["adr20"].iloc[pos]
    return (
        (close >= u["min_close"])
        & (ind["dv20"].iloc[pos] >= u["min_dv20"])
        & (adr >= u["adr_min"]) & (adr <= u["adr_max"])
    ).fillna(False)


def trend_mask(ind: dict, pos: int, cfg: dict, universe: pd.Series) -> pd.Series:
    t = cfg["trend"]
    c = ind["close"].iloc[pos]
    s50, s150, s200 = ind["sma50"].iloc[pos], ind["sma150"].iloc[pos], ind["sma200"].iloc[pos]
    s200_prev = ind["sma200"].iloc[pos - t["sma200_rising_days"]]
    hi52, lo52 = ind["high52"].iloc[pos], ind["low52"].iloc[pos]
    r6m = ind["r6m"].iloc[pos]
    r6m_pct = r6m[universe].rank(pct=True) * 100  # 유니버스 내 백분위
    m = (
        (c > s50) & (s50 > s150) & (s150 > s200) & (s200 > s200_prev)
        & (c >= lo52 * (1 + t["above_52w_low_pct"] / 100))
        & (c >= hi52 * (1 - t["below_52w_high_pct"] / 100))
        & (r6m_pct.reindex(c.index) >= 100 - t["r6m_top_pct"])
    )
    return m.fillna(False)


def pullback_mask(ind: dict, pos: int, cfg: dict) -> pd.Series:
    p = cfg["pullback"]
    c = ind["close"].iloc[pos]
    hi20 = ind["high"].rolling(p["high_window"]).max().iloc[pos]
    dd = c / hi20 - 1
    s20, s50 = ind["sma20"].iloc[pos], ind["sma50"].iloc[pos]
    adr = ind["adr20"].iloc[pos] / 100
    m = (
        (dd <= -p["min_pct"] / 100) & (dd >= -p["max_pct"] / 100)
        & (c >= s50)
        & ((c / s20 - 1).abs() <= p["sma20_adr_mult"] * adr)
    )
    return m.fillna(False)


def trigger_mask(ind: dict, pos: int) -> pd.Series:
    """당일 종가 > 전일 고가 (반등 첫날)."""
    return (ind["close"].iloc[pos] > ind["high"].iloc[pos - 1]).fillna(False)


def screen_mid(ind: dict, names: dict[str, str], pos: int = -1, cfg: dict | None = None,
               capital: float | None = None, exchanges: dict[str, str] | None = None) -> list[dict]:
    cfg = cfg or load_config()["us_mid"]
    exchanges = exchanges or {}
    money, ex = cfg["money"], cfg["exit"]
    capital = capital if capital is not None else money["capital"]
    dates = ind["close"].index
    if pos < 0:
        pos = len(dates) + pos
    date = dates[pos]
    um = universe_mask(ind, pos, cfg)
    tm = trend_mask(ind, pos, cfg, um)
    pm = pullback_mask(ind, pos, cfg)
    tr = trigger_mask(ind, pos)
    ok = um & tm & pm & tr
    tickers = list(ok.index[ok.to_numpy()])
    log.info("[중기] %s 유니버스 %d, 추세 %d, 눌림 %d, 트리거 %d", date.date(), int(um.sum()),
             int((um & tm).sum()), int((um & tm & pm).sum()), len(tickers))
    low_n = ind["low"].rolling(ex["stop_low_days"]).min().iloc[pos]
    rows = []
    for tk in tickers:
        entry = float(ind["close"][tk].iat[pos])
        stop = float(low_n[tk]) * ex["stop_mult"]
        stop = max(stop, entry * (1 - ex["stop_max_pct"] / 100))
        risk = entry - stop
        if risk <= 0:
            continue
        target = entry + ex["target_r"] * risk
        s20 = float(ind["sma20"][tk].iat[pos])
        rows.append({
            "date": str(date.date()), "ticker": tk, "name": names.get(tk, ""), "exchange": exchanges.get(tk, ""),
            "entry_price": round(entry, 4), "stop_price": round(stop, 4),
            "stop_pct": round(risk / entry * 100, 2), "target_2r": round(target, 4),
            "adr20": round(float(ind["adr20"][tk].iat[pos]), 2),
            "r6m": round(float(ind["r6m"][tk].iat[pos]), 1),
            "r3m": round(float(ind["r3m"][tk].iat[pos]), 1),
            "dist_sma20": round((entry / s20 - 1) * 100, 2),
            "dist_sma50": round((entry / float(ind["sma50"][tk].iat[pos]) - 1) * 100, 2),
            "pct_from_20d_high": round((entry / float(ind["high"][tk].iloc[pos - cfg["pullback"]["high_window"] + 1:pos + 1].max()) - 1) * 100, 2),
            "dv20": round(float(ind["dv20"][tk].iat[pos])),
            "qty": position_qty(entry, stop, capital, money["risk_pct"], money["max_position_pct"]),
            "score": round(float(ind["r6m"][tk].iat[pos]), 1),
        })
    rows.sort(key=lambda r: r["score"], reverse=True)
    return rows
