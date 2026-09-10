"""미국 단기 (며칠 ~ 2주): 셋업 A 돌파(Breakout) + 셋업 B 에피소딕 피벗(EP).

모든 판단은 wide 지표 프레임(index=date, columns=ticker)의 정수 위치 `pos`(= t-1, 기본 마지막 날) 기준.
"""
from __future__ import annotations

import logging
from datetime import datetime

import numpy as np
import pandas as pd

from .config import load_config
from .data import intraday_1m_summary, now_et
from .sizing import position_qty

log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# 4-1 유니버스
# ---------------------------------------------------------------------------

def liquidity_mask(ind: dict, pos: int, cfg: dict) -> pd.Series:
    """종가/DV20/ADR20 조건 (모멘텀 제외)."""
    u = cfg["universe"]
    close = ind["close"].iloc[pos]
    return (
        (close >= u["min_close"])
        & (ind["dv20"].iloc[pos] >= u["min_dv20"])
        & (ind["adr20"].iloc[pos] >= u["min_adr20"])
    ).fillna(False)


def momentum_mask(ind: dict, pos: int, cfg: dict, override: dict[str, pd.Series] | None = None) -> pd.Series:
    """R1M/R3M/R6M 중 하나라도 그날 전체 종목 중 상위 N%."""
    top = cfg["universe"]["momentum_top_pct"]
    ok = None
    for k in ("r1m", "r3m", "r6m"):
        s = ind[k].iloc[pos].copy()
        if override and k in override:
            s.update(override[k])
        pct = s.rank(pct=True) * 100
        m = (pct >= 100 - top).fillna(False)
        ok = m if ok is None else (ok | m)
    return ok


def universe_mask(ind: dict, pos: int, cfg: dict) -> pd.Series:
    return liquidity_mask(ind, pos, cfg) & momentum_mask(ind, pos, cfg)


def stop_pct_for(adr20: float, cfg: dict) -> float:
    e = cfg["exit"]
    return float(np.clip(max(adr20, e["stop_floor_pct"]), e["stop_min_pct"], e["stop_max_pct"]))


# ---------------------------------------------------------------------------
# 4-2 셋업 A - 돌파
# ---------------------------------------------------------------------------

def breakout_setup(ind: dict, ticker: str, pos: int, cfg: dict) -> dict | None:
    """pos(= t-1)까지 데이터로 '내일 돌파를 기다리는' 셋업인지 판정. 통과하면 상세 dict."""
    b = cfg["breakout"]
    h = ind["high"][ticker].to_numpy()
    l = ind["low"][ticker].to_numpy()
    c = ind["close"][ticker].to_numpy()
    v = ind["volume"][ticker].to_numpy()
    n = len(c)
    if pos < 0:
        pos = n + pos
    t = pos + 1  # 내일
    need = b["peak_window_start"] + b["trough_lookback"] + 5
    if pos < need:
        return None
    ws, we = t - b["peak_window_start"], t - b["peak_window_end"]  # inclusive
    if ws < b["trough_lookback"] or we > pos:
        return None
    seg = h[ws:we + 1]
    if np.isnan(seg).all():
        return None
    peak_pos = ws + int(np.nanargmax(seg))
    peak = h[peak_pos]
    trough = np.nanmin(l[peak_pos - b["trough_lookback"]:peak_pos])
    if not (trough > 0 and peak / trough - 1 >= b["min_runup_pct"] / 100):
        return None
    box_days = pos - peak_pos
    if not (b["box_min_days"] <= box_days <= b["box_max_days"]):
        return None
    box_high = np.nanmax(h[peak_pos + 1:pos + 1])
    box_low = np.nanmin(l[peak_pos + 1:pos + 1])
    if not (box_low > 0 and box_high / box_low - 1 <= b["box_max_range_pct"] / 100):
        return None
    vol_recent = np.nanmean(v[pos - b["vol_recent_days"] + 1:pos + 1])
    vol_before = np.nanmean(v[peak_pos - b["vol_before_peak_days"]:peak_pos])
    if not (vol_recent < vol_before):
        return None
    sma20 = ind[f"sma{b['trend_sma']}"][ticker].iat[pos]
    sma10 = ind["sma10"][ticker].to_numpy()
    adr = ind["adr20"][ticker].iat[pos]
    if np.isnan(sma20) or np.isnan(adr):
        return None
    if not (c[pos] >= sma20 * (1 - b["trend_adr_mult"] * adr / 100)):
        return None
    if not (sma10[pos] > sma10[pos - b["sma10_rising_days"]]):
        return None
    return {
        "peak": float(peak), "trough": float(trough), "runup_pct": float((peak / trough - 1) * 100),
        "box_high": float(box_high), "box_low": float(box_low), "box_days": int(box_days),
        "box_range_pct": float((box_high / box_low - 1) * 100),
        "vol_recent": float(vol_recent), "vol_before_peak": float(vol_before),
    }


