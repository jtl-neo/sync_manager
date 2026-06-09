@echo off
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion

:: ============================================================
:: WinSCP Sync Manager  v1.1
::   - 主機離線偵測 (TCP 連線測試, 5 秒逾時, 不依賴 ICMP/ping)
::   - Slack / Discord Webhook 通知 (成功 / 失敗 / 離線 可分別開關)
::   - 背景排程改為呼叫  sync_manager.bat /run  (headless)
::     => 排程同步也會自動偵測主機與發送通知
:: ============================================================

:: ============================================================
:: Paths
:: ============================================================
set "DIR=%~dp0"
set "SELF=%~f0"
set "CONFIG=%DIR%sync_config.cfg"
set "WS_SCRIPT=%DIR%sync_script.txt"
set "LOG_FILE=%DIR%sync.log"
set "WINSCP=C:\Program Files (x86)\WinSCP\WinSCP.com"
set "TASK_NAME=WinSCP_Sync"

:: ============================================================
:: Defaults
:: ============================================================
set "CFG_HOST=100.89.136.63"
set "CFG_PORT=22"
set "CFG_USER=neo"
set "CFG_PASS="
set "CFG_REMOTE=/home/neo/neo.heyinna.com"
set "CFG_LOCAL=C:\Users\ljthu\Documents\neo.heyinna.com"
set "CFG_FREQ=HOURLY"
set "CFG_INTERVAL=1"
set "CFG_MIRROR=0"
set "CFG_IGNORE="
set "CFG_WEBHOOK_URL="
set "CFG_WEBHOOK_TYPE=SLACK"
set "CFG_NOTIFY_OK=0"
set "CFG_NOTIFY_FAIL=1"
set "CFG_NOTIFY_OFFLINE=0"

:: ============================================================
:: Load Config  (放在最前面, 讓 headless 模式也能讀到設定)
:: ============================================================
if exist "!CONFIG!" (
    for /f "usebackq tokens=1,* delims==" %%A in ("!CONFIG!") do set "CFG_%%A=%%B"
)

:: ============================================================
:: Headless 模式 (給工作排程器用):  sync_manager.bat /run
:: ============================================================
if /i "%~1"=="/run" goto :run_headless

:: ============================================================
:: Check WinSCP  (auto-install if missing)  -- 互動模式才會自動安裝
:: ============================================================
call :find_winscp
if not exist "!WINSCP!" (
    echo.
    echo  [INFO] WinSCP not found. Attempting to install...
    echo.

    :: --- Try winget first ---
    where winget >nul 2>&1
    if !errorlevel! equ 0 (
        echo  [INFO] Installing via winget...
        winget install --id WinSCP.WinSCP -e --accept-source-agreements --accept-package-agreements
    ) else (
        :: --- Fallback: download installer and run silently ---
        echo  [INFO] winget not available, downloading installer from winscp.net...
        set "WS_SETUP=%TEMP%\WinSCP-Setup.exe"
        powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { Invoke-WebRequest -Uri 'https://winscp.net/download/WinSCP-Setup.exe' -OutFile '!WS_SETUP!' } catch { Write-Host $_.Exception.Message; exit 1 }"
        if exist "!WS_SETUP!" (
            echo  [INFO] Running silent install...
            "!WS_SETUP!" /VERYSILENT /NORESTART /SUPPRESSMSGBOXES /ALLUSERS
            del /q "!WS_SETUP!" >nul 2>&1
        )
    )

    :: --- Re-detect after install ---
    call :find_winscp
    if not exist "!WINSCP!" (
        echo.
        echo  [ERROR] WinSCP installation failed or not found.
        echo  Please install WinSCP manually: https://winscp.net/eng/download.php
        echo.
        pause
        exit /b 1
    )
    echo  [OK] WinSCP ready: !WINSCP!
    echo.
)

