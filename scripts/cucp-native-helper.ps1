# ============================================================================
# CUCP Native Desktop Helper (no Windows MCP / no Codex helper dependency)
# ============================================================================
# 이 helper는 외부 windows-mcp 또는 ~/.codex/bin/codex-win.ps1 helper에 의존하지
# 않고, Win32 API + UIAutomationClient + System.Drawing + Windows.Media.Ocr
# 만으로 다음을 제공합니다:
#
#   [관찰 / 탐색]
#   - window enum + foreground 추출 (EnumWindows + GetWindowText)
#   - UIA tree + label 매칭 (BoundingRectangle, Pattern 지원 여부)
#   - OCR (Windows.Media.Ocr): 화면/이미지 텍스트 + 좌표
#   - OCR+UIA fusion: OCR 좌표 위에 UIA element 가 있는지 + invoke 가능 여부
#
#   [actuation / 조작]
#   - mouse click (SendInput / mouse_event)
#   - keyboard text/shortcut (SendInput unicode + virtual-key)
#   - UIA Pattern 직접 호출 (InvokePattern.Invoke / TogglePattern.Toggle / SetValue)
#     → 마우스 안 움직임. BoundingRectangle 만으로 동작.
#   - OCR+UIA invoke: OCR 좌표 위 element 를 한 프로세스 안에서 직접 invoke
#     → UIA Name 비어있어도 AutomationId/ClassName 로 invoke
#
#   [출력]
#   - screenshot capture (Graphics.CopyFromScreen → PNG)
#   - screenshot diff (LockBits + Marshal.Copy 픽셀 비교, ignore-region 지원)
#
# ----------------------------------------------------------------------------
# 사용 방식:
#   powershell -NoProfile -ExecutionPolicy Bypass -File cucp-native-helper.ps1 \
#              -Action <action> [<옵션>] [-OutPath <file>]
#
# 모든 출력은 단일 JSON envelope (action / status / elapsed_ms 포함):
#   { status: "ok"|"error"|"partial", action, elapsed_ms, ... }
#
# Exit codes (CUCP 표준 — wrapper / Pester 도 같은 매핑 사용):
#   0   = ok
#   1   = generic failure / missing required argument
#   2   = partial (no_match, low_confidence, no_invoke_pattern 등 회복 가능)
#   3   = safety blocked (좌표 범위 초과 등 — 현재는 wrapper 가 주로 사용)
#   124 = timeout (wrapper 가 child kill 후 매핑)
#
# ----------------------------------------------------------------------------
# 함정 / 디자인 결정 (수정 시 주의):
#   - PowerShell 5.x 의 inline-if (`$x = if (cond) {...} else {...}`) 는 statement
#     context 에서 깨질 수 있음. 변수 미리 할당 패턴 사용.
#   - $args 는 PowerShell 자동 변수 — 함수 매개변수 이름으로 쓰면 충돌. $argList 로.
#   - JSON envelope 출력은 [Console]::Out.WriteLine 사용 (Write-Output 은 PowerShell
#     output stream 으로 가서 함수 return 값과 섞임 → JSON 깨짐).
#   - .ps1 파일은 한글 주석 보존을 위해 UTF-8 with BOM 으로 저장. 공백 라인 단위로
#     주석 끝 / 코드 시작 분리 (한 줄에 주석 + 코드 섞으면 PS5 가 코드를 주석으로 흡수).
#   - 모든 actuation action 은 wrapper 측에서 -AllowLiveControl 게이트 통과해야 함.
#     이 helper 자체는 게이트 안 잡음 (wrapper 책임).
# ============================================================================

  [CmdletBinding(PositionalBinding = $false)]
param(
  # 수행할 동작 — windows / focused / focus / screenshot / click / type /
  # shortcut / uia-tree / uia-find / uia-click / uia-invoke / uia-set-value /
  # uia-toggle / ocr-screen / ocr-image / ocr-find-text / ocr-uia-fuse /
  # ocr-uia-invoke / screenshot-diff / hit-test / hit-scan / cdp-detect / cdp-eval /
  # cdp-type / cdp-click / cdp-smart-click / cdp-smart-type / cdp-smart-find / cdp-smart-type-find / health
  # v1.4.0: ime-paste (한국어 IME 우회 클립보드 paste), modal-detect (UI recovery),
  #         cdp-deep-find (Shadow DOM/iframe 깊이 보고)
  [Parameter(Mandatory = $true)]
  [ValidateSet(
    "windows", "focused", "focus", "screenshot",
    "click", "type", "shortcut",
    "uia-tree", "uia-find", "uia-click",
    "uia-invoke", "uia-set-value", "uia-toggle",
    "ocr-screen", "ocr-image", "ocr-find-text",
    "ocr-uia-fuse", "ocr-uia-invoke", "screenshot-diff",
    "hit-test", "hit-scan",
    "cdp-detect", "cdp-eval", "cdp-type", "cdp-click",
    "cdp-smart-click", "cdp-smart-type", "cdp-smart-find", "cdp-smart-type-find",
    "cdp-deep-find",
    "cdp-prosemirror-insert",
    "ime-paste", "modal-detect",
    "health"
  )]
  [string]$Action,

  # window 검색용 (case-insensitive 부분 매칭, title 또는 process name)
  [string]$Match,

  # 좌표 기반 click/type 용
  [int]$X,
  [int]$Y,
  [ValidateSet("left", "right", "middle", "double")]
  [string]$Button = "left",

  # type 용 텍스트 (유니코드 그대로)
  [string]$Text,
  [switch]$ClearFirst,
  [switch]$PressEnter,

  # uia-set-value 전용 — UIA ValuePattern.SetValue 로 들어갈 값
  [string]$Value,

  # shortcut 용 (예: "ctrl+s", "alt+f4", "win+d")
  [string]$Keys,

  # screenshot 출력 경로
  [string]$OutPath,

  # screenshot 영역 (전체 가상 데스크톱이 기본)
  [int]$ScreenshotX = -1,
  [int]$ScreenshotY = -1,
  [int]$ScreenshotW = -1,
  [int]$ScreenshotH = -1,

  # UIA 검색 옵션
  [string]$Label,
  [string]$Role,
  [int]$MaxElements = 400,
  [int]$MinSize = 6,

  # 포커스 대상
  [string]$WindowTitle,
  [int]$WindowHwnd,

  # v1.2.0: hit-test 가드 — click/type/shortcut 직전 좌표가 의도한 윈도우 안인지 검증
  # - TargetHwnd: 정확한 hwnd 일치 검사
  # - TargetMatch: title 부분 매칭 (case-insensitive). hwnd 와 OR 관계.
  # 둘 다 비어있으면 가드 없음 (기존 동작). 하나라도 있으면 click/type 시 hit-test 후
  # 매칭 안 되면 exit 3 (safety blocked) + 기록.
  [int]$TargetHwnd,
  [string]$TargetMatch,
  [ValidateSet("none", "uia-safe")]
  [string]$ClickRefine = "none",
  [int]$ClickInset = 3,
  [int]$ScanRadius = 0,
  [int]$ScanStep = 6,
  [switch]$SkipUia,

  # v1.3.0: CDP 옵션
  # - CdpPort: Electron debug port (기본 9222)
  # - CdpPageMatch: /json/list 의 title 또는 url 부분 매칭 (Electron 앱은 보통 여러 페이지)
  # - CdpSelector: cdp-type / cdp-click 의 DOM 셀렉터 (예: "textarea", "button.send")
  # - CdpText: cdp-smart-click / cdp-smart-type / cdp-smart-find / cdp-smart-type-find 의 visible text/aria/placeholder label
  # - CdpExpr: cdp-eval 의 JavaScript expression
  # - CdpExprB64: cdp-eval 의 JavaScript expression (base64 인코딩, 긴 expression 또는
  #   특수문자 (`;` `:` `&`) 가 PowerShell argument parsing 에서 깨질 때 사용)
  [int]$CdpPort = 9222,
  [string]$CdpPageMatch,
  [string]$CdpSelector,
  [string]$CdpText,
  [string]$CdpExpr,
  [string]$CdpExprB64,

  # OCR 옵션
  # - OcrLanguage: "ko" / "en-US" — 비어있으면 사용자 언어 자동 선택 (TryCreateFromUserProfileLanguages)
  # - OcrPath: ocr-image 입력 PNG 경로
  # - OcrText: ocr-find-text 검색어 (case-insensitive 부분 일치 / score 매칭)
  # - OcrMatch: ocr-find-text 매칭 모드 (exact / contains / prefix / fuzzy). 기본 contains
  # - OcrMaxCandidates: ocr-find-text 결과 후보 최대 개수
  [string]$OcrLanguage,
  [string]$OcrPath,
  [string]$OcrText,
  [ValidateSet("exact", "contains", "prefix", "fuzzy")]
  [string]$OcrMatch = "contains",
  [int]$OcrMaxCandidates = 8,

  # screenshot-diff 옵션
  # - DiffBefore / DiffAfter: 비교 대상 PNG 경로
  # - DiffThreshold: per-pixel RGB 절대 차이가 N 이상이면 변화로 간주 (기본 16)
  # - DiffRegion: 비교 영역. 비어있으면 두 PNG 의 크기가 같다고 가정하고 전체 비교
  # - DiffIgnoreRegions: "x1,y1,w1,h1;x2,y2,w2,h2" 형식. 이 영역 안 픽셀은 비교에서 제외
  #   (동영상/애니메이션 영역 마스킹용 — v1.0.0)
  [string]$DiffBefore,
  [string]$DiffAfter,
  [int]$DiffThreshold = 16,
  [string]$DiffIgnoreRegions,

  # 일반 옵션
  [switch]$JsonOnly,
  [switch]$Quiet
)

