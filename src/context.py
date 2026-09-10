"""종목별 근거(컨텍스트): 뉴스(세이브티커 공개 API), 애널리스트 의견, 재무건전성 해석 (yfinance).

출력은 output/us_context.json (ticker → dict). 뉴스는 제목/요약/출처/링크만 저장 (본문은 저장하지 않음).
"""
from __future__ import annotations

import json
import logging
import math
import time
from datetime import datetime, timedelta, timezone

import pandas as pd
import requests
import yfinance as yf

from .config import OUTPUT_DIR

log = logging.getLogger(__name__)

SAVE_BASE = "https://www.saveticker.com"
SAVE_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
    "Accept": "application/json",
    "Referer": "https://www.saveticker.com/news",
}


# ---------------------------------------------------------------------------
# 세이브티커 (로그인 없이 되는 공개 API 만 사용)
# ---------------------------------------------------------------------------

def _save_get(path: str, params: dict | None = None, timeout: int = 20) -> dict | None:
    try:
        r = requests.get(SAVE_BASE + path, params=params, headers=SAVE_HEADERS, timeout=timeout)
        if r.status_code != 200:
            log.warning("세이브티커 %s → HTTP %s", path, r.status_code)
            return None
        return r.json()
    except Exception as e:  # noqa: BLE001
        log.warning("세이브티커 %s 실패: %s", path, e)
        return None


def _text_of(blocks) -> str:
    if isinstance(blocks, list):
        return " ".join(str(b.get("content", "")) for b in blocks if isinstance(b, dict)).strip()
    if isinstance(blocks, str):
        return blocks.strip()
    return ""


def _news_item(it: dict) -> dict:
    tr = (it.get("translations") or {}).get("translated") or {}
    ko = tr.get("ko_KR") or {}
    en = tr.get("en_US") or {}
    summary = _text_of(ko.get("summary")) or _text_of(ko.get("content")) or str(it.get("content") or "")
    votes = (it.get("vote_stats") or {}).get("vote_counts") or {}
    total = sum(v for v in votes.values() if isinstance(v, (int, float))) if votes else 0
    pos = None
    if total:
        up = sum(v for k, v in votes.items() if str(k).lower() in ("up", "positive", "bull", "like", "1", "good"))
        pos = round(up / total * 100)
    return {
        "id": str(it.get("id")),
        "title": it.get("title") or ko.get("title") or "",
        "title_en": en.get("title") or "",
        "summary": summary[:400],
        "source": it.get("source") or "",
        "time": it.get("created_at") or "",
        "url": f"{SAVE_BASE}/news/{it.get('id')}",
        "tickers": [t.get("symbol") for t in (it.get("tickers") or []) if isinstance(t, dict)],
        "tags": [t.get("name") for t in (it.get("tags") or []) if isinstance(t, dict) and not t.get("is_ticker")],
        "is_top": bool(it.get("is_top_story")),
        "views": it.get("view_count"),
        "comments": it.get("comment_count"),
        "positive_pct": pos,
    }


def news_for_ticker(ticker: str, n: int = 8) -> list[dict]:
    j = _save_get("/api/news/list", {"page": 1, "page_size": n, "sort": "created_at_desc", "tickers": ticker})
    if not j:
        return []
    return [_news_item(it) for it in (j.get("news_list") or [])]


def top_stories(n: int = 20) -> list[dict]:
    j = _save_get("/api/news/top-stories")
    items = []
    if isinstance(j, dict):
        items = j.get("news_list") or j.get("items") or j.get("data") or []
    elif isinstance(j, list):
        items = j
    out = [_news_item(it) for it in items if isinstance(it, dict)]
    if not out:
        j = _save_get("/api/news/list", {"page": 1, "page_size": n, "sort": "created_at_desc", "label_group": 1, "label_name": 1})
        out = [_news_item(it) for it in ((j or {}).get("news_list") or [])]
    return out[:n]


