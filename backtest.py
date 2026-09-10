"""백테스트 (SPEC §10).

  python backtest.py --short   # 단기 돌파 + EP, 2016-01-01 ~ 오늘, 초기 자산 $700
  python backtest.py --mid     # 중기 눌림목, 초기 자산 $3,500
  python backtest.py --long    # 장기 월별 리밸런스 (상위 5 동일비중) vs SPY
  옵션: --start 2016-01-01 --pick (단기: 매일 1픽만 매매하는 변형도 함께)

출력: output/report_short.md, report_mid.md, report_long.md (한국어), output/equity_*.png, output/trades_*.csv
"""
from __future__ import annotations

import argparse
import logging
import math
import sys
from datetime import datetime

import numpy as np
import pandas as pd

from src.config import OUTPUT_DIR, load_config
from src.data import get_daily, to_wide
from src.indicators import compute
from src.universe import long_universe, us_common_stocks
from src.us_short import breakout_setup, stop_pct_for
from src.picks import choose_pick

log = logging.getLogger("backtest")

CAVEATS = (
    "- **생존 편향**: yfinance 에는 상장폐지 종목이 없어 실제보다 결과가 좋게 나옵니다.\n"
    "- **EP 거래량**: 백테스트는 당일 전체 거래량을 써서(장중에는 알 수 없는 값) 미래 정보가 약간 섞입니다.\n"
    "- **수수료·슬리피지**: 편도 0.25% + 0.2% 를 진입·청산 모두에 적용했습니다.\n"
    "- 과거 성과는 미래 수익을 보장하지 않습니다.\n"
)


# ---------------------------------------------------------------------------
# 공통: 지표 (float32 로 메모리 절약)
# ---------------------------------------------------------------------------

def load_wide(start: str, tickers: list[str] | None = None, name: str = "us_full") -> tuple[dict, pd.DataFrame]:
    uni = us_common_stocks()
    tk = tickers or uni["ticker"].tolist()
    df = get_daily(tk, start="2015-01-01", name=name, offline=False)
    w = to_wide(df)
    ind = compute(w)
    for k, v in list(ind.items()):
        ind[k] = v.astype("float32")
    return ind, uni


class Sim:
    """포지션 관리 + 지표 계산 (단기/중기 공통)."""

    def __init__(self, capital: float, risk_pct: float, max_pos_pct: float, max_positions: int,
                 commission: float, slippage: float):
        self.cash = capital
        self.capital0 = capital
        self.risk_pct, self.max_pos_pct, self.max_positions = risk_pct, max_pos_pct, max_positions
        self.cost = (commission + slippage) / 100.0
        self.positions: dict[str, dict] = {}
        self.trades: list[dict] = []
        self.equity_curve: list[tuple] = []

    def equity(self, closes: pd.Series) -> float:
        v = self.cash
        for tk, p in self.positions.items():
            c = closes.get(tk)
            if c is not None and not np.isnan(c):
                v += p["qty"] * float(c)
            else:
                v += p["qty"] * p["last"]
        return v

    def qty_for(self, entry: float, stop: float, equity: float) -> int:
        if entry <= stop or entry <= 0:
            return 0
        q = math.floor(equity * self.risk_pct / 100 / (entry - stop))
        cap = math.floor(equity * self.max_pos_pct / 100 / entry)
        q = max(0, min(q, cap))
        # 레버리지 없음: 현금 한도
        q = min(q, math.floor(self.cash / (entry * (1 + self.cost))))
        return max(0, q)

    def open(self, tk: str, date, entry: float, stop: float, qty: int, setup: str, meta: dict | None = None):
        px = entry * (1 + self.cost)
        self.cash -= qty * px
        self.positions[tk] = {"ticker": tk, "entry_date": date, "entry": entry, "entry_px": px, "stop": stop,
                              "stop0": stop, "qty": qty, "qty0": qty, "days": 0, "setup": setup, "last": entry,
                              "realized": 0.0, "partial": False, "meta": meta or {}}

    def close_part(self, tk: str, date, price: float, frac: float, reason: str):
        p = self.positions[tk]
        q = p["qty"] if frac >= 1 else int(round(p["qty0"] * frac))
        q = min(q, p["qty"])
        if q <= 0:
            return
        px = price * (1 - self.cost)
        self.cash += q * px
        p["realized"] += q * (px - p["entry_px"])
        p["qty"] -= q
        if p["qty"] <= 0:
            risk_per_share = p["entry"] - p["stop0"]
            pnl = p["realized"]
            self.trades.append({
                "ticker": tk, "setup": p["setup"], "entry_date": p["entry_date"], "exit_date": date,
                "entry": round(p["entry"], 4), "exit": round(price, 4), "qty": p["qty0"], "days": p["days"],
                "pnl": round(pnl, 2), "pnl_pct": round(pnl / (p["qty0"] * p["entry_px"]) * 100, 2),
                "r": round(pnl / (p["qty0"] * risk_per_share), 3) if risk_per_share > 0 else None,
                "reason": reason, **{f"m_{k}": v for k, v in p["meta"].items()},
            })
            del self.positions[tk]


