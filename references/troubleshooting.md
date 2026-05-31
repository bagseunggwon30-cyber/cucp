# CUCP Troubleshooting & Selector Reference

이 문서는 SKILL.md 본문에서 분리된 심층 진단·복구·셀렉터 점수표·perf 해석 자료입니다. SKILL.md는 작업 표면(워크플로 + 매크로 인덱스)만, 이 문서는 "왜 이렇게 동작하는지 + 실패했을 때 무엇을 해야 하는지"를 다룹니다.

## 1. Unified observation envelope (`cucp.observation/v1`)

`macro windows`, `find-label --explain`, `list-affordances`, `health-quick`, `log-tail` 등 read-only 매크로가 동일한 envelope을 반환합니다.

| 필드 | 의미 |
|---|---|
| `schema` | 항상 `cucp.observation/v1` |
| `kind` | `windows` / `find-label` / `list-affordances` / `health-quick` / `log-tail` 등 |
| `status` | `ok` / `partial` / `error` |
| `collected_at` | ISO8601 |
| `elapsed_ms` | 매크로 전체 소요 시간 |
| `sources[]` | 데이터 출처 — `win32`, `helper`, `uia`, `ocr`, `screenshot`, `cache`, `vision`, `fallback` 중 다수 |
| `provenance` | 필드별 출처 맵 (예: `{foreground: "win32", items: "win32+helper"}`) |
| `observation_id` | 해당하는 CUCP appshot id (관련 있을 때만) |
| `foreground` | 활성 윈도우 객체 (`title`/`hwnd`/`pid`/`process`/`class`/`rect`) |
| `active_hwnd` | 포커스 중인 HWND (정수) |
| `focused_title` | 포커스 윈도우 제목 (편의 필드) |
| `desktop` | `{ width, height }` 알 수 있을 때만 |
| `windows` | 정규화된 윈도우 리스트 (해당 매크로일 때) |
| `data` | 매크로별 페이로드 |
| `cache` | `{ hit, age_ms, max_age_ms, key, reason }` |
| `stale` | 캐시가 budget 초과인지 |
| `confidence` | `high` / `medium` / `low` |
| `warnings[]` | non-fatal soft 이슈 |
| `recoverable_errors[]` | `{ code, message, recommended_action }` |
| `degraded_helper_empty` | helper 빈 응답이지만 win32로 메워진 경우 true |

### degraded_helper_empty
helper가 `observe windows` 에 빈 배열을 돌려줬을 때 win32 EnumWindows로 메우고 이 플래그를 켭니다. **status는 `ok` 유지** — Win32 evidence가 foreground 결정에 authoritative 이기 때문. brief 출력은 `ok-fallback` 태그를 씁니다.

## 2. Selector ranking (find-label)

각 후보 element 점수:

| 단계 | 가산점 |
|---|---|
| exact (정규화 후) | +100 |
| substring | +60 ~ +100 (길이 차이 적을수록 높음) |
| prefix(앞 3자) | +20 |
| `--window` 일치 안 함 | 즉시 제외 |
| `--role` 불일치 | 즉시 제외 |
| `confidence` high/medium/low | +4 / +2 / +1 |
| tier base (grounded/fused/items) | +4 / +2 / +0 |

상위 두 후보의 점수 차이가 `--ambiguity-window` (기본 10) 미만이면 **partial(2)** 반환. `--explain` 사용 시 `data.candidates`에 상위 8개 + 점수 breakdown 노출.

복구 가이드:
- `not_found` → `macro list-affordances --window "..."` 로 실제 라벨 목록 확인
- `ambiguous_target` → `--window`/`--role` 좁히기, 또는 candidates의 `affordance_id`로 `macro click-id` 사용
- `appshot_failed` → `macro ensure-helper` 후 재시도, 또는 `macro windows --match "..."`로 윈도우 존재부터 확인

## 3. Failure category catalogue

매크로가 `recoverable_errors[].code` 로 emit 하는 식별자:

| code | 의미 | recommended_action 요지 |
|---|---|---|
| `no_window` | match 조건에 보이는 윈도우 없음 | 앱 실행 확인 / `--match` 제거 / `--include-hidden` |
| `no_visible_windows` | 가시 윈도우 없음 (잠금/안전 데스크톱) | 잠금 해제 후 재시도 |
| `helper_unavailable` | helper HTTP 비응답 | `cucp macro ensure-helper` |
| `appshot_failed` | observe appshot 실패 | helper 상태 확인 → 재시도 |
| `no_match` | find-label 후보 0 | `list-affordances` 로 실제 라벨 확인 |
| `ambiguous_target` | 동률 후보 | `--window`/`--role` 좁히기 또는 affordance_id 사용 |
| `log_missing` | wrapper log 파일 없음 | 아무 cucp 명령 실행 |
| `invoke_timeout` | `-InvokeTimeoutMs` 만료 | timeout 늘리기 / helper restart |

