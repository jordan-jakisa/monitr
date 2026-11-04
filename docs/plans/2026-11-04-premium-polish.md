# Monitr premium polish pass (2026-11-04)

Lens: premium-psychology. Monitr is a personal utility with no paywall, onboarding or rewards,
so sections 9 to 12 do not apply. The metric is the one Jordan set: it must feel smooth and
polished while staying near 0.6% CPU idle and under 2 to 4% with the window open.

## Scores before (0 missing, 1 partial, 2 premium)

| # | Principle | Score | Evidence | Fix |
|---|---|---|---|---|
| 1 | Every state | 0 | `Store.lastError` is set on a failed stop but never shown; an app that refuses to quit (unsaved document) silently reappears after 6 s; a quit app leaves its pane as an empty table with a spinner; the Idle filter's empty state reads "No results for Idle"; the first sample after opening shows 0% for every process for a full interval | Inline notice for failed stops and refusals with a Force Quit button; "has quit" state with a way back; filter-specific empty states; a second quick sample 0.6 s after opening |
| 2 | One product | 1 | Popover shows memory as %, the dashboard as GB; stop buttons say Stop, Quit, Quit app, Stop all | Memory in GB everywhere; Quit for apps, Stop for processes, Stop all for groups |
| 3 | Worst moment | 0 | Same as row 1: the failure path says nothing | Covered by row 1 |
| 4 | Physical feedback | 1 | Busiest-app rows are buttons with no hover or press state | Hover and press highlight on clickable rows |
| 5 | Cues over tutorials | 1 | Force stop is only in a tooltip | Notice offers Force Quit at the moment it is needed |
| 6 | Consistency through math | 1 | Spacing literals 3, 6, 8, 10, 14, 18, 20, 28, 32; no shared radius | One spacing scale (4, 8, 12, 16, 24, 32) and continuous 8 pt corners |
| 7 | Subtraction | 2 | One primary action per row; settings are four controls | None |
| 8 | System and continuity | 1 | Sparklines jump one step each tick; usage bars snap; panes swap hard | Sparklines glide left with a short ease-out (transform only), bars ease, panes cross-fade; all off under Reduce Motion |
| 9 to 12 | Rewards, progression, paywall, onboarding | n/a | Personal tool, no purchases | None |

## Performance guardrails

- Motion uses transforms (offset, scale, opacity) only, never animated text or re-laid-out paths,
  so frames are composited without re-rendering glyphs (the numericText lesson).
- Every animation is short (0.3 to 0.5 s) and runs only when data changes, never continuously.
- Measure idle and window-open CPU and memory after the pass; revert any motion that costs more
  than 1% CPU.
