"""매일 1픽 선정 + 성적표(앞으로의 검증).

1픽 규칙(단기 돌파 대기 후보 중): 다음 4가지 순위의 평균이 가장 좋은 종목
  - R3M 높을수록 (모멘텀)
  - 횡보 폭(box_range_pct) 좁을수록
  - 거래량 감소율(vol_recent / vol_before_peak) 낮을수록
  - 종가가 트리거가에 가까울수록 (close / trigger)
결과는 output/us_picks.json 에 매일 1줄씩 쌓이고, 다음 날부터 자동 채점된다.

채점 규칙(SPEC 4-2, 4-4 그대로):
  - 선정 다음 거래일(t) 고가 > 트리거가 이면 발동. 진입가 = max(t 시가, 트리거가). 트리거가보다 5% 넘게 높으면 '건너뜀'
  - 손절: 진입일 종가 < stop 이면 손절. 이후 저가 < stop 이면 stop, 시가부터 stop 아래면 시가
  - 3번째 거래일 종가 절반 매도, 남은 물량 stop = 진입가. 종가 < SMA10 전량 청산. 최대 60일
  - 아직 보유 중이면 '진행 중'으로 현재 손익 표시
"""
from __future__ import annotations

import json
import logging
from datetime import datetime, timezone

import numpy as np
import pandas as pd

from .config import OUTPUT_DIR, load_config

log = logging.getLogger(__name__)
PATH = OUTPUT_DIR / "us_picks.json"


def choose_pick(rows: list[dict]) -> dict | None:
    """돌파 대기 목록에서 1픽 선정. 각 항목에 pick_score/pick_rank 를 채우고 1위를 돌려준다."""
    if not rows:
        return None
    df = pd.DataFrame(rows)
    if "vol_recent" not in df.columns:
        df["vol_recent"] = np.nan
    ranks = pd.DataFrame({
        "mom": df["r3m"].rank(ascending=False),
        "box": df["box_range_pct"].rank(ascending=True),
        "vol": (df["vol_recent"] / df["vol_before_peak"]).rank(ascending=True) if "vol_before_peak" in df.columns else df["box_range_pct"].rank(),
        "near": (df["close"] / df["trigger_price"]).rank(ascending=False),
    })
    df["pick_score"] = ranks.mean(axis=1)
    df["pick_rank"] = df["pick_score"].rank(method="first").astype(int)
    for i, r in enumerate(rows):
        r["pick_score"] = round(float(df["pick_score"].iat[i]), 2)
        r["pick_rank"] = int(df["pick_rank"].iat[i])
    best = int(df["pick_rank"].idxmin())
    rows[best]["is_pick"] = True
    return rows[best]


def pick_reason(r: dict) -> str:
    parts = [f"3개월 +{r.get('r3m')}% (후보 중 모멘텀 상위)",
             f"급등 +{r.get('runup_pct')}% 뒤 {r.get('box_days')}일 횡보, 폭 {r.get('box_range_pct')}%"]
    if r.get("vol_recent") and r.get("vol_before_peak"):
        parts.append(f"거래량 급등기 대비 {round(r['vol_recent'] / r['vol_before_peak'] * 100)}% 로 감소")
    if r.get("close") and r.get("trigger_price"):
        parts.append(f"종가가 트리거가의 {round(r['close'] / r['trigger_price'] * 100, 1)}% 위치")
    return " · ".join(parts)