def calendar_events(days_back: int = 1, days_fwd: int = 7) -> list[dict]:
    today = datetime.now(timezone.utc).date()
    j = _save_get("/api/calendar/events", {"start_date": (today - timedelta(days=days_back)).isoformat(),
                                           "end_date": (today + timedelta(days=days_fwd)).isoformat()})
    if not j:
        return []
    out = []
    for e in j.get("events") or []:
        title = str(e.get("title") or "")
        stars = title.count("★")
        out.append({"id": e.get("id"), "title": title.replace("★", "").strip(), "importance": stars,
                    "time": e.get("event_date") or "", "date_only": bool(e.get("event_date_only"))})
    out.sort(key=lambda x: x["time"])
    return out


# ---------------------------------------------------------------------------
# 애널리스트 + 재무건전성 (yfinance)
# ---------------------------------------------------------------------------

def _grade(v, bands: list[tuple[float, str]], higher_better: bool = True) -> str | None:
    """bands: [(threshold, grade)...] 위에서부터 검사."""
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return None
    for th, g in bands:
        if (v >= th) if higher_better else (v <= th):
            return g
    return "F"


_GRADE_WORD = {"A": "매우 좋음", "B": "좋음", "C": "보통", "D": "주의", "F": "위험"}
_GRADE_NUM = {"A": 4, "B": 3, "C": 2, "D": 1, "F": 0}


def _row(fr: pd.DataFrame, name: str, col=None):
    try:
        if fr is None or fr.empty or name not in fr.index:
            return None
        s = fr.loc[name]
        v = s.iloc[0] if col is None else s.loc[col]
        return None if pd.isna(v) else float(v)
    except Exception:  # noqa: BLE001
        return None


def _piotroski(fin: pd.DataFrame, bs: pd.DataFrame, cf: pd.DataFrame) -> dict | None:
    """피오트로스키 F점수 (0~9). 최근 연도 vs 전년."""
    try:
        if fin is None or bs is None or cf is None or fin.shape[1] < 2 or bs.shape[1] < 2:
            return None
        c0, c1 = fin.columns[0], fin.columns[1]
        ni0, ni1 = _row(fin, "Net Income", c0), _row(fin, "Net Income", c1)
        ta0, ta1 = _row(bs, "Total Assets", c0), _row(bs, "Total Assets", c1)
        cfo0 = _row(cf, "Operating Cash Flow", c0)
        ltd0, ltd1 = _row(bs, "Long Term Debt", c0) or 0.0, _row(bs, "Long Term Debt", c1) or 0.0
        ca0, ca1 = _row(bs, "Current Assets", c0), _row(bs, "Current Assets", c1)
        cl0, cl1 = _row(bs, "Current Liabilities", c0), _row(bs, "Current Liabilities", c1)
        sh0, sh1 = _row(fin, "Diluted Average Shares", c0), _row(fin, "Diluted Average Shares", c1)
        gp0, gp1 = _row(fin, "Gross Profit", c0), _row(fin, "Gross Profit", c1)
        rv0, rv1 = _row(fin, "Total Revenue", c0), _row(fin, "Total Revenue", c1)
        if None in (ni0, ni1, ta0, ta1, cfo0, rv0, rv1) or not ta0 or not ta1:
            return None
        roa0, roa1 = ni0 / ta0, ni1 / ta1
        pts = {
            "순이익 흑자": ni0 > 0,
            "영업현금흐름 흑자": cfo0 > 0,
            "ROA 개선": roa0 > roa1,
            "현금흐름 > 순이익": cfo0 > ni0,
            "장기부채 감소": (ltd0 / ta0) < (ltd1 / ta1),
            "유동비율 개선": (ca0 and cl0 and ca1 and cl1) and (ca0 / cl0) > (ca1 / cl1),
            "신주 발행 없음": (sh0 is not None and sh1 is not None and sh0 <= sh1 * 1.02),
            "매출총이익률 개선": (gp0 is not None and gp1 is not None and (gp0 / rv0) > (gp1 / rv1)),
            "자산회전율 개선": (rv0 / ta0) > (rv1 / ta1),
        }
        pts = {k: bool(v) for k, v in pts.items()}
        return {"score": sum(pts.values()), "points": pts}
    except Exception as e:  # noqa: BLE001
        log.debug("piotroski 실패: %s", e)
        return None


