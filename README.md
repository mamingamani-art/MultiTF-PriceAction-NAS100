# MultiTF PriceAction — NAS100 (MT5)

Market-specific NAS100 build and validation artifacts for MetaTrader 5.

## Contents

- `MultiTF_PriceAction_EA_MT5_NAS100_OPTIMIZED.mq5` — EA source.
- `MT4Compat.mqh` — compatibility helpers required by the source.
- `MultiTF_PriceAction_EA_MT5_NAS100_OPTIMIZED.ex5` — compiled EA.
- `NAS100_MT5_OPTIMIZED.set` — selected Strategy Tester inputs.
- `NAS100_MT5_EngineB.csv` — Engine B research log.
- `NAS100_MT5_OPTIMIZED_2024_2026.htm` and PNGs — optimized test report and charts.
- `NAS100_MT5_RESEARCH_AND_VALIDATION.md` — concise comparison and status.

## Validation summary

| Run | Trades | Net profit | Profit factor | Equity drawdown | Status |
|---|---:|---:|---:|---:|---|
| Research baseline, both engines, 24-hour | 953 | -$6,734.96 | 0.82 | 71.09% | Rejected |
| NAS100 selected configuration | 19 | +$742.80 | 1.68 | 4.84% | Cautious demo forward testing only |

The selected run used 99% history quality and 88,209,371 ticks over 2024-01-01 to 2026-09-30. It enables Engine B only, long trades only, with 1% risk and a 1% combined risk cap. The sample is small (19 trades); these results do not establish future performance and are not an approval for live trading.

## Build and test

Keep the `.mq5` source and `MT4Compat.mqh` together, open the EA in MetaEditor, compile, then load `NAS100_MT5_OPTIMIZED.set` in Strategy Tester. The report was produced with the NAS100 symbol in the Alpari MT5 tester; broker symbol specifications and spread can change results.

## License and risk

No license is specified. This is trading software for research and demo testing. It does not guarantee performance or returns.