def load_picks() -> dict:
    if PATH.exists():
        try:
            return json.loads(PATH.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            pass
    return {"picks": []}


def add_today_pick(pick: dict | None, date: str, candidates: list[dict]) -> dict:
    j = load_picks()
    picks = [p for p in j["picks"] if p.get("date") != date]
    if pick:
        picks.append({
            "date": date, "ticker": pick["ticker"], "name": pick.get("name", ""), "setup": "breakout",
            "trigger_price": pick["trigger_price"], "stop_price": pick["stop_price"], "stop_pct": pick.get("stop_pct"),
            "reason": pick_reason(pick), "candidates": [c["ticker"] for c in candidates],
            "status": "대기", "result": None,
        })
    j["picks"] = picks[-400:]
    return j


def grade_picks(j: dict, w: dict, cfg: dict | None = None) -> dict:
    """가격 데이터(wide)로 과거 1픽을 채점."""
    cfg = cfg or load_config()["us_short"]
    ex = cfg["exit"]
    close, high, low, opn = w["close"], w["high"], w["low"], w["open"]
    sma10 = close.rolling(ex["trail_sma"]).mean()
    dates = close.index
    for p in j["picks"]:
        tk = p["ticker"]
        if tk not in close.columns:
            continue
        d0 = pd.Timestamp(p["date"])
        after = dates[dates > d0]
        if len(after) == 0:
            p["status"], p["result"] = "대기", None
            continue
        t = after[0]
        trig, stop0 = float(p["trigger_price"]), float(p["stop_price"])
        h, o = float(high.at[t, tk]), float(opn.at[t, tk])
        if np.isnan(h) or not (h > trig):
            p["status"] = "미발동"
            p["result"] = {"entry_date": None, "note": "다음 날 트리거가를 넘지 못함",
                           "next_close": None if np.isnan(close.at[t, tk]) else round(float(close.at[t, tk]), 2)}
            continue
        entry = max(o, trig)
        if entry > trig * (1 + cfg["breakout"]["max_above_box_pct"] / 100):
            p["status"] = "건너뜀"
            p["result"] = {"entry_date": str(t.date()), "note": f"시가가 트리거가보다 {round((o / trig - 1) * 100, 1)}% 높아 진입 안 함"}
            continue
        stop = entry * (1 - float(p["stop_pct"] or 0) / 100) if p.get("stop_pct") else stop0
        qty_frac, realized, pnl_parts = 1.0, 0.0, []
        exit_date, exit_reason = None, None
        idx = list(dates).index(t)
        # 진입일: 종가 < stop → 손절
        c0 = float(close.at[t, tk])
        if c0 < stop:
            exit_date, exit_reason = t, "진입일 손절"
            realized = (c0 / entry - 1) * 100
            qty_frac = 0.0
        else:
            for k in range(1, ex["max_hold_days"] + 1):
                if idx + k >= len(dates):
                    break
                d = dates[idx + k]
                lo, op, cl = float(low.at[d, tk]), float(opn.at[d, tk]), float(close.at[d, tk])
                if np.isnan(cl):
                    continue
                if op < stop:
                    px = op
                    realized += qty_frac * (px / entry - 1) * 100
                    exit_date, exit_reason, qty_frac = d, "갭하락 손절(시가)", 0.0
                    break
                if lo < stop:
                    px = stop
                    realized += qty_frac * (px / entry - 1) * 100
                    exit_date, exit_reason, qty_frac = d, "손절", 0.0
                    break
                if k == ex["partial_day"] and qty_frac == 1.0:
                    realized += ex["partial_frac"] * (cl / entry - 1) * 100
                    qty_frac -= ex["partial_frac"]
                    stop = entry
                    pnl_parts.append(f"{k}일째 절반 매도 {round((cl / entry - 1) * 100, 1)}%")
                s10 = float(sma10.at[d, tk]) if not np.isnan(sma10.at[d, tk]) else None
                if s10 is not None and cl < s10:
                    realized += qty_frac * (cl / entry - 1) * 100
                    exit_date, exit_reason, qty_frac = d, "SMA10 이탈", 0.0
                    break
                if k >= ex["max_hold_days"]:
                    realized += qty_frac * (cl / entry - 1) * 100
                    exit_date, exit_reason, qty_frac = d, "60일 만료", 0.0
                    break
        last_close = float(close[tk].dropna().iloc[-1])
        open_pnl = qty_frac * (last_close / entry - 1) * 100
        total = realized + open_pnl
        r_mult = total / ((entry - (entry * (1 - float(p["stop_pct"]) / 100) if p.get("stop_pct") else stop0)) / entry * 100) if entry else None
        p["status"] = "종료" if qty_frac == 0.0 else "진행 중"
        p["result"] = {
            "entry_date": str(t.date()), "entry_price": round(entry, 4),
            "exit_date": None if exit_date is None else str(exit_date.date()), "exit_reason": exit_reason,
            "pnl_pct": round(total, 2), "r_multiple": None if r_mult is None else round(r_mult, 2),
            "remaining_frac": qty_frac, "last_close": round(last_close, 4), "notes": pnl_parts,
        }
    # 요약
    done = [p for p in j["picks"] if p.get("status") in ("종료", "진행 중") and p.get("result") and p["result"].get("pnl_pct") is not None]
    trig = [p for p in j["picks"] if p.get("status") in ("종료", "진행 중", "건너뜀")]
    wins = [p for p in done if p["result"]["pnl_pct"] > 0]
    j["summary"] = {
        "total": len(j["picks"]), "triggered": len(trig), "not_triggered": sum(1 for p in j["picks"] if p.get("status") == "미발동"),
        "closed": sum(1 for p in j["picks"] if p.get("status") == "종료"), "open": sum(1 for p in j["picks"] if p.get("status") == "진행 중"),
        "win_rate": round(len(wins) / len(done) * 100, 1) if done else None,
        "avg_pnl_pct": round(float(np.mean([p["result"]["pnl_pct"] for p in done])), 2) if done else None,
        "avg_r": round(float(np.mean([p["result"]["r_multiple"] for p in done if p["result"].get("r_multiple") is not None])), 2) if done else None,
        "sum_pnl_pct": round(float(np.sum([p["result"]["pnl_pct"] for p in done])), 2) if done else None,
    }
    j["generated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return j


def save_picks(j: dict) -> None:
    PATH.write_text(json.dumps(j, ensure_ascii=False, indent=1, default=str), encoding="utf-8")