def _altman(fin: pd.DataFrame, bs: pd.DataFrame, market_cap: float | None, sector: str) -> dict | None:
    """알트만 Z (비금융). >2.99 안전 / 1.81~2.99 회색 / <1.81 위험."""
    try:
        if fin is None or bs is None or fin.empty or bs.empty or market_cap is None:
            return None
        if "financ" in (sector or "").lower():
            return None
        c0 = bs.columns[0]
        ta = _row(bs, "Total Assets", c0)
        tl = _row(bs, "Total Liabilities Net Minority Interest", c0)
        ca, cl = _row(bs, "Current Assets", c0), _row(bs, "Current Liabilities", c0)
        re = _row(bs, "Retained Earnings", c0)
        ebit = _row(fin, "EBIT", fin.columns[0])
        sales = _row(fin, "Total Revenue", fin.columns[0])
        if None in (ta, tl, ca, cl, re, ebit, sales) or not ta or not tl:
            return None
        z = 1.2 * (ca - cl) / ta + 1.4 * re / ta + 3.3 * ebit / ta + 0.6 * market_cap / tl + 1.0 * sales / ta
        zone = "안전" if z > 2.99 else ("회색지대" if z >= 1.81 else "위험")
        return {"z": round(z, 2), "zone": zone}
    except Exception as e:  # noqa: BLE001
        log.debug("altman 실패: %s", e)
        return None