# ---------------------------------------------------------------------------
# 단기 (돌파 + EP)
# ---------------------------------------------------------------------------

def run_short(ind: dict, uni: pd.DataFrame, start: str, cfg: dict, risk_pct: float | None = None,
              pick_only: bool = False) -> Sim:
    money, ex, ep, bcfg = cfg["money"], cfg["exit"], cfg["ep"], cfg["breakout"]
    sim = Sim(load_config()["backtest"]["short_capital"], risk_pct or money["risk_pct"], money["max_position_pct"],
              money["max_positions"], money["commission_pct"], money["slippage_pct"])
    dates = ind["close"].index
    close, high, low, opn, vol = ind["close"], ind["high"], ind["low"], ind["open"], ind["volume"]
    sma10 = ind["sma10"]
    u = cfg["universe"]
    start_pos = max(int(np.searchsorted(dates, pd.Timestamp(start))), 130)
    pending: list[dict] = []  # 어제(t-1) 계산한 '내일 돌파 대기'
    names = dict(zip(uni["ticker"], uni["name"]))
    for pos in range(start_pos, len(dates)):
        d = dates[pos]
        c_row, h_row, l_row, o_row, v_row = close.iloc[pos], high.iloc[pos], low.iloc[pos], opn.iloc[pos], vol.iloc[pos]
        # 1) 보유 관리
        for tk in list(sim.positions.keys()):
            p = sim.positions[tk]
            c, h, l, o = c_row.get(tk), h_row.get(tk), l_row.get(tk), o_row.get(tk)
            if c is None or np.isnan(c):
                continue
            p["last"] = float(c)
            if p["days"] == 0 and p["entry_date"] == d:
                if c < p["stop"]:
                    sim.close_part(tk, d, float(c), 1.0, "진입일 손절")
                continue
            p["days"] += 1
            if o < p["stop"]:
                sim.close_part(tk, d, float(o), 1.0, "갭하락 손절")
                continue
            if l < p["stop"]:
                sim.close_part(tk, d, float(p["stop"]), 1.0, "손절")
                continue
            if p["days"] == ex["partial_day"] and not p["partial"]:
                sim.close_part(tk, d, float(c), ex["partial_frac"], "3일째 절반")
                if tk in sim.positions:
                    sim.positions[tk]["partial"] = True
                    sim.positions[tk]["stop"] = p["entry"]
                else:
                    continue
            s10 = sma10.iat[pos, sma10.columns.get_loc(tk)]
            if not np.isnan(s10) and c < s10:
                sim.close_part(tk, d, float(c), 1.0, "SMA10 이탈")
                continue
            if p["days"] >= ex["max_hold_days"]:
                sim.close_part(tk, d, float(c), 1.0, "60일 만료")
        # 2) 진입 (어제 후보의 트리거 확인 + EP)
        eq = sim.equity(c_row)
        signals = []
        for cand in pending:
            tk = cand["ticker"]
            if tk in sim.positions:
                continue
            h, o = h_row.get(tk), o_row.get(tk)
            if h is None or np.isnan(h) or not (h > cand["trigger"]):
                continue
            entry = max(float(o), cand["trigger"])
            if entry > cand["trigger"] * (1 + bcfg["max_above_box_pct"] / 100):
                continue
            signals.append({"ticker": tk, "entry": entry, "setup": "breakout", "r3m": cand["r3m"], "adr": cand["adr"],
                            "meta": {"box_days": cand["box_days"], "box_range": cand["box_range"], "runup": cand["runup"],
                                     "pick_rank": cand.get("pick_rank")}})
        # EP: t-1 유동성 유니버스 + 갭 + 거래량(당일 전체) + 소외 + 모멘텀(시가 반영)
        if pos >= 1:
            prev_c = close.iloc[pos - 1]
            liq = ((prev_c >= u["min_close"]) & (ind["dv20"].iloc[pos - 1] >= u["min_dv20"])
                   & (ind["adr20"].iloc[pos - 1] >= u["min_adr20"])).fillna(False)
            gap = (o_row / prev_c)
            m = liq & (gap >= ep["min_gap"]) & (gap <= ep["max_gap"]) & (v_row >= ind["vol20"].iloc[pos - 1] * ep["vol_mult"]) \
                & (ind["r3m"].iloc[pos - 1] <= ep["max_r3m_pct"])
            m = m.fillna(False)
            if ep.get("apply_momentum_filter", True) and m.any():
                top = u["momentum_top_pct"]
                mom = None
                for k, sh in (("r1m", 21), ("r3m", 63), ("r6m", 126)):
                    base = ind[k].iloc[pos - 1].copy()
                    if pos - sh >= 0:
                        base[m] = (o_row[m] / close.iloc[pos - sh][m] - 1) * 100
                    pct = base.rank(pct=True) * 100
                    mm = (pct >= 100 - top).fillna(False)
                    mom = mm if mom is None else (mom | mm)
                m = m & mom
            for tk in m.index[m.to_numpy()]:
                if tk in sim.positions or any(s["ticker"] == tk for s in signals):
                    # 돌파와 겹치면 EP 로 분류
                    signals = [s for s in signals if s["ticker"] != tk]
                entry = float(o_row[tk]) * ep["entry_mult"]
                if float(h_row[tk]) < entry:
                    continue
                signals.append({"ticker": tk, "entry": entry, "setup": "ep", "r3m": float(ind["r3m"].iloc[pos - 1][tk]),
                                "adr": float(ind["adr20"].iloc[pos - 1][tk]), "meta": {"gap": round(float(gap[tk]) * 100 - 100, 1)}})
        if pick_only:
            signals = [s for s in signals if s["setup"] == "breakout" and s["meta"].get("pick_rank") == 1]
        signals.sort(key=lambda s: -(s["r3m"] if s["r3m"] == s["r3m"] else -1e9))
        for s in signals:
            if len(sim.positions) >= sim.max_positions:
                break
            sp = stop_pct_for(s["adr"], cfg)
            stop = s["entry"] * (1 - sp / 100)
            q = sim.qty_for(s["entry"], stop, eq)
            if q <= 0:
                continue
            sim.open(s["ticker"], d, s["entry"], stop, q, s["setup"], s["meta"])
        # 3) 오늘 기준 '내일 돌파 대기' 계산
        um = ((c_row >= u["min_close"]) & (ind["dv20"].iloc[pos] >= u["min_dv20"]) & (ind["adr20"].iloc[pos] >= u["min_adr20"])).fillna(False)
        mom = None
        for k in ("r1m", "r3m", "r6m"):
            pct = ind[k].iloc[pos].rank(pct=True) * 100
            mm = (pct >= 100 - u["momentum_top_pct"]).fillna(False)
            mom = mm if mom is None else (mom | mm)
        um = um & mom
        pending = []
        rows = []
        for tk in um.index[um.to_numpy()]:
            s = breakout_setup(ind, tk, pos, cfg)
            if not s:
                continue
            adr = float(ind["adr20"].iloc[pos][tk])
            r3 = float(ind["r3m"].iloc[pos][tk])
            row = {"ticker": tk, "trigger": s["box_high"], "trigger_price": s["box_high"], "r3m": r3, "adr": adr,
                   "box_days": s["box_days"], "box_range": s["box_range_pct"], "box_range_pct": s["box_range_pct"],
                   "runup": s["runup_pct"], "runup_pct": s["runup_pct"], "close": float(c_row[tk]),
                   "vol_recent": s["vol_recent"], "vol_before_peak": s["vol_before_peak"]}
            rows.append(row)
        if rows:
            choose_pick(rows)
        pending = rows
        sim.equity_curve.append((d, sim.equity(c_row)))
        if pos % 250 == 0:
            log.info("  %s 자산 %.0f 거래 %d", d.date(), sim.equity(c_row), len(sim.trades))
    # 미청산 강제 청산
    last = dates[-1]
    for tk in list(sim.positions.keys()):
        sim.close_part(tk, last, sim.positions[tk]["last"], 1.0, "백테스트 종료")
    return sim