:: ============================================================
:: Main Menu
:: ============================================================
:menu
cls
echo.
echo  ==========================================
echo         WinSCP Sync Manager  v1.1
echo  ==========================================
echo.
echo    [1]  連線設定  (Host/Port/User/Pass)
echo    [2]  路徑設定  (Remote/Local)
echo    [3]  排程設定  (頻率/間隔)
echo    [4]  立即同步
echo    [5]  查看日誌
echo    [6]  查看目前設定
echo    [7]  啟用排程
echo    [8]  停用排程
echo    [9]  忽略資料夾
echo    [W]  Webhook 通知  (Slack/Discord)
echo    [0]  離開
echo.
echo  ------------------------------------------
call :check_task_status
call :check_webhook_status
echo  ==========================================
echo.
set "c="
set /p "c=  請選擇 [0-9 / W]: "
if "!c!"=="1" goto :opt_conn
if "!c!"=="2" goto :opt_path
if "!c!"=="3" goto :opt_sched
if "!c!"=="4" goto :opt_sync
if "!c!"=="5" goto :opt_log
if "!c!"=="6" goto :opt_show
if "!c!"=="7" goto :opt_enable
if "!c!"=="8" goto :opt_disable
if "!c!"=="9" goto :opt_ignore
if /i "!c!"=="W" goto :opt_webhook
if "!c!"=="0" exit /b 0
goto :menu

:: ============================================================
:: [1] 連線設定
:: ============================================================
:opt_conn
cls
echo.
echo  --- 連線設定 ---
echo.
echo  (直接按 Enter 保留目前值)
echo.

set "v="
set /p "v=  Host [!CFG_HOST!]: "
if defined v set "CFG_HOST=!v!"

set "v="
set /p "v=  Port [!CFG_PORT!]: "
if defined v set "CFG_PORT=!v!"

set "v="
set /p "v=  User [!CFG_USER!]: "
if defined v set "CFG_USER=!v!"

set "v="
if defined CFG_PASS (
    set /p "v=  Password [****]: "
) else (
    set /p "v=  Password: "
)
if defined v set "CFG_PASS=!v!"

call :save_cfg
echo.
echo  已儲存!
timeout /t 2 >nul
goto :menu

:: ============================================================
:: [2] 路徑設定
:: ============================================================
:opt_path
cls
echo.
echo  --- 路徑設定 ---
echo.
echo  (直接按 Enter 保留目前值)
echo.

set "v="
set /p "v=  Remote [!CFG_REMOTE!]: "
if defined v set "CFG_REMOTE=!v!"

set "v="
set /p "v=  Local  [!CFG_LOCAL!]: "
if defined v set "CFG_LOCAL=!v!"

echo.
echo  鏡像模式: 刪除本地有但遠端沒有的檔案
if "!CFG_MIRROR!"=="1" (
    echo  目前: 開啟
) else (
    echo  目前: 關閉
)
set "v="
set /p "v=  切換鏡像模式? (y/n): "
if /i "!v!"=="y" (
    if "!CFG_MIRROR!"=="1" (set "CFG_MIRROR=0") else (set "CFG_MIRROR=1")
)

call :save_cfg
echo.
echo  已儲存!
timeout /t 2 >nul
goto :menu

:: ============================================================
:: [9] 忽略資料夾
:: ============================================================
:opt_ignore
cls
echo.
echo  --- 忽略資料夾設定 ---
echo.
echo  同步時會跳過這些資料夾 (遞迴比對所有層級)
echo.
if defined CFG_IGNORE (
    echo  目前清單: !CFG_IGNORE!
) else (
    echo  目前清單: (無)
)
echo.
echo    [1] 重設清單 (輸入完整清單)
echo    [2] 新增一個資料夾
echo    [3] 清空
echo    [0] 返回主選單
echo.
set "v="
set /p "v=  請選擇 [0-3]: "
if "!v!"=="1" goto :ign_set
if "!v!"=="2" goto :ign_add
if "!v!"=="3" goto :ign_clear
goto :menu

