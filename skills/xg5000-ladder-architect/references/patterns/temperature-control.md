# Pattern: Temperature Control (온도 제어 — RTD + 히스테리시스 / PID)

## When to use
RTD(PT100) 입력으로 온도를 읽고 히터/쿨러를 제어. 기본은 ON/OFF + 히스테리시스(채터링 방지),
정밀 제어는 PID. 건조로, 항온조, 사출 배럴 등.

## Modules (spec-board)
- RTD: `XBF-RD04A` slot 2, ch0 = `U02.00` (PT100, 0.1C 단위 정수 — 예 253 = 25.3C)
- AO(선택, PID 출력): `XBF-DV04A` slot 3, ch0 = `U03.00`

## Devices / variables
| addr | name | type | comment |
|---|---|---|---|
| U02.00 | U_TEMP_PV | word | 현재온도 (0.1C, 예 253=25.3C) |
| D0300 | D_TEMP_SP | word | 목표온도 설정 (0.1C, 예 600=60.0C) |
| D0302 | D_TEMP_HYS | word | 히스테리시스 (0.1C, 예 20=2.0C) |
| P0040 | Q_HEATER | bit | out | 히터 출력 |
| P0041 | Q_COOLER | bit | out | 쿨러 출력 |
| M0010 | M_HEAT_PERMIT | bit | int | 히터 허가(도어닫힘·결함없음 등) |

## Ladder (비교 명령 + 상호배제)
```
; 히터 ON: PV <= (SP - HYS) 이면 ON, PV >= SP 면 OFF (히스테리시스)
;  하한 = SP - HYS 를 D0304 에 계산
--| always_on |--[- D_TEMP_SP D_TEMP_HYS D0304]          ; D0304 = SP - HYS (하한)
; 히터 ON 조건 (자기유지 + 히스테리시스 상한)
--[<= U_TEMP_PV D0304]--| M_HEAT_PERMIT --|/| Q_COOLER --+--------( ) Q_HEATER
                                                         |
--[<  U_TEMP_PV D_TEMP_SP]--| | Q_HEATER -----------------+      ; 상한(SP) 도달 전까지 유지
; 쿨러 ON: PV >= (SP + HYS)
--| always_on |--[+ D_TEMP_SP D_TEMP_HYS D0306]          ; D0306 = SP + HYS (상한)
--[>= U_TEMP_PV D0306]--|/| Q_HEATER ---------------------( ) Q_COOLER
```

## Why it works (학습 포인트)
- **히스테리시스**: 단순 `PV < SP → 히터 ON` 만 쓰면 SP 근처에서 ON/OFF 가 초당 수십 번 떨림
  (채터링) → 접점 수명 단축. 하한(SP-HYS)에서 켜고 상한(SP)에서 꺼서 폭을 둔다.
- **상호배제**: 히터 룽에 `--|/| Q_COOLER --`, 쿨러 룽에 `--|/| Q_HEATER --` 로 동시 ON 방지.
- 비교 명령 `[<= ]`, `[< ]`, `[>= ]` 와 사칙 `[- ]`, `[+ ]` 조합. RTD 값은 0.1C 정수라 SP/HYS 도 0.1C 단위로 통일.

## PID 버전(정밀 제어)
- LS XGB/XGK 의 PID 명령(또는 PID 펑션블록)을 사용. SP=D_TEMP_SP, PV=U_TEMP_PV, MV=U03.00(AO).
- PID 파라미터(P/I/D, 주기)는 별도 D 영역에 두고 튜닝. 정확한 PID 명령 문법은 기종 매뉴얼 확인.
- ON/OFF 와 달리 MV(조작량)를 아날로그 출력으로 — analog-scaling.md 와 연계.

## Safety notes
- **과열 방어 필수**: PV > 상한임계(예 SP+50C) 또는 센서단선 시 히터 강제 OFF + 결함 래치.
- 센서 단선(RTD open) 시 보통 최대값/특정코드로 읽히니 그 값을 결함으로 처리.
- 히터는 E-Stop·도어인터록(M_HEAT_PERMIT)과 직렬.

## Verification points
- 히스테리시스 적용(채터링 방지)
- 히터/쿨러 상호배제
- 과열/단선 방어 룽 존재
- RTD 단위(0.1C) 일관성