# ---------------------------------------------------------------------------
# 중기
# ---------------------------------------------------------------------------

def run_mid(ind: dict, uni: pd.DataFrame, start: str, cfg: dict, risk_pct: float | None = None) -> Sim:
    from src.us_mid import pullback_mask, trend_mask, trigger_mask, universe_mask
    money, ex = cfg["money"], cfg["exit"]
    sim = Sim(load_config()["backtest"]["mid_capital"], risk_pct or money["risk_pct"], money["max_position_pct"],
              money["max_positions"], money["commission_pct"], money["slippage_pct"])
    dates = ind["close"].index
    close, high, low, opn = ind["close"], ind["high"], ind["low"], ind["open"]
    sma50 = ind["sma50"]
    low10 = ind["low"].rolling(ex["stop_low_days"]).min()
    start_pos = max(int(np.searchsorted(dates, pd.Timestamp(start))), 260)
    pending: list[dict] = []
    for pos in range(start_pos, len(dates)):
        d = dates[pos]
        c_row, h_row, l_row, o_row = close.iloc[pos], high.iloc[pos], low.iloc[pos], opn.iloc[pos]
        for tk in list(sim.positions.keys()):
            p = sim.positions[tk]
            c, h, l, o = c_row.get(tk), h_row.get(tk), l_row.get(tk), o_row.get(tk)
            if c is None or np.isnan(c):
                continue
            p["last"] = float(c)
            if p["entry_date"] == d:
                if c < p["stop"]:
                    sim.close_part(tk, d, float(c), 1.0, "진입일 손절")
                continue
            p["days"] += 1
            if o < p["stop"]:
                sim.close_part(tk, d, float(o), 1.0, "갭하락 손절")
                continue
            if l < p["stop"]:
                sim.close_part(tk, d, float(p["stop"]), 1.0, "손절")
                continue
            target = p["entry"] + ex["target_r"] * (p["entry"] - p["stop0"])
            if not p["partial"] and h >= target:
                sim.close_part(tk, d, float(target), ex["partial_frac"], "2R 절반")
                if tk in sim.positions:
                    sim.positions[tk]["partial"] = True
                else:
                    continue
            s50 = sma50.iat[pos, sma50.columns.get_loc(tk)]
            if not np.isnan(s50) and c < s50:
                sim.close_part(tk, d, float(c), 1.0, "SMA50 이탈")
                continue
            if p["days"] >= ex["max_hold_days"]:
                sim.close_part(tk, d, float(c), 1.0, "120일 만료")
        eq = sim.equity(c_row)
        pending.sort(key=lambda s: -s["r6m"])
        for cand in pending:
            if len(sim.positions) >= sim.max_positions:
                break
            tk = cand["ticker"]
            if tk in sim.positions:
                continue
            o = o_row.get(tk)
            if o is None or np.isnan(o):
                continue
            entry = float(o)
            stop = max(cand["stop_low"] * ex["stop_mult"], entry * (1 - ex["stop_max_pct"] / 100))
            q = sim.qty_for(entry, stop, eq)
            if q <= 0:
                continue
            sim.open(tk, d, entry, stop, q, "pullback", {"r6m": round(cand["r6m"], 1)})
        um = universe_mask(ind, pos, cfg)
        ok = um & trend_mask(ind, pos, cfg, um) & pullback_mask(ind, pos, cfg) & trigger_mask(ind, pos)
        pending = [{"ticker": tk, "r6m": float(ind["r6m"].iloc[pos][tk]), "stop_low": float(low10.iloc[pos][tk])}
                   for tk in ok.index[ok.to_numpy()] if not np.isnan(low10.iloc[pos][tk])]
        sim.equity_curve.append((d, sim.equity(c_row)))
        if pos % 250 == 0:
            log.info("  %s 자산 %.0f 거래 %d", d.date(), sim.equity(c_row), len(sim.trades))
    last = dates[-1]
    for tk in list(sim.positions.keys()):
        sim.close_part(tk, last, sim.positions[tk]["last"], 1.0, "백테스트 종료")
    return sim


