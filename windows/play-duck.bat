@echo off
rem ============================================================
rem  Microduck policy playback (Windows, repo-portable version)
rem  Usage: double-click, or in cmd:
rem    play-duck.bat            -> our trained velstand (bundled)
rem    play-duck.bat official   -> windows\models\official-velstand.onnx
rem                                (download official policies first, see
rem                                 windows/WINDOWS_PORT.md section 2.3)
rem  Control: click the MuJoCo 3D window and type:
rem    UP/DOWN forward-back, LEFT/RIGHT strafe, A/E turn,
rem    SPACE stop, P push, Y sit (with --sitstand), R roll, Q quit
rem  Xbox controller is auto-detected (left stick drive, A push,
rem    B sit, X roll, Y stop, BACK quit, START pause).
rem ============================================================

cd /d "%~dp0.."

set "MPLCONFIGDIR=%~dp0.windows-cache\matplotlib"
set "TMP=%~dp0.windows-cache\tmp"
set "TEMP=%~dp0.windows-cache\tmp"
set "PATH=%~dp0..\.venv\Scripts;%PATH%"

if /i "%1"=="official" (
    if exist "%~dp0models\official-velstand.onnx" (
        set "WALK=%~dp0models\official-velstand.onnx"
        echo === OFFICIAL velstand policy ===
    ) else (
        echo [ERROR] windows\models\official-velstand.onnx not found.
        echo         Download it from hf-mirror.com/pollen-robotics/microduck-policies
        pause
        exit /b 1
    )
) else (
    set "WALK=%~dp0models\ours-velstand.onnx"
    echo === OURS velstand policy (bundled) ===
)

.venv\Scripts\python.exe scripts\infer_policy.py --walking "%WALK%" --new-cmd-obs

pause
