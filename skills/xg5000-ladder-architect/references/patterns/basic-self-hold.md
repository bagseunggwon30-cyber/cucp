# Pattern: Self-Hold (자기유지 / Latch / Seal-in)

## When to use
START 버튼을 한 번 누르면 출력이 ON 을 유지하고, STOP 을 누르면 OFF. 가장 기본이 되는
유지 회로. 펌프/모터/표시등 등 "한 번 켜면 유지"가 필요한 모든 곳.

## Devices / variables
| addr | name | type | dir | comment |
|---|---|---|---|---|
| P0000 | PB_START | bit | in | 기동 푸시버튼 (a접점, NO) |
| P0001 | PB_STOP  | bit | in | 정지 푸시버튼 (b접점, NC 배선 권장) |
| P0040 | Q_RUN    | bit | out | 운전 출력 |

## Ladder (standard form)
```
; 자기유지: STOP(b) 가 라인을 끊고, START(a)로 기동, Q_RUN 접점으로 유지(seal-in)
--|/| PB_STOP --+--| | PB_START --+----------------------( ) Q_RUN
                |                  |
                +--| | Q_RUN ------+
```

## Why it works (학습 포인트)
- `PB_STOP` 을 **b접점(NC)** 으로 두면 정지버튼 단선 시에도 안전하게 정지(fail-safe).
- `PB_START` 가 한 스캔 라인을 참으로 만들고, 그 다음 `Q_RUN` 자기 접점이 라인을 계속 유지.
- 출력 `Q_RUN` 은 이 룽에서 **단 한 번** 코일로 등장 (중복 코일 금지).

## Safety notes
- 실제 정지버튼은 물리적으로도 NC 배선(눌리면 열림)이 표준.
- 비상정지가 필요한 설비는 이 회로 위에 E-Stop 체인(estop-safety-chain.md)을 둔다.

## Verification points (diagnose-ladder)
- STOP 이 b접점인지, START 가 a접점인지
- Q_RUN 이 코일 + 자기유지 접점으로 2회 등장(코일은 1개)
- 중복 코일 없음