## 4. Action lifecycle

라이브 매크로의 단계 (envelope/log 에서 확인 가능):

```
planned → gated → executed → verified → recovered/failed
```

- **planned**: 매크로 진입, `Brief` 사전 메시지
- **gated**: `-AllowLiveControl` 검사 + observe-after 강제
- **executed**: actuation 호출 직후
- **verified**: 후속 `find-label`/`wait-label` 또는 hash diff (`click-and-verify`)
- **recovered**: `auto-do`가 다음 strategy로 fallback
- **failed**: `recoverable_errors[]`에 원인 + recommended_action 동봉

## 5. Speed targets (`macro perf`)

| target | warn threshold | 의미 |
|---|---|---|
| `windows_fast` | >500ms | Win32 EnumWindows top-level 100개 이내 정상이면 100~300ms |
| `windows_no_match` | >500ms | 매칭 0건 빠른 종료 경로 |
| `macro_health_quick` | >1000ms | helper 안 부르는 경량 헬스 |
| `appshot_no_match` | (hint) >5000ms | helper 응답 슬로우 후보 |
| `find_label_no_match` | (hint) >8000ms | vision fallback 활성 의심 |

`thresholds`는 advisory 이며 hard fail 하지 않음. `--quick` 모드는 cheap probes 6개로 보통 3초 안에 끝남. `--include-live-ish` 는 cold/warm appshot pair 까지 측정 (read-only).

## 6. Cache metadata 해석

매크로 envelope의 `cache` 객체:

| 필드 | 의미 |
|---|---|
| `hit` | 이번 호출이 캐시에서 응답됐는지 |
| `age_ms` | 캐시된 데이터의 나이 |
| `max_age_ms` | 만료 임계값 (기본 `-CacheSeconds * 1000`) |
| `key` | 캐시 키 (예: `appshot::match=Notepad`) |
| `reason` | `cache_fresh` / `live_capture` / `live_enumerate` 등 |

`stale=true` 는 데이터가 budget 초과지만 다른 신호(예: foreground)는 fresh 일 때 표시. 호출자가 재캡처 결정에 활용.

## 7. Timeout envelope (`-InvokeTimeoutMs`)

`Invoke-Cucp` 가 타임아웃되면 다음 envelope이 stdout으로 emit:

```json
{
  "status": "error",
  "error_type": "invoke_timeout",
  "command_id": "<12자 hex>",
  "elapsed_ms": <int>,
  "timeout_ms": <int>,
  "summary": "CUCP command timed out after Nms",
  "recommended_action": "Increase -InvokeTimeoutMs or run 'cucp macro ensure-helper'. Failing command: ..."
}
```

exit 124 보장. main path는 raw stdout이 비어있을 경우 위 JSON을 추가 출력.

## 8. macro log-tail 주의점

- `--lines` 기본 50 — 상위 N 라인 (Tail)
- `--errors-only` — `ERROR/TIMEOUT/FAIL/throw/exit (1|2|3|124)` 매칭 필터
- 자동 redact 패턴: `password=`, `passwd=`, `pwd=`, `secret=`, `token=`, `apikey=`, `api_key=`, `authorization:`, `Bearer …`, JWT 셋 segment 형태
- 매칭된 토큰만 `[redacted]` 로 치환되고 나머지 구조는 보존됨

## 9. 빠른 복구 체크리스트

| 증상 | 첫 시도 |
|---|---|
| "No active window" / "No windows found" | `macro windows` (Win32 fallback) |
| 라벨 못 찾음 | `find-label --explain` 으로 후보 확인 |
| 동률 라벨 두 개 | `--window` / `--role` 좁히기 또는 `click-id` |
| helper 멈춤 | `macro ensure-helper`, 그래도면 `-InvokeTimeoutMs 60000` |
| log이 너무 시끄러움 | `macro log-tail --errors-only --lines 100` |
| perf 회귀 | `macro perf --iters 3 --quick` 후 `regression_hints` 확인 |
