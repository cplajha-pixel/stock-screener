"""자금 관리: 수량 계산."""
from __future__ import annotations

import math


def position_qty(entry: float, stop: float, capital: float, risk_pct: float,
                 max_position_pct: float) -> int:
    """리스크 기반 수량. 정수 주, 레버리지 없음.

    수량 = floor(자산 x 리스크% / (진입가 - 손절가)), 단 한 종목 최대 비중 제한.
    """
    if entry is None or stop is None or entry <= 0 or entry <= stop:
        return 0
    risk_amt = capital * risk_pct / 100.0
    qty = math.floor(risk_amt / (entry - stop))
    cap_qty = math.floor(capital * max_position_pct / 100.0 / entry)
    return max(0, min(qty, cap_qty))
