"""장중 실시간 스캐너 (토스증권 오픈API). PC에서 실행.

  python live_scanner.py            # 오늘 미국 정규장 시작까지 기다렸다가 1분마다 스캔, 마감 후 종료
  python live_scanner.py --now      # 지금 즉시 1회 스캔 (테스트)
  python live_scanner.py --loop 5   # 지금부터 5분 간격 반복 (테스트)

규칙 (config.yaml us_short.ep / us_live):
  - EP: 정규장 시가 >= 전일 종가 x 1.10 (x1.40 이하), 누적 거래량 하루치 환산 >= Vol20 x 5, 전일 기준 R3M <= 25%.
        진입가 = 시가 x 1.02. 고가가 진입가에 닿으면 '진입가 도달'
  - 단타(모멘텀): 전일 종가 대비 >= +5%, 누적 거래량 하루치 환산 >= Vol20 x 3, 당일 고가의 2% 이내, 종가 >= $2, DV20 >= $1M
  - 종목당 하루 1번 알림. 결과는 output/us_live.json + GitHub `live` 브랜치 (앱이 1분마다 읽음)
키: ~/stock-screener-keys/toss.env (TOSS_CLIENT_ID, TOSS_CLIENT_SECRET). 저장소에 올라가지 않음.
"""
from __future__ import annotations

import argparse
import base64
import json
import logging
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import requests

from src.config import OUTPUT_DIR, ROOT, load_config

log = logging.getLogger("live")
KST = ZoneInfo("Asia/Seoul")
BASE = "https://openapi.tossinvest.com"
KEY_FILE = Path.home() / "stock-screener-keys" / "toss.env"
STATE_FILE = ROOT / "data" / "live_state.json"
REPO = "cplajha-pixel/stock-screener"
STATS_URL = f"https://raw.githubusercontent.com/{REPO}/main/output/us_universe_stats.json"


# ---------------------------------------------------------------------------
# 토스 API
# ---------------------------------------------------------------------------
def load_env() -> dict:
    env = {}
    for line in KEY_FILE.read_text(encoding="utf-8-sig").splitlines():
        if "=" in line and not line.strip().startswith("#"):
            k, v = line.strip().split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def ntfy_topic() -> str:
    """알림 릴레이 토픽 (비밀 아님, 추측 어려운 이름). toss.env 에 NTFY_TOPIC 으로 보관."""
    env = load_env()
    t = env.get("NTFY_TOPIC")
    if not t:
        import secrets
        t = "stk-" + secrets.token_urlsafe(12).replace("-", "x").replace("_", "y")
        with KEY_FILE.open("a", encoding="utf-8") as f:
            f.write("\nNTFY_TOPIC=" + t + "\n")
        log.info("ntfy 토픽 생성: %s (앱 설정에 입력)", t)
    return t


def ntfy_push(alert: dict) -> None:
    """ntfy.sh 로 즉시 푸시 (앱이 구독). 실패해도 스캔은 계속."""
    try:
        payload = {"topic": ntfy_topic(), "title": alert["title"], "message": alert["body"], "priority": 4,
                   "tags": ["chart_with_upwards_trend", alert["type"], alert["ticker"]]}
        r = requests.post("https://ntfy.sh/", json=payload, timeout=15)
        if r.status_code != 200:
            log.warning("ntfy 푸시 실패 %s: %s", r.status_code, r.text[:120])
    except Exception as e:  # noqa: BLE001
        log.warning("ntfy 푸시 실패: %s", e)