:ign_set
echo.
echo  用分號 ; 分隔多個, 例如: node_modules;.git;tmp
set "v="
set /p "v=  完整清單: "
if defined v set "CFG_IGNORE=!v!"
call :save_cfg
goto :opt_ignore

:ign_add
echo.
set "v="
set /p "v=  要新增的資料夾名稱: "
if defined v (
    if defined CFG_IGNORE (set "CFG_IGNORE=!CFG_IGNORE!;!v!") else (set "CFG_IGNORE=!v!")
)
call :save_cfg
goto :opt_ignore

:ign_clear
set "CFG_IGNORE="
call :save_cfg
goto :opt_ignore

:: ============================================================
:: [3] 排程設定
:: ============================================================
:opt_sched
cls
echo.
echo  --- 排程設定 ---
echo.
echo  目前: 每 !CFG_INTERVAL! !CFG_FREQ!
echo.
echo    [1] MINUTE  (分鐘)
echo    [2] HOURLY  (小時)
echo    [3] DAILY   (天)
echo.
set "v="
set /p "v=  頻率 (1/2/3) [不變]: "
if "!v!"=="1" set "CFG_FREQ=MINUTE"
if "!v!"=="2" set "CFG_FREQ=HOURLY"
if "!v!"=="3" set "CFG_FREQ=DAILY"

set "v="
set /p "v=  間隔 [!CFG_INTERVAL!]: "
if defined v set "CFG_INTERVAL=!v!"

call :save_cfg
echo.
echo  已儲存! (需重新啟用排程才會生效)
timeout /t 2 >nul
goto :menu

:: ============================================================
:: [4] 立即同步
:: ============================================================
:opt_sync
cls
echo.
echo  --- 立即同步 ---
echo.

if not defined CFG_PASS (
    echo  [ERROR] 尚未設定密碼! 請先到 [1] 連線設定。
    echo.
    pause
    goto :menu
)

echo  檢查主機是否在線 (!CFG_HOST!:!CFG_PORT!)...
call :check_host
if errorlevel 1 (
    echo.
    echo  [離線] 主機沒有回應，可能尚未開機。已略過同步。
    call :send_webhook offline
    echo.
    pause
    goto :menu
)

call :gen_script

echo  Host:   !CFG_HOST!:!CFG_PORT!
echo  User:   !CFG_USER!
echo  Remote: !CFG_REMOTE!
echo  Local:  !CFG_LOCAL!
echo.
echo  同步中...
echo.

"!WINSCP!" /ini=nul /script="!WS_SCRIPT!" /log="!LOG_FILE!"
set "RC=!errorlevel!"

if !RC! equ 0 (
    echo.
    echo  同步完成!
    call :send_webhook ok
) else (
    echo.
    echo  同步失敗! 錯誤碼: !RC!
    echo  請用 [5] 查看日誌。
    set "WH_DETAIL=Sync error code !RC! (see sync.log)"
    call :send_webhook fail
)
echo.
pause
goto :menu

:: ============================================================
:: [5] 查看日誌
:: ============================================================
:opt_log
cls
echo.
echo  --- 同步日誌 (最後 40 行) ---
echo.
if exist "!LOG_FILE!" (
    powershell -NoProfile -Command "Get-Content '!LOG_FILE!' -Tail 40"
) else (
    echo  尚無日誌。
)
echo.
pause
goto :menu

