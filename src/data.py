"""가격 데이터: yfinance 일봉 OHLCV, 배치 다운로드 + 재시도 + parquet 캐시 + 증분 업데이트."""
from __future__ import annotations

import logging
import time
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import numpy as np
import pandas as pd
import yfinance as yf

from .config import DATA_DIR, load_config

log = logging.getLogger(__name__)

ET = ZoneInfo("America/New_York")
KST = ZoneInfo("Asia/Seoul")
FIELDS = ["open", "high", "low", "close", "volume"]

try:  # yfinance 시간대 캐시를 data/ 아래에 두기 (윈도우 잠금 오류 방지)
    (DATA_DIR / "yf_cache").mkdir(parents=True, exist_ok=True)
    yf.set_tz_cache_location(str(DATA_DIR / "yf_cache"))
except Exception:  # noqa: BLE001
    pass


def now_et() -> datetime:
    return datetime.now(ET)


def market_session_open_now(market: str = "us") -> bool:
    """현재 정규장 시간인지 (미국: 09:30~16:00 ET 평일)."""
    if market == "us":
        n = now_et()
        if n.weekday() >= 5:
            return False
        t = n.hour * 60 + n.minute
        return 9 * 60 + 30 <= t < 16 * 60
    n = datetime.now(KST)
    if n.weekday() >= 5:
        return False
    t = n.hour * 60 + n.minute
    return 9 * 60 <= t < 15 * 60 + 30


def _normalize(df: pd.DataFrame, ticker: str) -> pd.DataFrame | None:
    """yfinance 단일 종목 프레임 → long 형식."""
    if df is None or df.empty:
        return None
    d = df.copy()
    d.columns = [str(c).lower() for c in d.columns]
    if "close" not in d.columns:
        return None
    d = d[[c for c in FIELDS if c in d.columns]]
    d = d.dropna(subset=["close"])
    if d.empty:
        return None
    d.index = pd.to_datetime(d.index)
    if getattr(d.index, "tz", None) is not None:
        d.index = d.index.tz_localize(None)
    d.index = d.index.normalize()
    d = d[~d.index.duplicated(keep="last")]
    d = d.reset_index().rename(columns={"index": "date", "Date": "date"})
    d["ticker"] = ticker
    return d[["ticker", "date"] + [c for c in FIELDS if c in d.columns]]


def _download_batch(tickers: list[str], start: str | None = None, period: str | None = None,
                    retries: int = 3) -> tuple[pd.DataFrame, list[str]]:
    """배치 다운로드. (long df, 실패 티커) 반환."""
    frames: list[pd.DataFrame] = []
    failed: list[str] = []
    todo = list(tickers)
    for attempt in range(retries):
        if not todo:
            break
        try:
            kw = dict(group_by="ticker", auto_adjust=True, threads=True, progress=False,
                      actions=False, timeout=30)
            if start:
                raw = yf.download(todo, start=start, **kw)
            else:
                raw = yf.download(todo, period=period or "2y", **kw)
        except Exception as e:  # noqa: BLE001
            log.warning("yf.download 예외 (%d/%d): %s", attempt + 1, retries, e)
            time.sleep(5 * (attempt + 1))
            continue
        if raw is None or raw.empty:
            time.sleep(5 * (attempt + 1))
            continue
        got: set[str] = set()
        if isinstance(raw.columns, pd.MultiIndex):
            lvl0 = raw.columns.get_level_values(0)
            for t in todo:
                if t in lvl0:
                    n = _normalize(raw[t], t)
                    if n is not None:
                        frames.append(n)
                        got.add(t)
        else:  # 단일 종목
            n = _normalize(raw, todo[0])
            if n is not None:
                frames.append(n)
                got.add(todo[0])
        todo = [t for t in todo if t not in got]
        if todo and attempt < retries - 1:
            time.sleep(3 * (attempt + 1))
    failed = todo
    out = pd.concat(frames, ignore_index=True) if frames else pd.DataFrame(columns=["ticker", "date"] + FIELDS)
    return out, failed