class Toss:
    def __init__(self):
        env = load_env()
        self.cid, self.sec = env["TOSS_CLIENT_ID"], env["TOSS_CLIENT_SECRET"]
        self.tok, self.tok_exp = None, 0.0
        self.s = requests.Session()

    def token(self) -> str:
        if self.tok and time.time() < self.tok_exp - 300:
            return self.tok
        r = self.s.post(f"{BASE}/oauth2/token", data={"grant_type": "client_credentials", "client_id": self.cid,
                                                       "client_secret": self.sec}, timeout=30)
        r.raise_for_status()
        j = r.json()
        self.tok, self.tok_exp = j["access_token"], time.time() + int(j.get("expires_in", 3600))
        return self.tok

    def get(self, path: str, retries: int = 3, **params):
        for _ in range(retries):
            r = self.s.get(f"{BASE}{path}", params=params, headers={"Authorization": f"Bearer {self.token()}"}, timeout=30)
            if r.status_code == 429:
                time.sleep(float(r.headers.get("X-RateLimit-Reset", 1)) + 0.2)
                continue
            if r.status_code == 401:
                self.tok = None
                continue
            if r.status_code == 403:
                raise RuntimeError("403: 허용 IP가 아니거나 권한 없음 (토스 WTS > 설정 > Open API > 허용 IP 관리)")
            r.raise_for_status()
            return r.json().get("result")
        raise RuntimeError(f"{path} 재시도 실패")

    def rankings(self, typ: str, n: int = 100):
        j = self.get("/api/v1/rankings", type=typ, marketCountry="US", duration="1d", count=n)
        return (j or {}).get("rankings", [])

    def candles_1m(self, symbol: str, since: datetime) -> list[dict]:
        """since(KST) 이후 1분봉 (오름차순)."""
        out, before = [], None
        for _ in range(4):
            j = self.get("/api/v1/candles", symbol=symbol, interval="1m", count=200, **({"before": before} if before else {}))
            cs = (j or {}).get("candles", [])
            if not cs:
                break
            for c in cs:
                t = datetime.fromisoformat(c["timestamp"].replace("Z", "+00:00")).astimezone(KST)
                if t < since:
                    continue
                out.append({"t": t, "o": float(c["openPrice"]), "h": float(c["highPrice"]), "l": float(c["lowPrice"]),
                            "c": float(c["closePrice"]), "v": float(c["volume"])})
            last_t = datetime.fromisoformat(cs[-1]["timestamp"].replace("Z", "+00:00")).astimezone(KST)
            if last_t < since or not (j or {}).get("nextBefore"):
                break
            before = j["nextBefore"]
        out.sort(key=lambda x: x["t"])
        return out

    def us_calendar(self) -> dict:
        return self.get("/api/v1/market-calendar/US") or {}


# ---------------------------------------------------------------------------
# 스캔
# ---------------------------------------------------------------------------
def load_stats() -> dict:
    p = OUTPUT_DIR / "us_universe_stats.json"
    try:
        r = requests.get(STATS_URL, timeout=30)
        if r.status_code == 200:
            j = r.json()
            p.write_text(json.dumps(j, ensure_ascii=False), encoding="utf-8")
            log.info("유니버스 통계 %s (%d 종목) 다운로드", j.get("date"), j.get("count"))
            return j
    except Exception as e:  # noqa: BLE001
        log.warning("유니버스 통계 다운로드 실패: %s", e)
    if p.exists():
        j = json.loads(p.read_text(encoding="utf-8"))
        log.info("유니버스 통계 로컬 사용 %s", j.get("date"))
        return j
    raise RuntimeError("유니버스 통계 파일이 없습니다")


def load_state(date: str) -> dict:
    if STATE_FILE.exists():
        try:
            st = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            if st.get("date") == date:
                return st
        except Exception:  # noqa: BLE001
            pass
    return {"date": date, "alerted": {}, "alerts": []}


def save_state(st: dict) -> None:
    STATE_FILE.parent.mkdir(exist_ok=True)
    STATE_FILE.write_text(json.dumps(st, ensure_ascii=False, default=str), encoding="utf-8")


def session_today(toss: Toss) -> tuple[datetime, datetime] | None:
    cal = toss.us_calendar()
    today = (cal or {}).get("today") or {}
    reg = today.get("regularMarket")
    if not reg:
        return None
    s = datetime.fromisoformat(reg["startTime"].replace("Z", "+00:00")).astimezone(KST)
    e = datetime.fromisoformat(reg["endTime"].replace("Z", "+00:00")).astimezone(KST)
    return s, e