$ErrorActionPreference = "Stop"
try {
  [System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# ============================================================================
# Win32 P/Invoke surface (한 번만 컴파일)
# ============================================================================
# CUCP가 직접 호출하는 Win32 API들. 외부 라이브러리 없이 user32.dll 만 사용.
# - EnumWindows / GetWindowText / GetForegroundWindow / GetWindowRect: 윈도우 열거
# - SendInput / mouse_event / keybd_event: 입력 이벤트 주입
# - SetForegroundWindow / ShowWindow: 포커스 제어
# - GetCursorPos / SetCursorPos: 커서 위치 조회/설정
# ============================================================================
$Script:_Win32Loaded = $false
function _Ensure-Win32Native {
  if ($Script:_Win32Loaded) { return $true }
  try {
    $signature = @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class CucpNative {
  // ----- delegates -----
  public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

  // ----- window enum -----
  [DllImport("user32.dll")]
  public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

  [DllImport("user32.dll", CharSet = CharSet.Auto)]
  public static extern int GetWindowTextLength(IntPtr hWnd);

  [DllImport("user32.dll", CharSet = CharSet.Auto)]
  public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

  [DllImport("user32.dll", CharSet = CharSet.Auto)]
  public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

  [DllImport("user32.dll")]
  public static extern bool IsWindowVisible(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool IsIconic(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool SetProcessDPIAware();

  [DllImport("user32.dll")]
  public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();

  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

  // ----- focus / show -----
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

  [DllImport("user32.dll")]
  public static extern bool BringWindowToTop(IntPtr hWnd);

  // ----- cursor -----
  [DllImport("user32.dll")]
  public static extern bool GetCursorPos(out POINT lpPoint);

  [DllImport("user32.dll")]
  public static extern bool SetCursorPos(int X, int Y);

  // ----- input injection (SendInput) -----
  [DllImport("user32.dll", SetLastError = true)]
  public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

  [DllImport("user32.dll", SetLastError = true)]
  public static extern short VkKeyScan(char ch);

  [DllImport("user32.dll", SetLastError = true)]
  public static extern uint MapVirtualKey(uint uCode, uint uMapType);

  // ----- desktop bounds -----
  [DllImport("user32.dll")]
  public static extern int GetSystemMetrics(int nIndex);

  // ----- v1.2.0: hit-testing — 좌표가 진짜 어떤 윈도우 안인지 클릭 전 검증 -----
  // WindowFromPoint: 화면 좌표를 받아 그 위치의 child window hwnd 반환
  // GetAncestor + GA_ROOT: child hwnd → top-level (root) hwnd 로 변환
  // 이 둘을 조합하면 "좌표가 어느 top-level 윈도우 안인지" 결정론적으로 판단 가능.
  // (GetWindowThreadProcessId 는 이미 위에 정의돼 있어 재선언 안 함)
  [DllImport("user32.dll")]
  public static extern IntPtr WindowFromPoint(POINT Point);

  [DllImport("user32.dll")]
  public static extern IntPtr GetAncestor(IntPtr hwnd, uint gaFlags);

  public const uint GA_PARENT  = 1;
  public const uint GA_ROOT    = 2;
  public const uint GA_ROOTOWNER = 3;

  // ----- structs -----
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

  [StructLayout(LayoutKind.Sequential)]
  public struct POINT { public int X; public int Y; }

  [StructLayout(LayoutKind.Sequential)]
  public struct MOUSEINPUT {
    public int dx; public int dy;
    public uint mouseData; public uint dwFlags;
    public uint time; public IntPtr dwExtraInfo;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct KEYBDINPUT {
    public ushort wVk; public ushort wScan;
    public uint dwFlags; public uint time;
    public IntPtr dwExtraInfo;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct HARDWAREINPUT {
    public uint uMsg; public ushort wParamL; public ushort wParamH;
  }

  [StructLayout(LayoutKind.Explicit)]
  public struct INPUTUNION {
    [FieldOffset(0)] public MOUSEINPUT mi;
    [FieldOffset(0)] public KEYBDINPUT ki;
    [FieldOffset(0)] public HARDWAREINPUT hi;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct INPUT {
    public uint type;          // 0=mouse, 1=keyboard, 2=hardware
    public INPUTUNION u;
  }

  // ----- constants -----
  public const uint INPUT_MOUSE = 0;
  public const uint INPUT_KEYBOARD = 1;

  // mouse flags
  public const uint MOUSEEVENTF_MOVE        = 0x0001;
  public const uint MOUSEEVENTF_LEFTDOWN    = 0x0002;
  public const uint MOUSEEVENTF_LEFTUP      = 0x0004;
  public const uint MOUSEEVENTF_RIGHTDOWN   = 0x0008;
  public const uint MOUSEEVENTF_RIGHTUP     = 0x0010;
  public const uint MOUSEEVENTF_MIDDLEDOWN  = 0x0020;
  public const uint MOUSEEVENTF_MIDDLEUP    = 0x0040;
  public const uint MOUSEEVENTF_ABSOLUTE    = 0x8000;
  public const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;

  // keyboard flags
  public const uint KEYEVENTF_KEYUP   = 0x0002;
  public const uint KEYEVENTF_UNICODE = 0x0004;
  public const uint KEYEVENTF_SCANCODE = 0x0008;

  // virtual keys (subset)
  public const ushort VK_CONTROL = 0x11;
  public const ushort VK_SHIFT   = 0x10;
  public const ushort VK_MENU    = 0x12;     // Alt
  public const ushort VK_LWIN    = 0x5B;
  public const ushort VK_RETURN  = 0x0D;
  public const ushort VK_TAB     = 0x09;
  public const ushort VK_ESCAPE  = 0x1B;
  public const ushort VK_BACK    = 0x08;
  public const ushort VK_DELETE  = 0x2E;
  public const ushort VK_SPACE   = 0x20;

  // GetSystemMetrics indices
  public const int SM_CXVIRTUALSCREEN = 78;
  public const int SM_CYVIRTUALSCREEN = 79;
  public const int SM_XVIRTUALSCREEN  = 76;
  public const int SM_YVIRTUALSCREEN  = 77;
  public const int SM_CXSCREEN        = 0;
  public const int SM_CYSCREEN        = 1;

  // ShowWindow nCmdShow
  public const int SW_RESTORE = 9;
  public const int SW_SHOW    = 5;

  // ----- helpers -----
  public class WindowInfo {
    public IntPtr Hwnd;
    public string Title;
    public string ClassName;
    public uint Pid;
    public string ProcessName;
    public bool Visible;
    public bool Minimized;
    public bool Foreground;
    public int X, Y, Width, Height;
  }

  public static List<WindowInfo> EnumerateTopLevel() {
    var result = new List<WindowInfo>();
    IntPtr fg = GetForegroundWindow();
    EnumWindows(delegate (IntPtr hwnd, IntPtr lParam) {
      try {
        bool vis = IsWindowVisible(hwnd);
        if (!vis) return true;
        int len = GetWindowTextLength(hwnd);
        if (len <= 0) return true;
        var sb = new StringBuilder(len + 4);
        GetWindowText(hwnd, sb, sb.Capacity);
        var title = sb.ToString();
        if (string.IsNullOrWhiteSpace(title)) return true;
        var cb = new StringBuilder(256);
        GetClassName(hwnd, cb, cb.Capacity);
        var cls = cb.ToString();
        // Hard skip: Windows shell artifacts that pollute every enum
        if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd" ||
            cls == "Shell_SecondaryTrayWnd" || cls == "TaskListThumbnailWnd") {
          return true;
        }
        uint pid; GetWindowThreadProcessId(hwnd, out pid);
        string pname = "";
        try { pname = Process.GetProcessById((int)pid).ProcessName; } catch { }
        RECT r; GetWindowRect(hwnd, out r);
        result.Add(new WindowInfo {
          Hwnd = hwnd, Title = title, ClassName = cls,
          Pid = pid, ProcessName = pname,
          Visible = vis, Minimized = IsIconic(hwnd),
          Foreground = (hwnd == fg),
          X = r.Left, Y = r.Top,
          Width = r.Right - r.Left, Height = r.Bottom - r.Top
        });
      } catch { }
      return true;
    }, IntPtr.Zero);
    return result;
  }

  // ----- mouse click via SendInput (v1.6.0: absolute-only, race-free) -----
  // 변경 사항 (v1.6.0):
  //   - SetCursorPos 제거 — SendInput absolute 와 race 발생 가능, 정확도 ↓
  //   - 단일 SendInput batch 안에서 [move, down, up] 원자적 실행
  //   - move 후 5ms 마이크로 sleep 으로 OS scheduler 가 hover state 인식하게 함
  //   - PostClickX / PostClickY 정적 필드로 호출자가 실제 도착 좌표 검증 가능
  public static int PostClickX = 0;
  public static int PostClickY = 0;
  public static int PostClickRequestedX = 0;
  public static int PostClickRequestedY = 0;
  public static void SendMouseClick(int x, int y, string button, bool doubleClick) {
    PostClickRequestedX = x;
    PostClickRequestedY = y;

    int virtW = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    int virtH = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    int virtX = GetSystemMetrics(SM_XVIRTUALSCREEN);
    int virtY = GetSystemMetrics(SM_YVIRTUALSCREEN);
    if (virtW <= 0) virtW = GetSystemMetrics(SM_CXSCREEN);
    if (virtH <= 0) virtH = GetSystemMetrics(SM_CYSCREEN);

    int normX = (int)((double)(x - virtX) * 65535 / Math.Max(1, virtW - 1));
    int normY = (int)((double)(y - virtY) * 65535 / Math.Max(1, virtH - 1));

    uint downFlag, upFlag;
    switch (button) {
      case "right":  downFlag = MOUSEEVENTF_RIGHTDOWN;  upFlag = MOUSEEVENTF_RIGHTUP;  break;
      case "middle": downFlag = MOUSEEVENTF_MIDDLEDOWN; upFlag = MOUSEEVENTF_MIDDLEUP; break;
      default:       downFlag = MOUSEEVENTF_LEFTDOWN;   upFlag = MOUSEEVENTF_LEFTUP;   break;
    }

    // Stage 1: move only — Windows hover state 인식까지 대기
    var move = new INPUT {
      type = INPUT_MOUSE,
      u = new INPUTUNION { mi = new MOUSEINPUT {
        dx = normX, dy = normY, mouseData = 0,
        dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
        time = 0, dwExtraInfo = IntPtr.Zero
      }}
    };
    var moveArr = new INPUT[] { move };
    SendInput(1u, moveArr, Marshal.SizeOf(typeof(INPUT)));

    // 5ms micro-sleep — OS 가 hover state 디스패치할 시간 확보
    System.Threading.Thread.Sleep(5);

    // Stage 2: down + up batch — 클릭이 hover state 위에서 발생하도록
    var down = new INPUT { type = INPUT_MOUSE, u = new INPUTUNION { mi = new MOUSEINPUT { dwFlags = downFlag } } };
    var up   = new INPUT { type = INPUT_MOUSE, u = new INPUTUNION { mi = new MOUSEINPUT { dwFlags = upFlag } } };
    var clickArr = new INPUT[] { down, up };
    SendInput(2u, clickArr, Marshal.SizeOf(typeof(INPUT)));

    // 도착 좌표 검증 — 호출자가 hit-test 시 사용
    POINT p;
    if (GetCursorPos(out p)) {
      PostClickX = p.X;
      PostClickY = p.Y;
    } else {
      PostClickX = x;
      PostClickY = y;
    }

    if (doubleClick) {
      System.Threading.Thread.Sleep(60);
      SendInput(2u, clickArr, Marshal.SizeOf(typeof(INPUT)));
    }
  }

  // ----- type text via SendInput unicode (handles Korean, emoji, etc.) -----
  public static void SendUnicodeText(string text) {
    if (string.IsNullOrEmpty(text)) return;
    var inputs = new List<INPUT>();
    foreach (char ch in text) {
      var down = new INPUT { type = INPUT_KEYBOARD, u = new INPUTUNION { ki = new KEYBDINPUT {
        wVk = 0, wScan = (ushort)ch, dwFlags = KEYEVENTF_UNICODE,
        time = 0, dwExtraInfo = IntPtr.Zero
      }}};
      var up = down;
      up.u.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
      inputs.Add(down);
      inputs.Add(up);
    }
    SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf(typeof(INPUT)));
  }

  // ----- send virtual key (down/up) -----
  public static void SendVk(ushort vk, bool keyUp) {
    var input = new INPUT { type = INPUT_KEYBOARD, u = new INPUTUNION { ki = new KEYBDINPUT {
      wVk = vk, wScan = 0, dwFlags = keyUp ? KEYEVENTF_KEYUP : 0,
      time = 0, dwExtraInfo = IntPtr.Zero
    }}};
    var arr = new INPUT[] { input };
    SendInput(1u, arr, Marshal.SizeOf(typeof(INPUT)));
  }
}
"@
    Add-Type -TypeDefinition $signature -Language CSharp -ErrorAction Stop
    try { [void][CucpNative]::SetProcessDPIAware() } catch { }
    $Script:_Win32Loaded = $true
    return $true
  } catch {
    Write-Error ("native helper P/Invoke load failed: " + $_.Exception.Message)
    return $false
  }
}

# ============================================================================
# UIAutomationClient assembly (UIA tree access)
# ============================================================================
$Script:_UIALoaded = $false
function _Ensure-UIA {
  if ($Script:_UIALoaded) { return $true }
  try {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    Add-Type -AssemblyName WindowsBase -ErrorAction Stop
    $Script:_UIALoaded = $true
    return $true
  } catch {
    return $false
  }
}

# ============================================================================
# Windows.Media.Ocr (UWP Runtime API) — 외부 의존 0
# ============================================================================
# Windows 10/11 기본 내장 OCR 엔진. 별도 설치 불필요.
# 사용자 언어 설정에 따라 한국어/영어/일본어/중국어 등 25+ 언어 지원.
# 브라우저 캔버스 / 이미지 안 텍스트 / Electron 커스텀 그리기 표면처럼
# UIA로 안 잡히는 표면을 OCR text+BoundingRect 로 좌표 결정 가능.
# ============================================================================
$Script:_OCRLoaded = $false
$Script:_OCREngine = $null
$Script:_OCRError = $null

function _Ensure-OCR {
  # 한 번만 WinRT 어셈블리 로드 + OcrEngine 인스턴스화
  if ($Script:_OCRLoaded) { return ($null -ne $Script:_OCREngine) }
  $Script:_OCRLoaded = $true
  try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
    # 정적 reference로 WinRT projection 트리거 (PS 5.x 패턴)
    [void][Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType=WindowsRuntime]
    [void][Windows.Storage.StorageFile, Windows.Storage, ContentType=WindowsRuntime]
    [void][Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
    [void][Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
    [void][Windows.Storage.Streams.RandomAccessStream, Windows.Storage.Streams, ContentType=WindowsRuntime]
    [void][Windows.Globalization.Language, Windows.Globalization, ContentType=WindowsRuntime]

    # 엔진 선택: -OcrLanguage 명시 우선, 없으면 사용자 프로필 언어 자동
    $engine = $null
    if ($OcrLanguage) {
      try {
        $lang = New-Object Windows.Globalization.Language $OcrLanguage
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
      } catch { $engine = $null }
    }
    if (-not $engine) {
      $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    }
    if (-not $engine) {
      # 마지막 fallback — 첫 사용 가능 언어
      $avail = [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages
      if ($avail -and $avail.Count -gt 0) {
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($avail[0])
      }
    }
    if (-not $engine) {
      $Script:_OCRError = "no_ocr_language_available"
      return $false
    }
    $Script:_OCREngine = $engine
    return $true
  } catch {
    $Script:_OCRError = $_.Exception.Message
    return $false
  }
}

# IAsyncOperation<T> -> .Result wait helper. PS 5.x에서 await 흉내.
function _Wait-AsyncOp {
  param($AsyncOp, [Type]$ResultType)
  $asTask = [WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq "AsTask" -and $_.GetParameters().Count -eq 1 -and $_.IsGenericMethod
  } | Select-Object -First 1
  $generic = $asTask.MakeGenericMethod($ResultType)
  $task = $generic.Invoke($null, @($AsyncOp))
  $task.Wait()
  return $task.Result
}

# PNG 파일 -> SoftwareBitmap (OcrEngine.RecognizeAsync 입력 형식)
function _Load-SoftwareBitmapFromFile {
  param([string]$Path)
  $file = _Wait-AsyncOp ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
  $stream = _Wait-AsyncOp ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $decoder = _Wait-AsyncOp ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $sb = _Wait-AsyncOp ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  return $sb
}

# OcrResult를 결정론적 JSON-friendly 구조로 변환 (offset_x/offset_y 적용 가능)
function _Convert-OcrResult {
  param($OcrResult, [int]$OffsetX = 0, [int]$OffsetY = 0)
  $lines = @()
  $allWords = @()
  foreach ($line in $OcrResult.Lines) {
    $words = @()
    $minX = [int]::MaxValue; $minY = [int]::MaxValue
    $maxR = 0; $maxB = 0
    foreach ($w in $line.Words) {
      $r = $w.BoundingRect
      $wx = [int]$r.X + $OffsetX
      $wy = [int]$r.Y + $OffsetY
      $ww = [int]$r.Width
      $wh = [int]$r.Height
      $word = [ordered]@{
        text = $w.Text
        x = $wx; y = $wy; w = $ww; h = $wh
        # 클릭 좌표 (BoundingRect 중심)
        cx = $wx + [int]($ww / 2)
        cy = $wy + [int]($wh / 2)
      }
      $words += $word
      $allWords += $word
      if ($wx -lt $minX) { $minX = $wx }
      if ($wy -lt $minY) { $minY = $wy }
      if ($wx + $ww -gt $maxR) { $maxR = $wx + $ww }
      if ($wy + $wh -gt $maxB) { $maxB = $wy + $wh }
    }
    if ($words.Count -gt 0) {
      $lineCx = $minX + [int](($maxR - $minX) / 2)
      $lineCy = $minY + [int](($maxB - $minY) / 2)
      $lines += [ordered]@{
        text = $line.Text
        x = $minX; y = $minY
        w = $maxR - $minX; h = $maxB - $minY
        cx = $lineCx; cy = $lineCy
        word_count = $words.Count
        words = $words
      }
    }
  }
  return [ordered]@{
    text = $OcrResult.Text
    line_count = $lines.Count
    word_count = $allWords.Count
    lines = $lines
  }
}

# ocr-find-text matching score. 0..100.
# exact/prefix/contains stay deterministic; fuzzy is opt-in to avoid unsafe clicks.
function _Normalize-OcrText {
  param([string]$Text)
  if (-not $Text) { return "" }
  $s = $Text
  try { $s = $s.Normalize([System.Text.NormalizationForm]::FormKC) } catch { }
  $s = $s.ToLowerInvariant()
  $s = $s -replace '[^\p{L}\p{Nd}\s]+', ' '
  $s = $s -replace '\s+', ' '
  return $s.Trim()
}

function _Levenshtein-Distance {
  param([string]$A, [string]$B)
  if ($null -eq $A) { $A = "" }
  if ($null -eq $B) { $B = "" }
  $n = $A.Length
  $m = $B.Length
  if ($n -eq 0) { return $m }
  if ($m -eq 0) { return $n }
  $prev = New-Object 'int[]' ($m + 1)
  $curr = New-Object 'int[]' ($m + 1)
  for ($j = 0; $j -le $m; $j++) { $prev[$j] = $j }
  for ($i = 1; $i -le $n; $i++) {
    $curr[0] = $i
    for ($j = 1; $j -le $m; $j++) {
      $cost = 1
      if ($A[$i - 1] -eq $B[$j - 1]) { $cost = 0 }
      $del = $prev[$j] + 1
      $ins = $curr[$j - 1] + 1
      $sub = $prev[$j - 1] + $cost
      $curr[$j] = [math]::Min([math]::Min($del, $ins), $sub)
    }
    $tmp = $prev; $prev = $curr; $curr = $tmp
  }
  return $prev[$m]
}

function _Similarity-Percent {
  param([string]$A, [string]$B)
  if (-not $A -or -not $B) { return 0 }
  $maxLen = [math]::Max($A.Length, $B.Length)
  if ($maxLen -le 0) { return 0 }
  $dist = _Levenshtein-Distance -A $A -B $B
  $score = [int][math]::Round((1.0 - ($dist / [double]$maxLen)) * 100)
  if ($score -lt 0) { return 0 }
  if ($score -gt 100) { return 100 }
  return $score
}

function _Score-OcrText {
  param([string]$Needle, [string]$Hay, [string]$Mode)
  if (-not $Needle -or -not $Hay) { return 0 }
  $n = _Normalize-OcrText $Needle
  $h = _Normalize-OcrText $Hay
  if (-not $n -or -not $h) { return 0 }
  if ($n -eq $h) { return 100 }
  switch ($Mode) {
    "exact"  { if ($n -eq $h) { return 100 } else { return 0 } }
    "prefix" { if ($h.StartsWith($n)) { return 80 } else { return 0 } }
    "fuzzy"  {
      $best = _Similarity-Percent -A $n -B $h
      if ($h.Contains($n)) {
        $ratio = [math]::Min(1.0, $n.Length / [math]::Max(1, $h.Length))
        $containsScore = 55 + [int]([math]::Floor($ratio * 30))
        if ($containsScore -gt $best) { $best = $containsScore }
      }
      return $best
    }
    default {
      $idx = $h.IndexOf($n)
      if ($idx -lt 0) { return 0 }
      $ratio = [math]::Min(1.0, $n.Length / [math]::Max(1, $h.Length))
      $bonus = [int]([math]::Floor($ratio * 30))
      $score = 50 + $bonus
      if ($idx -eq 0) { $score += 10 }
      if ($score -gt 95) { $score = 95 }
      return $score
    }
  }
  return 0
}

# ============================================================================
# v1.0.0 리팩토링: 공통 OCR 헬퍼들
# ============================================================================
# OCR 관련 action 들 (_Action-OcrFindText / _Action-OcrUiaFuse / _Action-OcrUiaInvoke)
# 이 같은 캡처 + OCR + 매칭 흐름을 반복하므로 헬퍼로 추출. 호출 측은
# region 결정 + capture + OCR + score 매칭의 4단계가 모두 이 헬퍼들을 통해 일어난다.
# ============================================================================

# 화면 영역을 캡처해서 임시 PNG 경로를 반환. 호출자가 사용 후 직접 삭제 책임.
# region 인자가 모두 0/-1 이면 전체 가상 데스크톱.
# OcrEngine.MaxImageDimension(보통 10000) 초과 시 $null 반환 (호출자가 에러 처리).
function _Capture-ScreenRegionToTempPng {
  param(
    [int]$RegionX,
    [int]$RegionY,
    [int]$RegionW,
    [int]$RegionH,
    [string]$Prefix = "cucp-cap"
  )
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop
  $vx = [CucpNative]::GetSystemMetrics([CucpNative]::SM_XVIRTUALSCREEN)
  $vy = [CucpNative]::GetSystemMetrics([CucpNative]::SM_YVIRTUALSCREEN)
  $vw = [CucpNative]::GetSystemMetrics([CucpNative]::SM_CXVIRTUALSCREEN)
  $vh = [CucpNative]::GetSystemMetrics([CucpNative]::SM_CYVIRTUALSCREEN)
  # PS 5.x inline-if 함정 회피: 변수 미리 할당
  $sx = $vx; if ($RegionX -ge 0) { $sx = $RegionX }
  $sy = $vy; if ($RegionY -ge 0) { $sy = $RegionY }
  $sw = $vw; if ($RegionW -gt 0) { $sw = $RegionW }
  $sh = $vh; if ($RegionH -gt 0) { $sh = $RegionH }

  # OCR 엔진의 픽셀 한도 (보통 10000) 검사
  $maxDim = 10000
  try { $maxDim = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension } catch { }
  if ($sw -gt $maxDim -or $sh -gt $maxDim) {
    return [pscustomobject]@{
      Path = $null; X = $sx; Y = $sy; W = $sw; H = $sh
      Error = "region_exceeds_max_image_dimension"; MaxDim = $maxDim
    }
  }

  $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(),
    "$Prefix-$([System.Guid]::NewGuid().ToString('N')).png")
  $bmp = New-Object System.Drawing.Bitmap $sw, $sh
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.CopyFromScreen($sx, $sy, 0, 0, (New-Object System.Drawing.Size $sw, $sh))
    $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
  } catch {
    return [pscustomobject]@{
      Path = $null; X = $sx; Y = $sy; W = $sw; H = $sh
      Error = "screenshot_unavailable"; Detail = $_.Exception.Message
    }
  } finally {
    $g.Dispose()
    $bmp.Dispose()
  }
  return [pscustomobject]@{
    Path = $tmp; X = $sx; Y = $sy; W = $sw; H = $sh; Error = $null
  }
}

# _Convert-OcrResult body -> OCR candidates.
# Includes line, word, and adjacent 2/3-word n-grams so labels like
# "Save As" or "Send Message" get a tighter center than the whole line.
function _Match-OcrCandidates {
  param(
    $Body,        # _Convert-OcrResult 결과 (lines 배열 포함)
    [string]$Needle,
    [string]$Mode # exact / contains / prefix / fuzzy
  )
  $cands = New-Object System.Collections.ArrayList
  $normalizedNeedle = _Normalize-OcrText $Needle
  $needleTokenCount = 0
  if ($normalizedNeedle) {
    $needleTokenCount = @($normalizedNeedle -split '\s+' | Where-Object { $_ }).Count
  }
  $needsNgrams = ($needleTokenCount -ge 2)
  foreach ($line in $Body.lines) {
    $ls = _Score-OcrText -Needle $Needle -Hay $line.text -Mode $Mode
    if ($ls -gt 0) {
      [void]$cands.Add([ordered]@{
        scope="line"; score=$ls; text=$line.text
        x=$line.x; y=$line.y; w=$line.w; h=$line.h
        cx=$line.cx; cy=$line.cy
      })
    }
    foreach ($w in $line.words) {
      $ws = _Score-OcrText -Needle $Needle -Hay $w.text -Mode $Mode
      if ($ws -gt 0) {
        [void]$cands.Add([ordered]@{
          scope="word"; score=$ws; text=$w.text
          x=$w.x; y=$w.y; w=$w.w; h=$w.h
          cx=$w.cx; cy=$w.cy
        })
      }
    }
    if (-not $needsNgrams) { continue }
    $words = @($line.words)
    for ($n = 2; $n -le 3; $n++) {
      if ($words.Count -lt $n) { continue }
      for ($i = 0; $i -le ($words.Count - $n); $i++) {
        $slice = @($words[$i..($i + $n - 1)])
        $text = (($slice | ForEach-Object { $_.text }) -join " ")
        $score = _Score-OcrText -Needle $Needle -Hay $text -Mode $Mode
        if ($score -le 0) { continue }
        $x1 = [double]::MaxValue
        $y1 = [double]::MaxValue
        $x2 = [double]::MinValue
        $y2 = [double]::MinValue
        foreach ($w in $slice) {
          if ([double]$w.x -lt $x1) { $x1 = [double]$w.x }
          if ([double]$w.y -lt $y1) { $y1 = [double]$w.y }
          if (([double]$w.x + [double]$w.w) -gt $x2) { $x2 = [double]$w.x + [double]$w.w }
          if (([double]$w.y + [double]$w.h) -gt $y2) { $y2 = [double]$w.y + [double]$w.h }
        }
        $ww = [int]($x2 - $x1)
        $hh = [int]($y2 - $y1)
        [void]$cands.Add([ordered]@{
          scope="word_ngram"; n=$n; score=$score; text=$text
          x=[int]$x1; y=[int]$y1; w=$ww; h=$hh
          cx=[int]($x1 + ($ww / 2)); cy=[int]($y1 + ($hh / 2))
        })
      }
    }
  }
  # PS 5.x 함정: single ordered-hashtable 의 [0] 은 첫 entry value 반환.
  # @() 로 강제 array 화 후 인덱싱.
  return @($cands | Sort-Object -Property `
    @{ Expression={ [int]$_["score"] }; Descending=$true },
    @{ Expression={
        $scope = "$($_["scope"])"
        if ($scope -eq "word_ngram") { return 0 }
        if ($scope -eq "word") { return 1 }
        return 2
      }; Ascending=$true },
    @{ Expression={
        $w = 0; $h = 0
        try { $w = [int]$_["w"] } catch { }
        try { $h = [int]$_["h"] } catch { }
        return ($w * $h)
      }; Ascending=$true })
}

function _Get-UiaSupportedPatternName {
  param($Element)
  if (-not $Element) { return $null }
  try {
    $p = $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    if ($p) { return "InvokePattern" }
  } catch { }
  try {
    $p = $Element.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($p) { return "TogglePattern" }
  } catch { }
  try {
    $p = $Element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    if ($p) { return "SelectionItemPattern" }
  } catch { }
  return $null
}

function _New-UiaMatchPayload {
  param($Cur, [string]$PatternName)
  $r = $Cur.BoundingRectangle
  $name = ""; try { $name = "$($Cur.Name)" } catch { }
  $autoId = ""; try { $autoId = "$($Cur.AutomationId)" } catch { }
  $localizedRole = ""; try { $localizedRole = $Cur.LocalizedControlType } catch { }
  $clazz = ""; try { $clazz = "$($Cur.ClassName)" } catch { }
  $enabled = $true; try { $enabled = [bool]$Cur.IsEnabled } catch { }
  $offscreen = $false; try { $offscreen = [bool]$Cur.IsOffscreen } catch { }
  $preferredId = "none"
  if ($name -and $name.Trim().Length -gt 0) { $preferredId = "name" }
  elseif ($autoId -and $autoId.Trim().Length -gt 0) { $preferredId = "automation_id" }
  elseif ($clazz -and $clazz.Trim().Length -gt 0) { $preferredId = "class_name" }
  return [ordered]@{
    name = $name
    automation_id = $autoId
    class_name = $clazz
    role = $localizedRole
    rect = [ordered]@{ x=[int]$r.X; y=[int]$r.Y; width=[int]$r.Width; height=[int]$r.Height }
    center = [ordered]@{ x=[int]($r.X + $r.Width / 2); y=[int]($r.Y + $r.Height / 2) }
    area = [int]($r.Width * $r.Height)
    is_enabled = $enabled
    is_offscreen = $offscreen
    invoke_pattern = $PatternName
    preferred_identifier = $preferredId
  }
}

function _Get-RoleWeight {
  param([string]$Role)
  if (-not $Role) { return 0 }
  $r = $Role.ToLowerInvariant()
  if ($r -match 'button|hyperlink|menu item|tab|check|radio|combo|split button') { return 40 }
  if ($r -match 'edit|document|list item|tree item|data item') { return 18 }
  if ($r -match 'pane|window|group|custom') { return -8 }
  return 0
}

function _Clamp-UiaPointToRect {
  param(
    [double]$X,
    [double]$Y,
    $Rect,
    [int]$Inset = 3,
    [string]$Source = "center",
    [bool]$NativeClickable = $false
  )
  if (-not $Rect -or $Rect.IsEmpty -or $Rect.Width -le 0 -or $Rect.Height -le 0) { return $null }
  $safeInset = [Math]::Max(0, $Inset)
  $insetX = [Math]::Min([double]$safeInset, [Math]::Max(0.0, ([double]$Rect.Width - 1.0) / 2.0))
  $insetY = [Math]::Min([double]$safeInset, [Math]::Max(0.0, ([double]$Rect.Height - 1.0) / 2.0))
  $minX = [double]$Rect.X + $insetX
  $maxX = [double]$Rect.X + [double]$Rect.Width - $insetX
  $minY = [double]$Rect.Y + $insetY
  $maxY = [double]$Rect.Y + [double]$Rect.Height - $insetY
  if ($maxX -lt $minX) { $minX = [double]$Rect.X + ([double]$Rect.Width / 2.0); $maxX = $minX }
  if ($maxY -lt $minY) { $minY = [double]$Rect.Y + ([double]$Rect.Height / 2.0); $maxY = $minY }
  $cx = [Math]::Max($minX, [Math]::Min($maxX, $X))
  $cy = [Math]::Max($minY, [Math]::Min($maxY, $Y))
  return [pscustomobject]@{
    X = [int][Math]::Round($cx)
    Y = [int][Math]::Round($cy)
    Source = $Source
    NativeClickable = $NativeClickable
  }
}

function _Get-UiaPreferredClickPoint {
  param(
    $Element,
    $Rect,
    [int]$Inset = 3
  )
  if (-not $Element -or -not $Rect -or $Rect.IsEmpty) { return $null }

  try {
    $pt = New-Object System.Windows.Point
    $ok = $Element.TryGetClickablePoint([ref]$pt)
    if ($ok) {
      return (_Clamp-UiaPointToRect -X ([double]$pt.X) -Y ([double]$pt.Y) -Rect $Rect -Inset $Inset -Source "clickable_point" -NativeClickable $true)
    }
  } catch { }

  $centerX = [double]$Rect.X + ([double]$Rect.Width / 2.0)
  $centerY = [double]$Rect.Y + ([double]$Rect.Height / 2.0)
  return (_Clamp-UiaPointToRect -X $centerX -Y $centerY -Rect $Rect -Inset $Inset -Source "rect_center" -NativeClickable $false)
}

function _Resolve-UiaPointRefinement {
  param(
    [int]$X,
    [int]$Y,
    [int]$MaxWidth = 360,
    [int]$MaxHeight = 220,
    [int]$Inset = 3
  )
  if (-not (_Ensure-UIA)) { return $null }
  try {
    $pt = New-Object System.Windows.Point($X, $Y)
    $el = [System.Windows.Automation.AutomationElement]::FromPoint($pt)
  } catch { return $null }
  if (-not $el) { return $null }

  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $best = $null
  for ($depth = 0; $depth -le 5 -and $el; $depth++) {
    try {
      $cur = $el.Current
      $r = $cur.BoundingRectangle
      if (-not $r.IsEmpty -and $r.Width -gt 1 -and $r.Height -gt 1) {
        $pattern = _Get-UiaSupportedPatternName -Element $el
        $role = ""; try { $role = "$($cur.LocalizedControlType)" } catch { }
        $enabled = $true; try { $enabled = [bool]$cur.IsEnabled } catch { }
        $offscreen = $false; try { $offscreen = [bool]$cur.IsOffscreen } catch { }
        $area = [double]($r.Width * $r.Height)
        $bounded = ($r.Width -le $MaxWidth -and $r.Height -le $MaxHeight)
        $roleWeight = _Get-RoleWeight -Role $role
        $score = 0
        if ($pattern) { $score += 80 }
        $score += $roleWeight
        if ($bounded) { $score += 30 } else { $score -= 45 }
        if ($enabled) { $score += 10 } else { $score -= 40 }
        if ($offscreen) { $score -= 60 }
        if ($depth -gt 0) { $score -= ($depth * 4) }
        if ($area -le 800) { $score += 10 }
        if ($area -gt 120000) { $score -= 30 }

        $point = $null
        try { $point = _Get-UiaPreferredClickPoint -Element $el -Rect $r -Inset $Inset } catch { $point = $null }
        if ($point -and $point.NativeClickable) { $score += 8 }

        if ($score -ge 45 -and $point) {
          $payload = _New-UiaMatchPayload -Cur $cur -PatternName $pattern
          $candidate = [pscustomobject]@{
            X = [int]$point.X
            Y = [int]$point.Y
            Score = $score
            Depth = $depth
            PatternName = $pattern
            Role = $role
            Area = $area
            PointSource = $point.Source
            NativeClickable = [bool]$point.NativeClickable
            Match = $payload
          }
          if (-not $best -or $candidate.Score -gt $best.Score) { $best = $candidate }
        }
      }
      $parent = $null
      try { $parent = $walker.GetParent($el) } catch { $parent = $null }
      if (-not $parent) { break }
      $el = $parent
    } catch { break }
  }
  return $best
}

function _Find-SmallestUiaElementAtPoint {
  param($Elements, [int]$X, [int]$Y)
  $bestArea = [double]::MaxValue
  $bestEl = $null
  $bestCur = $null
  foreach ($el in $Elements) {
    try {
      $cur = $el.Current
      $r = $cur.BoundingRectangle
      if ($r.IsEmpty) { continue }
      if ($X -lt $r.X -or $X -gt ($r.X + $r.Width)) { continue }
      if ($Y -lt $r.Y -or $Y -gt ($r.Y + $r.Height)) { continue }
      $area = [double]($r.Width * $r.Height)
      if ($area -lt $bestArea) {
        $bestArea = $area
        $bestEl = $el
        $bestCur = $cur
      }
    } catch { continue }
  }
  if (-not $bestEl) { return $null }
  return [pscustomobject]@{ Element=$bestEl; Current=$bestCur; Area=$bestArea }
}

function _Resolve-OcrUiaFusionCandidate {
  param(
    $RootEl,
    $Elements,
    [object[]]$OcrCandidates,
    [int]$Limit = 8
  )
  $results = @()
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $limited = @($OcrCandidates | Select-Object -First $Limit)
  foreach ($ocr in $limited) {
    $cx = [int]$ocr.cx
    $cy = [int]$ocr.cy
    $hit = _Find-SmallestUiaElementAtPoint -Elements $Elements -X $cx -Y $cy
    if (-not $hit) { continue }
    $el = $hit.Element
    for ($depth = 0; $depth -le 6 -and $el; $depth++) {
      try {
        $cur = $el.Current
        $r = $cur.BoundingRectangle
        if ($r.IsEmpty) { break }
        $pattern = _Get-UiaSupportedPatternName -Element $el
        $payload = _New-UiaMatchPayload -Cur $cur -PatternName $pattern
        $role = ""; try { $role = "$($cur.LocalizedControlType)" } catch { }
        $enabled = $true; try { $enabled = [bool]$cur.IsEnabled } catch { }
        $offscreen = $false; try { $offscreen = [bool]$cur.IsOffscreen } catch { }
        $fusionScore = [int]$ocr.score
        if ($pattern) { $fusionScore += 100 }
        if ($role -match 'button|menu|hyperlink|tab|list item|check|radio') { $fusionScore += 20 }
        if ($enabled) { $fusionScore += 10 } else { $fusionScore -= 20 }
        if ($offscreen) { $fusionScore -= 30 }
        if ($depth -gt 0) { $fusionScore -= ($depth * 3) }
        $results += [pscustomobject]@{
          Ocr = $ocr
          Element = $el
          Current = $cur
          PatternName = $pattern
          CanInvoke = [bool]$pattern
          UiaMatch = $payload
          FusionScore = $fusionScore
          ParentClimbDepth = $depth
        }
        if ($pattern) { break }
        $parent = $null
        try { $parent = $walker.GetParent($el) } catch { $parent = $null }
        if (-not $parent) { break }
        try { if ($parent.Equals($RootEl)) { break } } catch { }
        $el = $parent
      } catch { break }
    }
  }
  $ranked = @($results | Sort-Object -Property @{Expression="CanInvoke";Descending=$true}, @{Expression="FusionScore";Descending=$true}, @{Expression={ [int]$_.Ocr.score };Descending=$true})
  if ($ranked.Count -gt 0) { return $ranked[0] }
  return $null
}

# ============================================================================
# v1.3.0 — Chrome DevTools Protocol (CDP) 통합
# ============================================================================
# Electron 앱 (Kiro / VS Code / Slack / Discord 등) 의 DOM 직접 제어를 위한
# CDP 클라이언트. 좌표 / Win32 SendInput / UIA 우회 — DOM API 로 element 직접
# focus / value set / dispatchEvent.
#
# 사용 흐름:
#   1. Electron 앱이 --remote-debugging-port=9222 옵션으로 떠있어야 함
#   2. cdp-detect 로 9222 포트 + 페이지 목록 확인
#   3. cdp-eval 로 임의 JavaScript 실행
#   4. cdp-type / cdp-click 으로 selector 기반 actuation
#
# 설계 결정:
#   - HttpClient 대신 .NET WebRequest (PS 5.x 기본 .NET 4.x 에서 안정)
#   - WebSocket 은 ClientWebSocket 사용 (System.Net.WebSockets, .NET 4.5+)
#   - 단일 WS connection 으로 여러 CDP 명령 전송 → race condition 없음
#   - JSON message id auto-increment, response correlation by id
# ============================================================================

# CDP HTTP endpoint 호출 — /json/version, /json/list 등
function _Cdp-HttpGet {
  param([string]$Url, [int]$TimeoutMs = 3000)
  try {
    $req = [System.Net.WebRequest]::Create($Url)
    $req.Method = "GET"
    $req.Timeout = $TimeoutMs
    try {
      $req.Proxy = $null
      $req.ReadWriteTimeout = $TimeoutMs
      $req.KeepAlive = $false
    } catch { }
    $resp = $req.GetResponse()
    $reader = New-Object System.IO.StreamReader $resp.GetResponseStream()
    $body = $reader.ReadToEnd()
    $reader.Close()
    $resp.Close()
    return [pscustomobject]@{ ok = $true; body = $body; error = $null }
  } catch {
    return [pscustomobject]@{ ok = $false; body = $null; error = $_.Exception.Message }
  }
}

# CDP WebSocket 단일 명령 호출 — open + send + recv (until matching id) + close
# 다중 명령은 호출자가 각각 호출 (간단함 우선, 성능 원하면 향후 connection pool)
function _Cdp-WsCall {
  param(
    [string]$WsUrl,
    [string]$Method,
    [hashtable]$Params = @{},
    [int]$TimeoutMs = 5000,
    [int]$MessageId = 1
  )
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $cts = New-Object System.Threading.CancellationTokenSource
  $cts.CancelAfter($TimeoutMs)
  try {
    # WebSocket 연결 (URI string)
    $uri = New-Object System.Uri $WsUrl
    $connectTask = $ws.ConnectAsync($uri, $cts.Token)
    $connectTask.Wait()

    # JSON 명령 직렬화
    $cmd = [ordered]@{
      id = $MessageId
      method = $Method
      params = $Params
    }
    $json = $cmd | ConvertTo-Json -Compress -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sendBuf = New-Object System.ArraySegment[byte] (,[byte[]]$bytes)
    $sendTask = $ws.SendAsync($sendBuf, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token)
    $sendTask.Wait()

    # 응답 수신 — 같은 id 의 메시지가 올 때까지 (event 메시지 무시)
    $response = $null
    while ($null -eq $response -and -not $cts.Token.IsCancellationRequested) {
      $recvBuffer = New-Object byte[] 65536
      $recvBufSeg = New-Object System.ArraySegment[byte] (,$recvBuffer)
      $allBytes = New-Object System.Collections.Generic.List[byte]
      do {
        $recvTask = $ws.ReceiveAsync($recvBufSeg, $cts.Token)
        $recvTask.Wait()
        $recvResult = $recvTask.Result
        for ($i = 0; $i -lt $recvResult.Count; $i++) {
          [void]$allBytes.Add($recvBuffer[$i])
        }
      } while (-not $recvResult.EndOfMessage)
      $msgText = [System.Text.Encoding]::UTF8.GetString($allBytes.ToArray())
      $msgObj = $null
      try { $msgObj = $msgText | ConvertFrom-Json -ErrorAction Stop } catch { continue }
      if ($msgObj.id -eq $MessageId) {
        $response = $msgObj
      }
      # 다른 id 또는 event 메시지는 그냥 무시하고 다음 메시지 대기
    }

    try { $closeTask = $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $cts.Token); $closeTask.Wait(1000) } catch { }
    return [pscustomobject]@{ ok = $true; response = $response; error = $null }
  } catch {
    return [pscustomobject]@{ ok = $false; response = $null; error = $_.Exception.Message }
  } finally {
    try { $ws.Dispose() } catch { }
    try { $cts.Dispose() } catch { }
  }
}

function _Cdp-PortOpen {
  param([int]$Port = 9222, [int]$TimeoutMs = 120)
  $client = New-Object System.Net.Sockets.TcpClient
  $handle = $null
  try {
    $iar = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
    $handle = $iar.AsyncWaitHandle
    if (-not $handle.WaitOne($TimeoutMs, $false)) { return $false }
    $client.EndConnect($iar)
    return [bool]$client.Connected
  } catch {
    return $false
  } finally {
    try { if ($handle) { $handle.Close() } } catch { }
    try { $client.Close() } catch { }
    try { $client.Dispose() } catch { }
  }
}

function _Cdp-NewDomBridgePlan {
  param(
    [ValidateSet("click", "type", "find")]
    [string]$DomAction,
    [string]$Query,
    [int]$Port = 9222,
    [string]$PageMatch,
    [string]$TextToType,
    [bool]$Clear,
    [bool]$Enter
  )
  $readOnlyAction = if ($DomAction -eq "type") { "cdp-smart-type-find" } else { "cdp-smart-find" }
  $liveAction = if ($DomAction -eq "type") { "cdp-smart-type" } else { "cdp-smart-click" }
  $readOnlyCommand = @("macro", $readOnlyAction)
  $liveCommand = @("macro", $liveAction)
  if ($DomAction -eq "type") {
    $readOnlyCommand += @("--label", $Query)
    $liveCommand += @("--label", $Query)
    if ($TextToType) { $liveCommand += @("--text", $TextToType) }
    if ($Clear) { $liveCommand += "--clear-first" }
    if ($Enter) { $liveCommand += "--press-enter" }
  } else {
    $readOnlyCommand += @("--text", $Query)
    $liveCommand += @("--text", $Query)
  }
  $readOnlyCommand += @("--port", "$Port")
  $liveCommand += @("--port", "$Port")
  if ($PageMatch) {
    $readOnlyCommand += @("--page-match", $PageMatch)
    $liveCommand += @("--page-match", $PageMatch)
  }

  $locatorHints = @()
  if ($DomAction -eq "type") {
    $locatorHints += [ordered]@{ kind="playwright_label"; template="page.getByLabel(<query>)"; priority=100 }
    $locatorHints += [ordered]@{ kind="playwright_placeholder"; template="page.getByPlaceholder(<query>)"; priority=92 }
    $locatorHints += [ordered]@{ kind="css_textbox"; template="[role='textbox'], input, textarea, [contenteditable='true']"; priority=70 }
  } else {
    $locatorHints += [ordered]@{ kind="playwright_role_button"; template="page.getByRole('button', { name: <query> })"; priority=100 }
    $locatorHints += [ordered]@{ kind="playwright_role_link"; template="page.getByRole('link', { name: <query> })"; priority=88 }
    $locatorHints += [ordered]@{ kind="playwright_text"; template="page.getByText(<query>)"; priority=72 }
  }

  return [ordered]@{
    schema = "cucp.cdp-dom-bridge-plan/v1"
    route = "cdp_dom"
    dom_action = $DomAction
    query = $Query
    port = $Port
    page_match = $PageMatch
    read_only_command = $readOnlyCommand
    live_command = $liveCommand
    locator_hints = $locatorHints
    selector_ranking = @(
      [ordered]@{ signal="test_id_or_data_attr"; priority=100 },
      [ordered]@{ signal="aria_label_or_label_control"; priority=94 },
      [ordered]@{ signal="role_plus_accessible_name"; priority=90 },
      [ordered]@{ signal="placeholder_or_name"; priority=82 },
      [ordered]@{ signal="visible_text"; priority=70 },
      [ordered]@{ signal="css_fallback"; priority=50 }
    )
    fallback_order = @("cdp_dom", "uia_pattern", "ocr_uia", "target_validate_precision_point", "vision")
  }
}

# CDP 자동 detect — 9222 포트 + Electron 앱 페이지 목록
# 반환: { available, version, pages[] (id, title, url, webSocketDebuggerUrl) }
function _Cdp-Detect {
  param([int]$Port = 9222)
  if (-not (_Cdp-PortOpen -Port $Port -TimeoutMs 120)) {
    return [pscustomobject]@{
      available = $false
      port = $Port
      error = "tcp_port_closed_or_timeout"
      pages = @()
    }
  }
  $verResp = _Cdp-HttpGet -Url "http://127.0.0.1:$Port/json/version" -TimeoutMs 250
  if (-not $verResp.ok) {
    return [pscustomobject]@{
      available = $false
      port = $Port
      error = $verResp.error
      pages = @()
    }
  }
  $version = $null
  try { $version = $verResp.body | ConvertFrom-Json } catch { }

  $listResp = _Cdp-HttpGet -Url "http://127.0.0.1:$Port/json/list" -TimeoutMs 250
  $pages = @()
  if ($listResp.ok) {
    try {
      $pageList = $listResp.body | ConvertFrom-Json
      foreach ($p in $pageList) {
        $pages += [ordered]@{
          id = $p.id
          title = $p.title
          url = $p.url
          type = $p.type
          ws_url = $p.webSocketDebuggerUrl
        }
      }
    } catch { }
  }
  return [pscustomobject]@{
    available = $true
    port = $Port
    version = $version
    pages = $pages
  }
}

# ============================================================================
# Output helpers
# ============================================================================
$Script:_StartedAt = Get-Date

function _Emit { param($Payload, [int]$ExitCode = 0)
  $elapsed = [int]((Get-Date) - $Script:_StartedAt).TotalMilliseconds
  if ($Payload -is [hashtable] -or $Payload -is [System.Collections.Specialized.OrderedDictionary]) {
    $Payload["elapsed_ms"] = $elapsed
    $Payload["action"] = $Action
    $obj = [pscustomobject]$Payload
  } else {
    $obj = $Payload
    if ($obj -and -not ($obj.PSObject.Properties.Name -contains "elapsed_ms")) {
      $obj | Add-Member -NotePropertyName elapsed_ms -NotePropertyValue $elapsed -Force
    }
    if ($obj -and -not ($obj.PSObject.Properties.Name -contains "action")) {
      $obj | Add-Member -NotePropertyName action -NotePropertyValue $Action -Force
    }
  }
  [Console]::Out.WriteLine(($obj | ConvertTo-Json -Depth 8))
  exit $ExitCode
}

# ============================================================================
# Action: health  ─ helper 자체 검증
# ============================================================================
function _Action-Health {
  $win32 = _Ensure-Win32Native
  $uia = _Ensure-UIA
  $ocr = _Ensure-OCR
  $ocrLangs = @()
  if ($ocr) {
    try {
      foreach ($l in [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages) {
        $ocrLangs += $l.LanguageTag
      }
    } catch { }
  }
  $payload = [ordered]@{
    status = if ($win32) { "ok" } else { "error" }
    win32 = $win32
    uia = $uia
    ocr = $ocr
    ocr_languages = $ocrLangs
    ocr_engine_language = if ($Script:_OCREngine) { $Script:_OCREngine.RecognizerLanguage.LanguageTag } else { $null }
    ocr_error = $Script:_OCRError
    psversion = "$($PSVersionTable.PSVersion)"
    pid = $PID
  }
  $exitCode = 1
  if ($win32) { $exitCode = 0 }
  _Emit $payload $exitCode
}

# ============================================================================
# Action: windows  ─ EnumWindows 기반 윈도우 목록
# ============================================================================
function _Action-Windows {
  if (-not (_Ensure-Win32Native)) { _Emit @{status="error"; reason="win32_load_failed"} 1 }
  $list = [CucpNative]::EnumerateTopLevel()
  $items = @()
  foreach ($w in $list) {
    if ($Match) {
      $needle = $Match.ToLowerInvariant()
      $tt = if ($w.Title) { $w.Title.ToLowerInvariant() } else { "" }
      $pp = if ($w.ProcessName) { $w.ProcessName.ToLowerInvariant() } else { "" }
      if ($tt.IndexOf($needle) -lt 0 -and $pp.IndexOf($needle) -lt 0) { continue }
    }
    $items += [ordered]@{
      hwnd = [int64]$w.Hwnd
      title = $w.Title
      class = $w.ClassName
      pid = [int]$w.Pid
      process = $w.ProcessName
      visible = $w.Visible
      minimized = $w.Minimized
      foreground = $w.Foreground
      rect = [ordered]@{ x=$w.X; y=$w.Y; width=$w.Width; height=$w.Height }
    }
  }
  _Emit ([ordered]@{
    status = "ok"
    match = $Match
    count = $items.Count
    windows = $items
  })
}

# ============================================================================
# Action: focused  ─ foreground window 한 개 반환
# ============================================================================
function _Action-Focused {
  if (-not (_Ensure-Win32Native)) { _Emit @{status="error"; reason="win32_load_failed"} 1 }
  $list = [CucpNative]::EnumerateTopLevel()
  $fg = $list | Where-Object { $_.Foreground } | Select-Object -First 1
  if (-not $fg) { _Emit @{status="partial"; reason="no_foreground_window"} 2 }
  _Emit ([ordered]@{
    status = "ok"
    foreground = [ordered]@{
      hwnd = [int64]$fg.Hwnd
      title = $fg.Title
      class = $fg.ClassName
      pid = [int]$fg.Pid
      process = $fg.ProcessName
      rect = [ordered]@{ x=$fg.X; y=$fg.Y; width=$fg.Width; height=$fg.Height }
    }
  })
}

# ============================================================================
# Action: focus  ─ 윈도우 포커스 (BringWindowToTop + SetForegroundWindow)
# ============================================================================
function _Action-Focus {
  if (-not (_Ensure-Win32Native)) { _Emit @{status="error"; reason="win32_load_failed"} 1 }
  $hwnd = [IntPtr]::Zero
  if ($WindowHwnd -gt 0) { $hwnd = [IntPtr]$WindowHwnd }
  elseif ($WindowTitle) {
    $list = [CucpNative]::EnumerateTopLevel()
    $needle = $WindowTitle.ToLowerInvariant()
    $hit = $list | Where-Object { $_.Title -and $_.Title.ToLowerInvariant().Contains($needle) } | Select-Object -First 1
    if ($hit) { $hwnd = $hit.Hwnd }
  } else {
    _Emit @{status="error"; reason="missing_target"; recommended_action="provide -WindowHwnd or -WindowTitle"} 1
  }
  if ($hwnd -eq [IntPtr]::Zero) {
    _Emit @{status="partial"; reason="no_matching_window"; window_title=$WindowTitle; window_hwnd=$WindowHwnd} 2
  }
  [void][CucpNative]::ShowWindow($hwnd, [CucpNative]::SW_RESTORE)
  [void][CucpNative]::BringWindowToTop($hwnd)
  $ok = [CucpNative]::SetForegroundWindow($hwnd)
  Start-Sleep -Milliseconds 80
  $newFg = [CucpNative]::GetForegroundWindow()
  $verified = ($newFg -eq $hwnd)
  $statusStr = "partial"; $exitCode = 2
  if ($verified) { $statusStr = "ok"; $exitCode = 0 }
  _Emit ([ordered]@{
    status = $statusStr
    set_foreground_returned = $ok
    verified = $verified
    target_hwnd = [int64]$hwnd
    actual_foreground_hwnd = [int64]$newFg
  }) $exitCode
}

# ============================================================================
# Action: screenshot  ─ Graphics.CopyFromScreen → PNG 파일
# ============================================================================
function _Action-Screenshot {
  if (-not $OutPath) {
    _Emit @{status="error"; reason="missing_outpath"; recommended_action="provide -OutPath <png file>"} 1
  }
  if (-not (_Ensure-Win32Native)) { _Emit @{status="error"; reason="win32_load_failed"} 1 }
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop

  # 영역 결정: 명시 지정 없으면 전체 가상 데스크톱
  $vx = [CucpNative]::GetSystemMetrics([CucpNative]::SM_XVIRTUALSCREEN)
  $vy = [CucpNative]::GetSystemMetrics([CucpNative]::SM_YVIRTUALSCREEN)
  $vw = [CucpNative]::GetSystemMetrics([CucpNative]::SM_CXVIRTUALSCREEN)
  $vh = [CucpNative]::GetSystemMetrics([CucpNative]::SM_CYVIRTUALSCREEN)

  $sx = if ($ScreenshotX -ge 0) { $ScreenshotX } else { $vx }
  $sy = if ($ScreenshotY -ge 0) { $ScreenshotY } else { $vy }
  $sw = if ($ScreenshotW -gt 0) { $ScreenshotW } else { $vw }
  $sh = if ($ScreenshotH -gt 0) { $ScreenshotH } else { $vh }

  $bmp = $null
  $g = $null
  try {
    $bmp = New-Object System.Drawing.Bitmap $sw, $sh
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($sx, $sy, 0, 0, (New-Object System.Drawing.Size $sw, $sh))
  } catch {
    if ($g) { $g.Dispose() }
    if ($bmp) { $bmp.Dispose() }
    _Emit ([ordered]@{
      status = "partial"
      reason = "screenshot_unavailable"
      detail = $_.Exception.Message
      recommended_action = "Run from an interactive unlocked desktop session, or retry with a smaller visible region."
      out_path = $OutPath
      rect = [ordered]@{ x=$sx; y=$sy; width=$sw; height=$sh }
    }) 2
  } finally {
    if ($g) { $g.Dispose() }
  }

  # 출력 폴더 생성
  $dir = Split-Path -Parent $OutPath
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()

  _Emit ([ordered]@{
    status = "ok"
    out_path = $OutPath
    rect = [ordered]@{ x=$sx; y=$sy; width=$sw; height=$sh }
    bytes = (Get-Item -LiteralPath $OutPath).Length
  })
}

# ============================================================================
# v1.2.0: hit-test 헬퍼 + click/type 사전 검증
# ============================================================================
# 목표: 라이브 actuation (click / type / shortcut) 직전에 좌표가 진짜 의도한
# 윈도우 안인지 Win32 WindowFromPoint 로 검증.
#
# 사고 사례:
#   1. click (1500, 935) — Kiro 가 전체화면일 땐 codex 패널, 창모드일 땐 코드 에디터
#   2. click (1700, 945) — toolbar 의 maximize 영역에 떨어져서 창 모드 토글
#
# 해결: click 직전에 _Test-CoordsInTarget 호출 → 다른 윈도우면 exit 3 (블록).
# ============================================================================

# 좌표가 -TargetHwnd 또는 -TargetMatch (title 부분일치) 와 매칭되는지 검사.
# 반환: PSCustomObject { matched, actual_hwnd, actual_root_hwnd, actual_title, reason }
function _Test-CoordsInTarget {
  param(
    [int]$X,
    [int]$Y,
    [int]$ExpectedHwnd,
    [string]$ExpectedMatch
  )
  $pt = New-Object CucpNative+POINT
  $pt.X = $X; $pt.Y = $Y
  $childHwnd = [CucpNative]::WindowFromPoint($pt)
  if ($childHwnd -eq [IntPtr]::Zero) {
    return [pscustomobject]@{
      matched = $false; actual_hwnd = 0; actual_root_hwnd = 0
      actual_title = ""; reason = "no_window_at_coords"
    }
  }
  $rootHwnd = [CucpNative]::GetAncestor($childHwnd, [CucpNative]::GA_ROOT)
  # title 추출
  $sb = New-Object System.Text.StringBuilder 256
  [void][CucpNative]::GetWindowText($rootHwnd, $sb, 256)
  $title = $sb.ToString()

  # 가드 매칭 — TargetHwnd 우선, 없으면 TargetMatch (title 부분일치)
  $matched = $false
  $reason = ""
  if ($ExpectedHwnd -gt 0) {
    $matched = ([int64]$rootHwnd -eq [int64]$ExpectedHwnd)
    if (-not $matched) { $reason = "hwnd_mismatch" }
  } elseif ($ExpectedMatch) {
    $needle = $ExpectedMatch.ToLowerInvariant()
    if ($title -and $title.ToLowerInvariant().Contains($needle)) { $matched = $true }
    else { $reason = "title_mismatch" }
  } else {
    # 가드 명시 없음 — 통과
    $matched = $true
  }

  return [pscustomobject]@{
    matched = $matched
    actual_hwnd = [int64]$childHwnd
    actual_root_hwnd = [int64]$rootHwnd
    actual_title = $title
    reason = $reason
  }
}

# ============================================================================
# Action: hit-test  ─ 좌표가 어떤 윈도우에 있는지 read-only 조회
# ============================================================================
# 입력: -X <n> -Y <n>
# 출력: { hwnd, root_hwnd, title, process, class }
# read-only — 클릭하지 않음. wrapper 가 dry-run 검증할 때 사용.
# ============================================================================
function _Action-HitTest {
  if (-not (_Ensure-Win32Native)) { _Emit @{status="error"; reason="win32_load_failed"} 1 }
  if ($X -le 0 -or $Y -le 0) {
    _Emit @{status="error"; reason="invalid_coords"; recommended_action="provide positive -X and -Y"} 1
  }
  $pt = New-Object CucpNative+POINT
  $pt.X = $X; $pt.Y = $Y
  $childHwnd = [CucpNative]::WindowFromPoint($pt)
  if ($childHwnd -eq [IntPtr]::Zero) {
    _Emit @{status="partial"; reason="no_window_at_coords"; x=$X; y=$Y} 2
  }
  $rootHwnd = [CucpNative]::GetAncestor($childHwnd, [CucpNative]::GA_ROOT)
  $sb = New-Object System.Text.StringBuilder 256
  [void][CucpNative]::GetWindowText($rootHwnd, $sb, 256)
  $rootTitle = $sb.ToString()
  $sb2 = New-Object System.Text.StringBuilder 256
  [void][CucpNative]::GetWindowText($childHwnd, $sb2, 256)
  $childTitle = $sb2.ToString()
  $sbCls = New-Object System.Text.StringBuilder 256
  [void][CucpNative]::GetClassName($rootHwnd, $sbCls, 256)
  $rootClass = $sbCls.ToString()
  $procId = [uint32]0
  [void][CucpNative]::GetWindowThreadProcessId($rootHwnd, [ref]$procId)
  $procName = ""
  try { $procName = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName } catch { }
  $uiaPoint = $null
  if (-not $SkipUia) {
    try { $uiaPoint = _Resolve-UiaPointRefinement -X $X -Y $Y -Inset $ClickInset } catch { $uiaPoint = $null }
  }

  # 매칭 검증 (TargetHwnd / TargetMatch 명시 시)
  $matched = $true
  $matchReason = "no_target_specified"
  if ($TargetHwnd -gt 0) {
    $matched = ([int64]$rootHwnd -eq [int64]$TargetHwnd)
    $matchReason = if ($matched) { "hwnd_match" } else { "hwnd_mismatch" }
  } elseif ($TargetMatch) {
    $needle = $TargetMatch.ToLowerInvariant()
    $matched = ($rootTitle -and $rootTitle.ToLowerInvariant().Contains($needle))
    $matchReason = if ($matched) { "title_match" } else { "title_mismatch" }
  }

  $statusStr = "ok"
  $exitCode = 0
  if ((($TargetHwnd -gt 0) -or $TargetMatch) -and -not $matched) {
    $statusStr = "partial"
    $exitCode = 2
  }

  $payload = [ordered]@{
    status = $statusStr
    x = $X; y = $Y
    child_hwnd = [int64]$childHwnd
    root_hwnd = [int64]$rootHwnd
    root_title = $rootTitle
    child_title = $childTitle
    root_class = $rootClass
    process_id = [int]$procId
    process_name = $procName
    target_hwnd = $TargetHwnd
    target_match = $TargetMatch
    matched = $matched
    match_reason = $matchReason
    uia_skipped = [bool]$SkipUia
  }
  if ($uiaPoint) {
    $payload["uia_point"] = [ordered]@{
      refined_x = [int]$uiaPoint.X
      refined_y = [int]$uiaPoint.Y
      score = [int]$uiaPoint.Score
      role = $uiaPoint.Role
      pattern = $uiaPoint.PatternName
      point_source = $uiaPoint.PointSource
      native_clickable = [bool]$uiaPoint.NativeClickable
      match = $uiaPoint.Match
    }
  }
  _Emit $payload $exitCode
}

function _Action-HitScan {
  if (-not (_Ensure-Win32Native)) { _Emit @{status="error"; reason="win32_load_failed"} 1 }
  if ($X -le 0 -or $Y -le 0) {
    _Emit @{status="error"; reason="invalid_coords"; recommended_action="provide positive -X and -Y"} 1
  }
  if ($ScanRadius -lt 0) { $ScanRadius = 0 }
  if ($ScanRadius -gt 64) { $ScanRadius = 64 }
  if ($ScanStep -le 0) { $ScanStep = 6 }
  if ($ScanStep -gt 16) { $ScanStep = 16 }
  if ($ClickInset -le 0) { $ClickInset = 3 }

  $swScan = [System.Diagnostics.Stopwatch]::StartNew()
  $candidates = New-Object System.Collections.ArrayList
  $sampleCount = 0
  $targetMatchedSamples = 0
  $offsets = New-Object System.Collections.ArrayList
  [void]$offsets.Add(0)
  for ($o = $ScanStep; $o -le $ScanRadius; $o += $ScanStep) {
    [void]$offsets.Add(-$o)
    [void]$offsets.Add($o)
  }
  if ($ScanRadius -gt 0 -and ($ScanRadius % $ScanStep) -ne 0) {
    [void]$offsets.Add(-$ScanRadius)
    [void]$offsets.Add($ScanRadius)
  }
  $offsets = @($offsets | Sort-Object -Unique)

  foreach ($dy in $offsets) {
    foreach ($dx in $offsets) {
      $sx = $X + $dx
      $sy = $Y + $dy
      if ($sx -le 0 -or $sy -le 0) { continue }
      $sampleCount++

      $sampleHit = _Test-CoordsInTarget -X $sx -Y $sy -ExpectedHwnd $TargetHwnd -ExpectedMatch $TargetMatch
      if (-not $sampleHit.matched) { continue }
      $targetMatchedSamples++

      $uiaPoint = $null
      try { $uiaPoint = _Resolve-UiaPointRefinement -X $sx -Y $sy -Inset $ClickInset } catch { $uiaPoint = $null }
      if (-not $uiaPoint) { continue }

      $refinedHit = _Test-CoordsInTarget -X ([int]$uiaPoint.X) -Y ([int]$uiaPoint.Y) -ExpectedHwnd $TargetHwnd -ExpectedMatch $TargetMatch
      if (-not $refinedHit.matched) { continue }

      $identifier = ""
      try { $identifier = "$($uiaPoint.Match.preferred_identifier)" } catch { $identifier = "" }
      if (-not $identifier) {
        try { $identifier = "$($uiaPoint.Match.name)|$($uiaPoint.Match.automation_id)|$($uiaPoint.Role)" } catch { $identifier = "$($uiaPoint.Role)" }
      }
      $key = "$identifier|$($uiaPoint.Role)|$($uiaPoint.PatternName)|$([int]$uiaPoint.X),$([int]$uiaPoint.Y)"
      [void]$candidates.Add([pscustomobject]@{
        key = $key
        sample_x = $sx
        sample_y = $sy
        dx = $dx
        dy = $dy
        refined_x = [int]$uiaPoint.X
        refined_y = [int]$uiaPoint.Y
        score = [int]$uiaPoint.Score
        role = "$($uiaPoint.Role)"
        pattern = "$($uiaPoint.PatternName)"
        point_source = "$($uiaPoint.PointSource)"
        native_clickable = [bool]$uiaPoint.NativeClickable
        depth = [int]$uiaPoint.Depth
        area = [int]$uiaPoint.Area
        match = $uiaPoint.Match
      })
    }
  }

  $groups = @{}
  foreach ($c in @($candidates)) {
    if (-not $groups.ContainsKey($c.key)) {
      $groups[$c.key] = [pscustomobject]@{ count = 0; max_score = 0 }
    }
    $groups[$c.key].count = [int]$groups[$c.key].count + 1
    if ([int]$c.score -gt [int]$groups[$c.key].max_score) { $groups[$c.key].max_score = [int]$c.score }
  }

  $ranked = New-Object System.Collections.ArrayList
  foreach ($c in @($candidates)) {
    $support = [int]$groups[$c.key].count
    $dist = [Math]::Sqrt(([double](($c.refined_x - $X) * ($c.refined_x - $X))) + ([double](($c.refined_y - $Y) * ($c.refined_y - $Y))))
    $distPenalty = [int][Math]::Round($dist)
    $clickBonus = 0
    if ($c.native_clickable) { $clickBonus += 12 }
    if ($c.point_source -eq "clickable_point") { $clickBonus += 8 }
    $finalScore = [int]$c.score + ($support * 7) + $clickBonus - $distPenalty
    [void]$ranked.Add([pscustomobject]@{
      sample_x = $c.sample_x
      sample_y = $c.sample_y
      dx = $c.dx
      dy = $c.dy
      refined_x = $c.refined_x
      refined_y = $c.refined_y
      final_score = $finalScore
      base_score = $c.score
      support = $support
      distance_from_origin = $dist
      role = $c.role
      pattern = $c.pattern
      point_source = $c.point_source
      native_clickable = $c.native_clickable
      depth = $c.depth
      area = $c.area
      match = $c.match
    })
  }

  $ordered = @($ranked | Sort-Object -Property final_score, support, base_score -Descending)
  $best = $null
  if ($ordered.Count -gt 0) { $best = $ordered[0] }
  $swScan.Stop()

  if (-not $best) {
    _Emit ([ordered]@{
      status = "partial"
      reason = "no_uia_candidate"
      x = $X
      y = $Y
      radius = $ScanRadius
      step = $ScanStep
      click_inset = $ClickInset
      target_hwnd = $TargetHwnd
      target_match = $TargetMatch
      sample_count = $sampleCount
      target_matched_samples = $targetMatchedSamples
      candidate_count = @($candidates).Count
      elapsed_ms = [int]$swScan.Elapsed.TotalMilliseconds
      recommended_action = "Try a slightly larger --radius, narrower --target-match, or DOM/UIA label route."
    }) 2
  }

  $top = @($ordered | Select-Object -First 12)
  _Emit ([ordered]@{
    status = "ok"
    x = $X
    y = $Y
    radius = $ScanRadius
    step = $ScanStep
    click_inset = $ClickInset
    target_hwnd = $TargetHwnd
    target_match = $TargetMatch
    sample_count = $sampleCount
    target_matched_samples = $targetMatchedSamples
    candidate_count = @($candidates).Count
    best = $best
    recommended_point = [ordered]@{
      x = [int]$best.refined_x
      y = [int]$best.refined_y
      point_source = $best.point_source
      native_clickable = [bool]$best.native_clickable
      confidence = if ($best.support -ge 4 -or $best.native_clickable) { "high" } elseif ($best.support -ge 2) { "medium" } else { "low" }
    }
    candidates = $top
    elapsed_ms = [int]$swScan.Elapsed.TotalMilliseconds
  }) 0
}

# ============================================================================
# v1.3.0: CDP Actions
# ============================================================================
$Script:_LastCdpPageSelection = $null

function _Cdp-ScorePages {
  param(
    [Parameter(Mandatory)]$Detect,
    [string]$PageMatch
  )
  $out = New-Object System.Collections.ArrayList
  $pages = @($Detect.pages)
  $needle = ""
  if ($PageMatch) { $needle = $PageMatch.ToLowerInvariant() }
  foreach ($p in $pages) {
    $title = if ($p.title) { "$($p.title)" } else { "" }
    $url = if ($p.url) { "$($p.url)" } else { "" }
    $type = if ($p.type) { "$($p.type)" } else { "" }
    $titleLower = $title.ToLowerInvariant()
    $urlLower = $url.ToLowerInvariant()
    $score = 0
    $reasons = New-Object System.Collections.ArrayList
    if ($PageMatch) {
      if ($titleLower -eq $needle -or $urlLower -eq $needle) {
        $score += 140
        [void]$reasons.Add("exact_page_match")
      } elseif ($titleLower.Contains($needle) -or $urlLower.Contains($needle)) {
        $score += 105
        [void]$reasons.Add("substring_page_match")
      } else {
        $score -= 100
        [void]$reasons.Add("page_match_miss")
      }
    }
    if ($type -eq "page") {
      $score += 45
      [void]$reasons.Add("type_page")
    } elseif ($type -eq "webview") {
      $score += 42
      [void]$reasons.Add("type_webview")
    } elseif ($type -eq "iframe") {
      $score -= 20
      [void]$reasons.Add("type_iframe")
    } elseif ($type -eq "worker" -or $type -eq "service_worker") {
      $score -= 60
      [void]$reasons.Add("type_worker")
    }
    if ($title) {
      $score += 12
      [void]$reasons.Add("has_title")
    }
    if ($urlLower.StartsWith("devtools://")) {
      $score -= 80
      [void]$reasons.Add("devtools_page_penalty")
    } elseif ($urlLower.StartsWith("http") -or $urlLower.StartsWith("file:") -or $urlLower.StartsWith("app:")) {
      $score += 8
      [void]$reasons.Add("document_url")
    }
    [void]$out.Add([pscustomobject]@{
      id = $p.id
      title = $title
      url = $url
      type = $type
      score = [int]$score
      reasons = @($reasons)
      page = $p
    })
  }
  return @($out | Sort-Object @{ Expression = { -1 * [int]$_.score } }, @{ Expression = { $_.title } })
}

# CDP page 매칭 헬퍼 — title 또는 url 부분일치
function _Cdp-FindPage {
  param(
    [Parameter(Mandatory)]$Detect,  # _Cdp-Detect 결과
    [string]$PageMatch
  )
  $Script:_LastCdpPageSelection = $null
  if (-not $Detect.available) { return $null }
  $pages = $Detect.pages
  if (-not $pages -or @($pages).Count -eq 0) { return $null }
  $scores = @(_Cdp-ScorePages -Detect $Detect -PageMatch $PageMatch)
  if (-not $scores -or $scores.Count -eq 0) { return $null }
  $selected = $scores[0]
  if ($PageMatch -and ($selected.reasons -contains "page_match_miss")) {
    $Script:_LastCdpPageSelection = [pscustomobject]@{
      page_match = $PageMatch
      selected = $null
      candidates = @($scores | Select-Object -First 8 | ForEach-Object {
        [pscustomobject]@{ id=$_.id; title=$_.title; url=$_.url; type=$_.type; score=$_.score; reasons=$_.reasons }
      })
    }
    return $null
  }
  $Script:_LastCdpPageSelection = [pscustomobject]@{
    page_match = $PageMatch
    selected = [pscustomobject]@{ id=$selected.id; title=$selected.title; url=$selected.url; type=$selected.type; score=$selected.score; reasons=$selected.reasons }
    candidates = @($scores | Select-Object -First 8 | ForEach-Object {
      [pscustomobject]@{ id=$_.id; title=$_.title; url=$_.url; type=$_.type; score=$_.score; reasons=$_.reasons }
    })
  }
  return $selected.page
}

function _Js-StringLiteral {
  param([string]$Value)
  if ($null -eq $Value) { return "null" }
  return ($Value | ConvertTo-Json -Compress)
}

function _Cdp-RunSmartDomAction {
  param(
    [ValidateSet("click", "type")]
    [string]$DomAction,
    [string]$Needle,
    [string]$TextToType,
    [bool]$Clear,
    [bool]$Enter,
    [bool]$PlanOnly = $false
  )
  if (-not $Needle) {
    _Emit @{status="error"; reason="missing_cdp_text"; recommended_action="provide -CdpText <visible text or label>"} 1
  }
  $bridgePlan = _Cdp-NewDomBridgePlan -DomAction $DomAction -Query $Needle -Port $CdpPort -PageMatch $CdpPageMatch -TextToType $TextToType -Clear $Clear -Enter $Enter
  $detect = _Cdp-Detect -Port $CdpPort
  if (-not $detect.available) {
    _Emit @{status="partial"; reason="cdp_port_closed"; port=$CdpPort; detail=$detect.error; dom_bridge_plan=$bridgePlan} 2
  }
  $page = _Cdp-FindPage -Detect $detect -PageMatch $CdpPageMatch
  if (-not $page) {
    _Emit @{status="partial"; reason="no_matching_page"; page_match=$CdpPageMatch; available_pages=@($detect.pages); page_selection=$Script:_LastCdpPageSelection; dom_bridge_plan=$bridgePlan} 2
  }

  $needleJs = _Js-StringLiteral $Needle
  $textJs = _Js-StringLiteral $TextToType
  $actionJs = _Js-StringLiteral $DomAction
  $clearJs = if ($Clear) { "true" } else { "false" }
  $enterJs = if ($Enter) { "true" } else { "false" }
  $planOnlyJs = if ($PlanOnly) { "true" } else { "false" }

  $expr = @"
(function(){
  const action = $actionJs;
  const needleRaw = $needleJs;
  const textToType = $textJs || '';
  const clearFirst = $clearJs;
  const pressEnter = $enterJs;
  const planOnly = $planOnlyJs;
  function norm(s) {
    try { s = (s || '').toString().normalize('NFKC'); } catch(e) { s = (s || '').toString(); }
    return s.toLowerCase().replace(/[^\p{L}\p{N}\s]+/gu, ' ').replace(/\s+/g, ' ').trim();
  }
  function visible(el) {
    if (!el || !el.isConnected) return false;
    const r = el.getBoundingClientRect();
    if (!r || r.width < 1 || r.height < 1) return false;
    const cs = window.getComputedStyle(el);
    if (!cs || cs.display === 'none' || cs.visibility === 'hidden' || Number(cs.opacity || 1) === 0) return false;
    return true;
  }
  function inputType(el) {
    return ((el && el.getAttribute && el.getAttribute('type')) || 'text').toLowerCase();
  }
  function typeable(el) {
    const tag = (el && el.tagName || '').toLowerCase();
    if (!el) return false;
    if (el.isContentEditable || tag === 'textarea') return true;
    if (tag !== 'input') return false;
    return !/^(button|submit|reset|checkbox|radio|file|image|range|color|hidden)$/i.test(inputType(el));
  }
  function setNativeValue(el, value) {
    const tag = (el.tagName || '').toLowerCase();
    const proto = tag === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const own = Object.getOwnPropertyDescriptor(el, 'value');
    const base = Object.getOwnPropertyDescriptor(proto, 'value');
    if (base && base.set && (!own || own.set !== base.set)) base.set.call(el, value);
    else el.value = value;
  }
  function fireValueEvents(el, data) {
    try { el.dispatchEvent(new InputEvent('input', { bubbles: true, data: data || null, inputType: 'insertText' })); }
    catch(e) { el.dispatchEvent(new Event('input', { bubbles: true })); }
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }
  function textParts(el) {
    const parts = [];
    const attrs = ['aria-label','title','placeholder','alt','name','id','value'];
    for (const a of attrs) {
      const v = el.getAttribute && el.getAttribute(a);
      if (v) parts.push(v);
    }
    if (el.labels) {
      for (const l of Array.from(el.labels)) {
        if (l && l.innerText) parts.push(l.innerText);
      }
    }
    if (el.tagName === 'LABEL' && el.control) {
      parts.push(el.innerText || '');
      const c = el.control;
      for (const a of ['aria-label','title','placeholder','name','id']) {
        const v = c.getAttribute && c.getAttribute(a);
        if (v) parts.push(v);
      }
    } else {
      parts.push(el.innerText || el.textContent || '');
    }
    return parts.map(p => (p || '').toString()).filter(Boolean);
  }
  function scoreText(parts, needle) {
    let best = 0;
    let bestText = '';
    for (const raw of parts) {
      const hay = norm(raw);
      if (!hay) continue;
      let score = 0;
      if (hay === needle) score = 100;
      else if (hay.startsWith(needle)) score = 88;
      else if (hay.includes(needle)) {
        const ratio = Math.min(1, needle.length / Math.max(1, hay.length));
        score = 62 + Math.floor(ratio * 25);
      } else if (needle.length >= 2 && hay.includes(needle.slice(0, Math.min(3, needle.length)))) {
        score = 25;
      }
      if (score > best) { best = score; bestText = raw; }
    }
    return { score: best, text: bestText };
  }
  function roleWeight(el, action) {
    const tag = (el.tagName || '').toLowerCase();
    const role = (el.getAttribute && (el.getAttribute('role') || '')) || '';
    const type = (el.getAttribute && (el.getAttribute('type') || '')) || '';
    if (action === 'type') {
      if (typeable(el) || role === 'textbox' || role === 'searchbox' || role === 'combobox') return 40;
      if (tag === 'label' && el.control) return 25;
      return -30;
    }
    if (tag === 'button' || tag === 'a' || role === 'button' || role === 'link' || role === 'menuitem' || role === 'tab') return 35;
    if (tag === 'input' && /button|submit|reset|checkbox|radio/.test(type)) return 35;
    if (el.onclick || tag === 'label' || tag === 'summary') return 20;
    return 0;
  }
  function attrQuote(v) {
    return (v || '').toString().replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, ' ');
  }
  function cssIdent(v) {
    try { if (window.CSS && CSS.escape) return CSS.escape(v); } catch(e) {}
    return (v || '').toString().replace(/[^a-zA-Z0-9_-]/g, function(ch) { return '\\' + ch; });
  }
  function selectorCandidates(el, matchedText, action) {
    const out = [];
    function push(kind, selector, score, reason) {
      if (!selector) return;
      if (out.some(x => x.selector === selector)) return;
      out.push({ kind, selector, score, reason });
    }
    const tag = (el.tagName || '').toLowerCase();
    const role = el.getAttribute && el.getAttribute('role');
    const id = el.getAttribute && el.getAttribute('id');
    if (id) push('css_id', '#' + cssIdent(id), 98, 'stable_id');
    for (const a of ['data-testid','data-test','data-cy','data-qa']) {
      const v = el.getAttribute && el.getAttribute(a);
      if (v) push('css_data_attr', '[' + a + '="' + attrQuote(v) + '"]', 96, a);
    }
    const aria = el.getAttribute && el.getAttribute('aria-label');
    if (aria) push('css_aria_label', '[aria-label="' + attrQuote(aria) + '"]', 90, 'aria_label');
    const name = el.getAttribute && el.getAttribute('name');
    if (name && tag) push('css_name', tag + '[name="' + attrQuote(name) + '"]', 84, 'name_attr');
    const placeholder = el.getAttribute && el.getAttribute('placeholder');
    if (placeholder) push('css_placeholder', '[placeholder="' + attrQuote(placeholder) + '"]', 82, 'placeholder');
    if (role) push('css_role', '[role="' + attrQuote(role) + '"]', 62, 'role_attr');
    if (tag) push('css_tag_fallback', tag, 35, 'last_resort_tag');
    out.sort((a,b) => b.score - a.score);
    return out.slice(0, 8);
  }
  function locatorCandidates(el, matchedText, action) {
    const out = [];
    function push(kind, locator, score, reason) {
      if (!locator) return;
      if (out.some(x => x.locator === locator)) return;
      out.push({ kind, locator, score, reason });
    }
    const nameJson = JSON.stringify(matchedText || needleRaw);
    const tag = (el.tagName || '').toLowerCase();
    const role = (el.getAttribute && (el.getAttribute('role') || '')) || '';
    const aria = el.getAttribute && el.getAttribute('aria-label');
    const placeholder = el.getAttribute && el.getAttribute('placeholder');
    if (action === 'type') {
      if (aria) push('playwright_label', 'page.getByLabel(' + JSON.stringify(aria) + ')', 100, 'aria_label');
      if (placeholder) push('playwright_placeholder', 'page.getByPlaceholder(' + JSON.stringify(placeholder) + ')', 94, 'placeholder');
      if (role === 'textbox' || role === 'searchbox') push('playwright_role', "page.getByRole('" + role + "', { name: " + nameJson + ' })', 86, 'role_textbox');
    } else {
      if (role === 'button' || tag === 'button') push('playwright_role', "page.getByRole('button', { name: " + nameJson + ' })', 100, 'button_name');
      if (role === 'link' || tag === 'a') push('playwright_role', "page.getByRole('link', { name: " + nameJson + ' })', 92, 'link_name');
      if (role === 'tab') push('playwright_role', "page.getByRole('tab', { name: " + nameJson + ' })', 90, 'tab_name');
      push('playwright_text', 'page.getByText(' + nameJson + ')', 70, 'visible_text');
    }
    out.sort((a,b) => b.score - a.score);
    return out.slice(0, 8);
  }
  function candidateSummary(c) {
    return {
      score: c.score,
      match_score: c.matchScore,
      matched_text: c.matchedText,
      tag_name: c.tag,
      role: c.role,
      rect: c.rect,
      selector_candidates: c.selectorCandidates,
      locator_candidates: c.locatorCandidates
    };
  }
  const needle = norm(needleRaw);
  if (!needle) return { ok: false, reason: 'empty_needle' };
  const selector = action === 'type'
    ? 'input,textarea,[contenteditable=true],[role=textbox],[role=searchbox],[role=combobox],label'
    : 'button,a,input,textarea,select,[role],[onclick],label,summary,[contenteditable=true]';
  // v1.4.0 DOM bridge v2: deep traversal — Shadow DOM + same-origin iframe
  // 기존 querySelectorAll 은 light-DOM 1뎁스만 보지만, Slack/Discord/Notion 같은
  // chromium 앱은 web component (shadowRoot) 와 same-origin iframe 안에 입력란이
  // 들어있는 경우가 많음. 보안상 cross-origin iframe 은 자동 스킵.
  function deepCollect(root, sel, out, hops) {
    if (!root || hops <= 0) return;
    try {
      const found = root.querySelectorAll ? root.querySelectorAll(sel) : [];
      for (let i = 0; i < found.length && out.length < 1200; i++) out.push(found[i]);
    } catch (e) { /* ignore selector errors */ }
    // shadow roots
    try {
      const all = root.querySelectorAll ? root.querySelectorAll('*') : [];
      for (let i = 0; i < all.length && out.length < 1200; i++) {
        const sr = all[i].shadowRoot;
        if (sr) deepCollect(sr, sel, out, hops - 1);
      }
    } catch (e) { /* ignore */ }
    // same-origin iframes
    try {
      const frames = root.querySelectorAll ? root.querySelectorAll('iframe,frame') : [];
      for (let i = 0; i < frames.length && out.length < 1200; i++) {
        let doc = null;
        try { doc = frames[i].contentDocument; } catch (e) { doc = null; }
        if (doc) deepCollect(doc, sel, out, hops - 1);
      }
    } catch (e) { /* ignore */ }
  }
  const nodes = [];
  deepCollect(document, selector, nodes, 4);
  // 동일 element 중복 제거 (shadow host + light child 같은 경우)
  const seen = new Set();
  const uniqueNodes = [];
  for (const n of nodes) {
    if (seen.has(n)) continue;
    seen.add(n);
    uniqueNodes.push(n);
    if (uniqueNodes.length >= 800) break;
  }
  const candidates = [];
  for (const el0 of uniqueNodes) {
    let el = el0;
    if (action === 'type' && el0.tagName === 'LABEL' && el0.control) el = el0.control;
    if (!visible(el0) && !visible(el)) continue;
    const parts = textParts(el0);
    if (el !== el0) parts.push(...textParts(el));
    const st = scoreText(parts, needle);
    if (st.score <= 0) continue;
    const r = (visible(el) ? el : el0).getBoundingClientRect();
    const area = Math.max(1, r.width * r.height);
    let score = st.score + roleWeight(el, action);
    if (area < 40000) score += 12;
    if (area > 180000) score -= 30;
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') score -= 80;
    candidates.push({
      el,
      el0,
      score,
      matchScore: st.score,
      matchedText: st.text,
      tag: el.tagName,
      role: el.getAttribute('role') || '',
      rect: {x:r.x,y:r.y,width:r.width,height:r.height},
      selectorCandidates: selectorCandidates(el, st.text, action),
      locatorCandidates: locatorCandidates(el, st.text, action)
    });
  }
  candidates.sort((a,b) => b.score - a.score || a.rect.width*a.rect.height - b.rect.width*b.rect.height);
  const best = candidates[0];
  if (!best || best.score < 55) {
    return {
      ok: false,
      reason: 'no_text_match',
      candidate_count: candidates.length,
      top_score: best ? best.score : 0,
      candidate_summaries: candidates.slice(0, 5).map(candidateSummary)
    };
  }
  const el = best.el;
  if (!planOnly) {
    try { el.scrollIntoView({block:'center', inline:'center', behavior:'instant'}); } catch(e) {}
    try { el.focus(); } catch(e) {}
    if (action === 'click') {
      if (best.el0 && best.el0.tagName === 'LABEL' && best.el0.control) best.el0.click();
      else el.click();
    } else {
      const isCE = !!el.isContentEditable;
      const isInput = typeable(el);
      if (!isCE && !isInput) return { ok: false, reason: 'matched_element_not_typeable', tag_name: el.tagName, matched_text: best.matchedText, score: best.score };
      let changed = false;
      if (clearFirst) {
        if (isCE) el.textContent = '';
        else setNativeValue(el, '');
        changed = true;
      }
      if (textToType) {
        if (isCE) el.textContent += textToType;
        else setNativeValue(el, (el.value || '') + textToType);
        changed = true;
      }
      if (changed) {
        fireValueEvents(el, textToType);
      }
      if (pressEnter) {
        for (const t of ['keydown','keypress','keyup']) {
          el.dispatchEvent(new KeyboardEvent(t, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
        }
      }
    }
  }
  return {
    ok: true,
    action,
    query: needleRaw,
    matched_text: best.matchedText,
    score: best.score,
    match_score: best.matchScore,
    tag_name: el.tagName,
    role: el.getAttribute('role') || '',
    rect: best.rect,
    selector_candidates: best.selectorCandidates,
    locator_candidates: best.locatorCandidates,
    candidate_summaries: candidates.slice(0, 5).map(candidateSummary),
    candidate_count: candidates.length,
    text_length: textToType.length,
    sent_enter: !planOnly && !!pressEnter,
    plan_only: !!planOnly
  };
})()
"@

  $r = _Cdp-WsCall -WsUrl $page.ws_url -Method "Runtime.evaluate" -Params @{
    expression = $expr
    returnByValue = $true
    awaitPromise = $false
  } -TimeoutMs 8000 -MessageId 1

  if (-not $r.ok -or -not $r.response) {
    _Emit @{status="error"; reason="cdp_call_failed"; detail=$r.error; page_id=$page.id} 1
  }
  $resp = $r.response
  $rExc = $resp.result.exceptionDetails
  if ($rExc) {
    _Emit @{
      status = "error"
      reason = "javascript_exception"
      exception_text = "$($rExc.text)"
      exception_description = "$($rExc.exception.description)"
      page_id = $page.id
    } 1
  }
  $rv = $resp.result.result.value
  if (-not $rv -or -not $rv.ok) {
    _Emit ([ordered]@{
      status = "partial"
      reason = if ($rv) { "$($rv.reason)" } else { "no_result" }
      query = $Needle
      candidate_count = if ($rv) { [int]$rv.candidate_count } else { 0 }
      top_score = if ($rv) { [int]$rv.top_score } else { 0 }
      candidate_summaries = if ($rv) { @($rv.candidate_summaries) } else { @() }
      page_id = $page.id
      page_title = "$($page.title)"
      page_url = "$($page.url)"
      page_selection = $Script:_LastCdpPageSelection
      dom_bridge_plan = $bridgePlan
    }) 2
  }
  _Emit ([ordered]@{
    status = "ok"
    dom_action = $DomAction
    plan_only = [bool]$rv.plan_only
    query = $Needle
    matched_text = "$($rv.matched_text)"
    score = [int]$rv.score
    match_score = [int]$rv.match_score
    tag_name = "$($rv.tag_name)"
    role = "$($rv.role)"
    rect = $rv.rect
    candidate_count = [int]$rv.candidate_count
    text_length = [int]$rv.text_length
    sent_enter = [bool]$rv.sent_enter
    page_id = $page.id
    page_title = "$($page.title)"
    page_url = "$($page.url)"
    page_selection = $Script:_LastCdpPageSelection
    selector_candidates = @($rv.selector_candidates)
    locator_candidates = @($rv.locator_candidates)
    candidate_summaries = @($rv.candidate_summaries)
    dom_bridge_plan = $bridgePlan
  })
}

# ============================================================================
# Action: cdp-detect ─ 9222 포트 + 페이지 목록
# ============================================================================
# read-only — Electron 앱이 --remote-debugging-port 옵션으로 떠있는지 확인.
# 출력: { available, port, pages[], version }
# ============================================================================
function _Action-CdpDetect {
  $detect = _Cdp-Detect -Port $CdpPort
  if (-not $detect.available) {
    _Emit ([ordered]@{
      status = "partial"
      reason = "cdp_port_closed"
      port = $CdpPort
      detail = $detect.error
      recommended_action = "Start the Electron app with --remote-debugging-port=$CdpPort. For Kiro: see references/cdp-setup.md"
    }) 2
  }
  $verObj = $detect.version
  _Emit ([ordered]@{
    status = "ok"
    port = $detect.port
    page_count = @($detect.pages).Count
    pages = @($detect.pages)
    browser = if ($verObj) { "$($verObj.Browser)" } else { "" }
    protocol_version = if ($verObj) { "$($verObj.'Protocol-Version')" } else { "" }
    user_agent = if ($verObj) { "$($verObj.'User-Agent')" } else { "" }
  })
}

# ============================================================================
# Action: cdp-eval ─ Runtime.evaluate JavaScript 실행
# ============================================================================
# 입력: -CdpExpr "document.title" [-CdpPageMatch "Kiro"]
# 출력: { result_type, result_value, page_id, page_title }
# ============================================================================
function _Action-CdpEval {
  # v1.3.0: CdpExpr 또는 CdpExprB64 (base64 디코딩) 지원
  if (-not $CdpExpr -and $CdpExprB64) {
    try { $CdpExpr = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($CdpExprB64)) } catch {
      _Emit @{status="error"; reason="b64_decode_failed"; detail=$_.Exception.Message} 1
    }
  }
  if (-not $CdpExpr) {
    _Emit @{status="error"; reason="missing_cdp_expr"; recommended_action="provide -CdpExpr <javascript> or -CdpExprB64 <base64>"} 1
  }
  $detect = _Cdp-Detect -Port $CdpPort
  if (-not $detect.available) {
    _Emit @{status="partial"; reason="cdp_port_closed"; port=$CdpPort; detail=$detect.error} 2
  }
  $page = _Cdp-FindPage -Detect $detect -PageMatch $CdpPageMatch
  if (-not $page) {
    _Emit @{status="partial"; reason="no_matching_page"; page_match=$CdpPageMatch; available_pages=@($detect.pages)} 2
  }

  $r = _Cdp-WsCall -WsUrl $page.ws_url -Method "Runtime.evaluate" -Params @{
    expression = $CdpExpr
    returnByValue = $true
    awaitPromise = $true
  } -TimeoutMs 8000 -MessageId 1

  if (-not $r.ok -or -not $r.response) {
    _Emit @{status="error"; reason="cdp_call_failed"; detail=$r.error; page_id=$page.id} 1
  }
  $resp = $r.response
  if ($resp.error) {
    _Emit @{
      status = "error"
      reason = "cdp_evaluate_error"
      cdp_error_code = $resp.error.code
      cdp_error_message = $resp.error.message
      page_id = $page.id
    } 1
  }
  $rv = $resp.result.result
  $rExc = $resp.result.exceptionDetails
  if ($rExc) {
    _Emit ([ordered]@{
      status = "partial"
      reason = "javascript_exception"
      exception_text = "$($rExc.text)"
      exception_description = "$($rExc.exception.description)"
      page_id = $page.id
    }) 2
  }
  _Emit ([ordered]@{
    status = "ok"
    expression = $CdpExpr
    result_type = "$($rv.type)"
    result_value = $rv.value
    page_id = $page.id
    page_title = "$($page.title)"
    page_url = "$($page.url)"
  })
}

# ============================================================================
# Action: cdp-type ─ DOM selector → focus + value set + dispatchEvent
# ============================================================================
# 입력: -CdpSelector "textarea" -Text "msg" [-CdpPageMatch "Kiro"]
#       [-PressEnter] [-ClearFirst]
# 동작:
#   1. element = document.querySelector(selector)
#   2. element.focus()
#   3. (textarea/input) element.value = text + dispatch input/change events
#      (contenteditable) element.textContent = text + dispatch input event
#   4. (옵션) Enter 키 dispatch (KeyboardEvent)
# ============================================================================
function _Action-CdpType {
  if (-not $CdpSelector) { _Emit @{status="error"; reason="missing_cdp_selector"} 1 }
  if (-not $Text -and -not $ClearFirst -and -not $PressEnter) {
    _Emit @{status="error"; reason="missing_text_or_action"} 1
  }
  $detect = _Cdp-Detect -Port $CdpPort
  if (-not $detect.available) {
    _Emit @{status="partial"; reason="cdp_port_closed"; port=$CdpPort; detail=$detect.error} 2
  }
  $page = _Cdp-FindPage -Detect $detect -PageMatch $CdpPageMatch
  if (-not $page) {
    _Emit @{status="partial"; reason="no_matching_page"; page_match=$CdpPageMatch} 2
  }

  # JavaScript 작성 — 안전한 escape
  $textJs = if ($Text) {
    $Text.Replace("\", "\\").Replace("`r", "").Replace("`n", "\n").Replace("`"", "\""")
  } else { "" }
  $selJs = $CdpSelector.Replace("\", "\\").Replace("`"", "\""")

  $clearStr = if ($ClearFirst) { "true" } else { "false" }
  $pressEnterStr = if ($PressEnter) { "true" } else { "false" }

  $expr = @"
(function(){
  var el = document.querySelector(`"$selJs`");
  if (!el) return { ok: false, reason: 'selector_not_found' };
  try { el.focus(); } catch(e) {}
  var isCE = el.isContentEditable;
  var isInput = el.tagName === 'INPUT' || el.tagName === 'TEXTAREA';
  if ($clearStr) {
    if (isCE) { el.textContent = ''; }
    else if (isInput) { el.value = ''; }
  }
  var newText = "$textJs";
  if (newText) {
    if (isCE) { el.textContent += newText; }
    else if (isInput) { el.value += newText; }
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }
  var sentEnter = false;
  if ($pressEnterStr) {
    var ev = new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true });
    el.dispatchEvent(ev);
    var ev2 = new KeyboardEvent('keypress', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true });
    el.dispatchEvent(ev2);
    var ev3 = new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true });
    el.dispatchEvent(ev3);
    sentEnter = true;
  }
  var current = isCE ? el.textContent : (isInput ? el.value : '');
  return {
    ok: true,
    selector: "$selJs",
    tag_name: el.tagName,
    is_content_editable: isCE,
    is_input: isInput,
    current_value_length: (current||'').length,
    sent_enter: sentEnter
  };
})()
"@

  $r = _Cdp-WsCall -WsUrl $page.ws_url -Method "Runtime.evaluate" -Params @{
    expression = $expr
    returnByValue = $true
    awaitPromise = $false
  } -TimeoutMs 8000 -MessageId 1

  if (-not $r.ok -or -not $r.response) {
    _Emit @{status="error"; reason="cdp_call_failed"; detail=$r.error; page_id=$page.id} 1
  }
  $resp = $r.response
  $rExc = $resp.result.exceptionDetails
  if ($rExc) {
    _Emit @{
      status = "error"
      reason = "javascript_exception"
      exception_text = "$($rExc.text)"
      exception_description = "$($rExc.exception.description)"
      page_id = $page.id
    } 1
  }
  $rv = $resp.result.result.value
  if (-not $rv -or -not $rv.ok) {
    _Emit @{
      status = "partial"
      reason = if ($rv) { "$($rv.reason)" } else { "no_result" }
      selector = $CdpSelector
      page_id = $page.id
    } 2
  }
  _Emit ([ordered]@{
    status = "ok"
    selector = $CdpSelector
    text_length = if ($Text) { $Text.Length } else { 0 }
    cleared = [bool]$ClearFirst
    sent_enter = [bool]$rv.sent_enter
    tag_name = "$($rv.tag_name)"
    is_content_editable = [bool]$rv.is_content_editable
    is_input = [bool]$rv.is_input
    current_value_length = [int]$rv.current_value_length
    page_id = $page.id
    page_title = "$($page.title)"
  })
}

