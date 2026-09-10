"""종목 리스트.

- 미국 전체 보통주: NASDAQ Trader 공개 파일 (nasdaqlisted.txt, otherlisted.txt)
- 장기용 유니버스: S&P 500 + 나스닥 100 (위키피디아, 실패 시 캐시)
"""
from __future__ import annotations

import io
import json
import logging
import re
import time
from datetime import datetime, timezone

import pandas as pd
import requests

from .config import DATA_DIR, OUTPUT_DIR

log = logging.getLogger(__name__)

NASDAQ_LISTED_URL = "https://www.nasdaqtrader.com/dynamic/SymDir/nasdaqlisted.txt"
OTHER_LISTED_URL = "https://www.nasdaqtrader.com/dynamic/SymDir/otherlisted.txt"
SP500_URL = "https://en.wikipedia.org/wiki/List_of_S%26P_500_companies"
NDX_URL = "https://en.wikipedia.org/wiki/List_of_NASDAQ-100_companies"
NDX_URL_FALLBACK = "https://en.wikipedia.org/wiki/Nasdaq-100"

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0 Safari/537.36 stock-screener/1.0"
}

# 이름으로 걸러낼 비(非)보통주 패턴
_EXCLUDE_NAME_RE = re.compile(
    r"warrant|\bunits?\b|preferred|preference|\brights?\b|\bnotes?\b|debenture|"
    r"\bbonds?\b|\betn\b|\bfund\b|trust preferred|closed[- ]end|"
    r"(?<!american )depositary shares?,? (each )?representing|"
    r"subordinated|senior notes|capital securities|\bspac\b|"
    r"contingent value|\bcvr\b|when[- ]issued|"
    # 폐쇄형 펀드 / 로열티 트러스트 (보통주 아님)
    r"term trust|income trust|municipal|bond trust|royalty trust|tax[- ](free|exempt|advantaged|managed)|"
    r"floating rate|senior loan|total return|dividend (and|&) income|allocation (term|trust)|"
    r"opportunit\w* (term |trust)|equity (income|opportunit)|strategic \w+ trust|credit (strategies|income|opportunit)|"
    r"health sciences trust|science (and|&) technology trust|innovation (and|&) growth trust|"
    r"capital (and|&) income|ESG capital|multi-?sector|convertible|mlp\b|\benergy infrastructure trust",
    re.IGNORECASE,
)
# 심볼로 걸러낼 패턴 (우선주 $ / - , 워런트 + / .W , 유닛 = / .U , 권리 ^ / .R)
_EXCLUDE_SYMBOL_RE = re.compile(r"[$+=^\-]|\.(W|WS|WSA|WSB|U|R|RT|WI)$", re.IGNORECASE)


def _fetch_text(url: str, retries: int = 3, timeout: int = 30) -> str:
    last = None
    for i in range(retries):
        try:
            r = requests.get(url, headers=HEADERS, timeout=timeout)
            r.raise_for_status()
            return r.text
        except Exception as e:  # noqa: BLE001
            last = e
            log.warning("fetch failed (%d/%d) %s: %s", i + 1, retries, url, e)
            time.sleep(2 * (i + 1))
    raise RuntimeError(f"fetch failed: {url}: {last}")


def _fetch_symdir(name: str) -> str:
    """NASDAQ Trader 심볼 파일. HTTPS 가 봇 차단(Incapsula)되면 FTP 로 재시도."""
    https = f"https://www.nasdaqtrader.com/dynamic/SymDir/{name}"
    try:
        t = _fetch_text(https, retries=2)
        if "Symbol|" in t[:200] or "ACT Symbol|" in t[:200]:
            return t
        log.warning("NASDAQ Trader HTTPS 응답이 심볼 파일이 아님 (봇 차단?) → FTP 시도")
    except Exception as e:  # noqa: BLE001
        log.warning("NASDAQ Trader HTTPS 실패: %s → FTP 시도", e)
    import urllib.request
    with urllib.request.urlopen(f"ftp://ftp.nasdaqtrader.com/SymbolDirectory/{name}", timeout=60) as r:
        t = r.read().decode("utf-8", errors="replace")
    if not ("Symbol|" in t[:200] or "ACT Symbol|" in t[:200]):
        raise RuntimeError(f"{name}: 심볼 파일 형식이 아님")
    return t


