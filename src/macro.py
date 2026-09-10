"""매일 갱신되는 '오늘의 시장': 거시 지표 등락, 지표 발표 일정(세이브티커), 주요 뉴스, FRED 실제 발표치.

출력 output/us_daily.json
"""
from __future__ import annotations

import io
import logging
from datetime import datetime, timedelta, timezone

import pandas as pd
import requests

from .config import load_config
from .context import calendar_events, top_stories
from .data import get_daily, to_wide

log = logging.getLogger(__name__)

MACRO = {
    "SPY": "S&P 500 (SPY)", "QQQ": "나스닥100 (QQQ)", "IWM": "소형주 (IWM)",
    "^VIX": "변동성 VIX", "^TNX": "미 10년물 금리", "DX-Y.NYB": "달러 인덱스",
    "CL=F": "WTI 원유", "GC=F": "금", "BTC-USD": "비트코인", "HG=F": "구리",
}
FRED = {
    "CPIAUCSL": {"name": "소비자물가(CPI, 전년비 %)", "yoy": True},
    "PCEPI": {"name": "PCE 물가(전년비 %)", "yoy": True},
    "UNRATE": {"name": "실업률 %", "yoy": False},
    "PAYEMS": {"name": "비농업 고용 (전월 대비 천 명)", "diff": True},
    "ICSA": {"name": "주간 실업수당 청구 (천 명)", "k": True},
    "FEDFUNDS": {"name": "연방기금금리 %", "yoy": False},
    "T10Y2Y": {"name": "10년-2년 금리차 %p", "yoy": False},
    "DGS10": {"name": "10년물 국채금리 %", "yoy": False},
}


def _ret(s: pd.Series, n: int):
    s = s.dropna()
    if len(s) <= n:
        return None
    return round((float(s.iloc[-1]) / float(s.iloc[-1 - n]) - 1) * 100, 2)


def macro_table() -> list[dict]:
    df = get_daily(list(MACRO.keys()), name="macro", lookback_days=300)
    w = to_wide(df)
    c = w["close"]
    out = []
    for tk, name in MACRO.items():
        if tk not in c.columns:
            continue
        s = c[tk].dropna()
        if s.empty:
            continue
        last = float(s.iloc[-1])
        is_level = tk in ("^VIX", "^TNX", "DX-Y.NYB")
        out.append({
            "ticker": tk, "name": name, "last": round(last, 2), "date": str(s.index[-1].date()),
            "d1": _ret(s, 1), "w1": _ret(s, 5), "m1": _ret(s, 21), "m3": _ret(s, 63),
            "d1_abs": round(last - float(s.iloc[-2]), 2) if len(s) > 1 else None,
            "level": is_level,
            "high_52w": round(float(s.iloc[-252:].max()), 2), "low_52w": round(float(s.iloc[-252:].min()), 2),
        })
    return out


def fred_latest(series: dict = FRED) -> list[dict]:
    """FRED 공개 CSV (키 불필요). 최근 2개 값과 변화."""
    out = []
    fails = 0
    for sid, meta in series.items():
        if fails >= 2:
            log.warning("FRED 연속 실패 → 나머지 건너뜀")
            break
        try:
            r = requests.get("https://fred.stlouisfed.org/graph/fredgraph.csv", params={"id": sid}, timeout=12,
                             headers={"User-Agent": "Mozilla/5.0"})
            r.raise_for_status()
            df = pd.read_csv(io.StringIO(r.text))
            df.columns = ["date", "value"]
            df["value"] = pd.to_numeric(df["value"], errors="coerce")
            df = df.dropna()
            if df.empty:
                continue
            if meta.get("yoy") and len(df) > 12:
                v = float(df["value"].iloc[-1] / df["value"].iloc[-13] * 100 - 100)
                p = float(df["value"].iloc[-2] / df["value"].iloc[-14] * 100 - 100)
            elif meta.get("diff") and len(df) > 2:
                v = float(df["value"].iloc[-1] - df["value"].iloc[-2])
                p = float(df["value"].iloc[-2] - df["value"].iloc[-3])
            else:
                v = float(df["value"].iloc[-1])
                p = float(df["value"].iloc[-2]) if len(df) > 1 else None
            out.append({"id": sid, "name": meta["name"], "date": str(df["date"].iloc[-1]),
                        "value": round(v, 2), "previous": None if p is None else round(p, 2)})
        except Exception as e:  # noqa: BLE001
            fails += 1
            log.warning("FRED %s 실패: %s", sid, e)
    return out


