# Pattern: Arithmetic & Compare (사칙연산 / 비교 / 데이터 처리)

## When to use
생산량 누적, 평균/이동평균, 단가 계산, 범위 판정, 배합비 계산 등 숫자를 다루는 모든 곳.
XG5000 의 산술/비교/전송 명령을 올바르게 쓰는 기본기.

## Core instructions (LS XGB/XGK 계열, 정확 문법은 매뉴얼 확인)
| 분류 | 명령 | 의미 |
|---|---|---|
| 전송 | `MOV / DMOV` | 16/32비트 값 이동 |
| 사칙 | `+ - * /` (16bit), `D+ D- DMUL DDIV` (32bit) | 가감승제 |
| 비교 | `= <> > >= < <=` (또는 CMP) | 조건 비교 |
| 증감 | `INC / DEC` | 1 증가/감소 |
| 변환 | `BCD / BIN / I2D / D2I` | 진수/형 변환 |

## Devices / variables
| addr | name | type | comment |
|---|---|---|---|
| D0400 | D_COUNT | word | 생산 누적 카운트 |
| D0402 | D_TARGET | word | 목표 수량 |
| D0404 | D_UNIT_PRICE | word | 단가 |
| D0406 | D_TOTAL | dword | 합계금액 (32bit) |
| M0020 | M_TARGET_REACHED | bit | 목표 도달 |

## Ladder
```
; 생산 1개마다 누적 (상승펄스에서 +1)
--| LS_PRODUCT_RISE |--[INC D_COUNT]

; 합계금액 = 누적 * 단가 (32비트로 오버플로 방지)
--| always_on |--[DMUL D_COUNT D_UNIT_PRICE D_TOTAL]

; 목표 도달 판정 (비교)
--[>= D_COUNT D_TARGET]----------------------( ) M_TARGET_REACHED

; 범위 판정 예: 하한 <= PV <= 상한
--[>= D_PV D_LO]--[<= D_PV D_HI]-------------( ) M_IN_RANGE
```

## Why it works (학습 포인트)
- **32비트 오버플로**: 곱셈 결과가 32767 넘으면 16비트로는 깨짐. `DMUL` + 32비트 목적지(D_TOTAL dword) 사용.
- **상승펄스(rising edge)** 로 카운트: 레벨로 INC 하면 매 스캔 증가해버림. 펄스 변환 필수.
- 비교 명령 두 개를 직렬로 두면 `LO <= PV <= HI` 범위 판정.
- 나눗셈은 0 나눗셈 방어(분모가 0이 아닌지 비교 후 실행).

## Safety notes
- 0 나눗셈 → 연산 에러. 분모 비교 룽으로 가드.
- 형/단위 일관성: 0.1 단위 값과 정수 값을 섞어 연산하지 말 것.

## Verification points
- 32비트 연산으로 오버플로 방지
- 카운트는 펄스 기반
- 0 나눗셈 가드