# ============================================================================
# Action: cdp-click ─ DOM selector → element.click()
# ============================================================================
function _Action-CdpClick {
  if (-not $CdpSelector) { _Emit @{status="error"; reason="missing_cdp_selector"} 1 }
  $detect = _Cdp-Detect -Port $CdpPort
  if (-not $detect.available) {
    _Emit @{status="partial"; reason="cdp_port_closed"; port=$CdpPort; detail=$detect.error} 2
  }
  $page = _Cdp-FindPage -Detect $detect -PageMatch $CdpPageMatch
  if (-not $page) {
    _Emit @{status="partial"; reason="no_matching_page"; page_match=$CdpPageMatch} 2
  }
  $selJs = $CdpSelector.Replace("\", "\\").Replace("`"", "\""")
  $expr = @"
(function(){
  var el = document.querySelector(`"$selJs`");
  if (!el) return { ok: false, reason: 'selector_not_found' };
  try { el.scrollIntoView({block:'center', behavior:'instant'}); } catch(e) {}
  try { el.focus(); } catch(e) {}
  el.click();
  return { ok: true, selector: "$selJs", tag_name: el.tagName };
})()
"@
  $r = _Cdp-WsCall -WsUrl $page.ws_url -Method "Runtime.evaluate" -Params @{
    expression = $expr
    returnByValue = $true
    awaitPromise = $false
  } -TimeoutMs 8000 -MessageId 1
  if (-not $r.ok -or -not $r.response) {
    _Emit @{status="error"; reason="cdp_call_failed"; detail=$r.error} 1
  }
  $rv = $r.response.result.result.value
  if (-not $rv -or -not $rv.ok) {
    _Emit @{status="partial"; reason=(if ($rv) { "$($rv.reason)" } else { "no_result" }); selector=$CdpSelector} 2
  }
  _Emit ([ordered]@{
    status = "ok"
    selector = $CdpSelector
    tag_name = "$($rv.tag_name)"
    page_id = $page.id
    page_title = "$($page.title)"
  })
}