# ---------------------------------------------------------------------------
# 통계
# ---------------------------------------------------------------------------

def stats(trades: pd.DataFrame, eq: pd.Series, capital0: float) -> dict:
    if eq.empty:
        return {}
    total = eq.iloc[-1] / capital0 - 1
    years = max((eq.index[-1] - eq.index[0]).days / 365.25, 1e-9)
    cagr = (eq.iloc[-1] / capital0) ** (1 / years) - 1 if eq.iloc[-1] > 0 else -1
    dd = (eq / eq.cummax() - 1).min()
    n = len(trades)
    wins = trades[trades["pnl"] > 0] if n else trades
    losses = trades[trades["pnl"] <= 0] if n else trades
    wr = len(wins) / n if n else 0
    payoff = (wins["pnl"].mean() / -losses["pnl"].mean()) if (n and len(wins) and len(losses) and losses["pnl"].mean() != 0) else None
    pf = (wins["pnl"].sum() / -losses["pnl"].sum()) if (n and len(losses) and losses["pnl"].sum() != 0) else None
    exp_r = trades["r"].mean() if n and "r" in trades else None
    top10 = (trades.nlargest(10, "pnl")["pnl"].sum() / wins["pnl"].sum() * 100) if (n and len(wins) and wins["pnl"].sum() > 0) else None
    return {"총수익률": total * 100, "CAGR": cagr * 100, "MDD": dd * 100, "거래 수": n, "승률": wr * 100,
            "손익비": payoff, "프로핏팩터": pf, "기대값(R)": exp_r, "평균 보유일": trades["days"].mean() if n else None,
            "상위10 거래 이익 비중": top10, "최종 자산": eq.iloc[-1]}