def screen_breakout(ind: dict, names: dict[str, str], pos: int = -1, cfg: dict | None = None,
                    capital: float | None = None, exchanges: dict[str, str] | None = None) -> list[dict]:
    """돌파 대기 목록 (내일 box_high 돌파 시 진입)."""
    cfg = cfg or load_config()["us_short"]
    exchanges = exchanges or {}
    money = cfg["money"]
    capital = capital if capital is not None else money["capital"]
    dates = ind["close"].index
    if pos < 0:
        pos = len(dates) + pos
    date = dates[pos]
    um = universe_mask(ind, pos, cfg)
    tickers = list(um.index[um.to_numpy()])
    log.info("[단기] %s 유니버스 %d 종목", date.date(), len(tickers))
    rows = []
    for tk in tickers:
        s = breakout_setup(ind, tk, pos, cfg)
        if not s:
            continue
        adr = float(ind["adr20"][tk].iat[pos])
        sp = stop_pct_for(adr, cfg)
        trigger = s["box_high"]
        stop = trigger * (1 - sp / 100)
        rows.append({
            "date": str(date.date()), "ticker": tk, "name": names.get(tk, ""), "exchange": exchanges.get(tk, ""),
            "setup": "breakout",
            "trigger_price": round(trigger, 4), "max_entry_price": round(trigger * (1 + cfg["breakout"]["max_above_box_pct"] / 100), 4),
            "stop_price": round(stop, 4), "stop_pct": round(sp, 2),
            "close": round(float(ind["close"][tk].iat[pos]), 4),
            "adr20": round(adr, 2),
            "r1m": round(float(ind["r1m"][tk].iat[pos]), 1),
            "r3m": round(float(ind["r3m"][tk].iat[pos]), 1),
            "r6m": round(float(ind["r6m"][tk].iat[pos]), 1),
            "dv20": round(float(ind["dv20"][tk].iat[pos])),
            "box_low": round(s["box_low"], 4), "box_days": s["box_days"],
            "box_range_pct": round(s["box_range_pct"], 1), "runup_pct": round(s["runup_pct"], 1),
            "vol_recent": round(s["vol_recent"]), "vol_before_peak": round(s["vol_before_peak"]),
            "sma10": round(float(ind["sma10"][tk].iat[pos]), 4), "sma20": round(float(ind["sma20"][tk].iat[pos]), 4),
            "peak": round(s["peak"], 4),
            "qty": position_qty(trigger, stop, capital, money["risk_pct"], money["max_position_pct"]),
            "score": round(float(ind["r3m"][tk].iat[pos]), 1),
        })
    rows.sort(key=lambda r: (r["score"] if r["score"] == r["score"] else -1e9), reverse=True)
    return rows


# ---------------------------------------------------------------------------
# 4-3 셋업 B - 에피소딕 피벗 (장중 실행)
# ---------------------------------------------------------------------------

def _minutes_elapsed(last_bar_time: datetime) -> float:
    open_min = 9 * 60 + 30
    m = last_bar_time.hour * 60 + last_bar_time.minute + 1  # 마지막 봉 포함
    return max(1.0, min(390.0, m - open_min))