function _Action-CdpSmartClick {
  _Cdp-RunSmartDomAction -DomAction "click" -Needle $CdpText -TextToType "" -Clear $false -Enter $false
}

function _Action-CdpSmartFind {
  _Cdp-RunSmartDomAction -DomAction "click" -Needle $CdpText -TextToType "" -Clear $false -Enter $false -PlanOnly $true
}

function _Action-CdpSmartTypeFind {
  _Cdp-RunSmartDomAction -DomAction "type" -Needle $CdpText -TextToType "" -Clear $false -Enter $false -PlanOnly $true
}

function _Action-CdpSmartType {
  if (-not $Text -and -not $ClearFirst -and -not $PressEnter) {
    _Emit @{status="error"; reason="missing_text_or_action"} 1
  }
  _Cdp-RunSmartDomAction -DomAction "type" -Needle $CdpText -TextToType $Text -Clear ([bool]$ClearFirst) -Enter ([bool]$PressEnter)
}

# ============================================================================
# Action: click  ─ 좌표 기반 마우스 클릭 (SendInput) + v1.2.0 hit-test 가드
# ============================================================================
function _Action-Click {
  if (-not (_Ensure-Win32Native)) { _Emit @{status="error"; reason="win32_load_failed"} 1 }
  if ($X -le 0 -or $Y -le 0) {
    _Emit @{status="error"; reason="invalid_coords"; recommended_action="provide positive -X and -Y"} 1
  }
  # 안전: 가상 데스크톱 범위 밖이면 차단
  $vx = [CucpNative]::GetSystemMetrics([CucpNative]::SM_XVIRTUALSCREEN)
  $vy = [CucpNative]::GetSystemMetrics([CucpNative]::SM_YVIRTUALSCREEN)
  $vw = [CucpNative]::GetSystemMetrics([CucpNative]::SM_CXVIRTUALSCREEN)
  $vh = [CucpNative]::GetSystemMetrics([CucpNative]::SM_CYVIRTUALSCREEN)
  if ($X -lt $vx -or $X -gt ($vx + $vw) -or $Y -lt $vy -or $Y -gt ($vy + $vh)) {
    _Emit @{
      status = "blocked"
      reason = "coords_out_of_virtual_desktop"
      x = $X; y = $Y
      virtual_desktop = @{ x=$vx; y=$vy; width=$vw; height=$vh }
    } 3
  }
  # v1.2.0: hit-test 가드 — TargetHwnd / TargetMatch 명시되면 좌표 검증
  if ($TargetHwnd -gt 0 -or $TargetMatch) {
    $hit = _Test-CoordsInTarget -X $X -Y $Y -ExpectedHwnd $TargetHwnd -ExpectedMatch $TargetMatch
    if (-not $hit.matched) {
      _Emit @{
        status = "blocked"
        reason = "hit_test_target_mismatch"
        x = $X; y = $Y
        actual_root_hwnd = $hit.actual_root_hwnd
        actual_title = $hit.actual_title
        target_hwnd = $TargetHwnd
        target_match = $TargetMatch
        mismatch_reason = $hit.reason
        recommended_action = "verify target window position; coords may have shifted (window moved/resized/full-screen toggle)"
      } 3
    }
  }
  $originalX = $X
  $originalY = $Y
  $refined = $null
  if ($ClickRefine -eq "uia-safe") {
    $refined = _Resolve-UiaPointRefinement -X $X -Y $Y -Inset $ClickInset
    if ($refined) {
      $X = [int]$refined.X
      $Y = [int]$refined.Y
      if ($TargetHwnd -gt 0 -or $TargetMatch) {
        $refinedHit = _Test-CoordsInTarget -X $X -Y $Y -ExpectedHwnd $TargetHwnd -ExpectedMatch $TargetMatch
        if (-not $refinedHit.matched) {
          $X = $originalX
          $Y = $originalY
          $refined = $null
        }
      }
    }
  }
  $isDouble = ($Button -eq "double")
  $btn = if ($isDouble) { "left" } else { $Button }
  [CucpNative]::SendMouseClick($X, $Y, $btn, $isDouble)
  # v1.7.0: 사후 좌표 검증 — SendInput absolute 가 OS scaling / DPI 에 의해 drift 가능
  $postX = $X
  $postY = $Y
  $postOk = $true
  $drift = 0
  try {
    $postX = [int][CucpNative]::PostClickX
    $postY = [int][CucpNative]::PostClickY
    $dx = $postX - $X
    $dy = $postY - $Y
    $drift = [int][Math]::Round([Math]::Sqrt($dx*$dx + $dy*$dy))
    # drift > 3px 면 정확도 경고 (DPI scaling / virtual desktop 경계)
    if ($drift -gt 3) { $postOk = $false }
  } catch { }
  $payload = [ordered]@{
    status = "ok"
    x = $X; y = $Y; button = $Button; double = $isDouble
    target_hwnd = $TargetHwnd
    target_match = $TargetMatch
    click_refine = $ClickRefine
    post_click = [ordered]@{
      requested_x = $X
      requested_y = $Y
      actual_x = $postX
      actual_y = $postY
      drift_px = $drift
      accurate = $postOk
    }
  }
  if ($refined) {
    $payload["original"] = [ordered]@{ x=$originalX; y=$originalY }
    $payload["refined_by"] = "uia-safe"
    $payload["refined_point_source"] = $refined.PointSource
    $payload["native_clickable_point"] = [bool]$refined.NativeClickable
    $payload["refine_score"] = [int]$refined.Score
    $payload["refine_depth"] = [int]$refined.Depth
    $payload["uia_match"] = $refined.Match
  }
  _Emit $payload
}

