# XG5000 Ladder Pattern Index

현장/자격증(자동화설비기능사·전기기능장) 수준 레더를 만들 때, 무작정 줄을 나열하지 말고
아래 표준 패턴(idiom) 중에서 공정에 맞는 것을 골라 조합한다. 각 패턴 문서는 적용 상황,
표준 레더 텍스트, 디바이스/변수, 안전 주의점, 검증 포인트를 담는다.

> 이 패턴들은 모두 **공개된 표준 제어 회로 지식**(교과서/일반 통용)이다. 특정 저자/영상의
> 회로를 그대로 베끼지 않는다. 현장 적용 시 컨트롤러 기종(XGB/XGK/XGI/XGR)별 명령어 문법과
> 특수릴레이는 반드시 매뉴얼로 확인한다.

## 패턴 선택 가이드 (이 공정엔 이 패턴)

| 공정 성격 | 권장 패턴 | 문서 |
|---|---|---|
| 단순 기동/정지 유지 | 자기유지(self-hold) | `basic-self-hold.md` |
| 모터 현장 표준 기동 | 3선식 기동/정지 | `motor-3wire.md` |
| 정/역 운전 (컨베이어, 도어) | 정역 인터록 | `interlock-fwd-rev.md` |
| 시간 지연 동작 | ON/OFF delay 타이머 | `timer-circuits.md` |
| 수량 카운트 / 배치 | 카운터 | `counter-batch.md` |
| 다단계 순차 공정 | 정수형 스텝 제어(Word State Machine) | `seq-word-state-machine.md` |
| 컨베이어 제품 추적 | 시프트 레지스터 스텝 | `seq-shift-register.md` |
| 아날로그 계측/지령 | 아날로그 스케일링 | `analog-scaling.md` |
| 온도 제어 | RTD + 히스테리시스/PID | `temperature-control.md` |
| 연산 기반 제어 | 사칙연산/비교 | `arithmetic-compare.md` |
| 비상정지/안전 | E-Stop 안전 체인 | `estop-safety-chain.md` |

## 패턴 조합 원칙 (현장급 레더의 조건)

1. **계층 구조**: 안전(E-Stop) → 모드(Auto/Manual) → 시퀀스/제어 → 출력 매핑 → 진단/HMI 순으로 배치.
2. **출력 단일화**: 어떤 출력 코일도 두 번 쓰지 않는다. 여러 조건은 OR 로 묶어 하나의 코일로.
3. **인터록 명시**: 모든 물리 출력 앞에 permissive(허가) / interlock(상호배제) / trip(차단) 조건을 둔다.
4. **상호배제**: heater/cooler, FWD/REV, open/close, star/delta 처럼 동시 ON 금지 쌍은 서로 b접점으로 막는다.
5. **초기화/리셋**: first-scan 에 상태/래치를 안전값으로 초기화한다.
6. **설명문/변수 필수**: 모든 디바이스는 의미 있는 변수명(PB_/LS_/M_/Q_/D_/T_/C_/U_) + 한글 주석을 갖는다.

## 변수 명명 컨벤션 (권장)

| 접두어 | 의미 | 예 |
|---|---|---|
| `PB_` | 푸시버튼 입력 | PB_START, PB_STOP |
| `LS_` | 리미트/센서 입력 | LS_HOME, LS_DONE |
| `SS_` | 셀렉터 스위치 | SS_AUTO |
| `Q_` 또는 `Y_` | 물리 출력 | Q_MOTOR, Y_VALVE |
| `M_` | 내부 릴레이/플래그 | M_RUNNING, M_FAULT |
| `D_` | 데이터(워드) | D_STEP, D_TEMP_PV |
| `T_` / `C_` | 타이머/카운터 | T_DRY, C_BATCH |
| `U_` | 특수모듈 채널 | U_AI_PRESSURE |

## 산출물 표준 (아키텍트가 항상 함께 제출)

레더만 주지 말고 아래를 **항상 세트로** 제출한다:
1. **I/O 파라미터 장착 안내** — spec-board `modules` 기준, 어느 base/slot 에 무슨 모듈
2. **변수/심볼 표** — 주소·변수명·자료형·방향·한글 주석
3. **레더 텍스트** — 계층 구조로 그룹화 (안전/모드/시퀀스/출력/진단)
4. **줄별 설명문(comment)** — 각 룽이 무엇을·왜 하는지 (학습용 핵심)
5. **검증 체크리스트** — diagnose-ladder.ps1 이 확인할 항목
