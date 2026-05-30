# Pattern: Integer Step Control (Word State Machine / 정수형 스텝 제어)

## When to use
다단계 순차 공정(자재투입→세척→건조→배출, 다축 로봇 셀 등). 개별 M비트 SET/RST 도배 대신
단일 정수 레지스터 하나로 단계를 관리. 현업 초급/고급을 가르는 핵심 패턴.

## Contract (spec-board sequences)
- `state_word` (예 D1000) — 이 시퀀스의 유일한 단계 레지스터. 모든 단계 제어는 이 워드로만.
- 각 step: `step`(번호) · `name` · `outputs` · `interlocks` · `transition{to, when}` · `timeout_ms`
- `init{reset_to, estop_input, auto_condition, first_scan_relay}`, `timeout_timer`, `fault_step`, `fault_record`
- 번호 컨벤션: 0 = IDLE, 900 = FAULT, 10 간격(중간 삽입 여지).

## Ladder (layered)
```
; ── (1) 초기화 / E-Stop : 최우선 ──────────────────────────────
--| F_FIRST_SCAN |----------------------------[MOV 0 D1000]      ; 전원 첫 스캔 -> IDLE
--| X_ESTOP |---------------------------------[MOV 0 D1000]      ; 비상정지 -> 강제 IDLE (최우선)

; ── (2) 단계 전환 : [= state step] AND when -> MOV next ───────
--[= D1000 0]--| X_START |--| M_AUTO_MODE |---[MOV 10 D1000]
--[= D1000 10]--| X_ASM_DONE |----------------[MOV 20 D1000]
--[= D1000 20]--| T_WASH_DONE |---------------[MOV 30 D1000]
--[= D1000 30]--| X_DRY_DONE |----------------[MOV 40 D1000]
--[= D1000 40]--| X_EJECT_DONE |--------------[MOV 0 D1000]
--[= D1000 900]--| X_RESET |------------------[MOV 0 D1000]

; ── (3) 공통 타임아웃 : state<>0 인 동안 가동, done 시 FAULT ──
--[<> D1000 0]--------------------------------( ) T0000_EN       ; 타이머 인에이블(기종별 타이머 명령 형태로)
--| T0000 |--[MOV D1000 D1002]----------------[MOV 900 D1000]    ; 결함 직전 스텝 기록 후 FAULT

; ── (4) 출력 매핑 : 하단에서 [= state step] + 인터록으로 1회만 ──
--[= D1000 10]--| M_GUARD_CLOSED |--|/| X_ESTOP |----( ) M_ASM_RUN
--[= D1000 20]--|/| X_ESTOP |------------------------( ) M_WASH_RUN
--[= D1000 30]--|/| X_ESTOP |------------------------( ) M_DRY_RUN
--[= D1000 40]--|/| X_ESTOP |------------------------( ) M_EJECT

; ── (5) HMI 상태(표시 전용, 제어 아님 — 중복코일 아님) ────────
--[= D1000 900]-------------------------------( ) M_HMI_FAULT
```

## Why it works (학습 포인트)
- **한 스캔에 단 하나의 MOV** 만 참 → 한 번에 한 스텝만 활성(상호배제 자동 보장).
- 출력을 `[= D1000 N]` 비교로 하단에서만 구동 → **중복 코일이 구조적으로 불가능**.
- D1000 값 하나만 모니터링하면 현재 공정 단계를 즉시 안다(디버깅·HMI 표시 쉬움).
- Pause/Resume, 스텝 점프도 D1000 값만 바꾸면 됨 → 하이엔드 장비 확장 용이.

## Safety notes
- E-Stop·init 리셋 룽은 **필수**. 없으면 부팅 시 임의 스텝 실행.
- 모든 물리 출력에 `AND NOT estop` + 필요한 인터록.
- 타임아웃은 스텝마다 쪼개지 말고 공통 타이머 하나로(스텝 진입 시 리셋).

## Verification points (diagnose-ladder: STEP010~050)
- 출력 분리(`= state N`) / 중복 코일 없음
- 모든 transition.to 가 실제 스텝
- init / estop / 공통 타임아웃 룽 존재
- M비트 SET/RST 도배 없음