# ============================================================================
# Action: type  ─ 유니코드 텍스트 입력 (한글, 이모지 OK) + v1.2.0 focus 가드
# ============================================================================
function _Action-Type {
  if (-not (_Ensure-Win32Native)) { _Emit @{status="error"; reason="win32_load_failed"} 1 }
  if (-not $Text -and -not $ClearFirst -and -not $PressEnter) {
    _Emit @{status="error"; reason="missing_text"} 1
  }
  # v1.2.0: focus 가드 — TargetHwnd / TargetMatch 명시되면 현재 foreground 검증
  if ($TargetHwnd -gt 0 -or $TargetMatch) {
    $fgHwnd = [CucpNative]::GetForegroundWindow()
    $sb = New-Object System.Text.StringBuilder 256
    [void][CucpNative]::GetWindowText($fgHwnd, $sb, 256)
    $fgTitle = $sb.ToString()
    $matched = $false
    $reason = ""
    if ($TargetHwnd -gt 0) {
      $matched = ([int64]$fgHwnd -eq [int64]$TargetHwnd)
      if (-not $matched) { $reason = "hwnd_mismatch" }
    } elseif ($TargetMatch) {
      $needle = $TargetMatch.ToLowerInvariant()
      if ($fgTitle -and $fgTitle.ToLowerInvariant().Contains($needle)) { $matched = $true }
      else { $reason = "title_mismatch" }
    }
    if (-not $matched) {
      _Emit @{
        status = "blocked"
        reason = "focus_target_mismatch"
        actual_foreground_hwnd = [int64]$fgHwnd
        actual_foreground_title = $fgTitle
        target_hwnd = $TargetHwnd
        target_match = $TargetMatch
        mismatch_reason = $reason
        recommended_action = "Re-focus target window (use focus action) before typing"
      } 3
    }
  }
  if ($ClearFirst) {
    # Ctrl+A → Backspace
    [CucpNative]::SendVk([CucpNative]::VK_CONTROL, $false)
    Start-Sleep -Milliseconds 20
    $a = [CucpNative]::VkKeyScan([char]'a') -band 0xFF
    [CucpNative]::SendVk([uint16]$a, $false)
    [CucpNative]::SendVk([uint16]$a, $true)
    [CucpNative]::SendVk([CucpNative]::VK_CONTROL, $true)
    Start-Sleep -Milliseconds 30
    [CucpNative]::SendVk([CucpNative]::VK_BACK, $false)
    [CucpNative]::SendVk([CucpNative]::VK_BACK, $true)
    Start-Sleep -Milliseconds 30
  }
  if ($Text) { [CucpNative]::SendUnicodeText($Text) }
  if ($PressEnter) {
    Start-Sleep -Milliseconds 30
    [CucpNative]::SendVk([CucpNative]::VK_RETURN, $false)
    [CucpNative]::SendVk([CucpNative]::VK_RETURN, $true)
  }
  _Emit ([ordered]@{ status="ok"; text_length=($Text.Length); clear=[bool]$ClearFirst; enter=[bool]$PressEnter })
}

# ============================================================================
# Action: shortcut  ─ "ctrl+s", "alt+f4", "win+d" 같은 조합키
# ============================================================================
function _Action-Shortcut {
  if (-not (_Ensure-Win32Native)) { _Emit @{status="error"; reason="win32_load_failed"} 1 }
  if (-not $Keys) { _Emit @{status="error"; reason="missing_keys"} 1 }

  # 키 토큰 → vk 매핑. PowerShell이 직접 vk 변환을 도와줌.
  $tokens = ($Keys.ToLowerInvariant() -split '\+') | ForEach-Object { $_.Trim() }
  $vkList = @()
  foreach ($tok in $tokens) {
    $vk = switch ($tok) {
      "ctrl"   { [CucpNative]::VK_CONTROL }
      "shift"  { [CucpNative]::VK_SHIFT }
      "alt"    { [CucpNative]::VK_MENU }
      "win"    { [CucpNative]::VK_LWIN }
      "enter"  { [CucpNative]::VK_RETURN }
      "tab"    { [CucpNative]::VK_TAB }
      "esc"    { [CucpNative]::VK_ESCAPE }
      "escape" { [CucpNative]::VK_ESCAPE }
      "space"  { [CucpNative]::VK_SPACE }
      "backspace" { [CucpNative]::VK_BACK }
      "delete" { [CucpNative]::VK_DELETE }
      default {
        # F1~F24
        if ($tok -match '^f(\d{1,2})$') {
          [uint16](0x6F + [int]$matches[1])  # VK_F1=0x70, here we use 0x6F + n
        } elseif ($tok.Length -eq 1) {
          $code = [CucpNative]::VkKeyScan([char]$tok[0])
          [uint16]($code -band 0xFF)
        } else {
          $null
        }
      }
    }
    if ($null -eq $vk) { _Emit @{status="error"; reason="unknown_key"; token=$tok} 1 }
    $vkList += [uint16]$vk
  }

  # 누름 → 떼기 순서 (modifier가 먼저)
  foreach ($vk in $vkList) { [CucpNative]::SendVk($vk, $false); Start-Sleep -Milliseconds 8 }
  Start-Sleep -Milliseconds 30
  for ($i = $vkList.Count - 1; $i -ge 0; $i--) { [CucpNative]::SendVk($vkList[$i], $true); Start-Sleep -Milliseconds 8 }

  _Emit ([ordered]@{ status="ok"; keys=$Keys; tokens=$tokens })
}