def fmt(v, digits=1, suffix=""):
    if v is None or (isinstance(v, float) and (np.isnan(v) or np.isinf(v))):
        return "-"
    return f"{v:,.{digits}f}{suffix}"


def stats_table(rows: dict[str, dict]) -> str:
    keys = ["총수익률", "CAGR", "MDD", "거래 수", "승률", "손익비", "프로핏팩터", "기대값(R)", "평균 보유일", "상위10 거래 이익 비중", "최종 자산"]
    suf = {"총수익률": "%", "CAGR": "%", "MDD": "%", "승률": "%", "상위10 거래 이익 비중": "%"}
    out = "| 항목 | " + " | ".join(rows.keys()) + " |\n|---|" + "---|" * len(rows) + "\n"
    for k in keys:
        out += f"| {k} | " + " | ".join(fmt(r.get(k), 0 if k in ("거래 수", "최종 자산") else 2 if k in ("손익비", "프로핏팩터", "기대값(R)") else 1, suf.get(k, "")) for r in rows.values()) + " |\n"
    return out


def monte_carlo(trades: pd.DataFrame, capital0: float, risk_pct: float, runs: int = 1000, seed: int = 7) -> dict:
    r = trades["r"].dropna().to_numpy()
    if len(r) < 5:
        return {}
    rng = np.random.default_rng(seed)
    finals, mdds = [], []
    for _ in range(runs):
        sample = rng.choice(r, size=len(r), replace=True)
        eq = capital0 * np.cumprod(1 + sample * risk_pct / 100)
        finals.append(eq[-1] / capital0 - 1)
        mdds.append((eq / np.maximum.accumulate(eq) - 1).min())
    finals, mdds = np.array(finals) * 100, np.array(mdds) * 100
    return {"수익률 5%": np.percentile(finals, 5), "수익률 50%": np.percentile(finals, 50), "수익률 95%": np.percentile(finals, 95),
            "MDD 5%(최악)": np.percentile(mdds, 5), "MDD 50%": np.percentile(mdds, 50), "손실 확률": float((finals < 0).mean() * 100)}


def plot_equity(curves: dict[str, pd.Series], path, title: str):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams["font.family"] = ["Malgun Gothic", "AppleGothic", "NanumGothic", "DejaVu Sans"]
    plt.rcParams["axes.unicode_minus"] = False
    fig, ax = plt.subplots(figsize=(10, 5))
    for k, s in curves.items():
        ax.plot(s.index, s.values, label=k)
    ax.set_yscale("log")
    ax.set_title(title)
    ax.grid(alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)