def scan_once(toss: Toss, stats: dict, st: dict, cfg: dict, session: tuple[datetime, datetime]) -> dict:
    ep_cfg, live_cfg, u = cfg["us_short"]["ep"], cfg.get("us_live", {}), cfg["us_short"]["universe"]
    ex = cfg["us_short"]["exit"]
    mom_change = live_cfg.get("min_change_pct", 5)
    mom_rvol = live_cfg.get("min_rvol", 3)
    mom_hod = live_cfg.get("near_high_pct", 2)
    relax = bool(os.environ.get("LIVE_RELAX"))
    if relax:  # 테스트: 문턱을 낮춰 파이프라인만 확인
        mom_change, mom_rvol, mom_hod = 1, 0.0, 50
    items = stats["items"]
    s_start, s_end = session
    now = datetime.now(KST)
    elapsed = max(1.0, min(390.0, (min(now, s_end) - s_start).total_seconds() / 60))
    # 1) 랭킹에서 후보 모으기
    cands: dict[str, dict] = {}
    for typ in ("TOP_GAINERS", "MARKET_TRADING_VOLUME", "MARKET_TRADING_AMOUNT"):
        try:
            for r in toss.rankings(typ, 100):
                sym = r["symbol"]
                if sym not in items:
                    continue
                pr = r.get("price") or {}
                c = cands.setdefault(sym, {"symbol": sym, "src": []})
                c["src"].append(typ)
                c["last"] = float(pr.get("lastPrice") or 0)
                c["base"] = float(pr.get("basePrice") or 0)
                c["vol_day"] = float(r.get("tradingVolume") or 0)
        except Exception as e:  # noqa: BLE001
            log.warning("랭킹 %s 실패: %s", typ, e)
    # 2) 1차 필터 (유동성 + 등락 + 거래량)
    pre = []
    for sym, c in cands.items():
        m = items[sym]
        if not m.get("prev_close") or not m.get("vol20") or not m.get("dv20"):
            continue
        if c["last"] < u["min_close"] or m["dv20"] < u["min_dv20"]:
            continue
        chg = c["last"] / m["prev_close"] - 1
        rvol = c["vol_day"] / (m["vol20"] * elapsed / 390) if m["vol20"] else 0
        if chg * 100 >= min(mom_change, (ep_cfg["min_gap"] - 1) * 100) * 0.8 and rvol >= (0 if relax else 1.5):
            c.update({"chg": chg, "rvol_day": rvol})
            pre.append(c)
    pre.sort(key=lambda c: -c["rvol_day"])
    pre = pre[: live_cfg.get("max_candles_per_scan", 60)]
    # 3) 1분봉으로 정밀 판정
    results, new_alerts = [], []
    for c in pre:
        sym = c["symbol"]
        m = items[sym]
        try:
            cs = toss.candles_1m(sym, s_start)
        except Exception as e:  # noqa: BLE001
            log.warning("1분봉 %s 실패: %s", sym, e)
            continue
        if not cs:
            continue
        o = cs[0]["o"]
        hod = max(x["h"] for x in cs)
        cum = sum(x["v"] for x in cs)
        last = cs[-1]["c"]
        prev = m["prev_close"]
        vol_est = cum * 390 / elapsed
        rvol = vol_est / m["vol20"] if m["vol20"] else 0
        gap = o / prev
        chg = last / prev - 1
        row = {"ticker": sym, "name": m.get("name", ""), "exchange": m.get("exchange", ""), "last": round(last, 4),
               "open": round(o, 4), "prev_close": prev, "high": round(hod, 4), "gap_pct": round((gap - 1) * 100, 1),
               "change_pct": round(chg * 100, 1), "rvol": round(rvol, 1), "cum_volume": int(cum),
               "adr20": m.get("adr20"), "r3m": m.get("r3m"), "dv20": m.get("dv20"), "asof": now.strftime("%H:%M"),
               "setups": []}
        sp = min(max(m.get("adr20") or ex["stop_floor_pct"], ex["stop_min_pct"]), ex["stop_max_pct"])
        # EP
        if ep_cfg["min_gap"] <= gap <= ep_cfg["max_gap"] and rvol >= ep_cfg["vol_mult"] and \
                (m.get("r3m") is not None and m["r3m"] <= ep_cfg["max_r3m_pct"]):
            entry = o * ep_cfg["entry_mult"]
            row["setups"].append("ep")
            row["ep_entry"] = round(entry, 4)
            row["ep_stop"] = round(entry * (1 - sp / 100), 4)
            row["ep_triggered"] = bool(hod >= entry)
        # 단타 모멘텀
        if chg * 100 >= mom_change and rvol >= mom_rvol and last >= hod * (1 - mom_hod / 100):
            row["setups"].append("momentum")
            row["mom_stop"] = round(last * (1 - sp / 100), 4)
        if not row["setups"]:
            continue
        results.append(row)
        key_ep, key_mo, key_tr = f"{sym}:ep", f"{sym}:momentum", f"{sym}:ep_trig"
        if "ep" in row["setups"] and key_ep not in st["alerted"]:
            st["alerted"][key_ep] = now.isoformat()
            new_alerts.append({"id": key_ep, "time": now.strftime("%H:%M"), "ticker": sym, "type": "EP",
                               "title": f"EP {sym} 갭 {row['gap_pct']:+}% · 거래량 {row['rvol']}배",
                               "body": f"진입가 {row['ep_entry']} 손절 {row['ep_stop']} 현재 {row['last']}"})
        if "ep" in row["setups"] and row["ep_triggered"] and key_tr not in st["alerted"]:
            st["alerted"][key_tr] = now.isoformat()
            new_alerts.append({"id": key_tr, "time": now.strftime("%H:%M"), "ticker": sym, "type": "EP도달",
                               "title": f"EP {sym} 진입가 {row['ep_entry']} 도달",
                               "body": f"현재 {row['last']} · 손절 {row['ep_stop']}"})
        if "momentum" in row["setups"] and key_mo not in st["alerted"]:
            st["alerted"][key_mo] = now.isoformat()
            new_alerts.append({"id": key_mo, "time": now.strftime("%H:%M"), "ticker": sym, "type": "단타",
                               "title": f"단타 {sym} {row['change_pct']:+}% · 거래량 {row['rvol']}배 · 고가 근처",
                               "body": f"현재 {row['last']} 고가 {row['high']} · 손절 참고 {row['mom_stop']}"})
    results.sort(key=lambda r: (-len(r["setups"]), -r["rvol"]))
    if not relax:
        for a in new_alerts:
            ntfy_push(a)
    st["alerts"] = (st.get("alerts", []) + new_alerts)[-200:]
    save_state(st)
    out = {"asof": now.strftime("%Y-%m-%d %H:%M"), "asof_kst": now.isoformat(), "session_start": s_start.isoformat(),
           "session_end": s_end.isoformat(), "elapsed_min": int(elapsed), "candidates_scanned": len(pre),
           "count": len(results), "items": results, "alerts": st["alerts"][-50:][::-1], "stats_date": stats.get("date")}
    (OUTPUT_DIR / "us_live.json").write_text(json.dumps(out, ensure_ascii=False, indent=1, default=str), encoding="utf-8")
    log.info("스캔 %s: 후보 %d → 신호 %d (새 알림 %d) %s", out["asof"], len(pre), len(results), len(new_alerts),
             ", ".join(f"{r['ticker']}[{'/'.join(r['setups'])}]" for r in results[:8]))
    return out