:: ============================================================
:: [6] 查看目前設定
:: ============================================================
:opt_show
cls
echo.
echo  --- 目前設定 ---
echo.
echo    Host:       !CFG_HOST!
echo    Port:       !CFG_PORT!
echo    User:       !CFG_USER!
if defined CFG_PASS (
    echo    Password:   ****
) else (
    echo    Password:   [未設定]
)
echo.
echo    Remote:     !CFG_REMOTE!
echo    Local:      !CFG_LOCAL!
if "!CFG_MIRROR!"=="1" (
    echo    鏡像模式:  開啟
) else (
    echo    鏡像模式:  關閉
)
if defined CFG_IGNORE (
    echo    忽略資料夾: !CFG_IGNORE!
) else (
    echo    忽略資料夾: (無)
)
echo.
echo    排程頻率:   每 !CFG_INTERVAL! !CFG_FREQ!
echo.
if defined CFG_WEBHOOK_URL (
    echo    Webhook:    已設定 ^(!CFG_WEBHOOK_TYPE!^)
) else (
    echo    Webhook:    未設定
)
set "S_OK=關閉"
if "!CFG_NOTIFY_OK!"=="1" set "S_OK=開啟"
set "S_FAIL=關閉"
if "!CFG_NOTIFY_FAIL!"=="1" set "S_FAIL=開啟"
set "S_OFF=關閉"
if "!CFG_NOTIFY_OFFLINE!"=="1" set "S_OFF=開啟"
echo    通知時機:   成功=!S_OK!  失敗=!S_FAIL!  離線=!S_OFF!
echo.
echo  ------------------------------------------
call :check_task_status
echo  ------------------------------------------
echo.
pause
goto :menu

:: ============================================================
:: [7] 啟用排程
:: ============================================================
:opt_enable
cls
echo.
echo  --- 啟用排程 ---
echo.

if not defined CFG_PASS (
    echo  [ERROR] 尚未設定密碼! 請先到 [1] 連線設定。
    echo.
    pause
    goto :menu
)

call :gen_script
echo  建立排程: 每 !CFG_INTERVAL! !CFG_FREQ!
echo.

schtasks /Create /TN "!TASK_NAME!" /TR "\"%SELF%\" /run" /SC !CFG_FREQ! /MO !CFG_INTERVAL! /F >nul 2>&1

if !errorlevel! equ 0 (
    echo  排程已啟用!
    echo  (背景同步會自動偵測主機是否開機, 並依設定發送 Webhook 通知)
) else (
    echo  排程建立失敗! 請嘗試以系統管理員身分執行。
)
echo.
pause
goto :menu

:: ============================================================
:: [8] 停用排程
:: ============================================================
:opt_disable
cls
echo.
echo  --- 停用排程 ---
echo.

schtasks /Delete /TN "!TASK_NAME!" /F >nul 2>&1

if !errorlevel! equ 0 (
    echo  排程已停用。
) else (
    echo  找不到排程或停用失敗。
)
echo.
pause
goto :menu

:: ============================================================
:: [W] Webhook 通知設定 (Slack / Discord)
:: ============================================================
:opt_webhook
cls
echo.
echo  --- Webhook 通知設定 (Slack / Discord) ---
echo.
if defined CFG_WEBHOOK_URL (
    echo  目前類型: !CFG_WEBHOOK_TYPE!
    echo  目前網址: (已設定, 為安全起見不顯示)
) else (
    echo  目前狀態: 未設定
)
echo.
set "S_OK=關閉"
if "!CFG_NOTIFY_OK!"=="1" set "S_OK=開啟"
set "S_FAIL=關閉"
if "!CFG_NOTIFY_FAIL!"=="1" set "S_FAIL=開啟"
set "S_OFF=關閉"
if "!CFG_NOTIFY_OFFLINE!"=="1" set "S_OFF=開啟"
echo  通知時機:
echo    同步成功: !S_OK!
echo    同步失敗: !S_FAIL!
echo    主機離線: !S_OFF!     (排程每次跑都會檢查, 開啟可能較吵)
echo.
echo    [1] 設定 Webhook 網址
echo    [2] 切換「同步成功」通知
echo    [3] 切換「同步失敗」通知
echo    [4] 切換「主機離線」通知
echo    [5] 發送測試訊息
echo    [6] 清除 Webhook 設定
echo    [0] 返回主選單
echo.
set "v="
set /p "v=  請選擇 [0-6]: "
if "!v!"=="1" goto :wh_set_url
if "!v!"=="2" goto :wh_tog_ok
if "!v!"=="3" goto :wh_tog_fail
if "!v!"=="4" goto :wh_tog_off
if "!v!"=="5" goto :wh_test
if "!v!"=="6" goto :wh_clear
goto :menu

