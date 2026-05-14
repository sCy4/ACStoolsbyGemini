#Requires AutoHotkey v2.0
#Include %A_ScriptDir%\UIA.ahk

; ==============================================================================
; ★ 變數初始化 (移至最上方以避免 #HotIf 找不到變數提早報錯)
; ==============================================================================
global isRunning := false
global isMouseLocked := false
; 告訴 Windows 重新讀取當前執行檔的圖示 (強制刷新單一檔案的圖示快取)
DllCall("shell32\SHChangeNotify", "UInt", 0x00002000, "UInt", 0x0005, "Str", A_ScriptFullPath, "Ptr", 0)

; ==============================================================================
; 1. 全域設定與字串字典
; ==============================================================================
global APP_CFG := {
    ; --- 版本與更新設定 ---
    Version: "v1.1.3",
    GithubRepo: "sCy4/ACStoolsbyGemini",  ; ★ 發布前請務必更改為你的 GitHub 帳號/儲存庫名稱

    ; --- 系統檔案與網址 ---
    ConfigFile: A_ScriptDir "\腳本設定檔-清關名單預設分配人員.txt",
    DefaultAssignees: "萍, 富, 蓁, 姿, 彥, 潔",
    GasUrl: "https://script.google.com/macros/s/AKfycbw2D6js48bcpApc6VhBfksd-98TCjvXZTccShoFBegp2P03Wh4tw3E3ufNQLKg4EXqX/exec",
    
    ; --- 瀏覽器分頁名稱 ---
    Tab_Logistics: "物流管理系統",
    Tab_Report: "清關報告",
    
    ; --- 提示訊息與對話框 (錯誤) ---
    Err_NoSelect: "■ 錯誤：沒有偵測到你要執行的單號",
    Err_NoPage: "■ 錯誤：找不到「物流管理系統」網頁",
    Err_NoSearch: "■ 錯誤：「物流管理系統」網頁異常",
    Err_CloudWrite: "■ 錯誤：清關報告內沒有看到你所執行的單號",
    Err_CloudConn: "■ 錯誤：清關報告的雲端指令碼沒有回應",
    Err_Script: "■ 錯誤：這可能超過了腳本的能力範圍",
    Err_WrongWindow: "■ 錯誤：這個功能只可以在清關報告中使用",
    Err_NoValidCode: "■ 錯誤：單號好像不對",
    
    ; --- 提示訊息與對話框 (狀態與 OSD) ---
    Osd_Running: "▶️ 腳本運作中：你現在不能操作電腦`n[進度 {1} / {2}]  (暫停：Esc)  (結束：F8)",
    Osd_Writing: "⏳ 修改表單資料中...`n你現在可以操作電腦",
    Osd_Paused: "⏸️ 腳本暫停：你現在可以操作電腦`n(恢復：回到暫停時的畫面按 ESC)  (結束：F8)",
    Osd_Resuming: "⏳ 腳本恢復中...",
    Osd_ResumeRun: "▶️ 繼續運行...",
    
    ; --- 提示訊息與對話框 (輸入與報告) ---
    Input_Title: "本次參與分配的人員",
    Input_Body: "哪些人要參與分配？`n`n請在人名之間用空格或逗號隔開`n如果沒有寫人名就只會標記 Y/N",
    Report_Title: "📑 統計報告",
    Report_Body: "完成了`n`n總共執行：{1}`n`n已按申報相符：{2}`n已上傳個案委任書：{3}`n其他：{4}`n`n本次有 {5} 筆狀態更改",

    ; --- 右鍵選單文字 ---
    Menu_Title: "清關報告幫手",
    Menu_Check: "查詢單筆",
    Menu_Renew: "更新申報狀態",
    Menu_Allot: "標記 Y/N 與分配人員",
    Menu_Highlight: "標記重複資料",
    
    ; --- 巨集快捷鍵設定 ---
    Key_HighlightMacro: "^+!1"  ; 代表 Ctrl + Alt + Shift + 1
}

; ==============================================================================
; 2. OSD 設計
; ==============================================================================

global OSD := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 +LastFound")
OSD.BackColor := "FAF9F5"
WinSetTransparent(238, OSD)

; 頂部 accent 線：用 Text 控制項 + WM_CTLCOLORSTATIC 強制上色
; CF6A4C 轉 COLORREF (BGR) → 0x4C6ACF
global OSD_TopBar := OSD.Add("Text", "x0 y0 w600 h3", "")
global hAccentBrush := DllCall("gdi32\CreateSolidBrush", "UInt", 0x4C6ACF, "Ptr")

OnMessage(0x0138, CtlColor)  ; 0x0138 = WM_CTLCOLORSTATIC
CtlColor(wParam, lParam, *) {
    global OSD_TopBar, hAccentBrush
    if (lParam = OSD_TopBar.Hwnd)
        return hAccentBrush
}

; 主文字，y3 緊接在 accent 線下方
OSD.SetFont("s16 w500", "Segoe UI Variable Text")
global OSD_Text := OSD.Add("Text", "x0 y3 w600 r2 Center c1C1917", "準備中...")

OSD.Show("Hide")
OSD.GetClientPos(,, &cw)
OSD_TopBar.Move(0, 0, cw, 3)
ApplyRoundedCorners(OSD.Hwnd, 12)

ApplyRoundedCorners(hwnd, radius) {
    WinGetPos(,, &w, &h, hwnd)
    hRgn := DllCall("gdi32.dll\CreateRoundRectRgn"
        , "Int", 0, "Int", 0, "Int", w, "Int", h
        , "Int", radius, "Int", radius, "Ptr")
    DllCall("user32.dll\SetWindowRgn", "Ptr", hwnd, "Ptr", hRgn, "Int", true)
}

; ==============================================================================
; ★ 啟動攔截：檢查是否有待命的更新檔 (第一時間無痕替換)
; ==============================================================================
ApplyStagedUpdate() {
    if !A_IsCompiled
        return

    fullCurrentPath := A_ScriptFullPath
    targetUpdateFile := ""
    targetVersion := ""

    ; 尋找暫存資料夾內的更新檔
    Loop Files, A_Temp "\Update_Temp_*.exe" {
        targetUpdateFile := A_LoopFilePath
        ; 從檔名提取版本號 (例如 Update_Temp_v1.1.0.exe -> v1.1.0)
        if RegExMatch(A_LoopFileName, "Update_Temp_(v[\d\.]+)\.exe", &match)
            targetVersion := match[1]
        break
    }

    if (targetUpdateFile = "")
        return

    ; ★ 終極防護：檢查暫存檔的版本是否「真的」比現在新
    cleanTarget := StrReplace(targetVersion, "v", "")
    cleanCurrent := StrReplace(APP_CFG.Version, "v", "")

    if (VerCompare(cleanTarget, cleanCurrent) <= 0) {
        ; 如果暫存檔版本比較舊或一樣 (幽靈殘留檔)，直接刪除它並中止更新
        try FileDelete(targetUpdateFile)
        return
    }

    ; 確認無誤，執行更新
    ShowOSD("🔄 偵測到新版本 (" targetVersion ")，正在自動更新...")
    Sleep(2000)

    psCommand := "Start-Sleep -Seconds 4; "
               . "Remove-Item -Path '" fullCurrentPath "' -Force; "
               . "Move-Item -Path '" targetUpdateFile "' -Destination '" fullCurrentPath "' -Force; "
               . "Start-Process -FilePath '" fullCurrentPath "'"
    
    Run("powershell.exe -WindowStyle Hidden -Command `"" psCommand "`"", A_ScriptDir, "Hide")
    ExitApp() 
}
ApplyStagedUpdate()

; ==============================================================================
; 3. 介面與選單建立
; ==============================================================================
BuildCustomsMenu(TargetMenu) {
    TargetMenu.Add(APP_CFG.Menu_Title, (*) => "")
    TargetMenu.Disable(APP_CFG.Menu_Title)
    TargetMenu.Add(APP_CFG.Menu_Check, Action_EZWCheck)
    TargetMenu.Add(APP_CFG.Menu_Renew, Action_EZWRenew)
    TargetMenu.Add(APP_CFG.Menu_Allot, Action_EZWAllot)
    TargetMenu.Add(APP_CFG.Menu_Highlight, Action_HighlightDuplicates)
}

; ==============================================================================
; 4. 核心動作函式
; ==============================================================================
Action_HighlightDuplicates(*) {
    if !WinActive("ahk_exe chrome.exe") {
        MsgBox(APP_CFG.Err_WrongWindow, "提示")
        return
    }
    try {
        WinActivate("ahk_exe chrome.exe")
        Sleep(100)
        Send(APP_CFG.Key_HighlightMacro)
    } catch as err {
        MsgBox(APP_CFG.Err_Script " " err.Message)
    }
}

Action_EZWCheck(*) {
    if !GetSelectedText(&cleanClip)
        return
    
    LockSystem()
    try {
        if !ActivateChromeTab(APP_CFG.Tab_Logistics, &ChromeEl) {
            EndProcess()
            MsgBox(APP_CFG.Err_NoPage)
            return
        }
            
        if !NavigateToSearch(ChromeEl) {
            EndProcess()
            MsgBox(APP_CFG.Err_NoSearch)
            return
        }

        ExecuteSearchCode(ChromeEl, cleanClip)
        EndProcess() 
    } catch as err {
        EndProcess()
        MsgBox(APP_CFG.Err_Script " " err.Message)
    }
}

Action_EZWRenew(*) {    
    if !GetSelectedText(&cleanClip)
        return

    LockSystem()
    trackings := StrSplit(cleanClip, "`n", "`r")
    matchCount := 0, validCount := 0, noMatchCount := 0, dataList := [] 
    
    try {
        if !ActivateChromeTab(APP_CFG.Tab_Logistics, &ChromeEl) {
            EndProcess()
            MsgBox(APP_CFG.Err_NoPage)
            return
        }

        for index, rawTrackCode in trackings {
            trackCode := RegExReplace(rawTrackCode, "[^\w\-]", "")
            if (StrLen(trackCode) < 4) {
                noMatchCount++
                continue
            }
            
            try {
                ShowOSD(Format(APP_CFG.Osd_Running, index, trackings.Length))
                if !NavigateToSearch(ChromeEl)
                    throw Error("NavFail")

                ExecuteSearchCode(ChromeEl, trackCode)

                ChromeEl.WaitElement({Name: "實名認證比對結果", MatchMode: "Substring"}, 10000)
                thisMatch := "無"
                if ChromeEl.ElementExist({Name: "資料相符", MatchMode: "Substring"})
                    matchCount++, thisMatch := "資料相符"
                else if ChromeEl.ElementExist({Name: "有效", MatchMode: "Substring"})
                    validCount++, thisMatch := "有效"
                else
                    noMatchCount++
                
                dataList.Push({code: trackCode, match: thisMatch})
            } catch {
                noMatchCount++
                dataList.Push({code: trackCode, match: "失敗"})
            }
        }
        
        SendToGAS(dataList, trackings.Length, matchCount, validCount, noMatchCount)
    } catch as err {
        EndProcess()
        MsgBox(APP_CFG.Err_Script " " err.Message)
    }
}

Action_EZWAllot(*) {
    if !FileExist(APP_CFG.ConfigFile) {
        try FileAppend(APP_CFG.DefaultAssignees, APP_CFG.ConfigFile, "UTF-8")
        rawAssigneeText := APP_CFG.DefaultAssignees
    } else {
        rawAssigneeText := FileRead(APP_CFG.ConfigFile, "UTF-8")
    }

    cleanedFileText := Trim(RegExReplace(rawAssigneeText, "[,\r\n，、\s]+", ", "), " ,")
    ib := InputBox(APP_CFG.Input_Body, APP_CFG.Input_Title, "w400 h160", cleanedFileText)
    if (ib.Result = "Cancel" || ib.Result = "Timeout")
        return 

    ; ★ 確認後將輸入值寫回設定檔,下次開啟 InputBox 自動帶入
    try {
        cleanedInput := Trim(RegExReplace(ib.Value, "[，、\s]+", ", "), " ,")
        if FileExist(APP_CFG.ConfigFile)
            FileDelete(APP_CFG.ConfigFile)
        FileAppend(cleanedInput, APP_CFG.ConfigFile, "UTF-8")
    }
    
    assignees := []
    for name in StrSplit(RegExReplace(ib.Value, "[，、\s]+", ","), ",")
        if (Trim(name) != "")
            assignees.Push(Trim(name))

    if !GetSelectedText(&cleanClip)
        return

    LockSystem()
    trackings := StrSplit(cleanClip, "`n", "`r")
    matchCount := 0, validCount := 0, noMatchCount := 0, dataList := []
    
    try {
        if !ActivateChromeTab(APP_CFG.Tab_Logistics, &ChromeEl) {
            EndProcess()
            MsgBox(APP_CFG.Err_NoPage)
            return
        }

        for index, rawTrackCode in trackings {
            trackCode := RegExReplace(rawTrackCode, "[^\w\-]", "")
            if (StrLen(trackCode) < 4) {
                noMatchCount++
                continue
            }
            
            try {
                ShowOSD(Format(APP_CFG.Osd_Running, index, trackings.Length))
                if !NavigateToSearch(ChromeEl)
                    throw Error("NavFail")

                ExecuteSearchCode(ChromeEl, trackCode)
                
                ChromeEl.WaitElement({Name: "實名認證比對結果", MatchMode: "Substring"}, 10000)
                thisMatch := "無"
                if ChromeEl.ElementExist({Name: "資料相符", MatchMode: "Substring"})
                    matchCount++, thisMatch := "資料相符"
                else if ChromeEl.ElementExist({Name: "有效", MatchMode: "Substring"})
                    validCount++, thisMatch := "有效"
                else
                    noMatchCount++

                ynStatus := ""
                if ChromeEl.ElementExist({Name: "Y", Type: "DataItem", ClassName: "text-success"})
                    ynStatus := "Y"
                else if ChromeEl.ElementExist({Name: "N", Type: "DataItem", ClassName: "text-danger"})
                    ynStatus := "N"
                
                ; 先標記這筆單號是否需要分配人員
                needsAssign := (thisMatch != "資料相符" && thisMatch != "有效")
                dataList.Push({code: trackCode, match: thisMatch, yn: ynStatus, needsAssign: needsAssign})
                
            } catch {
                noMatchCount++
                dataList.Push({code: trackCode, match: "失敗", yn: "", needsAssign: true})
            }
        }

        ; ★ 新增：第二階段分配邏輯 (連續平均分配) ★
        totalNeedsAssign := 0
        for item in dataList {
            if (item.needsAssign)
                totalNeedsAssign++
        }

        if (assignees.Length > 0 && totalNeedsAssign > 0) {
            baseCount := totalNeedsAssign // assignees.Length
            remainder := Mod(totalNeedsAssign, assignees.Length)
            
            assignIndex := 1
            currentAssigneeCount := 0
            ; 若有餘數，前幾個人會多拿 1 筆
            targetCount := baseCount + (assignIndex <= remainder ? 1 : 0)

            for item in dataList {
                if (item.needsAssign) {
                    item.assignee := assignees[assignIndex]
                    currentAssigneeCount++
                    
                    ; 如果這個人已經分滿了，換下一個人
                    if (currentAssigneeCount >= targetCount && assignIndex < assignees.Length) {
                        assignIndex++
                        currentAssigneeCount := 0
                        targetCount := baseCount + (assignIndex <= remainder ? 1 : 0)
                    }
                } else {
                    item.assignee := ""
                }
            }
        } else {
            ; 名單為空，或沒有單號需要分配
            for item in dataList
                item.assignee := ""
        }

        SendToGAS(dataList, trackings.Length, matchCount, validCount, noMatchCount)
    } catch as err {
        EndProcess()
        MsgBox(APP_CFG.Err_Script " " err.Message)
    }
}

; ==============================================================================
; 5. UIA 與網頁導航輔助函式
; ==============================================================================
ActivateChromeTab(TargetTabName, &ChromeEl) {
    chromeList := WinGetList("ahk_exe chrome.exe")
    for chromeHwnd in chromeList {
        try {
            el := UIA.ElementFromHandle(chromeHwnd)
            tab := el.ElementExist({Name: TargetTabName, Type: "TabItem", MatchMode: "Substring"})
            if tab {
                WinActivate(chromeHwnd), WinWaitActive(chromeHwnd)
                tab.Click(), Sleep(200)
                ChromeEl := el
                return true
            }
        }
    }
    return false
}

NavigateToSearch(ChromeEl) {
    if ChromeEl.ElementExist({AutomationId: "traceCode", Type: "Edit"})
        return true

    backLink := ChromeEl.ElementExist({Name: "返回上一頁", Type: "Link", MatchMode: "Substring"})
    if backLink {
        backLink.Click(), Sleep(200)
        ChromeEl.WaitElement({AutomationId: "traceCode", Type: "Edit"}, 5000)
        return true
    }

    navLink := ChromeEl.ElementExist({Value: "javascript:addTabs('%E8%A8%82%E5%96%AE%E6%9F%A5%E8%A9%A2','doc.order');"})
    if !navLink {
        dropdown := ChromeEl.ElementExist({Type: "Link", ClassName: "has-ul"})
        if dropdown {
            dropdown.Click(), Sleep(200)
            navLink := ChromeEl.ElementExist({Value: "javascript:addTabs('%E8%A8%82%E5%96%AE%E6%9F%A5%E8%A9%A2','doc.order');"})
        }
    }

    if navLink {
        navLink.Click(), Sleep(200)
        if ChromeEl.ElementExist({AutomationId: "traceCode", Type: "Edit"})
            return true
        backLink2 := ChromeEl.ElementExist({Name: "返回上一頁", Type: "Link", MatchMode: "Substring"})
        if backLink2
            backLink2.Click(), Sleep(200)
        ChromeEl.WaitElement({AutomationId: "traceCode", Type: "Edit"}, 8000)
        return true
    }
    return false
}

ExecuteSearchCode(ChromeEl, trackCode) {
    ChromeEl.WaitElement({AutomationId: "traceCode", Type: "Edit"}, 5000).Value := trackCode
    Sleep 50
    ChromeEl.WaitElement({Name: "查詢", Type: "Button"}, 5000).Click()
    Sleep 300
    ; ★ 對 trackCode 做正則跳脫,避免特殊字元造成匹配失敗
    escapedCode := EscapeRegex(trackCode)
    numLinkPattern := "^(\d+-\d|" . escapedCode . ")$"
    ChromeEl.WaitElement({Name: numLinkPattern, Type: "Link", MatchMode: "RegEx", Index: 1}, 10000).Click()
    Sleep 50
    ChromeEl.WaitElement({Name: "EZWAY", Type: "TabItem"}, 10000).Click()
    Sleep 50
}

; ==============================================================================
; 6. 系統操作與雲端連線輔助函式
; ==============================================================================

; ★ JSON 字串跳脫,避免 code/match/assignee 含特殊字元時 GAS 解析失敗
JsonEscape(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`t", "\t")
    s := StrReplace(s, Chr(8), "\b")
    s := StrReplace(s, Chr(12), "\f")
    return s
}

; ★ 正則表達式特殊字元跳脫
EscapeRegex(s) {
    return RegExReplace(s, "([\\.*+?^${}()|\[\]\/])", "\$1")
}

CheckAndUpdateInBackground() {
    if !A_IsCompiled
        return

    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", "https://api.github.com/repos/" APP_CFG.GithubRepo "/releases/latest", true)
        whr.SetRequestHeader("User-Agent", "ACStools-AutoUpdater")
        whr.Send()
        
        if (whr.WaitForResponse(2)) {
            if (whr.Status == 200) {
                if RegExMatch(whr.ResponseText, '"tag_name":\s*"([^"]+)"', &matchTag) {
                    latestVersion := matchTag[1]
                    
                    cleanLatest := StrReplace(latestVersion, "v", "")
                    cleanCurrent := StrReplace(APP_CFG.Version, "v", "")
                    
                    ; 只有遠端大於目前版本才下載
                    if (VerCompare(cleanLatest, cleanCurrent) > 0) {
                        if RegExMatch(whr.ResponseText, '"browser_download_url":\s*"([^"]+\.exe)"', &matchUrl) {
                            downloadUrl := matchUrl[1]
                            ; ★ 將版本號加入暫存檔名中
                            tempExePath := A_Temp "\Update_Temp_" latestVersion ".exe"
                            
                            ; 先清空以前遺留的其他版本暫存檔
                            Loop Files, A_Temp "\Update_Temp_*.exe"
                                try FileDelete(A_LoopFilePath)
                            
                            psCmd := "Invoke-WebRequest -Uri '" downloadUrl "' -OutFile '" tempExePath "' -UseBasicParsing"
                            Run("powershell.exe -WindowStyle Hidden -Command `"" psCmd "`"", , "Hide")
                        }
                    }
                }
            }
        }
    } catch {
        return
    }
}

ShowOSD(text) {
    OSD_Text.Value := text
    OSD.Show("NoActivate xCenter y100")
    ; ★ 每次顯示重套圓角,防 DPI/尺寸變動時邊角裁切異常
    ApplyRoundedCorners(OSD.Hwnd, 12)
}

HideOSD() {
    OSD.Hide()
}

SetSystemCursor(Cursor := "Wait") {
    CursorIDs := [32512, 32513, 32649] 
    for id in CursorIDs {
        hCursor := DllCall("LoadCursor", "Ptr", 0, "UInt", Cursor == "Wait" ? 32514 : 32512, "Ptr")
        hCopy := DllCall("CopyImage", "Ptr", hCursor, "UInt", 2, "Int", 0, "Int", 0, "UInt", 0, "Ptr")
        DllCall("SetSystemCursor", "Ptr", hCopy, "UInt", id)
    }
}

RestoreCursor() {
    DllCall("SystemParametersInfo", "UInt", 0x0057, "UInt", 0, "Ptr", 0, "UInt", 0)
}

LockSystem() {
    global isRunning := true
    global isMouseLocked := true 
    SetSystemCursor("Wait")
}

EndProcess() {
    global isRunning := false
    global isMouseLocked := false 
    RestoreCursor()
    HideOSD()
}

GetSelectedText(&cleanText) {
    hWnd := WinActive("A")
    if hWnd
        PostMessage(0x50, 0, 0x04090409, , "ahk_id " hWnd)
    
    ; ★ 備份使用者原本的剪貼簿內容
    savedClip := ClipboardAll()
    A_Clipboard := ""
    Send "^c"
    if !ClipWait(1) {
        A_Clipboard := savedClip  ; 失敗也要還原
        MsgBox(APP_CFG.Err_NoSelect)
        return false
    }
    cleanText := Trim(A_Clipboard, " `t`r`n")
    A_Clipboard := savedClip  ; 取出後立即還原
    return true
}

SendToGAS(dataList, totalCount, matchCount, validCount, noMatchCount) {
    ShowOSD(APP_CFG.Osd_Writing)
    RestoreCursor()
    global isMouseLocked := false 

    ; ★ 沒有任何有效單號 → 顯示明確訊息,避免使用者面對「無聲結束」
    if (dataList.Length == 0) {
        EndProcess()
        MsgBox(APP_CFG.Err_NoValidCode, "提示")
        return 
    }

    ActivateChromeTab(APP_CFG.Tab_Report, &_)

    ; ★ 所有寫入欄位先 JsonEscape,防止特殊字元破壞 JSON
    jsonBody := '{"data": ['
    for i, item in dataList {
        jsonBody .= '{"code":"' JsonEscape(item.code) '","match":"' JsonEscape(item.match) '"'
        if item.HasProp("yn")
            jsonBody .= ',"yn":"' JsonEscape(item.yn) '"'
        if item.HasProp("assignee")
            jsonBody .= ',"assignee":"' JsonEscape(item.assignee) '"'
        jsonBody .= '},'
    }
    jsonBody := RTrim(jsonBody, ",") . ']}'
    
    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.SetTimeouts(0, 60000, 30000, 300000)
        whr.Open("POST", APP_CFG.GasUrl, true)
        whr.SetRequestHeader("Content-Type", "application/json")
        whr.Send(jsonBody)
        
        while (whr.WaitForResponse(0.05) == 0)
            Sleep 50 
        
        if (whr.Status == 200) {
            if RegExMatch(whr.ResponseText, '"status"\s*:\s*"error"') {
                EndProcess()
                MsgBox(APP_CFG.Err_CloudWrite)
                return
            }
                
            actualNew := 0
            if RegExMatch(whr.ResponseText, '"newChanges"\s*:\s*(\d+)', &match)
                actualNew := match[1]

            EndProcess()
            reportMsg := Format(APP_CFG.Report_Body, totalCount, matchCount, validCount, noMatchCount, actualNew)
            MsgBox(reportMsg, APP_CFG.Report_Title)
        } else {
            EndProcess()
            MsgBox(APP_CFG.Err_CloudConn " " whr.Status)
        }
    } catch as err {
        EndProcess()
        MsgBox(APP_CFG.Err_Script " " err.Message)
    }
}

; ==============================================================================
; 7. 系統單獨執行邏輯與熱鍵綁定
; ==============================================================================
ShowOSD("✅ 腳本已啟動 (版本：" APP_CFG.Version ")")
SetTimer(HideOSD, -2000)

; ★ 啟動後 5 秒先在背景偷偷檢查第一次
SetTimer(CheckAndUpdateInBackground, -5000)
; ★ 之後每隔 1.5 小時 (5400000 毫秒) 背景自動循環檢查一次
SetTimer(CheckAndUpdateInBackground, 5400000)

SetTitleMatchMode 2

; ★ 統一退出清理:還原游標 + 釋放 GDI Brush
OnExit(CleanupOnExit)
CleanupOnExit(*) {
    global hAccentBrush
    RestoreCursor()
    if (hAccentBrush) {
        try DllCall("gdi32\DeleteObject", "Ptr", hAccentBrush)
        hAccentBrush := 0
    }
}

MyMenu := Menu()
BuildCustomsMenu(MyMenu)

Customs_StandaloneRButton(*) {
    if (isMouseLocked)
        return
    if (isRunning) {
        Click "Right"
        return
    }
    if !KeyWait("RButton", "T0.3") {
        MyMenu.Show()
        KeyWait "RButton"
    } else {
        Click "Right"
    }
}

Customs_StandaloneF8(*) {
    RestoreCursor()
    ShowOSD("下次見")
    SetTimer(() => ExitApp(), -2000)
}

Hotkey "$RButton", Customs_StandaloneRButton, "T2"
Hotkey "F8", Customs_StandaloneF8

; --- 全域熱鍵：防誤觸滑鼠鎖 ---
#HotIf isMouseLocked
*LButton::return
*MButton::return
*WheelUp::return
*WheelDown::return
*XButton1::return
*XButton2::return
#HotIf

; --- 全域熱鍵：暫停與恢復 ---
#HotIf isRunning
Esc:: {
    static paused := false
    static wasLocked := false
    paused := !paused
    if paused {
        wasLocked := isMouseLocked
        global isMouseLocked := false
        RestoreCursor()
        ShowOSD(APP_CFG.Osd_Paused)
        Pause 1
    } else {
        global isMouseLocked := wasLocked
        if (isMouseLocked)
            SetSystemCursor("Wait")
            
        ShowOSD(APP_CFG.Osd_Resuming)
        Sleep 500
        
        if (isRunning && !isMouseLocked)
            ShowOSD(APP_CFG.Osd_Writing)
        else if (isRunning)
            ShowOSD(APP_CFG.Osd_ResumeRun)
        else
            HideOSD()
            
        Pause 0
    }
}
#HotIf