def _cache_path(name: str) -> "Path":
    from pathlib import Path  # noqa: F401
    return DATA_DIR / f"prices_{name}.parquet"


def _load_cache(name: str) -> pd.DataFrame | None:
    p = _cache_path(name)
    if not p.exists():
        return None
    try:
        df = pd.read_parquet(p)
        df["date"] = pd.to_datetime(df["date"])
        return df
    except Exception as e:  # noqa: BLE001
        log.warning("캐시 읽기 실패 %s: %s", p, e)
        return None


def _save_cache(name: str, df: pd.DataFrame) -> None:
    p = _cache_path(name)
    tmp = p.with_suffix(".tmp.parquet")
    df.to_parquet(tmp, index=False)
    tmp.replace(p)


def _period_for_days(lookback_days: int) -> str:
    years = int(np.ceil(lookback_days / 252 * 1.2)) + 1
    return f"{max(years, 2)}y"


def get_daily(tickers: list[str], lookback_days: int | None = None, start: str | None = None,
              name: str = "us", force_full: bool = False, drop_partial_today: bool = True,
              market: str = "us", offline: bool = False) -> pd.DataFrame:
    """일봉 long 데이터프레임 (ticker, date, open, high, low, close, volume).

    - lookback_days: 스크리너용 (최근 N거래일만 유지)
    - start: 백테스트용 (이 날짜부터 전체)
    - 캐시가 있으면 최근 구간만 받아서 병합하고, 분할 등으로 과거 값이 달라진 종목은 전체 재다운로드
    - offline: 다운로드 없이 캐시만 사용
    """
    cfg = load_config()["data"]
    lookback_days = lookback_days or cfg["screener_lookback_days"]
    batch_size = cfg["batch_size"]
    retries = cfg["retries"]
    tickers = sorted(set(tickers))

    if offline:
        cached = _load_cache(name)
        if cached is None or cached.empty:
            raise RuntimeError("오프라인 모드인데 캐시가 없습니다")
        cached = cached[cached["ticker"].isin(tickers)].reset_index(drop=True)
        log.info("오프라인: 캐시 %d 종목, 최근일 %s", cached["ticker"].nunique(), cached["date"].max().date())
        return cached

    cached = None if force_full else _load_cache(name)
    today = pd.Timestamp(now_et().date())
    if cached is not None and not cached.empty:
        cached = cached[cached["ticker"].isin(tickers)]
        last_by_t = cached.groupby("ticker")["date"].max()
        cnt_by_t = cached.groupby("ticker")["date"].count()
        min_rows = 30 if start else min(lookback_days, 250)
        # 충분한 과거 데이터가 있는 종목만 증분
        ok = last_by_t.index[(cnt_by_t.reindex(last_by_t.index) >= min_rows).values]
        inc_tickers = [t for t in tickers if t in set(ok)]
        full_tickers = [t for t in tickers if t not in set(ok)]
        last_date = last_by_t.reindex(inc_tickers).max() if inc_tickers else None
    else:
        cached = pd.DataFrame(columns=["ticker", "date"] + FIELDS)
        inc_tickers, full_tickers, last_date = [], list(tickers), None

    frames = [cached]
    failed_all: list[str] = []

    # 1) 증분 (최근 ~30일, 겹치는 구간으로 분할/조정 감지)
    if inc_tickers:
        inc_start = (pd.Timestamp(last_date) - timedelta(days=45)).strftime("%Y-%m-%d")
        log.info("증분 다운로드 %d 종목 (%s ~)", len(inc_tickers), inc_start)
        inc_frames = []
        for i in range(0, len(inc_tickers), batch_size):
            b = inc_tickers[i:i + batch_size]
            df, failed = _download_batch(b, start=inc_start, retries=retries)
            inc_frames.append(df)
            failed_all += failed
            log.info("  증분 배치 %d/%d 완료 (실패 %d)", i // batch_size + 1,
                     (len(inc_tickers) + batch_size - 1) // batch_size, len(failed))
        inc = pd.concat(inc_frames, ignore_index=True) if inc_frames else cached.iloc[0:0]
        # 겹치는 구간 종가 비교 → 1% 넘게 다르면 전체 재다운로드
        if not inc.empty:
            ov = cached.merge(inc, on=["ticker", "date"], suffixes=("_old", "_new"))
            ov = ov[ov["close_old"] > 0]
            ratio = (ov["close_new"] / ov["close_old"] - 1).abs()
            changed = sorted(set(ov.loc[ratio > 0.01, "ticker"]))
            if changed:
                log.info("가격 조정 감지(분할/배당) %d 종목 → 전체 재다운로드", len(changed))
                full_tickers += changed
                inc = inc[~inc["ticker"].isin(changed)]
                frames[0] = cached[~cached["ticker"].isin(changed)]
        frames.append(inc)

    # 2) 전체
    full_tickers = sorted(set(full_tickers))
    if full_tickers:
        log.info("전체 다운로드 %d 종목", len(full_tickers))
        for i in range(0, len(full_tickers), batch_size):
            b = full_tickers[i:i + batch_size]
            if start:
                df, failed = _download_batch(b, start=start, retries=retries)
            else:
                df, failed = _download_batch(b, period=_period_for_days(lookback_days), retries=retries)
            frames.append(df)
            failed_all += failed
            log.info("  전체 배치 %d/%d 완료 (실패 %d)", i // batch_size + 1,
                     (len(full_tickers) + batch_size - 1) // batch_size, len(failed))

    allf = pd.concat([f for f in frames if f is not None and not f.empty], ignore_index=True) \
        if any(f is not None and not f.empty for f in frames) else cached
    if allf.empty:
        raise RuntimeError("가격 데이터를 하나도 받지 못했습니다")
    allf["date"] = pd.to_datetime(allf["date"])
    allf = allf.sort_values(["ticker", "date"]).drop_duplicates(["ticker", "date"], keep="last")
    for c in FIELDS:
        allf[c] = pd.to_numeric(allf[c], errors="coerce")

    # 장중이면 오늘 미완성 봉 제거
    if drop_partial_today and market_session_open_now(market):
        allf = allf[allf["date"] < today]

    # 스크리너 모드면 최근 N+60 거래일만 보관
    if not start:
        keep = lookback_days + 60
        allf = allf.groupby("ticker", group_keys=False).tail(keep)

    _save_cache(name, allf.reset_index(drop=True))
    n_ok = allf["ticker"].nunique()
    log.info("가격 데이터: %d/%d 종목, 최근일 %s (실패 %d)", n_ok, len(tickers),
             allf["date"].max().date(), len(set(failed_all)))
    return allf.reset_index(drop=True)


def to_wide(long_df: pd.DataFrame) -> dict[str, pd.DataFrame]:
    """long → {field: DataFrame(index=date, columns=ticker)}"""
    out = {}
    for f in FIELDS:
        out[f] = long_df.pivot(index="date", columns="ticker", values=f).sort_index()
    return out


def last_complete_pos(close_wide: pd.DataFrame, min_frac: float = 0.8, window: int = 30) -> int:
    """대부분(min_frac) 종목에 데이터가 있는 마지막 날짜의 정수 위치."""
    counts = close_wide.notna().sum(axis=1)
    ref = counts.iloc[-window:].max()
    ok = (counts >= ref * min_frac).to_numpy()
    idx = np.where(ok)[0]
    return int(idx[-1]) if len(idx) else len(counts) - 1


def trim_incomplete(w: dict[str, pd.DataFrame], min_frac: float = 0.8) -> dict[str, pd.DataFrame]:
    """뒤쪽의 미완성(일부 종목만 있는) 날짜를 잘라낸다."""
    pos = last_complete_pos(w["close"], min_frac)
    n = len(w["close"])
    if pos < n - 1:
        log.info("미완성 날짜 %d개 제거 (마지막 완전한 날 %s)", n - 1 - pos, w["close"].index[pos].date())
    return {k: v.iloc[:pos + 1] for k, v in w.items()}


def expected_session_date(market: str = "us") -> pd.Timestamp | None:
    """장 마감 후라면 오늘(현지) 날짜, 아니면 None. (휴장일은 호출 쪽에서 데이터로 판단)"""
    if market == "us":
        n = now_et()
        if n.weekday() >= 5:
            return None
        if n.hour * 60 + n.minute >= 16 * 60 + 5:
            return pd.Timestamp(n.date())
        return None
    n = datetime.now(KST)
    if n.weekday() >= 5:
        return None
    if n.hour * 60 + n.minute >= 15 * 60 + 40:
        return pd.Timestamp(n.date())
    return None


def intraday_1m_summary(tickers: list[str], session_date: pd.Timestamp, batch_size: int = 300,
                        label: str = "1분봉") -> pd.DataFrame:
    """오늘(session_date) 정규장 1분봉 요약. columns:
    ticker, open(첫 봉 시가), high, low, last(마지막 봉 종가), cum_volume(누적), last_time(ET), minutes_elapsed
    1분봉이 없는 종목은 빠진다."""
    rows = []
    n_batches = (len(tickers) + batch_size - 1) // batch_size
    for i in range(0, len(tickers), batch_size):
        b = tickers[i:i + batch_size]
        try:
            raw = yf.download(b, period="1d", interval="1m", group_by="ticker", auto_adjust=False,
                              threads=True, progress=False, prepost=False, timeout=30)
        except Exception as e:  # noqa: BLE001
            log.warning("%s 배치 실패: %s", label, e)
            continue
        if raw is None or raw.empty:
            continue
        idx = raw.index
        if getattr(idx, "tz", None) is None:
            idx = idx.tz_localize("UTC")
        idx = idx.tz_convert(ET)
        minutes = idx.hour * 60 + idx.minute
        mask = (idx.normalize().tz_localize(None) == session_date) & (minutes >= 9 * 60 + 30) & (minutes < 16 * 60)
        if not mask.any():
            continue
        sub = raw[mask]
        sub_idx = idx[mask]
        lvl0 = sub.columns.get_level_values(0) if isinstance(sub.columns, pd.MultiIndex) else [b[0]]
        for t in b:
            if t not in lvl0:
                continue
            d = sub[t] if isinstance(sub.columns, pd.MultiIndex) else sub
            keep = d["Close"].notna().to_numpy()
            if not keep.any():
                continue
            d = d[keep]
            last_time = sub_idx[keep][-1]
            elapsed = max(1.0, min(390.0, last_time.hour * 60 + last_time.minute + 1 - (9 * 60 + 30)))
            rows.append({"ticker": t, "date": session_date, "open": float(d["Open"].iloc[0]),
                         "high": float(d["High"].max()), "low": float(d["Low"].min()),
                         "last": float(d["Close"].iloc[-1]), "cum_volume": float(d["Volume"].sum()),
                         "last_time": last_time.strftime("%Y-%m-%d %H:%M"), "minutes_elapsed": float(elapsed)})
        log.info("  %s 배치 %d/%d (누적 %d 종목)", label, i // batch_size + 1, n_batches, len(rows))
    return pd.DataFrame(rows, columns=["ticker", "date", "open", "high", "low", "last", "cum_volume",
                                       "last_time", "minutes_elapsed"])


def synthesize_today_from_1m(tickers: list[str], session_date: pd.Timestamp, batch_size: int = 300) -> pd.DataFrame:
    """Yahoo 일봉이 아직 안 나온 종목의 오늘 봉을 1분봉으로 합성 (open/high/low/close/volume)."""
    s = intraday_1m_summary(tickers, session_date, batch_size, label="1분봉 합성")
    if s.empty:
        return pd.DataFrame(columns=["ticker", "date"] + FIELDS)
    out = s.rename(columns={"last": "close", "cum_volume": "volume"})
    return out[["ticker", "date"] + FIELDS]


def fill_today_if_missing(long_df: pd.DataFrame, name: str = "us", market: str = "us",
                          min_missing_frac: float = 0.5) -> pd.DataFrame:
    """장 마감 후인데 오늘 일봉이 대부분 없으면 1분봉으로 합성해서 채운다. 캐시에도 반영."""
    sd = expected_session_date(market)
    if sd is None:
        return long_df
    last_by_t = long_df.groupby("ticker")["date"].max()
    have = (last_by_t >= sd)
    if have.mean() >= (1 - min_missing_frac):
        return long_df
    missing = sorted(last_by_t.index[~have])
    log.info("오늘(%s) 일봉이 %d/%d 종목만 있음 → 1분봉으로 합성 시도 (%d 종목)", sd.date(), int(have.sum()),
             len(last_by_t), len(missing))
    syn = synthesize_today_from_1m(missing, sd)
    if syn.empty or len(syn) < len(missing) * 0.3:
        log.warning("1분봉 합성 결과 부족 (%d 종목) → 휴장일이거나 데이터 없음, 건너뜀", len(syn))
        return long_df
    out = pd.concat([long_df, syn], ignore_index=True)
    out["date"] = pd.to_datetime(out["date"])
    out = out.sort_values(["ticker", "date"]).drop_duplicates(["ticker", "date"], keep="last").reset_index(drop=True)
    _save_cache(name, out)
    log.info("오늘 봉 합성 완료: %d 종목 추가", len(syn))
    return out


# ---------------------------------------------------------------------------
# 장중 데이터 (EP 용)
# ---------------------------------------------------------------------------

def intraday_today(tickers: list[str]) -> pd.DataFrame:
    """오늘 일봉(미완성) 한 줄씩: ticker, open, high, low, last, volume. 없으면 제외."""
    frames = []
    for i in range(0, len(tickers), 300):
        b = tickers[i:i + 300]
        try:
            raw = yf.download(b, period="5d", interval="1d", group_by="ticker", auto_adjust=False,
                              threads=True, progress=False, prepost=False, timeout=30)
        except Exception as e:  # noqa: BLE001
            log.warning("장중 일봉 다운로드 실패: %s", e)
            continue
        if raw is None or raw.empty:
            continue
        lvl0 = raw.columns.get_level_values(0) if isinstance(raw.columns, pd.MultiIndex) else [b[0]]
        for t in b:
            if t not in lvl0:
                continue
            d = raw[t] if isinstance(raw.columns, pd.MultiIndex) else raw
            d = d.dropna(subset=["Close"])
            if d.empty:
                continue
            last = d.iloc[-1]
            idx = d.index[-1]
            frames.append({"ticker": t, "date": pd.Timestamp(idx).tz_localize(None).normalize()
                           if getattr(idx, "tzinfo", None) else pd.Timestamp(idx).normalize(),
                           "open": float(last["Open"]), "high": float(last["High"]),
                           "low": float(last["Low"]), "last": float(last["Close"]),
                           "volume": float(last["Volume"])})
    return pd.DataFrame(frames)


def intraday_1m(ticker: str) -> pd.DataFrame | None:
    """오늘 1분봉. 없으면 None."""
    try:
        d = yf.download(ticker, period="1d", interval="1m", auto_adjust=False, progress=False,
                        prepost=False, threads=False, timeout=30)
    except Exception as e:  # noqa: BLE001
        log.warning("1분봉 실패 %s: %s", ticker, e)
        return None
    if d is None or d.empty:
        return None
    if isinstance(d.columns, pd.MultiIndex):
        d = d.droplevel(1, axis=1) if d.columns.nlevels > 1 else d
    d.columns = [str(c).lower() for c in d.columns]
    d = d.dropna(subset=["close"])
    if d.empty:
        return None
    if getattr(d.index, "tz", None) is not None:
        d.index = d.index.tz_convert(ET)
    else:
        d.index = d.index.tz_localize("UTC").tz_convert(ET)
    # 정규장만
    d = d[(d.index.hour * 60 + d.index.minute >= 9 * 60 + 30) & (d.index.hour * 60 + d.index.minute < 16 * 60)]
    return d if not d.empty else None