:wh_set_url
cls
echo.
echo  --- 設定 Webhook 網址 ---
echo.
echo  貼上 Slack 或 Discord 的 Incoming Webhook URL:
echo    Slack:   https://hooks.slack.com/services/...
echo    Discord: https://discord.com/api/webhooks/...
echo.
set "v="
set /p "v=  URL (留空取消): "
if not defined v goto :opt_webhook
set "CFG_WEBHOOK_URL=!v!"
set "CFG_WEBHOOK_TYPE="
echo !v! | findstr /i "discord" >nul && set "CFG_WEBHOOK_TYPE=DISCORD"
echo !v! | findstr /i "slack"   >nul && set "CFG_WEBHOOK_TYPE=SLACK"
if not defined CFG_WEBHOOK_TYPE set "CFG_WEBHOOK_TYPE=SLACK"
echo.
echo  偵測到類型: !CFG_WEBHOOK_TYPE!
set "v="
set /p "v=  正確請按 Enter, 或輸入 SLACK / DISCORD 覆蓋: "
if /i "!v!"=="DISCORD" set "CFG_WEBHOOK_TYPE=DISCORD"
if /i "!v!"=="SLACK"   set "CFG_WEBHOOK_TYPE=SLACK"
call :save_cfg
echo.
echo  已儲存!
timeout /t 2 >nul
goto :opt_webhook

:wh_tog_ok
if "!CFG_NOTIFY_OK!"=="1" (set "CFG_NOTIFY_OK=0") else (set "CFG_NOTIFY_OK=1")
call :save_cfg
goto :opt_webhook

:wh_tog_fail
if "!CFG_NOTIFY_FAIL!"=="1" (set "CFG_NOTIFY_FAIL=0") else (set "CFG_NOTIFY_FAIL=1")
call :save_cfg
goto :opt_webhook

:wh_tog_off
if "!CFG_NOTIFY_OFFLINE!"=="1" (set "CFG_NOTIFY_OFFLINE=0") else (set "CFG_NOTIFY_OFFLINE=1")
call :save_cfg
goto :opt_webhook

:wh_test
cls
echo.
echo  --- 發送測試訊息 ---
echo.
if not defined CFG_WEBHOOK_URL (
    echo  尚未設定 Webhook 網址, 請先選 [1]。
    echo.
    pause
    goto :opt_webhook
)
echo  傳送中...
set "WH_DETAIL=This is a test message. If you see this, the webhook works."
call :send_webhook test force
if errorlevel 1 (
    echo  測試失敗! 請確認 URL 與網路連線。
) else (
    echo  測試訊息已送出, 請到 Slack/Discord 查看。
)
echo.
pause
goto :opt_webhook

:wh_clear
set "CFG_WEBHOOK_URL="
set "CFG_WEBHOOK_TYPE=SLACK"
call :save_cfg
goto :opt_webhook

:: ============================================================
:: Headless 排程同步入口 (sync_manager.bat /run)
::   主機未開機 -> 視為正常情況, 記 log 並 (可選) 通知, 不報錯
:: ============================================================
:run_headless
call :find_winscp
if not exist "!WINSCP!" (
    >>"!LOG_FILE!" echo [%date% %time%] [ERROR] WinSCP not found. Scheduled sync aborted.
    set "WH_DETAIL=WinSCP not found on this machine."
    call :send_webhook fail
    exit /b 1
)
if not defined CFG_PASS (
    >>"!LOG_FILE!" echo [%date% %time%] [ERROR] No password set. Scheduled sync aborted.
    set "WH_DETAIL=No password configured."
    call :send_webhook fail
    exit /b 1
)