def analyst_and_health(ticker: str) -> dict:
    out: dict = {"ticker": ticker}
    try:
        t = yf.Ticker(ticker)
        info = t.info or {}
    except Exception as e:  # noqa: BLE001
        log.warning("info 실패 %s: %s", ticker, e)
        return out
    price = info.get("currentPrice") or info.get("regularMarketPrice")
    out["name"] = info.get("shortName") or info.get("longName") or ""
    out["sector"] = info.get("sector") or ""
    out["industry"] = info.get("industry") or ""
    out["market_cap"] = info.get("marketCap")
    out["description"] = (info.get("longBusinessSummary") or "")[:600]
    out["price"] = price

    # 애널리스트
    rec_key = info.get("recommendationKey") or ""
    rec_ko = {"strong_buy": "적극 매수", "buy": "매수", "hold": "중립", "sell": "매도", "strong_sell": "적극 매도",
              "underperform": "비중 축소", "none": "의견 없음"}.get(rec_key, rec_key or "정보 없음")
    tgt = info.get("targetMeanPrice")
    out["analyst"] = {
        "recommendation": rec_ko,
        "count": info.get("numberOfAnalystOpinions"),
        "target_mean": tgt, "target_low": info.get("targetLowPrice"), "target_high": info.get("targetHighPrice"),
        "upside_pct": round((tgt / price - 1) * 100, 1) if tgt and price else None,
    }
    try:
        rec = t.recommendations
        if rec is not None and not rec.empty:
            r0 = rec.iloc[0]
            out["analyst"]["breakdown"] = {"strong_buy": int(r0.get("strongBuy", 0)), "buy": int(r0.get("buy", 0)),
                                           "hold": int(r0.get("hold", 0)), "sell": int(r0.get("sell", 0)),
                                           "strong_sell": int(r0.get("strongSell", 0))}
    except Exception:  # noqa: BLE001
        pass
    # 실적 발표
    try:
        cal = t.calendar or {}
        ed = cal.get("Earnings Date")
        if ed:
            d = ed[0] if isinstance(ed, (list, tuple)) else ed
            out["next_earnings"] = pd.Timestamp(d).strftime("%Y-%m-%d")
            out["earnings_est"] = {"eps_avg": cal.get("Earnings Average"), "revenue_avg": cal.get("Revenue Average")}
    except Exception:  # noqa: BLE001
        pass
    # 공매도 / 보유
    spf = info.get("shortPercentOfFloat")
    out["short"] = {
        "pct_of_float": round(spf * 100, 1) if spf is not None else None,
        "days_to_cover": info.get("shortRatio"),
        "level": None if spf is None else ("매우 높음" if spf > 0.25 else "높음" if spf > 0.15 else "보통" if spf > 0.05 else "낮음"),
        "institutions_pct": round((info.get("heldPercentInstitutions") or 0) * 100, 1) if info.get("heldPercentInstitutions") is not None else None,
        "insiders_pct": round((info.get("heldPercentInsiders") or 0) * 100, 1) if info.get("heldPercentInsiders") is not None else None,
    }

    # 재무건전성 항목별 등급
    pct = lambda x: None if x is None else x * 100  # noqa: E731
    de = info.get("debtToEquity")
    cr = info.get("currentRatio")
    fcf = info.get("freeCashflow")
    rev = info.get("totalRevenue")
    om = pct(info.get("operatingMargins"))
    rg = pct(info.get("revenueGrowth"))
    roe = pct(info.get("returnOnEquity"))
    pm = pct(info.get("profitMargins"))
    cash, debt = info.get("totalCash"), info.get("totalDebt")
    fcf_m = (fcf / rev * 100) if (fcf is not None and rev) else None
    items = [
        {"key": "debt", "name": "부채비율", "value": de, "unit": "%",
         "grade": _grade(de, [(50, "A"), (100, "B"), (150, "C"), (250, "D")], higher_better=False),
         "note": "자본 대비 부채. 150% 이하면 스크리너 장기 기준 통과"},
        {"key": "liquidity", "name": "유동비율", "value": cr, "unit": "x",
         "grade": _grade(cr, [(2, "A"), (1.5, "B"), (1, "C"), (0.8, "D")]),
         "note": "1년 안에 갚을 돈 대비 현금화 가능 자산. 1 미만이면 단기 자금 압박"},
        {"key": "fcf", "name": "잉여현금흐름/매출", "value": None if fcf_m is None else round(fcf_m, 1), "unit": "%",
         "grade": _grade(fcf_m, [(10, "A"), (0.0001, "B"), (-5, "C"), (-20, "D")]),
         "note": "영업으로 실제 남는 현금. 마이너스면 외부 자금(증자·차입)에 의존"},
        {"key": "op_margin", "name": "영업이익률", "value": None if om is None else round(om, 1), "unit": "%",
         "grade": _grade(om, [(20, "A"), (10, "B"), (0, "C"), (-20, "D")]),
         "note": "본업 수익성. 10% 이상이면 스크리너 장기 기준 통과"},
        {"key": "growth", "name": "매출 성장(yoy)", "value": None if rg is None else round(rg, 1), "unit": "%",
         "grade": _grade(rg, [(30, "A"), (15, "B"), (5, "C"), (0, "D")]),
         "note": "최근 분기 매출의 전년 대비 성장"},
        {"key": "roe", "name": "ROE", "value": None if roe is None else round(roe, 1), "unit": "%",
         "grade": _grade(roe, [(20, "A"), (15, "B"), (5, "C"), (0, "D")]),
         "note": "자본 대비 이익. 15% 이상이면 스크리너 장기 기준 통과"},
        {"key": "net_margin", "name": "순이익률", "value": None if pm is None else round(pm, 1), "unit": "%",
         "grade": _grade(pm, [(15, "A"), (5, "B"), (0, "C"), (-20, "D")]),
         "note": "매출에서 최종적으로 남는 비율"},
    ]
    for it in items:
        it["word"] = _GRADE_WORD.get(it["grade"]) if it["grade"] else "정보 없음"
    graded = [it for it in items if it["grade"]]
    avg = sum(_GRADE_NUM[it["grade"]] for it in graded) / len(graded) if graded else None
    overall = None if avg is None else ("A" if avg >= 3.5 else "B" if avg >= 2.5 else "C" if avg >= 1.5 else "D" if avg >= 0.75 else "F")

    # 재무제표 기반 점수
    fin = bs = cf = None
    try:
        fin, bs, cf = t.financials, t.balance_sheet, t.cashflow
    except Exception as e:  # noqa: BLE001
        log.debug("재무제표 실패 %s: %s", ticker, e)
    pio = _piotroski(fin, bs, cf)
    alt = _altman(fin, bs, out["market_cap"], out["sector"])

    # 최근 연간 실적 4년 (표)
    years = []
    try:
        if fin is not None and not fin.empty:
            for c in list(fin.columns)[:4]:
                years.append({
                    "year": pd.Timestamp(c).strftime("%Y"),
                    "revenue": _row(fin, "Total Revenue", c),
                    "operating_income": _row(fin, "Operating Income", c),
                    "net_income": _row(fin, "Net Income", c),
                    "eps": _row(fin, "Diluted EPS", c),
                    "operating_cash_flow": _row(cf, "Operating Cash Flow", c) if cf is not None else None,
                    "free_cash_flow": _row(cf, "Free Cash Flow", c) if cf is not None else None,
                    "total_debt": _row(bs, "Total Debt", c) if bs is not None else None,
                    "cash": _row(bs, "Cash And Cash Equivalents", c) if bs is not None else None,
                    "equity": _row(bs, "Stockholders Equity", c) if bs is not None else None,
                })
    except Exception:  # noqa: BLE001
        pass

    # 한 줄 종합
    lines = []
    if overall:
        lines.append(f"재무건전성 종합 {overall} ({_GRADE_WORD[overall]})")
    if cash is not None and debt is not None:
        lines.append("현금이 부채보다 많음" if cash > debt else "부채가 현금보다 많음")
    if fcf is not None:
        lines.append("현금을 벌고 있음" if fcf > 0 else "현금을 태우는 중(적자 현금흐름)")
    if pio:
        lines.append(f"피오트로스키 F점수 {pio['score']}/9 ({'우량' if pio['score'] >= 7 else '보통' if pio['score'] >= 4 else '취약'})")
    if alt:
        lines.append(f"알트만 Z {alt['z']} ({alt['zone']})")
    out["health"] = {
        "overall": overall, "overall_word": _GRADE_WORD.get(overall) if overall else None,
        "items": items, "piotroski": pio, "altman": alt, "summary": " · ".join(lines),
        "cash": cash, "debt": debt, "years": years,
    }
    out["valuation"] = {"trailing_pe": info.get("trailingPE"), "forward_pe": info.get("forwardPE"),
                        "price_to_book": info.get("priceToBook"), "peg": info.get("trailingPegRatio")}
    return out