def split_stats(trades: pd.DataFrame, eq: pd.Series, capital0: float, in_end: str) -> dict[str, dict]:
    out = {}
    ie = pd.Timestamp(in_end)
    for label, mask_eq, mask_tr in (
        ("인샘플 2016~2020", eq.index <= ie, trades["exit_date"] <= ie),
        ("아웃오브샘플 2021~", eq.index > ie, trades["exit_date"] > ie),
        ("전체", np.ones(len(eq), bool), np.ones(len(trades), bool)),
    ):
        e = eq[mask_eq]
        if e.empty:
            continue
        cap = capital0 if label != "아웃오브샘플 2021~" else float(eq[eq.index <= ie].iloc[-1]) if (eq.index <= ie).any() else capital0
        out[label] = stats(trades[mask_tr] if len(trades) else trades, e, cap)
    return out


def report_common(name: str, sim: Sim, cfg_money: dict, risk_levels: list[float], run_fn, ind, uni, start, cfg,
                  extra_sections: list[str] | None = None) -> str:
    tr = pd.DataFrame(sim.trades)
    if not tr.empty:
        tr["exit_date"] = pd.to_datetime(tr["exit_date"])
        tr["entry_date"] = pd.to_datetime(tr["entry_date"])
    eq = pd.Series({d: v for d, v in sim.equity_curve})
    bt = load_config()["backtest"]
    md = [f"# {name} 백테스트 리포트\n", f"기간 {start} ~ {datetime.now():%Y-%m-%d}, 초기 자산 ${sim.capital0:,.0f}, "
          f"리스크 {sim.risk_pct}%/회, 동시 최대 {sim.max_positions}종목, 한 종목 최대 {sim.max_pos_pct}%\n",
          "## 요약\n", stats_table(split_stats(tr, eq, sim.capital0, bt["in_sample_end"])) if not tr.empty else "거래 없음\n"]
    if not tr.empty:
        md.append("\n## 셋업별\n")
        md.append(stats_table({s: stats(g, eq, sim.capital0) for s, g in tr.groupby("setup")}))
        md.append("\n## 연도별\n| 연도 | 거래 수 | 승률 | 합계 손익($) | 평균 R |\n|---|---|---|---|---|\n")
        for y, g in tr.groupby(tr["exit_date"].dt.year):
            md.append(f"| {y} | {len(g)} | {fmt((g['pnl'] > 0).mean() * 100, 1, '%')} | {fmt(g['pnl'].sum(), 0)} | {fmt(g['r'].mean(), 2)} |\n")
        md.append("\n## 청산 사유별\n| 사유 | 거래 수 | 평균 손익% |\n|---|---|---|\n")
        for rsn, g in tr.groupby("reason"):
            md.append(f"| {rsn} | {len(g)} | {fmt(g['pnl_pct'].mean(), 2, '%')} |\n")
        md.append("\n## 리스크 비율 비교\n")
        rows = {}
        for rp in risk_levels:
            s2 = run_fn(ind, uni, start, cfg, risk_pct=rp)
            t2 = pd.DataFrame(s2.trades)
            e2 = pd.Series({d: v for d, v in s2.equity_curve})
            rows[f"리스크 {rp}%"] = stats(t2, e2, s2.capital0)
        md.append(stats_table(rows))
        mc = monte_carlo(tr, sim.capital0, sim.risk_pct, bt["monte_carlo_runs"])
        if mc:
            md.append(f"\n## 몬테카를로 {bt['monte_carlo_runs']}회 (거래 R 을 복원 추출)\n")
            md.append("| " + " | ".join(mc.keys()) + " |\n|" + "---|" * len(mc) + "\n| " + " | ".join(fmt(v, 1, '%') for v in mc.values()) + " |\n")
    for s in extra_sections or []:
        md.append(s)
    md.append("\n## 주의\n" + CAVEATS)
    return "".join(md)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--short", action="store_true")
    ap.add_argument("--mid", action="store_true")
    ap.add_argument("--long", action="store_true")
    ap.add_argument("--start", default=None)
    ap.add_argument("--no-pick", action="store_true", help="단기 1픽 변형 생략")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")
    logging.getLogger("yfinance").setLevel(logging.CRITICAL)
    cfg = load_config()
    start = args.start or cfg["backtest"]["start"]
    if not (args.short or args.mid or args.long):
        ap.error("--short / --mid / --long 중 하나")
    ind, uni = load_wide(start)
    log.info("지표 준비 완료: %s ~ %s, %d 종목", ind["close"].index[0].date(), ind["close"].index[-1].date(), ind["close"].shape[1])

    if args.short:
        c = cfg["us_short"]
        sim = run_short(ind, uni, start, c)
        tr = pd.DataFrame(sim.trades)
        tr.to_csv(OUTPUT_DIR / "trades_short.csv", index=False, encoding="utf-8-sig")
        eq = pd.Series({d: v for d, v in sim.equity_curve})
        curves = {"단기 (돌파+EP)": eq}
        extra = []
        if not args.no_pick:
            simp = run_short(ind, uni, start, c, pick_only=True)
            trp = pd.DataFrame(simp.trades)
            trp.to_csv(OUTPUT_DIR / "trades_short_pick.csv", index=False, encoding="utf-8-sig")
            eqp = pd.Series({d: v for d, v in simp.equity_curve})
            curves["매일 1픽만"] = eqp
            extra.append("\n## 변형: 매일 1픽만 매매 (후보 중 점수 1위 돌파만 진입)\n")
            extra.append(stats_table({"전체 후보": stats(tr, eq, sim.capital0), "1픽만": stats(trp, eqp, simp.capital0)}))
            if not trp.empty:
                extra.append("\n1픽 규칙: 3개월 수익률 순위 + 횡보 폭(좁을수록) + 거래량 감소율 + 종가의 트리거가 근접도 평균 순위 1위.\n")
        plot_equity(curves, OUTPUT_DIR / "equity_short.png", "단기 자산 곡선 (로그)")
        md = report_common("미국 단기 (돌파 + EP)", sim, c["money"], cfg["backtest"]["risk_pct_levels"], run_short, ind, uni, start, c, extra)
        md += "\n![자산 곡선](equity_short.png)\n"
        (OUTPUT_DIR / "report_short.md").write_text(md, encoding="utf-8")
        log.info("report_short.md 저장. 거래 %d", len(tr))
    if args.mid:
        c = cfg["us_mid"]
        sim = run_mid(ind, uni, start, c)
        tr = pd.DataFrame(sim.trades)
        tr.to_csv(OUTPUT_DIR / "trades_mid.csv", index=False, encoding="utf-8-sig")
        eq = pd.Series({d: v for d, v in sim.equity_curve})
        plot_equity({"중기 눌림목": eq}, OUTPUT_DIR / "equity_mid.png", "중기 자산 곡선 (로그)")
        md = report_common("미국 중기 (추세 눌림목)", sim, c["money"], [1, 2, 4], run_mid, ind, uni, start, c)
        md += "\n![자산 곡선](equity_mid.png)\n"
        (OUTPUT_DIR / "report_mid.md").write_text(md, encoding="utf-8")
        log.info("report_mid.md 저장. 거래 %d", len(tr))
    if args.long:
        run_long(ind, start, cfg)
    return 0


