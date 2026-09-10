"""주식 스크리너 실행 진입점.

사용법:
  python screener.py                 # 오늘 돌 것을 알아서 실행 (자동 모드)
  python screener.py --short         # 미국 단기 돌파 대기
  python screener.py --ep            # 미국 단기 EP (장중)
  python screener.py --mid           # 미국 중기
  python screener.py --long          # 미국 장기 (월 1회)
  python screener.py --insight       # 인사이트 (주 1회)
  python screener.py --market us|kr  # 시장 선택 (기본 us)
  python screener.py --force         # 시간/날짜 조건 무시하고 실행
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
import traceback
from datetime import datetime
from pathlib import Path

import pandas as pd

from src.config import OUTPUT_DIR, load_config
from src.data import ET, fill_today_if_missing, get_daily, now_et, to_wide, trim_incomplete
from src.indicators import compute
from src.universe import long_universe, us_common_stocks

log = logging.getLogger("screener")


def write_json(name: str, payload: dict) -> Path:
    p = OUTPUT_DIR / name
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=1, default=str), encoding="utf-8")
    tmp.replace(p)
    log.info("저장: %s", p)
    return p


def is_first_trading_day_of_month(dates: pd.DatetimeIndex) -> bool:
    if len(dates) == 0:
        return False
    last = dates[-1]
    same_month = dates[(dates.year == last.year) & (dates.month == last.month)]
    return len(same_month) == 1


def file_age_days(name: str) -> float:
    p = OUTPUT_DIR / name
    if not p.exists():
        return 1e9
    try:
        j = json.loads(p.read_text(encoding="utf-8"))
        g = j.get("generated_at")
        if g:
            return (pd.Timestamp.now("UTC") - pd.Timestamp(g)).total_seconds() / 86400
    except Exception:  # noqa: BLE001
        pass
    return (datetime.now().timestamp() - p.stat().st_mtime) / 86400


def run_us(args) -> int:
    cfg = load_config()
    from src.us_short import ep_run_window_ok, screen_breakout, screen_ep
    from src.us_mid import screen_mid
    from src.us_long import screen_long
    from src.insight import build_insight

    auto = not (args.short or args.ep or args.mid or args.long or args.insight)
    do_short, do_ep, do_mid, do_long, do_insight = args.short, args.ep, args.mid, args.long, args.insight
    if auto:
        do_short = do_mid = True
        do_ep = False
        do_long = do_insight = None  # 데이터 본 뒤 결정
    if do_ep and not args.force and not ep_run_window_ok(cfg["us_short"]):
        log.info("EP 실행 시간(미국 동부 %s)이 아님 → 건너뜀 (--force 로 강제)", cfg["us_short"]["ep"]["run_window_et"])
        do_ep = False
        if not (do_short or do_mid or do_long or do_insight):
            return 0

    uni = us_common_stocks()
    names = dict(zip(uni["ticker"], uni["name"]))
    exchanges = dict(zip(uni["ticker"], uni["exchange"]))
    tickers = uni["ticker"].tolist()
    lu = long_universe()
    tickers = sorted(set(tickers) | set(lu["ticker"]))

    prices = get_daily(tickers, name="us", offline=args.offline)
    got = prices["ticker"].nunique()
    log.info("가격 데이터 %d/%d 종목", got, len(tickers))
    if got < len(tickers) * 0.5:
        log.error("가격 데이터가 절반도 안 됨 → 이전 결과 유지, 종료")
        return 2
    if not args.no_fill:
        prices = fill_today_if_missing(prices, name="us")
    w = trim_incomplete(to_wide(prices))
    ind = compute(w)
    dates = ind["close"].index
    last_date = dates[-1]
    log.info("최근 거래일: %s", last_date.date())

    if auto:
        do_long = is_first_trading_day_of_month(dates) or file_age_days("us_long.json") > 27
        do_insight = now_et().weekday() == 0 or file_age_days("us_insight.json") > 6.5
        log.info("자동 모드: short=%s mid=%s long=%s insight=%s", do_short, do_mid, do_long, do_insight)

    rc = 0
    if do_short:
        try:
            rows = screen_breakout(ind, names, cfg=cfg["us_short"], exchanges=exchanges)
            write_json("us_short.json", {
                "date": str(last_date.date()), "generated_at": pd.Timestamp.now("UTC").strftime("%Y-%m-%dT%H:%M:%SZ"),
                "market": "us", "setup": "breakout", "capital": cfg["us_short"]["money"]["capital"],
                "risk_pct": cfg["us_short"]["money"]["risk_pct"], "max_positions": cfg["us_short"]["money"]["max_positions"],
                "count": len(rows), "items": rows,
            })
            log.info("[단기] 돌파 대기 %d 종목: %s", len(rows), ", ".join(r["ticker"] for r in rows[:15]))
        except Exception:  # noqa: BLE001
            log.error("[단기] 실패:\n%s", traceback.format_exc())
            rc = 1
    if do_mid:
        try:
            rows = screen_mid(ind, names, cfg=cfg["us_mid"], exchanges=exchanges)
            write_json("us_mid.json", {
                "date": str(last_date.date()), "generated_at": pd.Timestamp.now("UTC").strftime("%Y-%m-%dT%H:%M:%SZ"),
                "market": "us", "capital": cfg["us_mid"]["money"]["capital"],
                "risk_pct": cfg["us_mid"]["money"]["risk_pct"], "max_positions": cfg["us_mid"]["money"]["max_positions"],
                "count": len(rows), "items": rows,
            })
            log.info("[중기] 후보 %d 종목: %s", len(rows), ", ".join(r["ticker"] for r in rows[:15]))
        except Exception:  # noqa: BLE001
            log.error("[중기] 실패:\n%s", traceback.format_exc())
            rc = 1
    if do_long:
        try:
            res = screen_long(ind, lu, cfg=cfg["us_long"], force_fund=args.force, exchanges=exchanges)
            res["market"] = "us"
            write_json("us_long.json", res)
            log.info("[장기] 상위 %d: %s", len(res["candidates"]), ", ".join(r["ticker"] for r in res["candidates"][:10]))
        except Exception:  # noqa: BLE001
            log.error("[장기] 실패:\n%s", traceback.format_exc())
            rc = 1
    if do_insight:
        try:
            sp = lu[lu["in_sp500"]]["ticker"].tolist() if "in_sp500" in lu.columns else lu["ticker"].tolist()
            res = build_insight(ind, sp, cfg=cfg["insight"])
            res["market"] = "us"
            write_json("us_insight.json", res)
            log.info("[인사이트] %s (SPY %s / 브레드스 %s%%)", res["temperature"]["signal"], res["temperature"]["close"],
                     res["temperature"]["breadth_pct"])
        except Exception:  # noqa: BLE001
            log.error("[인사이트] 실패:\n%s", traceback.format_exc())
            rc = 1
    if do_ep:
        try:
            rows = screen_ep(ind, names, cfg=cfg["us_short"], exchanges=exchanges)
            write_json("us_short_ep.json", {
                "date": rows[0]["date"] if rows else str(now_et().date()),
                "generated_at": pd.Timestamp.now("UTC").strftime("%Y-%m-%dT%H:%M:%SZ"),
                "asof_et": now_et().strftime("%Y-%m-%d %H:%M"),
                "market": "us", "setup": "ep", "capital": cfg["us_short"]["money"]["capital"],
                "risk_pct": cfg["us_short"]["money"]["risk_pct"], "max_positions": cfg["us_short"]["money"]["max_positions"],
                "count": len(rows), "items": rows,
            })
            log.info("[EP] %d 종목: %s", len(rows), ", ".join(r["ticker"] for r in rows[:15]))
        except Exception:  # noqa: BLE001
            log.error("[EP] 실패:\n%s", traceback.format_exc())
            rc = 1
    write_json("status.json", {
        "generated_at": pd.Timestamp.now("UTC").strftime("%Y-%m-%dT%H:%M:%SZ"),
        "last_trading_day": str(last_date.date()), "tickers": got, "rc": rc,
        "ran": {"short": bool(do_short), "ep": bool(do_ep), "mid": bool(do_mid), "long": bool(do_long), "insight": bool(do_insight)},
    })
    return rc


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="주식 스크리너")
    ap.add_argument("--short", action="store_true", help="미국 단기 돌파 대기")
    ap.add_argument("--ep", action="store_true", help="미국 단기 EP (장중)")
    ap.add_argument("--mid", action="store_true", help="미국 중기")
    ap.add_argument("--long", action="store_true", help="미국 장기")
    ap.add_argument("--insight", action="store_true", help="인사이트")
    ap.add_argument("--market", default="us", choices=["us", "kr"])
    ap.add_argument("--force", action="store_true", help="시간/날짜/캐시 조건 무시")
    ap.add_argument("--no-fill", action="store_true", help="오늘 봉 1분봉 합성 건너뜀")
    ap.add_argument("--offline", action="store_true", help="다운로드 없이 캐시만 사용 (개발용)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s", datefmt="%H:%M:%S")
    logging.getLogger("yfinance").setLevel(logging.CRITICAL)
    logging.getLogger("peewee").setLevel(logging.ERROR)
    logging.getLogger("urllib3").setLevel(logging.WARNING)
    log.info("시작 %s (ET %s)", datetime.now().strftime("%Y-%m-%d %H:%M"), now_et().strftime("%Y-%m-%d %H:%M"))
    if args.market == "kr":
        log.info("국내주식은 아직 준비 중입니다 (11단계)")
        return 0
    return run_us(args)


if __name__ == "__main__":
    sys.exit(main())