def build_context(tickers: list[str], news_n: int = 8, sleep: float = 0.3) -> dict:
    """후보 종목들의 근거 묶음. 이전 결과가 있으면 하루 안 된 항목은 재사용."""
    path = OUTPUT_DIR / "us_context.json"
    prev = {}
    if path.exists():
        try:
            prev = json.loads(path.read_text(encoding="utf-8")).get("items", {})
        except Exception:  # noqa: BLE001
            prev = {}
    now = datetime.now(timezone.utc)
    items = {}
    for i, tk in enumerate(sorted(set(tickers))):
        old = prev.get(tk)
        fresh = False
        if old and old.get("updated"):
            try:
                fresh = (now - datetime.fromisoformat(old["updated"])).total_seconds() < 20 * 3600
            except Exception:  # noqa: BLE001
                fresh = False
        if fresh:
            d = dict(old)
        else:
            d = analyst_and_health(tk)
            time.sleep(sleep)
        d["news"] = news_for_ticker(tk, news_n)  # 뉴스는 매번 갱신
        d["updated"] = now.isoformat()
        items[tk] = d
        if (i + 1) % 10 == 0:
            log.info("  근거 수집 %d/%d", i + 1, len(tickers))
    log.info("근거 수집 완료: %d 종목", len(items))
    return {"generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "count": len(items), "items": items}
