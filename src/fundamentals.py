"""재무 데이터: yfinance Ticker.info (월 1회, 장기 유니버스만). 실패 시 SEC XBRL companyfacts 로 보완."""
from __future__ import annotations

import json
import logging
import time
from datetime import datetime, timezone

import pandas as pd
import requests
import yfinance as yf

from .config import DATA_DIR, load_config

log = logging.getLogger(__name__)

SEC_TICKERS_URL = "https://www.sec.gov/files/company_tickers.json"
SEC_FACTS_URL = "https://data.sec.gov/api/xbrl/companyfacts/CIK{cik:010d}.json"
SEC_HEADERS = {"User-Agent": "stock-screener research contact@example.com", "Accept-Encoding": "gzip, deflate"}

FIELDS = ["name", "sector", "industry", "roe", "revenue_growth", "operating_margin", "fcf",
          "debt_to_equity", "peg", "forward_pe", "trailing_pe", "market_cap", "next_earnings", "source"]


def _pct(x):
    return None if x is None or x != x else float(x) * 100


def _num(x):
    return None if x is None or x != x else float(x)


def _from_yf(ticker: str) -> dict | None:
    try:
        t = yf.Ticker(ticker)
        info = t.info or {}
    except Exception as e:  # noqa: BLE001
        log.warning("info 실패 %s: %s", ticker, e)
        return None
    if not info or info.get("regularMarketPrice") is None and info.get("currentPrice") is None:
        return None
    nxt = None
    try:
        cal = t.calendar
        ed = cal.get("Earnings Date") if isinstance(cal, dict) else None
        if ed:
            d = ed[0] if isinstance(ed, (list, tuple)) else ed
            nxt = pd.Timestamp(d).strftime("%Y-%m-%d")
    except Exception:  # noqa: BLE001
        pass
    peg = info.get("trailingPegRatio")
    if peg is None:
        peg = info.get("pegRatio")
    return {
        "name": info.get("shortName") or info.get("longName") or "",
        "sector": info.get("sector") or "",
        "industry": info.get("industry") or "",
        "roe": _pct(info.get("returnOnEquity")),
        "revenue_growth": _pct(info.get("revenueGrowth")),
        "operating_margin": _pct(info.get("operatingMargins")),
        "fcf": _num(info.get("freeCashflow")),
        "debt_to_equity": _num(info.get("debtToEquity")),  # yfinance 는 이미 % 단위
        "peg": _num(peg),
        "forward_pe": _num(info.get("forwardPE")),
        "trailing_pe": _num(info.get("trailingPE")),
        "market_cap": _num(info.get("marketCap")),
        "next_earnings": nxt,
        "source": "yfinance",
    }


# ---------------------------------------------------------------------------
# SEC XBRL 보완
# ---------------------------------------------------------------------------
_sec_cik: dict[str, int] | None = None


def _sec_cik_map() -> dict[str, int]:
    global _sec_cik
    if _sec_cik is not None:
        return _sec_cik
    p = DATA_DIR / "sec_tickers.json"
    try:
        r = requests.get(SEC_TICKERS_URL, headers=SEC_HEADERS, timeout=30)
        r.raise_for_status()
        p.write_text(r.text, encoding="utf-8")
        raw = r.json()
    except Exception as e:  # noqa: BLE001
        log.warning("SEC 티커 목록 실패: %s", e)
        raw = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}
    _sec_cik = {v["ticker"].upper().replace(".", "-"): int(v["cik_str"]) for v in raw.values()} if raw else {}
    return _sec_cik


def _sec_series(facts: dict, tags: list[str], form_pref=("10-K", "10-K/A", "20-F", "40-F")):
    """연간(FY) 값 시계열: [(end_date, value)] 최신순."""
    gaap = facts.get("facts", {}).get("us-gaap", {})
    for tag in tags:
        if tag not in gaap:
            continue
        units = gaap[tag].get("units", {})
        vals = units.get("USD") or units.get("USD/shares") or next(iter(units.values()), [])
        rows = [v for v in vals if v.get("form") in form_pref and v.get("fp") == "FY" and v.get("start") is None
                or (v.get("form") in form_pref and v.get("fp") == "FY" and v.get("start") and
                    (pd.Timestamp(v["end"]) - pd.Timestamp(v["start"])).days > 300)]
        if not rows:
            continue
        df = pd.DataFrame(rows).drop_duplicates("end", keep="last").sort_values("end", ascending=False)
        return [(r["end"], float(r["val"])) for _, r in df.iterrows()]
    return []