def _parse_pipe_file(text: str) -> pd.DataFrame:
    lines = [ln for ln in text.splitlines() if ln.strip() and not ln.startswith("File Creation Time")]
    df = pd.read_csv(io.StringIO("\n".join(lines)), sep="|", dtype=str).fillna("")
    df.columns = [c.strip() for c in df.columns]
    return df


def _to_yahoo(symbol: str) -> str:
    """NASDAQ 심볼 → yfinance 심볼 (BRK.B → BRK-B)."""
    return symbol.strip().replace(".", "-")


def us_common_stocks(use_cache_on_fail: bool = True) -> pd.DataFrame:
    """미국 상장 보통주 목록. columns: ticker, name, exchange"""
    cache = DATA_DIR / "us_tickers.json"
    fallback = OUTPUT_DIR / "us_tickers.csv"
    try:
        nas = _parse_pipe_file(_fetch_symdir("nasdaqlisted.txt"))
        oth = _parse_pipe_file(_fetch_symdir("otherlisted.txt"))
    except Exception as e:  # noqa: BLE001
        if use_cache_on_fail and cache.exists():
            log.warning("NASDAQ Trader 다운로드 실패, 캐시 사용: %s", e)
            return pd.DataFrame(json.loads(cache.read_text(encoding="utf-8")))
        if use_cache_on_fail and fallback.exists():
            log.warning("NASDAQ Trader 다운로드 실패, 저장소 사본 사용: %s", e)
            return pd.read_csv(fallback)
        raise

    rows = []
    # nasdaqlisted: Symbol|Security Name|Market Category|Test Issue|Financial Status|Round Lot Size|ETF|NextShares
    for _, r in nas.iterrows():
        sym = r["Symbol"].strip()
        name = r["Security Name"].strip()
        if r.get("Test Issue", "N").strip() == "Y":
            continue
        if r.get("ETF", "N").strip() == "Y":
            continue
        if r.get("NextShares", "N").strip() == "Y":
            continue
        if _EXCLUDE_SYMBOL_RE.search(sym) or _EXCLUDE_NAME_RE.search(name):
            continue
        rows.append({"ticker": _to_yahoo(sym), "name": name, "exchange": "NASDAQ"})

    # otherlisted: ACT Symbol|Security Name|Exchange|CQS Symbol|ETF|Round Lot Size|Test Issue|NASDAQ Symbol
    exch_map = {"N": "NYSE", "A": "NYSE American", "P": "NYSE Arca", "Z": "BATS", "V": "IEX"}
    for _, r in oth.iterrows():
        sym = r.get("NASDAQ Symbol", r.get("ACT Symbol", "")).strip()
        name = r["Security Name"].strip()
        if r.get("Test Issue", "N").strip() == "Y":
            continue
        if r.get("ETF", "N").strip() == "Y":
            continue
        exch = r.get("Exchange", "").strip()
        if exch in ("P", "Z"):  # Arca / BATS 는 사실상 ETF 전용
            continue
        if _EXCLUDE_SYMBOL_RE.search(sym) or _EXCLUDE_NAME_RE.search(name):
            continue
        rows.append({"ticker": _to_yahoo(sym), "name": name, "exchange": exch_map.get(exch, exch)})

    df = pd.DataFrame(rows).drop_duplicates("ticker").sort_values("ticker").reset_index(drop=True)
    df = df[df["ticker"].str.match(r"^[A-Z][A-Z0-9\-]{0,7}$")]
    cache.write_text(json.dumps(df.to_dict("records"), ensure_ascii=False), encoding="utf-8")
    df.to_csv(fallback, index=False, encoding="utf-8")
    log.info("미국 보통주 %d 종목", len(df))
    return df