# ============================================================================
# Action: uia-tree  ─ UIA 기반 affordance 목록 (BoundingRectangle 포함)
# ============================================================================
function _Action-UiaTree {
  if (-not (_Ensure-Win32Native)) { _Emit @{status="error"; reason="win32_load_failed"} 1 }
  if (-not (_Ensure-UIA)) {
    _Emit @{status="partial"; reason="uia_unavailable"; recommended_action="UIAutomationClient assembly load failed"} 2
  }

  # 대상 윈도우 결정
  $targetHwnd = [IntPtr]::Zero
  $list = [CucpNative]::EnumerateTopLevel()
  if ($Match) {
    $needle = $Match.ToLowerInvariant()
    $hit = $list | Where-Object { $_.Title -and $_.Title.ToLowerInvariant().Contains($needle) } | Select-Object -First 1
    if ($hit) { $targetHwnd = $hit.Hwnd }
  } else {
    $fg = $list | Where-Object { $_.Foreground } | Select-Object -First 1
    if ($fg) { $targetHwnd = $fg.Hwnd }
  }

  if ($targetHwnd -eq [IntPtr]::Zero) {
    _Emit @{status="partial"; reason="no_matching_window"; match=$Match} 2
  }

  $rootElement = [System.Windows.Automation.AutomationElement]::FromHandle($targetHwnd)
  if (-not $rootElement) {
    _Emit @{status="partial"; reason="uia_root_null"} 2
  }

  $items = New-Object System.Collections.ArrayList
  $count = 0
  $allElements = $rootElement.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  )
  foreach ($el in $allElements) {
    if ($count -ge $MaxElements) { break }
    try {
      $cur = $el.Current
      $r = $cur.BoundingRectangle
      if ($r.IsEmpty -or $r.Width -lt $MinSize -or $r.Height -lt $MinSize) { continue }
      $name = ""; try { $name = "$($cur.Name)" } catch { }
      $autoId = ""; try { $autoId = "$($cur.AutomationId)" } catch { }
      $help = ""; try { $help = "$($cur.HelpText)" } catch { }
      $accessKey = ""; try { $accessKey = "$($cur.AccessKey)" } catch { }
      $clazz = ""; try { $clazz = "$($cur.ClassName)" } catch { }
      $localizedRole = ""; try { $localizedRole = $cur.LocalizedControlType } catch { }
      $isOffscreen = $false; try { $isOffscreen = [bool]$cur.IsOffscreen } catch { }
      $isEnabled = $true; try { $isEnabled = [bool]$cur.IsEnabled } catch { }
      if ($isOffscreen) { continue }

      $text = if (-not [string]::IsNullOrWhiteSpace($name)) { $name }
              elseif (-not [string]::IsNullOrWhiteSpace($autoId)) { $autoId }
              elseif (-not [string]::IsNullOrWhiteSpace($help)) { $help }
              else { $null }
      if (-not $text) { continue }

      [void]$items.Add([ordered]@{
        text = $text
        name = $name
        automation_id = $autoId
        help_text = $help
        access_key = $accessKey
        class_name = $clazz
        role = $localizedRole
        enabled = $isEnabled
        rect = [ordered]@{ x=[int]$r.X; y=[int]$r.Y; width=[int]$r.Width; height=[int]$r.Height }
        center = [ordered]@{ x=[int]($r.X + $r.Width / 2); y=[int]($r.Y + $r.Height / 2) }
      })
      $count++
    } catch { continue }
  }

  _Emit ([ordered]@{
    status = "ok"
    target_hwnd = [int64]$targetHwnd
    affordance_count = $items.Count
    affordances = @($items)
  })
}

# ============================================================================
# Action: uia-find  ─ 라벨 기반 element 검색
# ============================================================================
function _Action-UiaFind {
  if (-not $Label) { _Emit @{status="error"; reason="missing_label"} 1 }
  # 직접 _Resolve-UiaElement 호출 (이전엔 uia-tree를 SetOut 리다이렉트로
  # 캡처했지만, 그 방식은 _Emit의 exit 호출 시 stdout이 사라지는 race가 있어
  # 빈 출력으로 떨어지는 문제가 있었습니다. 이제 동일한 in-process resolver를
  # 직접 호출해서 안정적으로 결과를 emit합니다.
  if (-not (_Ensure-Win32Native)) { _Emit @{status="error"; reason="win32_load_failed"} 1 }
  if (-not (_Ensure-UIA)) {
    _Emit @{status="partial"; reason="uia_unavailable"} 2
  }

  # 대상 윈도우 결정
  $list = [CucpNative]::EnumerateTopLevel()
  $targetHwnd = [IntPtr]::Zero
  if ($Match) {
    $needleW = $Match.ToLowerInvariant()
    $hit = $list | Where-Object { $_.Title -and $_.Title.ToLowerInvariant().Contains($needleW) } | Select-Object -First 1
    if ($hit) { $targetHwnd = $hit.Hwnd }
  } else {
    $fg = $list | Where-Object { $_.Foreground } | Select-Object -First 1
    if ($fg) { $targetHwnd = $fg.Hwnd }
  }
  if ($targetHwnd -eq [IntPtr]::Zero) {
    _Emit @{status="partial"; reason="no_matching_window"; match=$Match} 2
  }
  $rootEl = [System.Windows.Automation.AutomationElement]::FromHandle($targetHwnd)
  if (-not $rootEl) { _Emit @{status="partial"; reason="uia_root_null"} 2 }

  $needle = $Label.Trim().ToLowerInvariant()
  $needleNorm = ($needle -replace '\s+', ' ').Trim()
  $allElements = $rootEl.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  )

  $candidates = New-Object System.Collections.ArrayList
  $count = 0
  foreach ($el in $allElements) {
    if ($count -ge $MaxElements) { break }
    try {
      $cur = $el.Current
      $r = $cur.BoundingRectangle
      if ($r.IsEmpty -or $r.Width -lt $MinSize -or $r.Height -lt $MinSize) { continue }
      if ($cur.IsOffscreen) { continue }
      $name = ""; try { $name = "$($cur.Name)" } catch { }
      $autoId = ""; try { $autoId = "$($cur.AutomationId)" } catch { }
      $help = ""; try { $help = "$($cur.HelpText)" } catch { }
      $accessKey = ""; try { $accessKey = "$($cur.AccessKey)" } catch { }
      $localizedRole = ""; try { $localizedRole = $cur.LocalizedControlType } catch { }
      if ($Role -and $localizedRole -and ($localizedRole.ToLowerInvariant() -ne $Role.ToLowerInvariant())) { continue }

      $hays = @($name, $autoId, $help, $accessKey) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
              ForEach-Object { ($_.ToLowerInvariant() -replace '\s+', ' ').Trim() }
      if ($hays.Count -eq 0) { continue }
      $score = 0
      $reason = ""
      foreach ($hay in $hays) {
        $local = 0
        if ($hay -eq $needleNorm) { $local = 100 }
        elseif ($hay -match [regex]::Escape($needleNorm)) {
          $diff = [Math]::Abs($hay.Length - $needleNorm.Length)
          $local = 60 + [Math]::Max(0, 40 - $diff)
        } elseif ($needleNorm.Length -ge 2 -and $hay.IndexOf($needleNorm.Substring(0, [Math]::Min(2, $needleNorm.Length))) -ge 0) {
          $local = 15
        }
        if ($local -gt $score) {
          $score = $local
          $reason = if ($local -ge 100) { "exact" } elseif ($local -ge 60) { "substring" } else { "prefix" }
        }
      }
      if ($score -le 0) { continue }
      $pattern = $null
      try { $pattern = _Get-UiaSupportedPatternName -Element $el } catch { $pattern = $null }
      $valuePattern = $false
      $valueReadonly = $null
      try {
        $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if ($vp) {
          $valuePattern = $true
          $valueReadonly = [bool]$vp.Current.IsReadOnly
        }
      } catch { }
      $point = $null
      try { $point = _Get-UiaPreferredClickPoint -Element $el -Rect $r -Inset $ClickInset } catch { $point = $null }
      [void]$candidates.Add([ordered]@{
        text = if ($name) { $name } elseif ($autoId) { $autoId } else { $help }
        role = $localizedRole
        rect = [ordered]@{ x=[int]$r.X; y=[int]$r.Y; width=[int]$r.Width; height=[int]$r.Height }
        center = [ordered]@{ x=[int]($r.X + $r.Width / 2); y=[int]($r.Y + $r.Height / 2) }
        click_point = if ($point) { [ordered]@{ x=[int]$point.X; y=[int]$point.Y; source=$point.Source; native_clickable=[bool]$point.NativeClickable } } else { $null }
        score = $score
        match_reason = $reason
        automation_id = $autoId
        invoke_pattern = $pattern
        value_pattern = $valuePattern
        value_readonly = $valueReadonly
      })
      $count++
    } catch { continue }
  }
  $ranked = @($candidates | Sort-Object -Property { $_.score } -Descending)
  if ($ranked.Count -eq 0) { _Emit @{status="partial"; reason="no_match"; label=$Label} 2 }
  $top = $ranked[0]
  $second = if ($ranked.Count -gt 1) { $ranked[1] } else { $null }
  $ambiguous = ($second -and (($top.score - $second.score) -lt 8))
  $statusStr = "ok"; $exitCode = 0
  if ($ambiguous) { $statusStr = "partial"; $exitCode = 2 }
  _Emit ([ordered]@{
    status = $statusStr
    label = $Label
    top = $top
    candidates = ($ranked | Select-Object -First 5)
    ambiguous = $ambiguous
  }) $exitCode
}

# ============================================================================
# Action: uia-click  ─ uia-find로 좌표 결정 후 click 실행
# ============================================================================
function _Action-UiaClick {
  if (-not $Label) { _Emit @{status="error"; reason="missing_label"} 1 }
  if (-not (_Ensure-Win32Native)) { _Emit @{status="error"; reason="win32_load_failed"} 1 }
  $resolved = _Resolve-UiaElement -Match $Match -Label $Label -Role $Role -MaxElements $MaxElements -MinSize $MinSize
  if (-not $resolved) { _Emit @{status="partial"; reason="no_match"; label=$Label} 2 }
  $cur = $resolved.Element.Current
  $r = $cur.BoundingRectangle
  $cx = [int]($r.X + $r.Width / 2)
  $cy = [int]($r.Y + $r.Height / 2)
  $isDouble = ($Button -eq "double")
  $btn = if ($isDouble) { "left" } else { $Button }
  [CucpNative]::SendMouseClick($cx, $cy, $btn, $isDouble)
  _Emit ([ordered]@{
    status = "ok"
    label = $Label
    x = $cx; y = $cy
    button = $Button
    matched_text = $cur.Name
    rect = [ordered]@{ x=[int]$r.X; y=[int]$r.Y; width=[int]$r.Width; height=[int]$r.Height }
    score = $resolved.Score
    match_reason = $resolved.Reason
  })
}

# ============================================================================
# UIA Pattern 직접 호출 헬퍼 — _ResolveElement (uia-find의 in-process 버전)
# ============================================================================
# uia-invoke / uia-set-value / uia-toggle은 element를 찾아 BoundingRectangle이
# 아니라 InvokePattern.Invoke() 같은 UIA 명령을 직접 호출합니다.
# 마우스가 움직이지 않고, 화면이 가려져 있어도 동작합니다.
#
# 반환:
#   [pscustomobject] @{ Element, Cur, Found, Reason, Score }
function _Resolve-UiaElement {
  param([string]$Match, [string]$Label, [string]$Role, [int]$MaxElements = 400, [int]$MinSize = 6)
  if (-not (_Ensure-Win32Native)) { return $null }
  if (-not (_Ensure-UIA)) { return $null }

  $list = [CucpNative]::EnumerateTopLevel()
  $targetHwnd = [IntPtr]::Zero
  if ($Match) {
    $needle = $Match.ToLowerInvariant()
    $hit = $list | Where-Object { $_.Title -and $_.Title.ToLowerInvariant().Contains($needle) } | Select-Object -First 1
    if ($hit) { $targetHwnd = $hit.Hwnd }
  } else {
    $fg = $list | Where-Object { $_.Foreground } | Select-Object -First 1
    if ($fg) { $targetHwnd = $fg.Hwnd }
  }
  if ($targetHwnd -eq [IntPtr]::Zero) { return $null }

  $rootEl = [System.Windows.Automation.AutomationElement]::FromHandle($targetHwnd)
  if (-not $rootEl) { return $null }

  $needleLabel = $Label.Trim().ToLowerInvariant()
  $needleNorm = ($needleLabel -replace '\s+', ' ').Trim()

  $candidates = $rootEl.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  )

  $bestEl = $null
  $bestScore = 0
  $bestReason = ""
  $count = 0
  foreach ($el in $candidates) {
    if ($count -ge $MaxElements) { break }
    try {
      $cur = $el.Current
      $r = $cur.BoundingRectangle
      if ($r.IsEmpty -or $r.Width -lt $MinSize -or $r.Height -lt $MinSize) { continue }
      if ($cur.IsOffscreen) { continue }

      $name = ""; try { $name = "$($cur.Name)" } catch { }
      $autoId = ""; try { $autoId = "$($cur.AutomationId)" } catch { }
      $help = ""; try { $help = "$($cur.HelpText)" } catch { }
      $accessKey = ""; try { $accessKey = "$($cur.AccessKey)" } catch { }
      $localizedRole = ""; try { $localizedRole = $cur.LocalizedControlType } catch { }

      if ($Role -and $localizedRole -and ($localizedRole.ToLowerInvariant() -ne $Role.ToLowerInvariant())) { continue }

      $hays = @($name, $autoId, $help, $accessKey) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
      if ($hays.Count -eq 0) { continue }

      $score = 0
      $reason = ""
      foreach ($h in $hays) {
        $hl = ($h.ToLowerInvariant() -replace '\s+', ' ').Trim()
        $local = 0
        if ($hl -eq $needleNorm) { $local = 100 }
        elseif ($hl -match [regex]::Escape($needleNorm)) {
          $diff = [Math]::Abs($hl.Length - $needleNorm.Length)
          $local = 60 + [Math]::Max(0, 40 - $diff)
        } elseif ($needleNorm.Length -ge 2 -and $hl.IndexOf($needleNorm.Substring(0, [Math]::Min(2, $needleNorm.Length))) -ge 0) {
          $local = 15
        }
        if ($local -gt $score) {
          $score = $local
          $reason = if ($local -ge 100) { "exact" } elseif ($local -ge 60) { "substring" } else { "prefix" }
        }
      }
      if ($score -gt $bestScore) {
        $bestEl = $el
        $bestScore = $score
        $bestReason = $reason
      }
      $count++
    } catch { continue }
  }

  if (-not $bestEl) { return $null }
  return [pscustomobject]@{
    Element = $bestEl
    Score = $bestScore
    Reason = $bestReason
  }
}

# ============================================================================
# Action: uia-invoke ─ InvokePattern 직접 호출 (마우스 안 움직임)
# ============================================================================
# 가장 안정적인 클릭 방법. 다음 컨트롤에서 사용 가능:
#   - Button (대부분 단추)
#   - MenuItem (메뉴 항목)
#   - Hyperlink (하이퍼링크)
#   - 일부 ListItem
# Toggle 가능한 체크박스/라디오버튼은 uia-toggle을 사용해야 함.
# Edit 컨트롤에 값 넣을 때는 uia-set-value 사용.
#
# 안전 정책:
#   - score < 60 (substring 미만) 면 fallback도 거부 — 잘못된 element 클릭 방지.
#   - 좌표 fallback은 명시 옵션이 있을 때만. 기본은 Pattern만 시도.
# ============================================================================
function _Action-UiaInvoke {
  if (-not $Label) { _Emit @{status="error"; reason="missing_label"} 1 }
  $resolved = _Resolve-UiaElement -Match $Match -Label $Label -Role $Role -MaxElements $MaxElements -MinSize $MinSize
  if (-not $resolved) {
    _Emit @{status="partial"; reason="no_match"; label=$Label} 2
  }
  # 안전 가드: 매칭 신뢰도가 낮으면 클릭 자체를 거부
  if ($resolved.Score -lt 60) {
    _Emit ([ordered]@{
      status = "partial"
      reason = "low_confidence_match"
      label = $Label
      score = $resolved.Score
      match_reason = $resolved.Reason
      matched_text = $resolved.Element.Current.Name
      recommended_action = "라벨 정확도 낮음(score<60). 다른 라벨/role/match로 시도하거나 macro find-label --explain 으로 후보 확인."
    }) 2
  }
  $el = $resolved.Element
  $cur = $el.Current
  # 1) InvokePattern 시도 (가장 일반적)
  try {
    $pat = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    if ($pat) {
      $pat.Invoke()
      $r = $cur.BoundingRectangle
      _Emit ([ordered]@{
        status = "ok"
        method = "InvokePattern"
        label = $Label
        matched_text = $cur.Name
        automation_id = $cur.AutomationId
        rect = [ordered]@{ x=[int]$r.X; y=[int]$r.Y; width=[int]$r.Width; height=[int]$r.Height }
        score = $resolved.Score
        match_reason = $resolved.Reason
        mouse_moved = $false
      })
    }
  } catch { }

  # 2) Fallback: SelectionItemPattern (탭/리스트 항목)
  try {
    $sel = $el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    if ($sel) {
      $sel.Select()
      _Emit ([ordered]@{
        status = "ok"
        method = "SelectionItemPattern"
        label = $Label
        matched_text = $cur.Name
        score = $resolved.Score
        mouse_moved = $false
      })
    }
  } catch { }

  # 3) Fallback: ExpandCollapsePattern (서브메뉴 등)
  try {
    $exp = $el.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    if ($exp) {
      $exp.Expand()
      _Emit ([ordered]@{
        status = "ok"
        method = "ExpandCollapsePattern"
        label = $Label
        matched_text = $cur.Name
        score = $resolved.Score
        mouse_moved = $false
      })
    }
  } catch { }

  # 4) UIA pattern 없음 — partial 반환 (마우스 fallback은 명시 호출자가 click-point 사용)
  $r = $cur.BoundingRectangle
  _Emit ([ordered]@{
    status = "partial"
    reason = "no_invoke_pattern"
    label = $Label
    matched_text = $cur.Name
    rect = [ordered]@{ x=[int]$r.X; y=[int]$r.Y; width=[int]$r.Width; height=[int]$r.Height }
    score = $resolved.Score
    recommended_action = "UIA pattern 미지원 element. 좌표 클릭이 필요하면 macro click-point --x N --y N 호출."
  }) 2
}

# ============================================================================
# Action: uia-set-value ─ ValuePattern.SetValue 직접 호출
# ============================================================================
# Edit/ComboBox에 값을 넣을 때 키보드 입력 시뮬레이션 없이 즉시 설정.
# 한글/이모지/긴 텍스트도 한 번에 들어가고 IME 안 거침.
# ============================================================================
function _Action-UiaSetValue {
  if (-not $Label) { _Emit @{status="error"; reason="missing_label"} 1 }
  if ($null -eq $Value) { _Emit @{status="error"; reason="missing_value"} 1 }
  $resolved = _Resolve-UiaElement -Match $Match -Label $Label -Role $Role -MaxElements $MaxElements -MinSize $MinSize
  if (-not $resolved) {
    _Emit @{status="partial"; reason="no_match"; label=$Label} 2
  }
  $el = $resolved.Element
  $cur = $el.Current
  try {
    $pat = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if ($pat) {
      if ($pat.Current.IsReadOnly) {
        _Emit @{status="partial"; reason="value_readonly"; label=$Label} 2
      }
      $pat.SetValue($Value)
      _Emit ([ordered]@{
        status = "ok"
        method = "ValuePattern.SetValue"
        label = $Label
        matched_text = $cur.Name
        value_length = $Value.Length
        keyboard_used = $false
      })
    }
  } catch { }
  _Emit @{status="partial"; reason="no_value_pattern"; label=$Label; recommended_action="Try macro type-native after focusing the field"} 2
}

# ============================================================================
# Action: uia-toggle ─ TogglePattern.Toggle (체크박스/라디오버튼)
# ============================================================================
function _Action-UiaToggle {
  if (-not $Label) { _Emit @{status="error"; reason="missing_label"} 1 }
  $resolved = _Resolve-UiaElement -Match $Match -Label $Label -Role $Role -MaxElements $MaxElements -MinSize $MinSize
  if (-not $resolved) { _Emit @{status="partial"; reason="no_match"; label=$Label} 2 }
  $el = $resolved.Element
  $cur = $el.Current
  try {
    $pat = $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($pat) {
      $beforeState = "$($pat.Current.ToggleState)"
      $pat.Toggle()
      _Emit ([ordered]@{
        status = "ok"
        method = "TogglePattern"
        label = $Label
        matched_text = $cur.Name
        previous_state = $beforeState
        mouse_moved = $false
      })
    }
  } catch { }
  _Emit @{status="partial"; reason="no_toggle_pattern"; label=$Label} 2
}

