# NAS100 MT5 research and validation

## Research baseline (24-hour, both engines)

| Metric | Result |
|---|---:|
| History quality | 99% |
| Ticks | 88,209,371 |
| Trades | 953 |
| Net profit | -$6,734.96 |
| Profit factor | 0.82 |
| Equity drawdown | 71.09% |

Status: rejected. This version must not be used for forward testing on NAS100.

## Market-specific validated configuration

| Metric | Result |
|---|---:|
| History quality | 99% |
| Ticks | 88,209,371 |
| Trades | 19 |
| Net profit | +$742.80 |
| Profit factor | 1.68 |
| Expected payoff | $39.09 |
| Equity drawdown | 4.84% |
| Recovery factor | 1.36 |
| Sharpe ratio | 4.87 |

Selected configuration: Engine A disabled, Engine B enabled, long trades only, 1% risk with 1% combined cap. Strategy logic was not changed. Debug logging was disabled for performance; CSV logging remains enabled.

Status: acceptable only for cautious demo forward testing. The sample is small (19 trades), so it is not approved for live-money deployment.