def _from_sec(ticker: str) -> dict | None:
    cik = _sec_cik_map().get(ticker)
    if not cik:
        return None
    try:
        r = requests.get(SEC_FACTS_URL.format(cik=cik), headers=SEC_HEADERS, timeout=30)
        r.raise_for_status()
        facts = r.json()
    except Exception as e:  # noqa: BLE001
        log.warning("SEC facts 실패 %s: %s", ticker, e)
        return None
    rev = _sec_series(facts, ["Revenues", "RevenueFromContractWithCustomerExcludingAssessedTax", "SalesRevenueNet"])
    ni = _sec_series(facts, ["NetIncomeLoss"])
    eq = _sec_series(facts, ["StockholdersEquity", "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest"])
    op = _sec_series(facts, ["OperatingIncomeLoss"])
    cfo = _sec_series(facts, ["NetCashProvidedByUsedInOperatingActivities"])
    capex = _sec_series(facts, ["PaymentsToAcquirePropertyPlantAndEquipment"])
    debt = _sec_series(facts, ["LongTermDebt", "LongTermDebtNoncurrent", "DebtInstrumentCarryingAmount"])
    out = {"name": facts.get("entityName", ""), "sector": "", "industry": "", "roe": None, "revenue_growth": None,
           "operating_margin": None, "fcf": None, "debt_to_equity": None, "peg": None, "forward_pe": None,
           "trailing_pe": None, "market_cap": None, "next_earnings": None, "source": "sec"}
    if rev:
        if len(rev) >= 2 and rev[1][1]:
            out["revenue_growth"] = (rev[0][1] / rev[1][1] - 1) * 100
        if op and rev[0][1]:
            out["operating_margin"] = op[0][1] / rev[0][1] * 100
    if ni and eq and eq[0][1]:
        out["roe"] = ni[0][1] / eq[0][1] * 100
    if cfo:
        out["fcf"] = cfo[0][1] - (capex[0][1] if capex else 0.0)
    if debt and eq and eq[0][1]:
        out["debt_to_equity"] = debt[0][1] / eq[0][1] * 100
    return out


def _merge(a: dict | None, b: dict | None) -> dict | None:
    """a 의 빈 값을 b 로 채움."""
    if a is None:
        return b
    if b is None:
        return a
    m = dict(a)
    for k, v in b.items():
        if m.get(k) in (None, "") and v not in (None, ""):
            m[k] = v
    if a.get("source") != b.get("source") and any(a.get(k) in (None, "") and b.get(k) not in (None, "")
                                                  for k in ("roe", "revenue_growth", "operating_margin", "fcf", "debt_to_equity")):
        m["source"] = f"{a.get('source')}+{b.get('source')}"
    return m


def get_fundamentals(tickers: list[str], force: bool = False, max_age_days: int | None = None) -> pd.DataFrame:
    """장기 유니버스 재무 데이터. 캐시 유효기간 안이면 캐시 사용. index=ticker."""
    cfg = load_config()["data"]
    max_age_days = max_age_days or cfg["fundamentals_max_age_days"]
    cache = DATA_DIR / "fundamentals_us.json"
    cached: dict = {}
    if cache.exists():
        try:
            cached = json.loads(cache.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            cached = {}
    now = datetime.now(timezone.utc)
    need = []
    for t in tickers:
        row = cached.get(t)
        if force or not row:
            need.append(t)
            continue
        try:
            age = (now - datetime.fromisoformat(row["updated"])).days
        except Exception:  # noqa: BLE001
            age = 999
        if age > max_age_days:
            need.append(t)
    log.info("재무 데이터: %d 종목 중 %d 종목 갱신 필요", len(tickers), len(need))
    core = ("roe", "revenue_growth", "operating_margin", "fcf", "debt_to_equity")
    n_yf = n_sec = n_fail = 0
    for i, t in enumerate(need):
        row = _from_yf(t)
        if row is None or sum(row.get(k) is None for k in core) >= 3:
            sec = _from_sec(t)
            row = _merge(row, sec)
            if sec:
                n_sec += 1
        if row is None:
            n_fail += 1
            continue
        if row.get("source", "").startswith("yfinance"):
            n_yf += 1
        row["updated"] = now.isoformat()
        cached[t] = row
        if (i + 1) % 25 == 0:
            cache.write_text(json.dumps(cached, ensure_ascii=False), encoding="utf-8")
            log.info("  재무 %d/%d", i + 1, len(need))
        time.sleep(0.2)
    cache.write_text(json.dumps(cached, ensure_ascii=False), encoding="utf-8")
    log.info("재무 데이터 완료: yfinance %d, SEC 보완 %d, 실패 %d", n_yf, n_sec, n_fail)
    rows = {t: cached[t] for t in tickers if t in cached}
    df = pd.DataFrame.from_dict(rows, orient="index")
    for c in FIELDS:
        if c not in df.columns:
            df[c] = None
    return df
