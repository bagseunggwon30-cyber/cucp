# Pattern: 3-Wire Motor Start/Stop (3선식 기동/정지)

## When to use
현장 모터 제어의 표준. 모멘터리 START/STOP 버튼 + 자기유지 + 과부하(OL) 트립 + 운전 표시.
2선식(유지형 스위치)과 달리 정전 복귀 시 자동 재기동되지 않는 안전 구조(motor restart 방지).

## Devices / variables
| addr | name | type | dir | comment |
|---|---|---|---|---|
| P0000 | PB_START | bit | in | 기동 (a, NO) |
| P0001 | PB_STOP  | bit | in | 정지 (b, NC) |
| P0002 | LS_OL    | bit | in | 과부하 계전기(THR) b접점 — 트립 시 열림 |
| P0040 | Q_MC     | bit | out | 전자접촉기(MC) 코일 |
| P0041 | Q_LAMP_RUN | bit | out | 운전 표시등 |
| M0000 | M_FAULT  | bit | int | 과부하 결함 래치 |

## Ladder
```
; 과부하 트립 래치: OL b접점이 열리면(트립) 결함 SET, RESET(=STOP)로 해제
--|/| LS_OL ----------------------------------( ) M_FAULT_RAW   ; OL 트립 감지(라인)
; 3선식 자기유지 (STOP, FAULT 가 라인을 끊음)
--|/| PB_STOP --|/| M_FAULT --+--| | PB_START --+--------------( ) Q_MC
                              |                 |
                              +--| | Q_MC ------+
; 운전 표시
--| | Q_MC -----------------------------------( ) Q_LAMP_RUN
```

## Why it works
- **3선식 핵심**: 정전 후 복귀해도 `Q_MC` 자기유지가 풀려 있으므로 자동 재기동 안 됨 → 작업자 안전.
- `LS_OL` 은 과부하 계전기의 **b접점**(정상 시 닫힘, 트립 시 열림)으로 받아 트립이 라인을 끊음.
- `Q_MC`, `Q_LAMP_RUN` 각각 코일 1개씩 (중복 없음).

## Safety notes
- MC(전자접촉기)와 표시등은 분리된 출력. 표시등 로직이 MC 를 다시 구동하면 안 됨.
- 정/역 모터면 interlock-fwd-rev.md 의 상호배제를 추가.
- 실제 배선에서 OL/THR 은 하드와이어 직렬 차단도 병행하는 것이 표준.

## Verification points
- STOP b접점 + OL b접점이 자기유지 라인을 끊는가
- 정전 복귀 자동재기동 방지(자기유지 사용)
- 출력 코일 중복 없음
