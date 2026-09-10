"""인사이트 (매주 월요일): 시장 온도, 섹터 순위, 이번 달 변화, (선택) Claude 한국어 요약."""
from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timedelta

import pandas as pd

from .config import OUTPUT_DIR, load_config
from .data import get_daily, to_wide
from .indicators import compute

log = logging.getLogger(__name__)


def _ret(close: pd.Series, n: int) -> float | None:
    c = close.dropna()
    if len(c) <= n:
        return None
    return round((float(c.iloc[-1]) / float(c.iloc[-1 - n]) - 1) * 100, 1)


def build_insight(ind: dict, sp500_tickers: list[str], cfg: dict | None = None) -> dict:
    cfg = cfg or load_config()["insight"]
    etfs = [cfg["index_ticker"]] + list(cfg["sector_etfs"].keys())
    etf_long = get_daily(etfs, name="etf")
    w = to_wide(etf_long)
    e = compute(w)
    spy = cfg["index_ticker"]
    spy_close = float(e["close"][spy].dropna().iloc[-1])
    spy_sma200 = float(e["sma200"][spy].dropna().iloc[-1])
    date = e["close"].index[-1]

    # 브레드스: S&P 500 종목 중 SMA200 위 비율
    tk = [t for t in sp500_tickers if t in ind["close"].columns]
    c = ind["close"].iloc[-1][tk]
    s = ind["sma200"].iloc[-1][tk]
    valid = c.notna() & s.notna()
    breadth = float((c[valid] > s[valid]).mean() * 100) if valid.sum() else None
    invest_now = spy_close > spy_sma200 and breadth is not None and breadth > cfg["breadth_min_pct"]
    signal = "지금 투입" if invest_now else "3개월 분할 투입"

    sectors = []
    for etf, name in cfg["sector_etfs"].items():
        if etf not in e["close"].columns:
            continue
        cl = e["close"][etf]
        sectors.append({"etf": etf, "name": name, "r1m": _ret(cl, 21), "r3m": _ret(cl, 63), "r6m": _ret(cl, 126),
                        "close": round(float(cl.dropna().iloc[-1]), 2)})
    sectors.sort(key=lambda x: (x["r3m"] if x["r3m"] is not None else -1e9), reverse=True)
    for i, sct in enumerate(sectors):
        sct["rank"] = i + 1

    # 이번 달 변화 (장기 결과 파일 기준)
    changes = {"entered": [], "exited": [], "upcoming_earnings": [], "replace": [], "long_date": None}
    lp = OUTPUT_DIR / "us_long.json"
    if lp.exists():
        try:
            lj = json.loads(lp.read_text(encoding="utf-8"))
            changes["long_date"] = lj.get("date")
            changes["entered"] = lj.get("entered", [])
            changes["exited"] = lj.get("exited", [])
            changes["replace"] = [h for h in lj.get("previous_holdings", []) if h.get("replace")]
            today = datetime.now().date()
            lim = today + timedelta(days=cfg["earnings_window_days"])
            for r in lj.get("candidates", []):
                if r.get("hold") and r.get("next_earnings"):
                    try:
                        d = datetime.strptime(r["next_earnings"], "%Y-%m-%d").date()
                    except ValueError:
                        continue
                    if today <= d <= lim:
                        changes["upcoming_earnings"].append({"ticker": r["ticker"], "date": r["next_earnings"]})
        except Exception as ex:  # noqa: BLE001
            log.warning("장기 결과 읽기 실패: %s", ex)

    out = {
        "date": str(date.date()),
        "generated_at": pd.Timestamp.now("UTC").strftime("%Y-%m-%dT%H:%M:%SZ"),
        "temperature": {
            "index": spy, "close": round(spy_close, 2), "sma200": round(spy_sma200, 2),
            "above_sma200": bool(spy_close > spy_sma200),
            "pct_vs_sma200": round((spy_close / spy_sma200 - 1) * 100, 1),
            "breadth_pct": None if breadth is None else round(breadth, 1),
            "breadth_n": int(valid.sum()),
            "signal": signal,
        },
        "sectors": sectors,
        "changes": changes,
        "summary_ko": None,
    }
    prev = OUTPUT_DIR / "us_insight.json"
    if prev.exists():
        try:
            pj = json.loads(prev.read_text(encoding="utf-8"))
            out["previous_signal"] = pj.get("temperature", {}).get("signal")
            out["signal_changed"] = out["previous_signal"] != signal
        except Exception:  # noqa: BLE001
            pass
    out["summary_ko"] = claude_summary(out, cfg)
    return out


def claude_summary(insight: dict, cfg: dict) -> str | None:
    """ANTHROPIC_API_KEY 가 있으면 한국어 3~5줄 요약 생성. 없으면 None."""
    if not os.environ.get("ANTHROPIC_API_KEY"):
        return None
    try:
        import anthropic
    except ImportError:
        log.warning("anthropic 패키지 없음 → 요약 생략")
        return None
    payload = {k: insight[k] for k in ("date", "temperature", "sectors", "changes")}
    system = (
        "당신은 개인 투자자를 위한 주간 시장 브리핑 작성자입니다. 주어진 숫자만 근거로 "
        "한국어 3~5줄로 요약하세요. 각 줄은 한 문장, 줄바꿈으로 구분합니다. 매수/매도 지시나 "
        "특정 종목 추천은 하지 말고, 숫자가 뜻하는 상태를 담담하게 설명하세요. 서론/결론/이모지 없이 본문만."
    )
    try:
        client = anthropic.Anthropic()
        resp = client.messages.create(
            model=cfg.get("claude_model", "claude-opus-5"),
            max_tokens=2000,
            system=system,
            messages=[{"role": "user", "content": "이번 주 인사이트 데이터:\n" + json.dumps(payload, ensure_ascii=False)}],
        )
        if resp.stop_reason == "refusal":
            log.warning("Claude 요약 거절됨")
            return None
        text = "".join(b.text for b in resp.content if b.type == "text").strip()
        return text or None
    except anthropic.AuthenticationError:
        log.warning("Claude API 키가 잘못됨 → 요약 생략")
    except anthropic.RateLimitError:
        log.warning("Claude API 속도 제한 → 요약 생략")
    except anthropic.APIStatusError as e:
        log.warning("Claude API 오류 %s → 요약 생략", e.status_code)
    except anthropic.APIConnectionError:
        log.warning("Claude API 연결 실패 → 요약 생략")
    return None
