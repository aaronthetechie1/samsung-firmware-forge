#!/usr/bin/env python3
"""Run Asgard with the same tqdm-style progress bar used by MonsterROM."""

from __future__ import annotations

import atexit
import sys
from dataclasses import dataclass

from tqdm import tqdm

from asgard.cli import progress
from asgard.cli.app import main


@dataclass
class _BarState:
    total: int
    bar: tqdm


_bars: dict[str, _BarState] = {}


def render_tqdm_progress(
    label: str,
    done: int,
    total: int,
    started_at: float,
    *,
    speed_done: int | None = None,
    complete: bool = False,
) -> None:
    """Adapt Asgard's byte counters to MonsterROM/samloader's tqdm bar."""
    if progress._QUIET:
        return

    state = _bars.get(label)
    if state is None or state.total != total:
        if state is not None:
            state.bar.close()
        state = _BarState(
            total=total,
            bar=tqdm(
                total=total if total > 0 else None,
                unit="B",
                unit_scale=True,
                desc=label,
                dynamic_ncols=True,
                file=sys.stdout,
            ),
        )
        _bars[label] = state

    # tqdm maintains a moving-average transfer rate and ETA itself. Asgard may
    # emit repeated counters, therefore only advance the positive difference.
    if done > state.bar.n:
        state.bar.update(done - state.bar.n)
    if complete:
        state.bar.close()
        _bars.pop(label, None)


@atexit.register
def close_bars() -> None:
    for state in tuple(_bars.values()):
        state.bar.close()


progress.render_progress = render_tqdm_progress
raise SystemExit(main())