# ---------------------------------------------------------------------------
# 장기: 월별 리밸런스 vs SPY (재무 조건은 과거 데이터가 없어 추세+상대강도만)
# ---------------------------------------------------------------------------

def run_long(ind: dict, start: str, cfg: dict):
    lc = cfg["us_long"]
    lu = long_universe()
    tk = [t for t in lu["ticker"] if t in ind["close"].columns]
    spy = get_daily(["SPY"], start="2015-01-01", name="spy_full")
    spy = spy.set_index("date")["close"]
    close = ind["close"][tk]
    dates = close.index
    months = pd.Series(dates).groupby([dates.year, dates.month]).first().tolist()
    months = [m for m in months if m >= pd.Timestamp(start)]
    eq, hold, eq_val = [], [], 1.0
    weights: dict[str, float] = {}
    last_prices = None
    log_rows = []
    for m in months:
        pos = dates.get_loc(m)
        c = close.iloc[pos]
        if last_prices is not None and weights:
            ret = sum(w * (c[t] / last_prices[t] - 1) for t, w in weights.items() if not np.isnan(c[t]) and not np.isnan(last_prices[t]))
            eq_val *= 1 + ret
        eq.append((m, eq_val))
        # 후보: 추세 + RS 상위 30%
        s150, s200 = ind["sma150"][tk].iloc[pos], ind["sma200"][tk].iloc[pos]
        s200p = ind["sma200"][tk].iloc[max(0, pos - 105)]
        hi52, lo52 = ind["high52"][tk].iloc[pos], ind["low52"][tk].iloc[pos]
        r12x = ind["r12m_ex1"][tk].iloc[pos]
        trend = (c > s150) & (s150 > s200) & (s200 > s200p) & (c >= hi52 * (1 - lc["trend"]["below_52w_high_pct"] / 100)) & (c >= lo52 * (1 + lc["trend"]["above_52w_low_pct"] / 100))
        rs = r12x.rank(pct=True) * 100 >= 100 - lc["trend"]["r12m_ex1_top_pct"]
        ok = (trend & rs).fillna(False)
        ranked = r12x[ok].sort_values(ascending=False)
        rank_map = {t: i + 1 for i, t in enumerate(ranked.index)}
        # 교체 규칙
        keep = []
        for t in hold:
            below = 0
            for k in range(0, 10):
                if pos - k < 0:
                    break
                cc, ss = close[t].iloc[pos - k], ind["sma200"][t].iloc[pos - k]
                if not np.isnan(cc) and not np.isnan(ss) and cc < ss:
                    below += 1
                else:
                    break
            if below >= lc["replace"]["below_sma200_days"] or rank_map.get(t, 999) > lc["replace"]["rank_out"]:
                continue
            keep.append(t)
        new = keep[:]
        for t in ranked.index:
            if len(new) >= lc["hold_n"]:
                break
            if t not in new:
                new.append(t)
        hold = new
        weights = {t: 1 / len(hold) for t in hold} if hold else {}
        last_prices = c
        log_rows.append({"month": m.strftime("%Y-%m"), "holdings": ",".join(hold), "equity": round(eq_val, 4)})
    eqs = pd.Series({d: v for d, v in eq})
    spy_m = spy.reindex(eqs.index, method="ffill")
    spy_eq = spy_m / spy_m.iloc[0]
    out = pd.DataFrame(log_rows)
    out.to_csv(OUTPUT_DIR / "trades_long.csv", index=False, encoding="utf-8-sig")
    plot_equity({"장기 상위5 동일비중": eqs, "SPY": spy_eq}, OUTPUT_DIR / "equity_long.png", "장기 월별 리밸런스 vs SPY")

    def st(s: pd.Series):
        yrs = (s.index[-1] - s.index[0]).days / 365.25
        return {"총수익률": (s.iloc[-1] - 1) * 100, "CAGR": (s.iloc[-1] ** (1 / yrs) - 1) * 100, "MDD": (s / s.cummax() - 1).min() * 100}

    a, b = st(eqs), st(spy_eq)
    md = ["# 미국 장기 백테스트 리포트 (월별 리밸런스)\n",
          f"기간 {eqs.index[0].date()} ~ {eqs.index[-1].date()}, 매월 첫 거래일 상위 5종목 동일비중, 교체 규칙(SMA200 아래 10일 / 순위 10위 밖) 적용\n",
          "\n| 항목 | 장기 전략 | SPY |\n|---|---|---|\n",
          f"| 총수익률 | {fmt(a['총수익률'], 1, '%')} | {fmt(b['총수익률'], 1, '%')} |\n",
          f"| CAGR | {fmt(a['CAGR'], 1, '%')} | {fmt(b['CAGR'], 1, '%')} |\n",
          f"| MDD | {fmt(a['MDD'], 1, '%')} | {fmt(b['MDD'], 1, '%')} |\n",
          "\n## 주의\n- 재무 조건(ROE·매출성장·영업이익률·FCF·부채·PEG)은 과거 시점 데이터가 무료로 없어 **추세 + 상대강도 조건만**으로 검증했습니다.\n"
          "- 유니버스는 **현재** S&P 500 + 나스닥 100 구성 종목이라 생존 편향이 큽니다 (과거에 지수에 없던 종목이 포함됨).\n"
          "- 수수료·슬리피지는 반영하지 않았습니다.\n",
          "\n![자산 곡선](equity_long.png)\n"]
    (OUTPUT_DIR / "report_long.md").write_text("".join(md), encoding="utf-8")
    log.info("report_long.md 저장")


if __name__ == "__main__":
    sys.exit(main())
