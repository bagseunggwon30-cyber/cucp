# Pattern: Forward/Reverse with Interlock (정역 운전 + 상호배제)

## When to use
컨베이어 양방향, 도어 개폐, 게이트 등 정/역 두 출력이 **절대 동시에 ON 되면 안 되는** 경우.
전기적 단락(정역 동시 투입 시 단락) 방지가 핵심.

## Devices / variables
| addr | name | type | dir | comment |
|---|---|---|---|---|
| P0000 | PB_FWD | bit | in | 정방향 기동 (a) |
| P0001 | PB_REV | bit | in | 역방향 기동 (a) |
| P0002 | PB_STOP | bit | in | 정지 (b) |
| P0003 | LS_FWD_END | bit | in | 정방향 끝단 리미트 (b로 사용해 정방향 정지) |
| P0004 | LS_REV_END | bit | in | 역방향 끝단 리미트 |
| P0040 | Q_FWD | bit | out | 정방향 MC |
| P0041 | Q_REV | bit | out | 역방향 MC |

## Ladder
```
; 정방향: STOP·역방향출력(b)·정방향끝단(b)·역방향끝단리미트가 라인을 끊음
--|/| PB_STOP --|/| Q_REV --|/| LS_FWD_END --+--| | PB_FWD --+-----( ) Q_FWD
                                             |               |
                                             +--| | Q_FWD ---+
; 역방향: 정방향출력(b)으로 상호배제
--|/| PB_STOP --|/| Q_FWD --|/| LS_REV_END --+--| | PB_REV --+-----( ) Q_REV
                                             |               |
                                             +--| | Q_REV ---+
```

## Why it works (상호배제 = mutual exclusion)
- 정방향 룽에 `--|/| Q_REV --` (역방향 출력 b접점)를 직렬로 넣어, 역방향이 ON 이면 정방향 라인이
  끊김. 반대도 동일. → **소프트웨어 인터록**.
- 끝단 리미트(`LS_FWD_END`)가 b접점으로 라인을 끊어 기계적 한계에서 자동 정지.
- 방향 전환 시 STOP 을 거쳐야(또는 데드타임 타이머) 안전. 급반전 방지 타이머는 timer-circuits.md 참조.

## Safety notes
- **소프트웨어 인터록만으로는 부족**. 실제 설비는 MC 보조 b접점을 이용한 **하드와이어 인터록**을
  병행해야 단락을 확실히 막는다. 레더 주석에 이 점을 반드시 명시.
- 급반전이 기계에 무리를 주면 정↔역 사이 데드타임(off-delay) 추가.

## Verification points
- 정역 출력이 서로의 b접점으로 상호배제되는가
- STOP/끝단 리미트가 라인을 끊는가
- Q_FWD/Q_REV 코일 각 1개