def market_explain(temp: dict | None, macro: list[dict]) -> list[str]:
    """숫자를 한국어 한 줄 설명으로."""
    lines = []
    m = {x["ticker"]: x for x in macro}
    if temp:
        lines.append(
            f"{temp.get('index','SPY')}가 200일 이동평균보다 {temp.get('pct_vs_sma200')}% {'위' if temp.get('above_sma200') else '아래'}, "
            f"S&P 500 종목 중 {temp.get('breadth_pct')}%가 200일선 위 → 장기 자금 신호 '{temp.get('signal')}'")
    if "^VIX" in m:
        v = m["^VIX"]["last"]
        lines.append(f"VIX {v}: " + ("공포 구간(30 이상) — 변동성 큼, 단기 매매 손절 폭 주의" if v >= 30 else
                                    "경계 구간(20~30)" if v >= 20 else "안정 구간(20 미만) — 추세 매매에 유리한 환경"))
    if "^TNX" in m:
        x = m["^TNX"]
        lines.append(f"미 10년물 {x['last']}% (하루 {x['d1_abs']:+}p): " + ("금리 상승은 고성장주에 부담" if (x['d1_abs'] or 0) > 0.05 else
                                                                  "금리 하락은 성장주에 우호적" if (x['d1_abs'] or 0) < -0.05 else "큰 변화 없음"))
    if "CL=F" in m:
        x = m["CL=F"]
        lines.append(f"WTI 원유 ${x['last']} (한 달 {x['m1']:+}%): " + ("유가 급등 — 에너지주 강세, 소비·항공에 부담, 물가 우려" if (x['m1'] or 0) > 10 else
                                                               "유가 급락 — 에너지주 약세, 소비주에 우호적" if (x['m1'] or 0) < -10 else "유가 안정"))
    if "DX-Y.NYB" in m:
        x = m["DX-Y.NYB"]
        lines.append(f"달러 인덱스 {x['last']} (한 달 {x['m1']:+}%): " + ("달러 강세 — 신흥국·원자재에 부담" if (x['m1'] or 0) > 2 else
                                                                   "달러 약세 — 원자재·해외 매출 기업에 우호적" if (x['m1'] or 0) < -2 else "달러 안정"))
    if "IWM" in m and "SPY" in m:
        d = (m["IWM"]["m1"] or 0) - (m["SPY"]["m1"] or 0)
        lines.append(f"소형주가 대형주보다 한 달 {d:+.1f}%p: " + ("소형주 주도 — 단기 돌파 종목에 우호적" if d > 2 else
                                                            "대형주 주도 — 소형주 돌파 실패 잦을 수 있음" if d < -2 else "비슷"))
    return lines


def build_daily(temp: dict | None = None, breadth_hist: list[dict] | None = None, short_universe_size: int | None = None) -> dict:
    now = datetime.now(timezone.utc)
    macro = macro_table()
    cal = calendar_events(days_back=0, days_fwd=7)
    today_kst = (now + timedelta(hours=9)).date()
    for e in cal:
        try:
            t = pd.Timestamp(e["time"])
            # 세이브티커 캘린더 시각은 시간대 없는 한국시간
            t = t.tz_convert("Asia/Seoul") if t.tzinfo else t.tz_localize("Asia/Seoul")
            e["kst"] = t.strftime("%m/%d %H:%M")
            e["is_today"] = t.date() == today_kst
            e["is_past"] = t < pd.Timestamp.now(tz="Asia/Seoul")
        except Exception:  # noqa: BLE001
            e["kst"], e["is_today"], e["is_past"] = e["time"], False, False
    stories = top_stories(15)
    fred = fred_latest()
    return {
        "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "date": macro[0]["date"] if macro else str(now.date()),
        "macro": macro,
        "explain": market_explain(temp, macro),
        "calendar": cal,
        "top_stories": stories,
        "fred": fred,
        "breadth_history": breadth_hist or [],
        "short_universe_size": short_universe_size,
    }
