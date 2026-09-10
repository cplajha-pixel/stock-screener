"""지표 (일봉, 해당일 종가까지). 입력은 wide 프레임 (index=date, columns=ticker)."""
from __future__ import annotations

import pandas as pd


def compute(w: dict[str, pd.DataFrame]) -> dict[str, pd.DataFrame]:
    """to_wide() 결과에 지표 프레임을 추가해서 돌려준다."""
    o, h, l, c, v = w["open"], w["high"], w["low"], w["close"], w["volume"]
    ind = dict(w)
    ind["adr20"] = ((h / l - 1).rolling(20).mean()) * 100            # %
    ind["dv20"] = (c * v).rolling(20).mean()
    ind["vol20"] = v.rolling(20).mean()
    ind["r1m"] = (c / c.shift(21) - 1) * 100
    ind["r3m"] = (c / c.shift(63) - 1) * 100
    ind["r6m"] = (c / c.shift(126) - 1) * 100
    ind["r12m"] = (c / c.shift(252) - 1) * 100
    ind["r12m_ex1"] = (c.shift(21) / c.shift(252) - 1) * 100
    for n in (10, 20, 50, 150, 200):
        ind[f"sma{n}"] = c.rolling(n).mean()
    ind["high52"] = h.rolling(252, min_periods=120).max()
    ind["low52"] = l.rolling(252, min_periods=120).min()
    return ind


def pct_rank_row(s: pd.Series) -> pd.Series:
    """한 날짜의 횡단면 백분위 (0~100, 높을수록 상위)."""
    return s.rank(pct=True) * 100


def last_valid(ind: dict[str, pd.DataFrame], key: str, i: int = -1) -> pd.Series:
    return ind[key].iloc[i]