# ---------------------------------------------------------------------------
# 장기 유니버스: S&P 500 + 나스닥 100
# ---------------------------------------------------------------------------

def _read_wiki_table(url: str, must_have: tuple[str, ...], min_rows: int = 50) -> pd.DataFrame:
    html = _fetch_text(url)
    tables = pd.read_html(io.StringIO(html))
    for t in tables:
        cols = [str(c).split("[")[0].strip() for c in t.columns]
        if any(m in cols for m in must_have) and len(t) >= min_rows:
            t = t.copy()
            t.columns = cols
            return t
    raise RuntimeError(f"표를 찾지 못함: {url}")


def long_universe(force_refresh: bool = False) -> pd.DataFrame:
    """S&P 500 + 나스닥 100 구성 종목. columns: ticker, name, sector, in_sp500, in_ndx"""
    cache = DATA_DIR / "us_long_universe.json"
    fallback = OUTPUT_DIR / "us_long_universe.csv"

    if not force_refresh and cache.exists():
        try:
            meta = json.loads(cache.read_text(encoding="utf-8"))
            age = (datetime.now(timezone.utc) - datetime.fromisoformat(meta["updated"])).days
            if age <= 7:
                return pd.DataFrame(meta["rows"])
        except Exception:  # noqa: BLE001
            pass

    try:
        sp = _read_wiki_table(SP500_URL, ("Symbol",))
        sym_col = "Symbol"
        name_col = "Security" if "Security" in sp.columns else sp.columns[1]
        sector_col = "GICS Sector" if "GICS Sector" in sp.columns else None
        sp_rows = {}
        for _, r in sp.iterrows():
            t = _to_yahoo(str(r[sym_col]))
            sp_rows[t] = {
                "ticker": t,
                "name": str(r[name_col]),
                "sector": str(r[sector_col]) if sector_col else "",
                "in_sp500": True,
                "in_ndx": False,
            }

        try:
            ndx = _read_wiki_table(NDX_URL, ("Ticker", "Symbol"))
        except Exception:  # noqa: BLE001
            ndx = _read_wiki_table(NDX_URL_FALLBACK, ("Ticker", "Symbol"))
        sym_col = "Ticker" if "Ticker" in ndx.columns else "Symbol"
        name_col = "Company" if "Company" in ndx.columns else ndx.columns[0]
        sector_col = next((c for c in ("GICS Sector", "ICB Industry", "Sector") if c in ndx.columns), None)
        for _, r in ndx.iterrows():
            t = _to_yahoo(str(r[sym_col]))
            if t in sp_rows:
                sp_rows[t]["in_ndx"] = True
            else:
                sp_rows[t] = {
                    "ticker": t,
                    "name": str(r[name_col]),
                    "sector": str(r[sector_col]) if sector_col else "",
                    "in_sp500": False,
                    "in_ndx": True,
                }
        df = pd.DataFrame(list(sp_rows.values())).sort_values("ticker").reset_index(drop=True)
        if len(df) < 400:
            raise RuntimeError(f"유니버스가 너무 작음: {len(df)}")
        cache.write_text(
            json.dumps({"updated": datetime.now(timezone.utc).isoformat(), "rows": df.to_dict("records")},
                       ensure_ascii=False),
            encoding="utf-8",
        )
        df.to_csv(fallback, index=False, encoding="utf-8")
        log.info("장기 유니버스 %d 종목 (S&P500 %d, NDX %d)", len(df), df.in_sp500.sum(), df.in_ndx.sum())
        return df
    except Exception as e:  # noqa: BLE001
        log.warning("위키피디아 구성 종목 표 실패, 캐시 사용: %s", e)
        if cache.exists():
            return pd.DataFrame(json.loads(cache.read_text(encoding="utf-8"))["rows"])
        if fallback.exists():
            return pd.read_csv(fallback)
        raise
