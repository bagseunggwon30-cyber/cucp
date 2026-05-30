# Pattern: Analog Scaling (아날로그 스케일링 raw <-> engineering)

## When to use
아날로그 입력 모듈(XBF-AD04A 등)의 raw 값(0~16000 같은 디지털값)을 실제 공학단위
(0~100%, 0~10bar, 0~500L/min 등)로 변환. 출력(인버터 속도지령, 밸브 개도)은 반대로 변환.

## Modules (spec-board)
- AI: `XBF-AD04A` slot 1, ch0 = `U01.00` (raw 0~16000)
- AO: `XBF-DV04A` slot 3, ch0 = `U03.00` (raw 0~16000)

## Devices / variables
| addr | name | type | comment |
|---|---|---|---|
| U01.00 | U_AI_PRESS_RAW | word | 압력센서 raw (0~16000 = 0~10bar) |
| D0200 | D_PRESS_PV | word | 압력 실제값 (0.01bar 단위, 예 523 = 5.23bar) |
| D0210 | D_SPEED_SP | word | 속도 설정값 (0~100%) |
| U03.00 | U_AO_SPEED_RAW | word | 인버터 속도지령 raw (0~16000) |

## Ladder (사칙/스케일 명령 사용)
```
; 입력 스케일: PV = raw * 1000 / 16000   (0~16000 -> 0~1000 = 0.00~10.00bar)
;  오버플로 방지 위해 곱셈 먼저, 32비트 연산 권장 (DMUL/DDIV)
--| always_on |--[DMUL U01.00 1000 D0250]        ; D0250(32bit) = raw * 1000
--| always_on |--[DDIV D0250 16000 D0200]        ; D_PRESS_PV = D0250 / 16000

; 출력 스케일: raw = SP(0~100) * 16000 / 100
--| always_on |--[DMUL D0210 16000 D0260]
--| always_on |--[DDIV D0260 100 U03.00]         ; U_AO_SPEED_RAW
```

## Why it works (학습 포인트)
- **곱셈 먼저, 나눗셈 나중**: 정수 연산에서 먼저 나누면 소수점 손실. `raw*1000/16000` 순서가 정밀.
- **32비트(D 접두 명령 DMUL/DDIV)** 사용: `16000*1000` 은 16비트(최대 32767) 범위를 넘으므로
  32비트 연산 필수. 안 그러면 오버플로로 값이 망가짐 — 초보자 최대 함정.
- `always_on` 은 항상 ON 특수릴레이(기종별 F 디바이스, 매뉴얼 확인). 스캔마다 갱신.

## Safety notes
- 센서 단선/범위초과(raw < 0 또는 > 16000) 감지 룽을 별도로 두고 결함 처리 권장.
- 모듈 채널 주소(U01.00 등)는 spec-board `modules` 의 address_range 와 반드시 일치시킬 것.

## Verification points
- 32비트 연산 사용(오버플로 방지)
- 곱셈-나눗셈 순서
- 모듈 주소가 spec-board modules 와 일치