# ---------------------------------------------------------------------------
# GitHub live 브랜치에 게시 (gh CLI 인증 사용, 파일 1개만 갱신)
# ---------------------------------------------------------------------------
_gh_token: str | None = None


def gh_token() -> str | None:
    """gh CLI 에 저장된 토큰을 메모리로만 가져온다 (파일에 쓰지 않음)."""
    global _gh_token
    if _gh_token:
        return _gh_token
    gh = r"C:\Program Files\GitHub CLI\gh.exe"
    if not Path(gh).exists():
        gh = "gh"
    try:
        r = subprocess.run([gh, "auth", "token"], capture_output=True, text=True, timeout=30)
        if r.returncode == 0 and r.stdout.strip():
            _gh_token = r.stdout.strip()
    except Exception as e:  # noqa: BLE001
        log.warning("gh 토큰 조회 실패: %s", e)
    return _gh_token


def publish(out: dict) -> None:
    """GitHub live 브랜치의 us_live.json 을 REST API 로 갱신 (앱이 이 파일을 1분마다 읽음)."""
    tok = gh_token()
    if not tok:
        log.warning("게시 실패: gh 토큰 없음 (gh auth login 필요)")
        return
    url = f"https://api.github.com/repos/{REPO}/contents/us_live.json"
    h = {"Authorization": f"token {tok}", "Accept": "application/vnd.github+json"}
    body = base64.b64encode(json.dumps(out, ensure_ascii=False, default=str).encode("utf-8")).decode()
    try:
        sha = None
        r = requests.get(url, params={"ref": "live"}, headers=h, timeout=30)
        if r.status_code == 200:
            sha = r.json().get("sha")
        payload = {"message": f"live {out['asof']}", "branch": "live", "content": body}
        if sha:
            payload["sha"] = sha
        r = requests.put(url, headers=h, json=payload, timeout=60)
        if r.status_code not in (200, 201):
            log.warning("게시 실패 %s: %s", r.status_code, r.text[:200])
    except Exception as e:  # noqa: BLE001
        log.warning("게시 실패: %s", e)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--now", action="store_true", help="즉시 1회 스캔")
    ap.add_argument("--loop", type=int, default=0, help="N분 간격 반복 (테스트)")
    ap.add_argument("--no-publish", action="store_true")
    args = ap.parse_args(argv)
    (ROOT / "data").mkdir(exist_ok=True)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S",
                        handlers=[logging.StreamHandler(sys.stdout),
                                  logging.FileHandler(ROOT / "data" / "live_scanner.log", encoding="utf-8")])
    cfg = load_config()
    interval = cfg.get("us_live", {}).get("interval_sec", 60)
    toss = Toss()
    toss.token()
    log.info("토스 토큰 OK")
    stats = load_stats()
    ses = session_today(toss)
    if ses is None:
        log.info("오늘은 미국 휴장. 종료")
        return 0
    s_start, s_end = ses
    now = datetime.now(KST)
    if args.now or args.loop:
        if now < s_start:  # 장 전 테스트: 최근 30분 봉으로 흉내
            s_start = now - timedelta(minutes=30)
        st = load_state(str(now.date()))
        while True:
            out = scan_once(toss, stats, st, cfg, (s_start, s_end))
            if not args.no_publish:
                publish(out)
            if not args.loop:
                return 0
            time.sleep(args.loop * 60)
    if now < s_start:
        wait = (s_start - now).total_seconds()
        log.info("정규장 시작 %s 까지 %.0f분 대기", s_start.strftime("%H:%M"), wait / 60)
        time.sleep(max(0, wait))
    st = load_state(str(datetime.now(KST).date()))
    while datetime.now(KST) < s_end:
        t0 = time.time()
        try:
            out = scan_once(toss, stats, st, cfg, (s_start, s_end))
            if not args.no_publish:
                publish(out)
        except Exception as e:  # noqa: BLE001
            log.error("스캔 실패: %s", e)
        time.sleep(max(5, interval - (time.time() - t0)))
    log.info("정규장 마감. 종료")
    return 0


if __name__ == "__main__":
    sys.exit(main())