def screen_ep(ind: dict, names: dict[str, str], cfg: dict | None = None,
              capital: float | None = None, max_1m_fetch: int = 150,
              exchanges: dict[str, str] | None = None) -> list[dict]:
    """당일 EP 후보. 1분봉 없는 종목은 건너뜀."""
    cfg = cfg or load_config()["us_short"]
    exchanges = exchanges or {}
    ep, money = cfg["ep"], cfg["money"]
    capital = capital if capital is not None else money["capital"]
    pos = len(ind["close"].index) - 1
    prev_date = ind["close"].index[pos]
    n = now_et()
    today = pd.Timestamp(n.date())
    if n.weekday() >= 5 or today <= prev_date:
        log.warning("[EP] 오늘(%s) 봉이 아직 없거나 이미 t-1(%s)에 포함됨 → 건너뜀", today.date(), prev_date.date())
        return []
    lm = liquidity_mask(ind, pos, cfg)
    cands = list(lm.index[lm.to_numpy()])
    log.info("[EP] 유동성 통과 %d 종목 (t-1 = %s)", len(cands), prev_date.date())
    if not cands:
        return []
    # 오늘 1분봉 요약 (시가 = 첫 1분봉 시가, 누적 거래량). 1분봉 없는 종목은 자동 제외
    bars = intraday_1m_summary(cands, today, label="[EP] 1분봉")
    if bars.empty:
        log.warning("[EP] 오늘 1분봉이 없음 (장 시작 전이거나 휴장)")
        return []
    prev_close = ind["close"].iloc[pos]
    bars["prev_close"] = bars["ticker"].map(prev_close)
    bars["gap"] = bars["open"] / bars["prev_close"]
    gap = bars[(bars["gap"] >= ep["min_gap"]) & (bars["gap"] <= ep["max_gap"])].copy()
    log.info("[EP] 갭 +%d%%~+%d%% : %d 종목", int(round((ep["min_gap"] - 1) * 100)),
             int(round((ep["max_gap"] - 1) * 100)), len(gap))
    # 소외: t-1 기준 R3M <= 25%
    gap["r3m"] = gap["ticker"].map(ind["r3m"].iloc[pos])
    gap = gap[gap["r3m"] <= ep["max_r3m_pct"]]
    # 거래량: 누적 거래량을 하루치로 환산해서 Vol20 x 5 이상
    gap["vol20"] = gap["ticker"].map(ind["vol20"].iloc[pos])
    gap["vol_est"] = gap["cum_volume"] * ep["session_minutes"] / gap["minutes_elapsed"]
    gap = gap[(gap["vol20"] > 0) & (gap["vol_est"] >= gap["vol20"] * ep["vol_mult"])]
    log.info("[EP] 소외 + 거래량 통과 %d 종목", len(gap))

    # 모멘텀 상위 2% (현재가 반영)
    if ep.get("apply_momentum_filter", True) and not gap.empty:
        ov = {}
        cur = gap.set_index("ticker")["last"]
        for k, sh in (("r1m", 21), ("r3m", 63), ("r6m", 126)):
            if pos - sh + 1 < 0:
                continue
            base = ind["close"].iloc[pos - sh + 1]
            ov[k] = (cur / base.reindex(cur.index) - 1) * 100
        mm = momentum_mask(ind, pos, cfg, override=ov)
        gap = gap[gap["ticker"].map(mm).fillna(False).astype(bool)]
        log.info("[EP] 모멘텀 상위 %s%% 통과 %d 종목", cfg["universe"]["momentum_top_pct"], len(gap))

    rows = []
    for _, g in gap.iterrows():
        tk = g["ticker"]
        today_open = float(g["open"])
        entry = today_open * ep["entry_mult"]
        adr = float(ind["adr20"][tk].iat[pos])
        sp = stop_pct_for(adr, cfg)
        stop = entry * (1 - sp / 100)
        v20 = float(g["vol20"])
        rows.append({
            "date": str(today.date()), "ticker": tk, "name": names.get(tk, ""), "exchange": exchanges.get(tk, ""),
            "setup": "ep",
            "trigger_price": round(entry, 4), "stop_price": round(stop, 4), "stop_pct": round(sp, 2),
            "open": round(today_open, 4), "high_so_far": round(float(g["high"]), 4), "last": round(float(g["last"]), 4),
            "prev_close": round(float(g["prev_close"]), 4), "gap_pct": round((float(g["gap"]) - 1) * 100, 1),
            "vol_est": round(float(g["vol_est"])), "vol20": round(v20), "vol_mult": round(float(g["vol_est"]) / v20, 1),
            "minutes_elapsed": int(g["minutes_elapsed"]), "triggered": bool(float(g["high"]) >= entry),
            "adr20": round(adr, 2),
            "r1m": round(float(ind["r1m"][tk].iat[pos]), 1),
            "r3m": round(float(g["r3m"]), 1),
            "r6m": round(float(ind["r6m"][tk].iat[pos]), 1),
            "dv20": round(float(ind["dv20"][tk].iat[pos])),
            "qty": position_qty(entry, stop, capital, money["risk_pct"], money["max_position_pct"]),
            "score": round(float(g["r3m"]), 1),
            "asof_et": str(g["last_time"]),
        })
    rows.sort(key=lambda r: (r["triggered"], r["score"]), reverse=True)
    return rows


def ep_run_window_ok(cfg: dict | None = None) -> bool:
    """자동 실행 시 EP 실행 가능 시간(미국 동부)인지."""
    cfg = cfg or load_config()["us_short"]
    a, b = cfg["ep"]["run_window_et"]
    n = now_et()
    if n.weekday() >= 5:
        return False
    t = n.strftime("%H:%M")
    return a <= t <= b