call :check_host
if errorlevel 1 (
    >>"!LOG_FILE!" echo [%date% %time%] [SKIP] Host !CFG_HOST!:!CFG_PORT! offline. Sync skipped.
    call :send_webhook offline
    exit /b 0
)

call :gen_script
"!WINSCP!" /ini=nul /script="!WS_SCRIPT!" /log="!LOG_FILE!"
set "RC=!errorlevel!"

if !RC! equ 0 (
    >>"!LOG_FILE!" echo [%date% %time%] [OK] Sync completed.
    call :send_webhook ok
) else (
    >>"!LOG_FILE!" echo [%date% %time%] [ERROR] Sync failed. Code !RC!.
    set "WH_DETAIL=Sync error code !RC! (see sync.log)"
    call :send_webhook fail
)
exit /b !RC!

:: ============================================================
:: Helper: Check Task Status
:: ============================================================
:check_task_status
schtasks /Query /TN "!TASK_NAME!" >nul 2>&1
if !errorlevel! equ 0 (
    echo    排程狀態:  已啟用
    for /f "tokens=1,* delims=:" %%a in ('schtasks /Query /TN "!TASK_NAME!" /FO LIST 2^>nul ^| findstr /i "Next"') do (
        echo    下次執行: %%b
    )
) else (
    echo    排程狀態:  未啟用
)
exit /b

:: ============================================================
:: Helper: Check Webhook Status (一行摘要, 給選單用)
:: ============================================================
:check_webhook_status
if defined CFG_WEBHOOK_URL (
    echo    Webhook:   已設定 ^(!CFG_WEBHOOK_TYPE!^)
) else (
    echo    Webhook:   未設定
)
exit /b

:: ============================================================
:: Helper: Check Host  (TCP 連線測試)
::   errorlevel 0 = 主機:埠 可連線
::   errorlevel 1 = 離線 / 無回應 (5 秒逾時)
:: ============================================================
:check_host
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='SilentlyContinue'; $c=New-Object System.Net.Sockets.TcpClient; try { $iar=$c.BeginConnect('!CFG_HOST!',[int]'!CFG_PORT!',$null,$null); if($iar.AsyncWaitHandle.WaitOne(5000,$false) -and $c.Connected){ exit 0 } else { exit 1 } } catch { exit 1 } finally { $c.Close() }" >nul 2>&1
if errorlevel 1 ( exit /b 1 )
exit /b 0

:: ============================================================
:: Helper: Send Webhook  (Slack / Discord)
::   用法: call :send_webhook <ok|fail|offline|test> [force]
::   - WH_DETAIL 由呼叫端先設定 (可選), 送完會自動清空
::   - 加上 force 會略過開關設定 (測試用)
::   - 回傳 errorlevel: 0 成功, 1 失敗
:: ============================================================
:send_webhook
set "WH_S=%~1"
set "WH_FORCE=%~2"
if not defined CFG_WEBHOOK_URL exit /b 0
if /i "!WH_FORCE!"=="force" goto :wh_do
if /i "!WH_S!"=="ok"      if not "!CFG_NOTIFY_OK!"=="1"      ( set "WH_DETAIL=" & exit /b 0 )
if /i "!WH_S!"=="fail"    if not "!CFG_NOTIFY_FAIL!"=="1"    ( set "WH_DETAIL=" & exit /b 0 )
if /i "!WH_S!"=="offline" if not "!CFG_NOTIFY_OFFLINE!"=="1" ( set "WH_DETAIL=" & exit /b 0 )

:wh_do
set "WH_TYPE=!CFG_WEBHOOK_TYPE!"
set "WH_URL=!CFG_WEBHOOK_URL!"
set "WH_HOST=!CFG_HOST!:!CFG_PORT!"
set "WH_LOCAL=!CFG_LOCAL!"
set "WH_REMOTE=!CFG_REMOTE!"

powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $nl=[char]10; $s=$env:WH_S; switch($s){ 'ok'{$t='[OK] Sync completed'} 'fail'{$t='[FAILED] Sync failed'} 'offline'{$t='[OFFLINE] Host offline - sync skipped'} 'test'{$t='[TEST] Webhook connection test'} default{$t=$s} }; $m='WinSCP Sync - '+$t+$nl+'Time:   '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+$nl+'Host:   '+$env:WH_HOST+$nl+'Local:  '+$env:WH_LOCAL+$nl+'Remote: '+$env:WH_REMOTE; if($env:WH_DETAIL){ $m=$m+$nl+'Detail: '+$env:WH_DETAIL }; if($env:WH_TYPE -eq 'DISCORD'){ $b=@{content=$m} } else { $b=@{text=$m} }; $j=$b | ConvertTo-Json -Compress; try { Invoke-RestMethod -Uri $env:WH_URL -Method Post -ContentType 'application/json' -Body $j -TimeoutSec 15 | Out-Null; exit 0 } catch { exit 1 }" >nul 2>&1
set "WH_E=!errorlevel!"
set "WH_DETAIL="
exit /b !WH_E!

:: ============================================================
:: Helper: Save Config
:: ============================================================
:save_cfg
(
    echo HOST=!CFG_HOST!
    echo PORT=!CFG_PORT!
    echo USER=!CFG_USER!
    echo PASS=!CFG_PASS!
    echo REMOTE=!CFG_REMOTE!
    echo LOCAL=!CFG_LOCAL!
    echo FREQ=!CFG_FREQ!
    echo INTERVAL=!CFG_INTERVAL!
    echo MIRROR=!CFG_MIRROR!
    echo IGNORE=!CFG_IGNORE!
    echo WEBHOOK_URL=!CFG_WEBHOOK_URL!
    echo WEBHOOK_TYPE=!CFG_WEBHOOK_TYPE!
    echo NOTIFY_OK=!CFG_NOTIFY_OK!
    echo NOTIFY_FAIL=!CFG_NOTIFY_FAIL!
    echo NOTIFY_OFFLINE=!CFG_NOTIFY_OFFLINE!
) > "!CONFIG!"
exit /b

:: ============================================================
:: Helper: Generate WinSCP Script  (排程與立即同步共用)
:: ============================================================
:gen_script
set "DEL_OPT="
if "!CFG_MIRROR!"=="1" set "DEL_OPT= -delete"

:: build exclude filemask from ignored folders (semicolon separated)
set "EXC="
if defined CFG_IGNORE (
    for %%F in ("!CFG_IGNORE:;=" "!") do if not "%%~F"=="" set "EXC=!EXC!%%~F/;"
)

(
    echo open sftp://!CFG_USER!@!CFG_HOST!:!CFG_PORT!/ -password="!CFG_PASS!" -hostkey=* -timeout=15
    if defined EXC (
        echo synchronize local!DEL_OPT! -filemask="|!EXC!" "!CFG_LOCAL!" "!CFG_REMOTE!"
    ) else (
        echo synchronize local!DEL_OPT! "!CFG_LOCAL!" "!CFG_REMOTE!"
    )
    echo exit
) > "!WS_SCRIPT!"
exit /b

:: ============================================================
:: Locate WinSCP.com in common install locations
:: ============================================================
:find_winscp
if exist "!WINSCP!" exit /b
if exist "C:\Program Files (x86)\WinSCP\WinSCP.com" set "WINSCP=C:\Program Files (x86)\WinSCP\WinSCP.com" & exit /b
if exist "C:\Program Files\WinSCP\WinSCP.com" set "WINSCP=C:\Program Files\WinSCP\WinSCP.com" & exit /b
if exist "%LOCALAPPDATA%\Programs\WinSCP\WinSCP.com" set "WINSCP=%LOCALAPPDATA%\Programs\WinSCP\WinSCP.com" & exit /b
for /f "delims=" %%P in ('where WinSCP.com 2^>nul') do set "WINSCP=%%P" & exit /b
exit /b
