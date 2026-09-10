"""미국 장기 (몇 달 ~ 몇 년): S&P 500 + 나스닥 100, 재무 + 추세 + 상대강도 + 밸류 가드."""
from __future__ import annotations

import json
import logging
from pathlib import Path

import numpy as np
import pandas as pd

from .config import OUTPUT_DIR, load_config
from .fundamentals import get_fundamentals

log = logging.getLogger(__name__)


def _consec_below_sma200(close: pd.Series, sma200: pd.Series) -> int:
    below = (close < sma200).to_numpy()[::-1]
    n = 0
    for b in below:
        if b:
            n += 1
        else:
            break
    return n


def screen_long(ind: dict, universe: pd.DataFrame, pos: int = -1, cfg: dict | None = None,
                force_fund: bool = False, prev_path: Path | None = None,
                exchanges: dict[str, str] | None = None) -> dict:
    """장기 후보 상위 N + 편입/교체 정보. 반환값은 json 으로 그대로 저장 가능한 dict."""
    cfg = cfg or load_config()["us_long"]
    exchanges = exchanges or {}
    f, tr, val, sc = cfg["fundamentals"], cfg["trend"], cfg["value"], cfg["score"]
    dates = ind["close"].index
    if pos < 0:
        pos = len(dates) + pos
    date = dates[pos]
    tickers = [t for t in universe["ticker"] if t in ind["close"].columns]
    missing = [t for t in universe["ticker"] if t not in ind["close"].columns]
    if missing:
        log.warning("[장기] 가격 없음 %d 종목: %s", len(missing), ",".join(missing[:15]))
    fund = get_fundamentals(tickers, force=force_fund)
    sector_wiki = universe.set_index("ticker")["sector"].to_dict()

    c = ind["close"].iloc[pos]
    rows = []
    for t in tickers:
        fr = fund.loc[t] if t in fund.index else None
        get = (lambda k: (None if fr is None or pd.isna(fr.get(k)) else fr.get(k)))
        sector = (get("sector") or sector_wiki.get(t) or "")
        close = float(c[t]) if not pd.isna(c[t]) else np.nan
        s150 = float(ind["sma150"][t].iat[pos])
        s200 = float(ind["sma200"][t].iat[pos])
        s200_prev_pos = pos - tr["sma200_rising_months"] * 21
        s200_prev = float(ind["sma200"][t].iat[s200_prev_pos]) if s200_prev_pos >= 0 else np.nan
        hi52 = float(ind["high52"][t].iat[pos])
        lo52 = float(ind["low52"][t].iat[pos])
        r12x = float(ind["r12m_ex1"][t].iat[pos])
        fin_exempt = any(s.lower() in sector.lower() for s in f["exclude_debt_sectors"]) if sector else False
        roe, rg, om, fcf, de = get("roe"), get("revenue_growth"), get("operating_margin"), get("fcf"), get("debt_to_equity")
        peg, fpe = get("peg"), get("forward_pe")
        cond = {
            "roe": roe is not None and roe >= f["min_roe_pct"],
            "revenue_growth": rg is not None and rg >= f["min_revenue_growth_pct"],
            "operating_margin": om is not None and om >= f["min_operating_margin_pct"],
            "fcf": fcf is not None and fcf > f["min_fcf"],
            "debt_to_equity": True if fin_exempt else (de is not None and de <= f["max_debt_to_equity_pct"]),
            "trend": (not np.isnan(close) and close > s150 > s200 and s200 > s200_prev
                      and close >= hi52 * (1 - tr["below_52w_high_pct"] / 100)
                      and close >= lo52 * (1 + tr["above_52w_low_pct"] / 100)),
            "value": (peg is not None and 0 < peg <= val["max_peg"]) or (fpe is not None and 0 < fpe <= val["max_forward_pe"]),
        }
        rows.append({
            "ticker": t, "name": (get("name") or universe.set_index("ticker")["name"].get(t, "")),
            "exchange": exchanges.get(t, ""),
            "sector": sector, "close": None if np.isnan(close) else round(close, 2),
            "roe": None if roe is None else round(roe, 1),
            "revenue_growth": None if rg is None else round(rg, 1),
            "operating_margin": None if om is None else round(om, 1),
            "fcf": None if fcf is None else round(fcf),
            "debt_to_equity": None if de is None else round(de, 1),
            "peg": None if peg is None else round(peg, 2),
            "forward_pe": None if fpe is None else round(fpe, 1),
            "r12m_ex1": None if np.isnan(r12x) else round(r12x, 1),
            "pct_from_52w_high": None if np.isnan(hi52) or np.isnan(close) else round((close / hi52 - 1) * 100, 1),
            "sma200": None if np.isnan(s200) else round(s200, 2),
            "days_below_sma200": _consec_below_sma200(ind["close"][t].iloc[:pos + 1], ind["sma200"][t].iloc[:pos + 1]),
            "next_earnings": get("next_earnings"),
            "fin_exempt": fin_exempt,
            "_cond": cond,
        })
    df = pd.DataFrame(rows).set_index("ticker")
    # 상대강도: R12M_ex1 유니버스 상위 N%
    rs_pct = df["r12m_ex1"].rank(pct=True) * 100
    df["rs_pct"] = rs_pct
    for t in df.index:
        df.at[t, "_cond"]["rs"] = bool(rs_pct[t] >= 100 - tr["r12m_ex1_top_pct"]) if not pd.isna(rs_pct[t]) else False
    # 점수: 재무 순위 50% + R12M_ex1 순위 50%
    fund_rank = pd.concat([df["roe"].rank(pct=True), df["revenue_growth"].rank(pct=True),
                           df["operating_margin"].rank(pct=True)], axis=1).mean(axis=1) * 100
    df["fund_score"] = fund_rank
    df["score"] = sc["fundamental_weight"] * fund_rank + sc["momentum_weight"] * rs_pct
    df["passed"] = df["_cond"].apply(lambda d: [k for k, v in d.items() if v])
    df["pass_all"] = df["_cond"].apply(lambda d: all(d.values()))
    passing = df[df["pass_all"]].sort_values("score", ascending=False)
    passing = passing.assign(rank=range(1, len(passing) + 1))
    log.info("[장기] %s 유니버스 %d, 재무 %d, 전체 통과 %d", date.date(), len(df),
             int(df["_cond"].apply(lambda d: all(d[k] for k in ("roe", "revenue_growth", "operating_margin", "fcf", "debt_to_equity"))).sum()),
             len(passing))

    top = passing.head(cfg["top_n"])
    hold_n = cfg["hold_n"]

    def rec(t, r):
        d = {k: (None if isinstance(v, float) and np.isnan(v) else v) for k, v in r.items() if not k.startswith("_")}
        d["ticker"] = t
        d["score"] = round(float(r["score"]), 1) if not pd.isna(r["score"]) else None
        d["fund_score"] = round(float(r["fund_score"]), 1) if not pd.isna(r["fund_score"]) else None
        d["rs_pct"] = round(float(r["rs_pct"]), 1) if not pd.isna(r["rs_pct"]) else None
        d["rank"] = int(r["rank"]) if "rank" in r and not pd.isna(r["rank"]) else None
        d["hold"] = bool(d["rank"] is not None and d["rank"] <= hold_n)
        d["conditions"] = r["_cond"]
        return d

    top_rows = [rec(t, r) for t, r in top.iterrows()]

    # 이전 결과와 비교 → 교체 후보
    prev_path = prev_path or (OUTPUT_DIR / "us_long.json")
    prev_hold: list[str] = []
    prev_top: list[str] = []
    prev_date = None
    if prev_path.exists():
        try:
            prev = json.loads(prev_path.read_text(encoding="utf-8"))
            prev_hold = [r["ticker"] for r in prev.get("candidates", []) if r.get("hold")]
            prev_top = [r["ticker"] for r in prev.get("candidates", [])]
            prev_date = prev.get("date")
        except Exception:  # noqa: BLE001
            pass
    rank_map = passing["rank"].to_dict()
    rep = cfg["replace"]
    holdings_status = []
    for t in prev_hold:
        rk = rank_map.get(t)
        below = int(df.at[t, "days_below_sma200"]) if t in df.index else None
        reasons = []
        if below is not None and below >= rep["below_sma200_days"]:
            reasons.append(f"SMA200 아래 {below}거래일")
        if rk is None or rk > rep["rank_out"]:
            reasons.append("순위 10위 밖" if rk is None else f"순위 {rk}위")
        holdings_status.append({"ticker": t, "rank": rk, "days_below_sma200": below,
                                "replace": bool(reasons), "reason": ", ".join(reasons)})
    cur_top = [r["ticker"] for r in top_rows]
    return {
        "date": str(date.date()),
        "generated_at": pd.Timestamp.now("UTC").strftime("%Y-%m-%dT%H:%M:%SZ"),
        "universe_size": len(df),
        "fundamentals_ok": int(fund[["roe", "revenue_growth", "operating_margin"]].notna().all(axis=1).sum()) if len(fund) else 0,
        "pass_all": len(passing),
        "hold_n": hold_n,
        "candidates": top_rows,
        "holdings": cur_top[:hold_n],
        "previous_date": prev_date,
        "previous_holdings": holdings_status,
        "entered": [t for t in cur_top if t not in prev_top],
        "exited": [t for t in prev_top if t not in cur_top],
    }