# ============================================================================
# Action: ocr-image  ─ 임의 PNG 파일을 OCR (브라우저 캔버스 캡처 / 외부 이미지)
# ============================================================================
# 입력: -OcrPath <png>
# 출력: 인식된 라인/단어 + BoundingRectangle. 좌표는 이미지 픽셀 기준.
# 주의: ocr-image는 절대 화면 좌표가 아닌 이미지 내부 좌표를 반환합니다.
# 화면 클릭 좌표가 필요하면 ocr-screen 또는 ocr-find-text를 쓰세요.
# ============================================================================
function _Action-OcrImage {
  if (-not $OcrPath) {
    _Emit @{status="error"; reason="missing_ocr_path"; recommended_action="provide -OcrPath <png file>"} 1
  }
  if (-not (Test-Path -LiteralPath $OcrPath)) {
    _Emit @{status="error"; reason="ocr_path_not_found"; ocr_path=$OcrPath} 1
  }
  if (-not (_Ensure-OCR)) {
    _Emit @{status="error"; reason="ocr_unavailable"; ocr_error=$Script:_OCRError; recommended_action="install_windows_ocr_language_pack"} 1
  }
  try {
    $sb = _Load-SoftwareBitmapFromFile -Path $OcrPath
    $ocrResult = _Wait-AsyncOp ($Script:_OCREngine.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
    $payload = _Convert-OcrResult -OcrResult $ocrResult
    $payload["status"] = "ok"
    $payload["engine_language"] = $Script:_OCREngine.RecognizerLanguage.LanguageTag
    $payload["source"] = "image"
    $payload["ocr_path"] = $OcrPath
    _Emit $payload
  } catch {
    _Emit @{status="error"; reason="ocr_failed"; detail=$_.Exception.Message; ocr_path=$OcrPath} 1
  }
}

# ============================================================================
# Action: ocr-screen  ─ 화면 캡처 + OCR (UIA가 못 보는 표면용)
# ============================================================================
# 입력: -ScreenshotX/Y/W/H (생략 시 가상 데스크톱 전체)
# 출력: 인식된 라인/단어 + BoundingRectangle. 좌표는 절대 화면 좌표.
# ocr-screen은 임시 PNG를 만든 뒤 OCR하고 PNG는 자동 삭제합니다.
# ============================================================================
function _Action-OcrScreen {
  if (-not (_Ensure-Win32Native)) { _Emit @{status="error"; reason="win32_load_failed"} 1 }
  if (-not (_Ensure-OCR)) {
    _Emit @{status="error"; reason="ocr_unavailable"; ocr_error=$Script:_OCRError; recommended_action="install_windows_ocr_language_pack"} 1
  }
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop

  # 영역 결정 (screenshot action과 동일 규칙)
  $vx = [CucpNative]::GetSystemMetrics([CucpNative]::SM_XVIRTUALSCREEN)
  $vy = [CucpNative]::GetSystemMetrics([CucpNative]::SM_YVIRTUALSCREEN)
  $vw = [CucpNative]::GetSystemMetrics([CucpNative]::SM_CXVIRTUALSCREEN)
  $vh = [CucpNative]::GetSystemMetrics([CucpNative]::SM_CYVIRTUALSCREEN)
  $sx = if ($ScreenshotX -ge 0) { $ScreenshotX } else { $vx }
  $sy = if ($ScreenshotY -ge 0) { $ScreenshotY } else { $vy }
  $sw = if ($ScreenshotW -gt 0) { $ScreenshotW } else { $vw }
  $sh = if ($ScreenshotH -gt 0) { $ScreenshotH } else { $vh }

  # OcrEngine MaxImageDimension 한도 검사 (보통 10000)
  $maxDim = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
  if ($sw -gt $maxDim -or $sh -gt $maxDim) {
    _Emit @{
      status="error"
      reason="region_exceeds_max_image_dimension"
      max_dim=$maxDim
      width=$sw; height=$sh
      recommended_action="provide_smaller_region_via_ScreenshotW_ScreenshotH"
    } 1
  }

  $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "cucp-ocr-screen-$([System.Guid]::NewGuid().ToString('N')).png")
  try {
    $bmp = New-Object System.Drawing.Bitmap $sw, $sh
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
      $g.CopyFromScreen($sx, $sy, 0, 0, (New-Object System.Drawing.Size $sw, $sh))
    } finally { $g.Dispose() }
    $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()

    $sb = _Load-SoftwareBitmapFromFile -Path $tmp
    $ocrResult = _Wait-AsyncOp ($Script:_OCREngine.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
    # 화면 절대 좌표로 환산
    $payload = _Convert-OcrResult -OcrResult $ocrResult -OffsetX $sx -OffsetY $sy
    $payload["status"] = "ok"
    $payload["engine_language"] = $Script:_OCREngine.RecognizerLanguage.LanguageTag
    $payload["source"] = "screen"
    $payload["region"] = [ordered]@{ x=$sx; y=$sy; width=$sw; height=$sh }
    _Emit $payload
  } catch {
    _Emit @{status="error"; reason="ocr_screen_failed"; detail=$_.Exception.Message} 1
  } finally {
    if (Test-Path -LiteralPath $tmp) {
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
  }
}

# ============================================================================
# Action: ocr-find-text  ─ 화면/이미지에서 특정 텍스트 위치 찾기
# ============================================================================
# 입력: -OcrText "검색어" [-OcrMatch contains|exact|prefix] [-OcrPath png]
#       [-ScreenshotX/Y/W/H] [-OcrMaxCandidates N]
# 출력: 매칭된 후보들 (점수 내림차순), 각 후보는 line + word 단위
# UIA가 안 잡는 브라우저 캔버스/이미지 표면에서 클릭 좌표를 결정할 때 사용.
# ============================================================================
function _Action-OcrFindText {
  if (-not $OcrText) {
    _Emit @{status="error"; reason="missing_ocr_text"; recommended_action="provide -OcrText <search string>"} 1
  }
  # 입력 소스: -OcrPath 우선, 없으면 화면 캡처
  if ($OcrPath) {
    if (-not (Test-Path -LiteralPath $OcrPath)) {
      _Emit @{status="error"; reason="ocr_path_not_found"; ocr_path=$OcrPath} 1
    }
    if (-not (_Ensure-OCR)) {
      _Emit @{status="error"; reason="ocr_unavailable"; ocr_error=$Script:_OCRError} 1
    }
    try {
      $sb = _Load-SoftwareBitmapFromFile -Path $OcrPath
      $ocrResult = _Wait-AsyncOp ($Script:_OCREngine.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
      $body = _Convert-OcrResult -OcrResult $ocrResult
      $sourceMeta = [ordered]@{ source="image"; ocr_path=$OcrPath }
    } catch {
      _Emit @{status="error"; reason="ocr_failed"; detail=$_.Exception.Message} 1
    }
  } else {
    # 화면 캡처 + OCR 경로 — ocr-screen과 동일 로직 재사용
    if (-not (_Ensure-Win32Native)) { _Emit @{status="error"; reason="win32_load_failed"} 1 }
    if (-not (_Ensure-OCR)) {
      _Emit @{status="error"; reason="ocr_unavailable"; ocr_error=$Script:_OCRError} 1
    }
    $capX = $ScreenshotX; $capY = $ScreenshotY; $capW = $ScreenshotW; $capH = $ScreenshotH
    if ($Match -and $ScreenshotX -lt 0 -and $ScreenshotY -lt 0 -and $ScreenshotW -le 0 -and $ScreenshotH -le 0) {
      $needle = $Match.ToLowerInvariant()
      $targetWin = [CucpNative]::EnumerateTopLevel() |
        Where-Object { $_.Title -and $_.Title.ToLowerInvariant().Contains($needle) } |
        Select-Object -First 1
      if ($targetWin) {
        $capX = [int]$targetWin.X
        $capY = [int]$targetWin.Y
        $capW = [int]$targetWin.Width
        $capH = [int]$targetWin.Height
      }
    }
    $cap = _Capture-ScreenRegionToTempPng -RegionX $capX -RegionY $capY `
                                          -RegionW $capW -RegionH $capH `
                                          -Prefix "cucp-ocr-find"
    if ($cap.Error) {
      $exitCode = 1
      $statusText = "error"
      if ($cap.Error -eq "screenshot_unavailable") {
        $exitCode = 2
        $statusText = "partial"
      }
      _Emit @{
        status=$statusText
        reason=$cap.Error
        detail=$cap.Detail
        max_dim=$cap.MaxDim
        recommended_action="Retry from an interactive unlocked desktop session, provide -OcrPath, or use a smaller visible region."
      } $exitCode
    }
    $sx = $cap.X; $sy = $cap.Y; $sw = $cap.W; $sh = $cap.H
    $tmp = $cap.Path
    try {
      $sb = _Load-SoftwareBitmapFromFile -Path $tmp
      $ocrResult = _Wait-AsyncOp ($Script:_OCREngine.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
      $body = _Convert-OcrResult -OcrResult $ocrResult -OffsetX $sx -OffsetY $sy
      $sourceMeta = [ordered]@{
        source="screen"
        region = [ordered]@{ x=$sx; y=$sy; width=$sw; height=$sh }
      }
    } catch {
      _Emit @{status="error"; reason="ocr_screen_failed"; detail=$_.Exception.Message} 1
    } finally {
      if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
  }

  $sorted = @(_Match-OcrCandidates -Body $body -Needle $OcrText -Mode $OcrMatch | Select-Object -First $OcrMaxCandidates)

  if (-not $sorted -or @($sorted).Count -eq 0) {
    $payload = [ordered]@{
      status = "partial"
      reason = "no_text_match"
      ocr_text = $OcrText
      ocr_match = $OcrMatch
      engine_language = $Script:_OCREngine.RecognizerLanguage.LanguageTag
      total_lines = $body.line_count
      total_words = $body.word_count
    }
    foreach ($k in $sourceMeta.Keys) { $payload[$k] = $sourceMeta[$k] }
    _Emit $payload 2
  }

  $payload = [ordered]@{
    status = "ok"
    ocr_text = $OcrText
    ocr_match = $OcrMatch
    engine_language = $Script:_OCREngine.RecognizerLanguage.LanguageTag
    candidate_count = @($sorted).Count
    candidates = @($sorted)
    top = $sorted[0]
  }
  foreach ($k in $sourceMeta.Keys) { $payload[$k] = $sourceMeta[$k] }
  _Emit $payload
}

# ============================================================================
# Action: ocr-uia-fuse  ─ OCR 좌표 위에 UIA element 가 있으면 invoke 가능 보고
# ============================================================================
# 사용 사례:
#   OCR 이 "Send" 텍스트 좌표를 잡았는데 그 위에 UIA Button element 가 있으면
#   좌표 클릭 대신 InvokePattern.Invoke() 로 호출 가능 → 마우스 안 움직임.
#
# Electron / 일부 WPF 같이 "UIA에는 element 가 있지만 Name 이 비어있어서
# uia-find 로는 못 찾는" 표면을 OCR 텍스트로 식별 + UIA 좌표 매칭으로 invoke.
#
# 입력: -OcrText "<찾을 텍스트>" [-OcrMatch contains|exact|prefix]
#       [-Match <window 부분 매칭>] [-Region x,y,w,h via -ScreenshotX/Y/W/H]
#       [-OcrLanguage ko]
# 출력: { ocr_top, uia_match, can_invoke, invoke_pattern, recommendation }
#   - ocr_top: OCR 1순위 후보 (text + cx/cy + score + rect)
#   - uia_match: OCR rect 중심점이 들어있는 UIA element (없을 수 있음)
#   - can_invoke: UIA element 가 Invoke/Toggle/SelectionItem 패턴 지원하면 true
#   - invoke_pattern: "InvokePattern" / "TogglePattern" / "SelectionItemPattern"
#   - recommendation: "uia_invoke" / "ocr_click" / "low_confidence_skip"
#
# read-only — 실제 클릭/호출은 안 함. wrapper 의 smart-click 이 해석.
# ============================================================================
function _Action-OcrUiaFuse {
  if (-not $OcrText) {
    _Emit @{status="error"; reason="missing_ocr_text"} 1
  }
  if (-not (_Ensure-Win32Native)) { _Emit @{status="error"; reason="win32_load_failed"} 1 }
  if (-not (_Ensure-UIA)) {
    _Emit @{status="error"; reason="uia_unavailable"} 1
  }
  if (-not (_Ensure-OCR)) {
    _Emit @{status="error"; reason="ocr_unavailable"; ocr_error=$Script:_OCRError} 1
  }

  $list = [CucpNative]::EnumerateTopLevel()
  $targetHwnd = [IntPtr]::Zero
  $targetWin = $null
  if ($Match) {
    $needle = $Match.ToLowerInvariant()
    $targetWin = $list | Where-Object { $_.Title -and $_.Title.ToLowerInvariant().Contains($needle) } | Select-Object -First 1
  }
  if (-not $targetWin) {
    $targetWin = $list | Where-Object { $_.Foreground } | Select-Object -First 1
  }
  if ($targetWin) { $targetHwnd = $targetWin.Hwnd }
  if ($targetHwnd -eq [IntPtr]::Zero) {
    _Emit @{status="partial"; reason="no_target_window"} 2
  }

  $capX = $ScreenshotX; $capY = $ScreenshotY; $capW = $ScreenshotW; $capH = $ScreenshotH
  if ($targetWin -and $ScreenshotX -lt 0 -and $ScreenshotY -lt 0 -and $ScreenshotW -le 0 -and $ScreenshotH -le 0) {
    $capX = [int]$targetWin.X
    $capY = [int]$targetWin.Y
    $capW = [int]$targetWin.Width
    $capH = [int]$targetWin.Height
  }

  # 1) 화면 캡처 + OCR (v1.0.0 헬퍼로 추출)
  $cap = _Capture-ScreenRegionToTempPng -RegionX $capX -RegionY $capY `
                                          -RegionW $capW -RegionH $capH `
                                          -Prefix "cucp-fuse"
  if ($cap.Error) {
    $exitCode = 1
    $statusText = "error"
    if ($cap.Error -eq "screenshot_unavailable") {
      $exitCode = 2
      $statusText = "partial"
    }
    _Emit @{
      status=$statusText
      reason=$cap.Error
      detail=$cap.Detail
      max_dim=$cap.MaxDim
      recommended_action="Retry from an interactive unlocked desktop session, provide a matching foreground window, or use a smaller visible region."
    } $exitCode
  }
  $sx = $cap.X; $sy = $cap.Y; $sw = $cap.W; $sh = $cap.H
  $tmp = $cap.Path
  $ocrTop = $null
  $ocrCandidates = @()
  try {
    $sb = _Load-SoftwareBitmapFromFile -Path $tmp
    $ocrResult = _Wait-AsyncOp ($Script:_OCREngine.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
    $body = _Convert-OcrResult -OcrResult $ocrResult -OffsetX $sx -OffsetY $sy
    $ocrCandidates = @(_Match-OcrCandidates -Body $body -Needle $OcrText -Mode $OcrMatch | Select-Object -First $OcrMaxCandidates)
    if ($ocrCandidates.Count -gt 0) { $ocrTop = $ocrCandidates[0] }
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }

  if (-not $ocrTop) {
    _Emit @{
      status="partial"
      reason="no_ocr_match"
      ocr_text=$OcrText
      ocr_match=$OcrMatch
      recommendation="low_confidence_skip"
    } 2
  }

  $uiaMatch = $null
  $canInvoke = $false
  $invokePattern = $null
  $fusion = $null
  if ($targetHwnd -ne [IntPtr]::Zero) {
    try {
      $rootEl = [System.Windows.Automation.AutomationElement]::FromHandle($targetHwnd)
      if ($rootEl) {
        $allEls = $rootEl.FindAll(
          [System.Windows.Automation.TreeScope]::Descendants,
          [System.Windows.Automation.Condition]::TrueCondition
        )
        $fusion = _Resolve-OcrUiaFusionCandidate -RootEl $rootEl -Elements $allEls -OcrCandidates $ocrCandidates -Limit $OcrMaxCandidates
        if ($fusion) {
          $ocrTop = $fusion.Ocr
          $uiaMatch = $fusion.UiaMatch
          $canInvoke = [bool]$fusion.CanInvoke
          $invokePattern = $fusion.PatternName
        }
      }
    } catch { }
  }

  # 3) 추천 결정
  $recommendation = "ocr_click"  # default — UIA element 못 찾음
  if ([int]$ocrTop.score -lt 70) { $recommendation = "low_confidence_skip" }
  elseif ($canInvoke) { $recommendation = "uia_invoke" }

  _Emit ([ordered]@{
    status = "ok"
    ocr_text = $OcrText
    ocr_match = $OcrMatch
    target_hwnd = [int64]$targetHwnd
    ocr_top = $ocrTop
    uia_match = $uiaMatch
    can_invoke = $canInvoke
    invoke_pattern = $invokePattern
    recommendation = $recommendation
    candidate_count = @($ocrCandidates).Count
    candidates = @($ocrCandidates)
    region = [ordered]@{ x=$sx; y=$sy; width=$sw; height=$sh }
  })
}

# ============================================================================
# Action: ocr-uia-invoke  ─ fusion 탐색 + 곧바로 InvokePattern 호출 (v1.0.0)
# ============================================================================
# ocr-uia-fuse 와 같은 로직으로 OCR 좌표 위 UIA element 를 찾되,
# **그 자리에서 element handle 로 InvokePattern.Invoke() 직접 호출**한다.
#
# fusion (read-only) → wrapper 가 element name 으로 다시 uia-invoke 하는 패턴은
# Name 비어있는 element 에 대해 못 동작했음. 이제 한 프로세스 안에서 element
# AutomationElement 인스턴스를 그대로 invoke 하므로 Name 없어도 동작.
#
# 입력: -OcrText "<찾을 텍스트>" [-OcrMatch contains|exact|prefix]
#       [-Match <window 부분 매칭>] [-OcrLanguage ko]
# 출력: { status, method (InvokePattern/TogglePattern/SelectionItemPattern),
#         matched_ocr_text, uia_name, uia_automation_id, uia_class_name,
#         mouse_moved=false }
# 안전:
#   - OCR score < 70 → low_confidence_match → partial(2) 거부
#   - 어떤 pattern 도 지원 안 하면 partial(2)
# ============================================================================
function _Action-OcrUiaInvoke {
  if (-not $OcrText) { _Emit @{status="error"; reason="missing_ocr_text"} 1 }
  if (-not (_Ensure-Win32Native)) { _Emit @{status="error"; reason="win32_load_failed"} 1 }
  if (-not (_Ensure-UIA)) { _Emit @{status="error"; reason="uia_unavailable"} 1 }
  if (-not (_Ensure-OCR)) {
    _Emit @{status="error"; reason="ocr_unavailable"; ocr_error=$Script:_OCRError} 1
  }

  $list = [CucpNative]::EnumerateTopLevel()
  $targetHwnd = [IntPtr]::Zero
  $targetWin = $null
  if ($Match) {
    $needle = $Match.ToLowerInvariant()
    $targetWin = $list | Where-Object { $_.Title -and $_.Title.ToLowerInvariant().Contains($needle) } | Select-Object -First 1
  }
  if (-not $targetWin) {
    $targetWin = $list | Where-Object { $_.Foreground } | Select-Object -First 1
  }
  if ($targetWin) { $targetHwnd = $targetWin.Hwnd }
  if ($targetHwnd -eq [IntPtr]::Zero) {
    _Emit @{status="partial"; reason="no_target_window"} 2
  }

  $capX = $ScreenshotX; $capY = $ScreenshotY; $capW = $ScreenshotW; $capH = $ScreenshotH
  if ($targetWin -and $ScreenshotX -lt 0 -and $ScreenshotY -lt 0 -and $ScreenshotW -le 0 -and $ScreenshotH -le 0) {
    $capX = [int]$targetWin.X
    $capY = [int]$targetWin.Y
    $capW = [int]$targetWin.Width
    $capH = [int]$targetWin.Height
  }

  # 1) 화면 캡처 + OCR (v1.0.0 헬퍼로 추출)
  $cap = _Capture-ScreenRegionToTempPng -RegionX $capX -RegionY $capY `
                                          -RegionW $capW -RegionH $capH `
                                          -Prefix "cucp-ouinv"
  if ($cap.Error) {
    $exitCode = 1
    $statusText = "error"
    if ($cap.Error -eq "screenshot_unavailable") {
      $exitCode = 2
      $statusText = "partial"
    }
    _Emit @{
      status=$statusText
      reason=$cap.Error
      detail=$cap.Detail
      max_dim=$cap.MaxDim
      recommended_action="Retry from an interactive unlocked desktop session, provide a matching foreground window, or use a smaller visible region."
    } $exitCode
  }
  $sx = $cap.X; $sy = $cap.Y; $sw = $cap.W; $sh = $cap.H
  $tmp = $cap.Path
  $ocrTop = $null
  $ocrCandidates = @()
  try {
    $sb = _Load-SoftwareBitmapFromFile -Path $tmp
    $ocrResult = _Wait-AsyncOp ($Script:_OCREngine.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
    $body = _Convert-OcrResult -OcrResult $ocrResult -OffsetX $sx -OffsetY $sy
    $ocrCandidates = @(_Match-OcrCandidates -Body $body -Needle $OcrText -Mode $OcrMatch | Select-Object -First $OcrMaxCandidates)
    if ($ocrCandidates.Count -gt 0) { $ocrTop = $ocrCandidates[0] }
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }

  if (-not $ocrTop) { _Emit @{status="partial"; reason="no_ocr_match"; ocr_text=$OcrText} 2 }
  if ([int]$ocrTop.score -lt 70) {
    _Emit @{
      status = "partial"
      reason = "low_confidence_match"
      score = [int]$ocrTop.score
      matched_ocr_text = $ocrTop.text
      threshold = 70
    } 2
  }

  $rootEl = [System.Windows.Automation.AutomationElement]::FromHandle($targetHwnd)
  if (-not $rootEl) { _Emit @{status="partial"; reason="uia_root_null"} 2 }

  $allEls = $rootEl.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  )
  $fusion = _Resolve-OcrUiaFusionCandidate -RootEl $rootEl -Elements $allEls -OcrCandidates $ocrCandidates -Limit $OcrMaxCandidates
  if (-not $fusion) {
    _Emit @{status="partial"; reason="no_uia_element_at_ocr_coord"; ocr_top=$ocrTop} 2
  }
  $ocrTop = $fusion.Ocr
  $bestEl = $fusion.Element
  $bestCur = $fusion.Current
  $cx = [int]$ocrTop.cx
  $cy = [int]$ocrTop.cy
  if ([int]$ocrTop.score -lt 70) {
    _Emit @{
      status = "partial"
      reason = "low_confidence_match"
      score = [int]$ocrTop.score
      matched_ocr_text = $ocrTop.text
      threshold = 70
    } 2
  }

  # 3) Pattern 찾고 곧바로 invoke
  $name = ""; try { $name = "$($bestCur.Name)" } catch { }
  $autoId = ""; try { $autoId = "$($bestCur.AutomationId)" } catch { }
  $clazz = ""; try { $clazz = "$($bestCur.ClassName)" } catch { }

  # InvokePattern 우선 — 가장 안전하고 확실
  try {
    $invP = $bestEl.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    if ($invP) {
      $invP.Invoke()
      _Emit ([ordered]@{
        status = "ok"
        method = "InvokePattern"
        matched_ocr_text = $ocrTop.text
        ocr_score = [int]$ocrTop.score
        uia_name = $name
        uia_automation_id = $autoId
        uia_class_name = $clazz
        mouse_moved = $false
      })
    }
  } catch { }

  # TogglePattern (체크박스/라디오)
  try {
    $togP = $bestEl.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($togP) {
      $beforeState = "$($togP.Current.ToggleState)"
      $togP.Toggle()
      _Emit ([ordered]@{
        status = "ok"
        method = "TogglePattern"
        matched_ocr_text = $ocrTop.text
        ocr_score = [int]$ocrTop.score
        uia_name = $name
        uia_automation_id = $autoId
        previous_state = $beforeState
        mouse_moved = $false
      })
    }
  } catch { }

  # SelectionItemPattern (탭/리스트 항목)
  try {
    $selP = $bestEl.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    if ($selP) {
      $selP.Select()
      _Emit ([ordered]@{
        status = "ok"
        method = "SelectionItemPattern"
        matched_ocr_text = $ocrTop.text
        ocr_score = [int]$ocrTop.score
        uia_name = $name
        uia_automation_id = $autoId
        mouse_moved = $false
      })
    }
  } catch { }

  # 어떤 pattern 도 안 잡히면 partial — wrapper 가 좌표 click fallback 해야 함
  _Emit ([ordered]@{
    status = "partial"
    reason = "no_invoke_pattern"
    matched_ocr_text = $ocrTop.text
    ocr_score = [int]$ocrTop.score
    uia_name = $name
    uia_automation_id = $autoId
    uia_class_name = $clazz
    fallback_coord = [ordered]@{ x = $cx; y = $cy }
  }) 2
}

# ============================================================================
# Action: screenshot-diff  ─ 두 PNG 의 픽셀 변화 비율 측정
# ============================================================================
# 클릭 직후 화면이 정말 바뀌었는지 검증하는 용도.
#
# 입력: -DiffBefore <png>  -DiffAfter <png>  [-DiffThreshold 16]
#       [-ScreenshotX/Y/W/H — 비교 영역, 비어있으면 두 PNG 의 교집합 영역 사용]
# 출력: { width, height, total_pixels, changed_pixels, changed_ratio,
#         changed=bool, threshold }
# 알고리즘:
#   - 픽셀 단위 ARGB 비교, |R1-R2| + |G1-G2| + |B1-B2| > threshold 면 변화로 카운트
#   - changed_ratio = changed_pixels / total_pixels
#   - changed = (changed_ratio > 0.001)  // 0.1% 이상 달라야 의미있는 변화
# 정확도/속도: LockBits + 마샬링으로 픽셀 직접 접근, 1920x1080 ~150ms 수준
# ============================================================================
function _Action-ScreenshotDiff {
  if (-not $DiffBefore -or -not $DiffAfter) {
    _Emit @{status="error"; reason="missing_diff_paths"; recommended_action="provide -DiffBefore and -DiffAfter"} 1
  }
  if (-not (Test-Path -LiteralPath $DiffBefore)) {
    _Emit @{status="error"; reason="before_not_found"; path=$DiffBefore} 1
  }
  if (-not (Test-Path -LiteralPath $DiffAfter)) {
    _Emit @{status="error"; reason="after_not_found"; path=$DiffAfter} 1
  }
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop

  $bmp1 = $null; $bmp2 = $null
  $data1 = $null; $data2 = $null
  try {
    $bmp1 = [System.Drawing.Bitmap]::FromFile($DiffBefore)
    $bmp2 = [System.Drawing.Bitmap]::FromFile($DiffAfter)

    # 비교 영역 결정 — 두 이미지 교집합
    # PS 5.x inline-if 함정 회피: 변수 미리 할당
    $cmpW = [Math]::Min($bmp1.Width, $bmp2.Width)
    $cmpH = [Math]::Min($bmp1.Height, $bmp2.Height)
    if ($ScreenshotW -gt 0) { $cmpW = [Math]::Min($cmpW, $ScreenshotW) }
    if ($ScreenshotH -gt 0) { $cmpH = [Math]::Min($cmpH, $ScreenshotH) }
    $offX = 0
    if ($ScreenshotX -gt 0) { $offX = $ScreenshotX }
    $offY = 0
    if ($ScreenshotY -gt 0) { $offY = $ScreenshotY }
    if ($offX + $cmpW -gt $bmp1.Width)  { $cmpW = $bmp1.Width  - $offX }
    if ($offY + $cmpH -gt $bmp1.Height) { $cmpH = $bmp1.Height - $offY }
    if ($offX + $cmpW -gt $bmp2.Width)  { $cmpW = $bmp2.Width  - $offX }
    if ($offY + $cmpH -gt $bmp2.Height) { $cmpH = $bmp2.Height - $offY }

    if ($cmpW -le 0 -or $cmpH -le 0) {
      _Emit @{status="error"; reason="empty_compare_region"; cmp_w=$cmpW; cmp_h=$cmpH} 1
    }

    $rect = New-Object System.Drawing.Rectangle $offX, $offY, $cmpW, $cmpH
    $fmt = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    $data1 = $bmp1.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, $fmt)
    $data2 = $bmp2.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, $fmt)

    $stride = $data1.Stride
    $byteCount = [Math]::Abs($stride) * $cmpH
    $buf1 = New-Object byte[] $byteCount
    $buf2 = New-Object byte[] $byteCount
    [System.Runtime.InteropServices.Marshal]::Copy($data1.Scan0, $buf1, 0, $byteCount)
    [System.Runtime.InteropServices.Marshal]::Copy($data2.Scan0, $buf2, 0, $byteCount)

    # v1.0.0: ignore-regions 파싱 (마스킹 영역)
    # 형식: "x1,y1,w1,h1;x2,y2,w2,h2"
    # 비교 영역 좌표계는 LockBits 의 (offX,offY) 부터 시작하므로 입력 좌표를 보정
    $ignoreRects = @()
    if ($DiffIgnoreRegions) {
      foreach ($spec in ($DiffIgnoreRegions -split ';')) {
        $spec = $spec.Trim()
        if (-not $spec) { continue }
        $p = $spec -split ','
        if ($p.Count -ne 4) { continue }
        $rx = [int]$p[0].Trim() - $offX
        $ry = [int]$p[1].Trim() - $offY
        $rw = [int]$p[2].Trim()
        $rh = [int]$p[3].Trim()
        # 비교 영역 안으로 클램프
        if ($rx -lt 0) { $rw += $rx; $rx = 0 }
        if ($ry -lt 0) { $rh += $ry; $ry = 0 }
        if ($rw -le 0 -or $rh -le 0) { continue }
        if ($rx + $rw -gt $cmpW) { $rw = $cmpW - $rx }
        if ($ry + $rh -gt $cmpH) { $rh = $cmpH - $ry }
        if ($rw -le 0 -or $rh -le 0) { continue }
        $ignoreRects += [ordered]@{ x=$rx; y=$ry; w=$rw; h=$rh }
      }
    }

    # ignore-region 빠른 검사 함수: 픽셀 (xx, yy) 가 마스크 안인지
    # 작은 ignoreRects.Count(보통 0~3) 라 선형 탐색이 충분
    $hasIgnore = ($ignoreRects.Count -gt 0)

    $changed = 0
    $ignoredCount = 0
    $total = $cmpW * $cmpH
    # 32bpp ARGB: B G R A 순. 4바이트씩 stride 따라 진행
    for ($yy = 0; $yy -lt $cmpH; $yy++) {
      $rowOff = $yy * $stride
      for ($xx = 0; $xx -lt $cmpW; $xx++) {
        # ignore-region 안 픽셀은 비교 스킵
        if ($hasIgnore) {
          $skipped = $false
          foreach ($irc in $ignoreRects) {
            if ($xx -ge $irc.x -and $xx -lt ($irc.x + $irc.w) -and
                $yy -ge $irc.y -and $yy -lt ($irc.y + $irc.h)) {
              $skipped = $true
              break
            }
          }
          if ($skipped) { $ignoredCount++; continue }
        }
        $i = $rowOff + ($xx * 4)
        $db = [int][Math]::Abs([int]$buf1[$i]     - [int]$buf2[$i])
        $dg = [int][Math]::Abs([int]$buf1[$i + 1] - [int]$buf2[$i + 1])
        $dr = [int][Math]::Abs([int]$buf1[$i + 2] - [int]$buf2[$i + 2])
        if (($db + $dg + $dr) -gt $DiffThreshold) { $changed++ }
      }
    }

    # ignore 영역 제외한 effective_total 기준으로 ratio 계산
    $effectiveTotal = $total - $ignoredCount
    $ratio = if ($effectiveTotal -gt 0) { [double]$changed / [double]$effectiveTotal } else { 0.0 }
    $isChanged = ($ratio -gt 0.001)

    _Emit ([ordered]@{
      status = "ok"
      width = $cmpW
      height = $cmpH
      total_pixels = $total
      effective_pixels = $effectiveTotal
      ignored_pixels = $ignoredCount
      ignored_regions = @($ignoreRects)
      changed_pixels = $changed
      changed_ratio = [math]::Round($ratio, 6)
      changed = $isChanged
      threshold = $DiffThreshold
      offset = [ordered]@{ x=$offX; y=$offY }
      before = $DiffBefore
      after = $DiffAfter
    })
  } catch {
    _Emit @{status="error"; reason="diff_failed"; detail=$_.Exception.Message} 1
  } finally {
    if ($data1 -and $bmp1) { try { $bmp1.UnlockBits($data1) } catch { } }
    if ($data2 -and $bmp2) { try { $bmp2.UnlockBits($data2) } catch { } }
    if ($bmp1) { $bmp1.Dispose() }
    if ($bmp2) { $bmp2.Dispose() }
  }
}

# ============================================================================
# v1.4.0 Action: cdp-deep-find  ─ Shadow DOM + same-origin iframe traversal report
# ============================================================================
# 동기: smart-find/smart-type 가 deepCollect 로 shadow/iframe 안까지 보지만,
# 그 traversal 메타정보 (몇 개 shadow root, iframe 통과했는지) 가 외부에 안 보임.
# 이 액션은 read-only 로 그 정보를 노출해서 디버깅/검증/벤치마크에 사용.
#
# 입력: -CdpText "<label>" [-CdpPort 9222] [-CdpPageMatch <s>]
# 출력: {
#   status, page_id, page_url, page_title,
#   traversal: { hops, shadow_roots_seen, iframes_seen, iframes_blocked, total_nodes },
#   found_count, top_matches: [...]
# }
# ============================================================================
function _Action-CdpDeepFind {
  if (-not $CdpText) {
    _Emit @{status="error"; reason="missing_text"; recommended_action="provide -CdpText"} 1
  }
  $detect = _Cdp-Detect -Port $CdpPort
  if (-not $detect.available) {
    _Emit @{status="partial"; reason="cdp_port_closed"; port=$CdpPort; detail=$detect.error} 2
  }
  $page = _Cdp-FindPage -Detect $detect -PageMatch $CdpPageMatch
  if (-not $page) {
    _Emit @{status="partial"; reason="no_matching_page"; page_match=$CdpPageMatch} 2
  }
  # JSON-safe single-quote escape
  $needleEscaped = ($CdpText -replace '\\', '\\\\') -replace "'", "\\'"
  $js = @"
(function(){
  var report = { hops:4, shadow_roots_seen:0, iframes_seen:0, iframes_blocked:0, total_nodes:0 };
  var matches = [];
  function norm(s){ return (s||'').toString().toLowerCase().replace(/\s+/g,' ').trim(); }
  function scoreText(parts, needle){
    var best=0, bestText=null;
    for (var i=0;i<parts.length;i++){
      var t = norm(parts[i]);
      if (!t) continue;
      if (t === needle) { if (best<100){best=100;bestText=parts[i];} }
      else if (t.indexOf(needle) >= 0) { if (best<70){best=70;bestText=parts[i];} }
    }
    return { score:best, text:bestText };
  }
  function textParts(el){
    var p=[];
    try{
      if (el.innerText) p.push(el.innerText);
      if (el.textContent) p.push(el.textContent);
      if (el.value) p.push(el.value);
      if (el.placeholder) p.push(el.placeholder);
      if (el.title) p.push(el.title);
      var aria = el.getAttribute && el.getAttribute('aria-label');
      if (aria) p.push(aria);
      var n = el.getAttribute && el.getAttribute('name');
      if (n) p.push(n);
      var id = el.id; if (id) p.push(id);
    } catch(e){}
    return p;
  }
  function deep(root, hops){
    if (!root || hops <= 0) return;
    var all=[];
    try { all = root.querySelectorAll ? root.querySelectorAll('*') : []; } catch(e){}
    report.total_nodes += all.length;
    for (var i=0;i<all.length && matches.length<25;i++){
      var el = all[i];
      var parts = textParts(el);
      var st = scoreText(parts, NEEDLE);
      if (st.score > 0){
        var r=null;
        try{ r = el.getBoundingClientRect(); } catch(e){}
        matches.push({
          tag: el.tagName ? el.tagName.toLowerCase() : null,
          score: st.score,
          matched_text: st.text ? st.text.substring(0,80) : null,
          rect: r ? {x:Math.round(r.left),y:Math.round(r.top),w:Math.round(r.width),h:Math.round(r.height)} : null
        });
      }
      if (el.shadowRoot) {
        report.shadow_roots_seen++;
        deep(el.shadowRoot, hops-1);
      }
      if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
        report.iframes_seen++;
        var doc=null;
        try { doc = el.contentDocument; } catch(e){ doc=null; }
        if (doc) deep(doc, hops-1);
        else report.iframes_blocked++;
      }
    }
  }
  var NEEDLE = norm('NEEDLE_HERE');
  deep(document, report.hops);
  matches.sort(function(a,b){return b.score-a.score;});
  return { traversal: report, found_count: matches.length, top_matches: matches.slice(0,8) };
})()
"@
  $js = $js -replace 'NEEDLE_HERE', $needleEscaped
  $resp = _Cdp-WsCall -PageWsUrl $page.ws_url -Method "Runtime.evaluate" -Params @{
    expression = $js
    returnByValue = $true
    awaitPromise = $false
    timeout = 4000
  }
  if (-not $resp.ok) {
    _Emit @{status="error"; reason="ws_call_failed"; detail=$resp.error} 1
  }
  $val = $null
  try { $val = $resp.result.result.value } catch { $val = $null }
  if (-not $val) {
    _Emit @{status="partial"; reason="no_result"; page_id=$page.id; page_title=$page.title} 2
  }
  _Emit ([ordered]@{
    status = "ok"
    page_id = "$($page.id)"
    page_url = "$($page.url)"
    page_title = "$($page.title)"
    traversal = $val.traversal
    found_count = [int]$val.found_count
    top_matches = @($val.top_matches)
  })
}

# ============================================================================
# v1.4.0 Action: ime-paste  ─ 한국어 IME-safe 텍스트 입력 (clipboard route)
# ============================================================================
# 동기: SendInput WM_CHAR 로 한글을 보내면 IME 가 조합 모드일 때 깨지거나 분리됨.
# Notepad, Word, 브라우저 contenteditable 등에서 발생.
# 해결: System.Windows.Forms.Clipboard 로 텍스트 임시 저장 → Ctrl+V 단축키로 paste.
# 원래 클립보드 내용은 복원.
#
# 입력: -Text <string> [-PressEnter] [-TargetMatch <s>] [-TargetHwnd N]
# 출력: { status, method=clipboard_paste, text_len, restored_clipboard, mouse_moved=false }
#
# 안전성:
#   - hit-test 가드 (TargetMatch/TargetHwnd) 통과해야 paste
#   - 클립보드 백업/복구
#   - 마우스 안 움직임
# ============================================================================
function _Action-ImePaste {
  if (-not $Text) {
    _Emit @{status="error"; reason="missing_text"; recommended_action="provide -Text"} 1
  }
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop

  # hit-test 가드 — TargetMatch/TargetHwnd 가 있으면 현재 foreground 검증
  $guardEvidence = $null
  if ($TargetHwnd -gt 0 -or $TargetMatch) {
    try {
      $fg = [Win32Helper]::GetForegroundWindow()
      $sb = New-Object System.Text.StringBuilder 512
      [void][Win32Helper]::GetWindowText($fg, $sb, 512)
      $title = $sb.ToString()
      $hwndOk = ($TargetHwnd -gt 0 -and $TargetHwnd -eq [int]$fg)
      $titleOk = ($TargetMatch -and $title -and ($title -match [regex]::Escape($TargetMatch)))
      $guardEvidence = [ordered]@{
        foreground_hwnd = [int]$fg
        foreground_title = $title
        match_hwnd = $hwndOk
        match_title = $titleOk
      }
      if (-not ($hwndOk -or $titleOk)) {
        _Emit @{status="blocked"; reason="target_mismatch"; guard=$guardEvidence; recommended_action="focus the target window first"} 3
      }
    } catch {
      _Emit @{status="error"; reason="hit_test_failed"; detail=$_.Exception.Message} 1
    }
  }

  # 클립보드 백업
  $restored = $false
  $oldText = $null
  try {
    if ([System.Windows.Forms.Clipboard]::ContainsText()) {
      $oldText = [System.Windows.Forms.Clipboard]::GetText()
    }
  } catch { $oldText = $null }

  try {
    # SetText 는 STA thread 필요 — PowerShell 5.x 기본은 MTA 일 수 있음
    # 안전하게 SetDataObject + true (persist) 사용
    [System.Windows.Forms.Clipboard]::SetDataObject($Text, $true, 5, 100)
    Start-Sleep -Milliseconds 60

    # Ctrl+V 단축키 송출 (SendKeys 가 IME 우회)
    [System.Windows.Forms.SendKeys]::SendWait("^v")
    Start-Sleep -Milliseconds 80

    if ($PressEnter) {
      [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
      Start-Sleep -Milliseconds 40
    }
  } catch {
    _Emit @{status="error"; reason="paste_failed"; detail=$_.Exception.Message} 1
  } finally {
    # 클립보드 복구 (원래 내용이 있었던 경우만)
    try {
      if ($null -ne $oldText) {
        [System.Windows.Forms.Clipboard]::SetDataObject($oldText, $true, 5, 100)
        $restored = $true
      }
    } catch { $restored = $false }
  }

  _Emit ([ordered]@{
    status = "ok"
    method = "clipboard_paste"
    text_len = [int]$Text.Length
    pressed_enter = [bool]$PressEnter
    restored_clipboard = $restored
    guard = $guardEvidence
    mouse_moved = $false
  })
}

# ============================================================================
# ============================================================================
# v1.7.0 Action: cdp-prosemirror-insert  ─ ProseMirror live 텍스트 입력
# ============================================================================
# 동기: ProseMirror / TipTap 같은 contenteditable 에디터는 v1.3.0 부터 부채.
# 이전 cdp-type / cdp-smart-type 의 execCommand('insertText') 는 React/Vue
# state machine 이 거부. CDP `Input.insertText` 는 OS-level keyboard event
# simulation 이라 ProseMirror schema 가 수용함.
#
# 입력: -CdpText <text>  -CdpSelector <css>  [-CdpPort 9222] [-CdpPageMatch <s>]
# 출력: { status, route, before_value, after_value, changed, page_id, page_title }
# ============================================================================
function _Action-CdpProseMirrorInsert {
  if (-not $CdpText) {
    _Emit @{status="error"; reason="missing_text"; recommended_action="provide -CdpText"} 1
  }
  if (-not $CdpSelector) {
    _Emit @{status="error"; reason="missing_selector"; recommended_action="provide -CdpSelector (CSS for ProseMirror root, e.g. '.ProseMirror' or '[contenteditable=true]')"} 1
  }
  $detect = _Cdp-Detect -Port $CdpPort
  if (-not $detect.available) {
    _Emit @{
      status = "partial"
      reason = "cdp_port_closed"
      port = $CdpPort
      detail = $detect.error
      recommended_action = "launch chrome/electron with --remote-debugging-port=$CdpPort"
    } 2
  }
  $page = _Cdp-FindPage -Detect $detect -PageMatch $CdpPageMatch
  if (-not $page) {
    _Emit @{status="partial"; reason="no_matching_page"; page_match=$CdpPageMatch} 2
  }
  $wsUrl = $page.ws_url
  # 1. enable required domains
  try {
    [void](_Cdp-WsCall -WsUrl $wsUrl -Method "DOM.enable" -Params @{})
    [void](_Cdp-WsCall -WsUrl $wsUrl -Method "Runtime.enable" -Params @{})
    [void](_Cdp-WsCall -WsUrl $wsUrl -Method "Input.enable" -Params @{})
  } catch {
    # Input.enable 일부 환경에서 not supported — 무시하고 계속
  }
  # 2. focus selector + before snapshot via Runtime.evaluate
  $selJs = ($CdpSelector -replace "'", "\\'")
  $focusExpr = "(function(){var el=document.querySelector('$selJs'); if(!el) return null; el.focus(); el.scrollIntoView(); return el.innerText || el.textContent || '';})()"
  $beforeResp = _Cdp-WsCall -WsUrl $wsUrl -Method "Runtime.evaluate" -Params @{
    expression = $focusExpr
    returnByValue = $true
  }
  if (-not $beforeResp.ok) {
    _Emit @{status="error"; reason="focus_failed"; detail=$beforeResp.error} 1
  }
  $beforeValue = ""
  try { $beforeValue = "$($beforeResp.result.result.value)" } catch { $beforeValue = "" }
  if ($null -eq $beforeResp.result.result.value) {
    _Emit @{
      status = "partial"
      reason = "selector_not_found"
      selector = $CdpSelector
      page_id = "$($page.id)"
      page_title = "$($page.title)"
      recommended_action = "verify selector matches a ProseMirror root or [contenteditable=true]"
    } 2
  }
  # 3. Input.insertText — OS-level event, ProseMirror state machine accepts
  $insertResp = _Cdp-WsCall -WsUrl $wsUrl -Method "Input.insertText" -Params @{ text = $CdpText }
  if (-not $insertResp.ok) {
    _Emit @{status="error"; reason="input_inserttext_failed"; detail=$insertResp.error} 1
  }
  Start-Sleep -Milliseconds 80  # ProseMirror state update + re-render
  # 4. after snapshot
  $afterExpr = "(function(){var el=document.querySelector('$selJs'); if(!el) return null; return el.innerText || el.textContent || '';})()"
  $afterResp = _Cdp-WsCall -WsUrl $wsUrl -Method "Runtime.evaluate" -Params @{
    expression = $afterExpr
    returnByValue = $true
  }
  $afterValue = ""
  try { $afterValue = "$($afterResp.result.result.value)" } catch { $afterValue = "" }
  $changed = ($afterValue -ne $beforeValue) -and ($afterValue -match [regex]::Escape($CdpText))
  $payload = [ordered]@{
    status = if ($changed) { "ok" } else { "partial" }
    route = "cdp_input_inserttext"
    page_id = "$($page.id)"
    page_title = "$($page.title)"
    selector = $CdpSelector
    text_inserted = $CdpText
    before_value = $beforeValue
    after_value = $afterValue
    before_length = [int]$beforeValue.Length
    after_length = [int]$afterValue.Length
    changed = $changed
  }
  if (-not $changed) {
    $payload["reason"] = "value_unchanged_or_text_not_found"
    $payload["recommended_action"] = "verify ProseMirror is not in IME composition mode; try cdp-type as fallback"
  }
  _Emit $payload
}

# ============================================================================
# v1.4.0 Action: modal-detect  ─ 모달/팝업/대화상자 감지 (UI recovery loop 용)
# ============================================================================
# 동기: 라이브 step 이 실패한 후, "왜 실패했지?" 를 답하기 위해 화면에 새로 떴거나
# 사라진 모달/대화상자를 자동 감지해서 다음 안전한 retry 경로를 제안.
# 메모: 이 액션은 read-only — 어떤 클릭도 안 하고 UIA tree + window enum 만.
#
# 입력: [-Match <s>] [-TargetHwnd N]
# 출력: {
#   status, foreground: { hwnd, title, class },
#   modal_candidates: [{ hwnd, title, class, role, score, reason }],
#   recommended_action: "dismiss | confirm | wait | observe"
# }
# ============================================================================
function _Action-ModalDetect {
  Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
  Add-Type -AssemblyName UIAutomationTypes -ErrorAction SilentlyContinue
  $candidates = @()
  $fgInfo = $null
  try {
    $fg = [Win32Helper]::GetForegroundWindow()
    $sb = New-Object System.Text.StringBuilder 512
    [void][Win32Helper]::GetWindowText($fg, $sb, 512)
    $clsB = New-Object System.Text.StringBuilder 256
    [void][Win32Helper]::GetClassName($fg, $clsB, 256)
    $fgInfo = [ordered]@{
      hwnd = [int]$fg
      title = $sb.ToString()
      class = $clsB.ToString()
    }
  } catch { $fgInfo = $null }

  # UIA: WindowPattern 의 IsModal=true 또는 control type Window/Pane 중 작은 사이즈
  try {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.OrCondition @(
      (New-Object System.Windows.Automation.PropertyCondition `
        ([System.Windows.Automation.AutomationElement]::ControlTypeProperty),
        ([System.Windows.Automation.ControlType]::Window)),
      (New-Object System.Windows.Automation.PropertyCondition `
        ([System.Windows.Automation.AutomationElement]::ControlTypeProperty),
        ([System.Windows.Automation.ControlType]::Pane))
    )
    $els = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
    foreach ($el in $els) {
      try {
        $name = "$($el.Current.Name)"
        $cls  = "$($el.Current.ClassName)"
        $rect = $el.Current.BoundingRectangle
        $isModal = $false
        try {
          $wp = $el.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
          if ($wp -and $wp.Current.IsModal) { $isModal = $true }
        } catch { }
        $reason = $null
        $score = 0
        if ($isModal) { $score += 100; $reason = "uia_window_is_modal" }
        # 흔한 dialog class names
        if ($cls -match "(?i)#32770|MessageBox|Dialog|TaskDialog|Popup") {
          $score += 60
          if (-not $reason) { $reason = "dialog_class_name" }
        }
        # 작은 윈도우 (~600x400 이하) + 짧은 제목
        if ($rect -and $rect.Width -gt 0 -and $rect.Width -lt 900 -and $rect.Height -gt 0 -and $rect.Height -lt 600) {
          $score += 20
          if (-not $reason) { $reason = "small_window_size" }
        }
        if ($score -gt 0) {
          $hwndProp = $null
          try { $hwndProp = [int]$el.Current.NativeWindowHandle } catch { $hwndProp = $null }
          $candidates += [ordered]@{
            hwnd = $hwndProp
            title = $name
            class = $cls
            role = "$($el.Current.LocalizedControlType)"
            rect = [ordered]@{ x=[int]$rect.X; y=[int]$rect.Y; w=[int]$rect.Width; h=[int]$rect.Height }
            score = $score
            reason = $reason
            is_modal = $isModal
          }
        }
      } catch { continue }
    }
  } catch { }

  # 가장 점수 높은 후보로 추천 행동
  $sorted = @($candidates | Sort-Object -Property score -Descending)
  $rec = "observe"
  if ($sorted.Count -gt 0) {
    $top = $sorted[0]
    if ($top.is_modal -or ($top.score -ge 100)) { $rec = "dismiss_or_confirm" }
    elseif ($top.score -ge 60) { $rec = "confirm_dialog" }
    else { $rec = "wait" }
  }
  _Emit ([ordered]@{
    status = "ok"
    foreground = $fgInfo
    modal_candidates = $sorted
    candidate_count = [int]$sorted.Count
    recommended_action = $rec
  })
}

# ============================================================================
# Dispatch
# ============================================================================
switch ($Action) {
  "health"        { _Action-Health }
  "windows"       { _Action-Windows }
  "focused"       { _Action-Focused }
  "focus"         { _Action-Focus }
  "screenshot"    { _Action-Screenshot }
  "click"         { _Action-Click }
  "type"          { _Action-Type }
  "shortcut"      { _Action-Shortcut }
  "uia-tree"      { _Action-UiaTree }
  "uia-find"      { _Action-UiaFind }
  "uia-click"     { _Action-UiaClick }
  "uia-invoke"    { _Action-UiaInvoke }
  "uia-set-value" { _Action-UiaSetValue }
  "uia-toggle"    { _Action-UiaToggle }
  "ocr-image"       { _Action-OcrImage }
  "ocr-screen"      { _Action-OcrScreen }
  "ocr-find-text"   { _Action-OcrFindText }
  "ocr-uia-fuse"    { _Action-OcrUiaFuse }
  "ocr-uia-invoke"  { _Action-OcrUiaInvoke }
  "screenshot-diff" { _Action-ScreenshotDiff }
  "hit-test"        { _Action-HitTest }
  "hit-scan"        { _Action-HitScan }
  "cdp-detect"      { _Action-CdpDetect }
  "cdp-eval"        { _Action-CdpEval }
  "cdp-type"        { _Action-CdpType }
  "cdp-click"       { _Action-CdpClick }
  "cdp-smart-click" { _Action-CdpSmartClick }
  "cdp-smart-find"  { _Action-CdpSmartFind }
  "cdp-smart-type-find" { _Action-CdpSmartTypeFind }
  "cdp-smart-type"  { _Action-CdpSmartType }
  "cdp-deep-find"   { _Action-CdpDeepFind }
  "cdp-prosemirror-insert" { _Action-CdpProseMirrorInsert }
  "ime-paste"       { _Action-ImePaste }
  "modal-detect"    { _Action-ModalDetect }
}
