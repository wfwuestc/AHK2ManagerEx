/*
AHK2ManagerEx
A toolkit to control all running instances of AutoHotkey(V2.0+)，written using AutoHotkey v2.0+ (http://www.autohotkey.com/)
By Jacques Yip

Copyright 2022-2023 Jacques Yip
Modified by wfwuestc, 2026：项目更名 AHK2ManagerEx（子文件夹结构支持、被引用的附加脚本自动过滤、中文文档、构建脚本可移植化）

注意：本文件要经 Ahk2Exe 编译，注释里不能出现 “#” 紧跟 “Include” 的字面量，
      否则编译器会把它当成 include 指令去解析，找不到文件导致编译失败。
--------------------------------
*/

; --------------------- COMPILER DIRECTIVES --------------------------

;@Ahk2Exe-SetName AHK2ManagerEx
;@Ahk2Exe-SetDescription AHK2ManagerEx
;@Ahk2Exe-SetVersion 0.0.2
;@Ahk2Exe-SetCopyright Jacques Yip (2022-2023) / modified by wfwuestc (2026)
;@Ahk2Exe-SetOrigFilename AHK2ManagerEx.exe
;@Ahk2Exe-SetMainIcon icons\main_light.ico
;@Ahk2Exe-AddResource icons\main_dark.ico, 160
; --------------------- GLOBAL --------------------------

#Requires AutoHotkey >=v2.0

#Include <Array>
#Include <WindowsTheme>
#Include <ConfMan>

SetWorkingDir A_ScriptDir
#SingleInstance Force
; 3 = 精确匹配。脚本窗口标题只有两种形态：「完整路径 - AutoHotkey」或「裸文件名 - AutoHotkey」；
; 用前缀匹配（旧值 1）会让不同目录里的同名脚本互相命中，导致 CloseTask/RestartTask 关错窗口
SetTitleMatchMode 3
DetectHiddenWindows 1
FileEncoding "UTF-8-RAW"

for item in ["lang", "scripts"] {
    If !FileExist(A_ScriptDir "\" item) {
        DirCreate(A_ScriptDir "\" item)
    }
}

; 语言包缺失时才解出，避免覆盖用户自己改过的文案（源码运行时文件本来就在，两个判断都不触发）
If !FileExist(".\lang\en_us.ini") {
    FileInstall(".\lang\en_us.ini", ".\lang\en_us.ini", 1)
}
If !FileExist(".\lang\zh_cn.ini") {
    FileInstall(".\lang\zh_cn.ini", ".\lang\zh_cn.ini", 1)
}

SplitPath A_ScriptName, , , , &appName

; 读不到主题键（不支持深色模式的系统）按浅色处理
global sysThemeMode := RegRead("HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize", "SystemUsesLightTheme", 1)

global CONF_PATH := A_ScriptDir "\setting.ini"
CONF := ConfMan.GetConf(CONF_PATH)
CONF.Setting := {
    language: "en_us",
    mode: 0
}
CONF.SCRIPTS := {}

If !FileExist(CONF_Path) {
    FileAppend "", CONF_Path
}
If (FileRead(CONF_Path) = "") {
    CONF.WriteFile()
}
CONF.ReadFile()

global typeEnum := Map("ONCE", 0, "TEMP", 1, "DAEMON", 2)

; scriptMap 的键是脚本的唯一 ID：相对 scripts 目录的路径去掉 .ahk
; 例如根目录的 "Obsidian"、子目录的 "EverythingToolbar\Everything_Toolbar"
global scriptMap := Map()

; 被判定为「附加脚本」的清单（被 #Include 引用、或文件名以 _ 开头），只在菜单里做只读展示
global ignoredScriptList := Array()
global ignoredMenu := Menu()

; #Include 目标解析缓存：绝对路径 → { mtime, targets }
; 按修改时间失效，避免每次重新加载都把整个 scripts 目录重读一遍
global includeCache := Map()

global langMenu := Menu()
global startMenu := Menu()
global restartMenu := Menu()
global closeMenu := Menu()

; 进程管理器窗口，第一次打开时建好，之后复用
global pmGui := ""
global pmLV := ""

WindowsTheme.SetAppMode(!sysThemeMode)

; 需要两个参数：mode sc / mode char；少一个参数时不处理，避免 A_Args 越界
if (A_Args.Length > 1 && A_Args[1] = "mode") {
    switch A_Args[2], false {
        case "sc":
            CONF.Setting.mode := 1
            CONF.WriteFile()
            ChangeToSCMode()
        case "char":
            CONF.Setting.mode := 0
            CONF.WriteFile()
        default:
    }
}

InitialLanguage()
; 先扫描脚本，托盘菜单才拿得到「附加脚本」清单
LoadScript(CONF.Setting.mode)
CreateLangMenu()
CreateTrayMenu()
CreateMenu()

OpenAllTask()
RegisterMouseShortcuts()

Persistent
Return

; --------------------- SHORTCUTS --------------------------

; Win + Shift + R, 重新加载
#+r:: ReloadTray

; Ctrl + Alt + 鼠标三键直达三个菜单。这三个组合会挂全局鼠标钩子，
; 不想被占用就在 setting.ini 的 [Setting] 段加 hotkeys=0（改完重启生效）。
RegisterMouseShortcuts() {
    if (IniRead(CONF_PATH, "Setting", "hotkeys", 1) + 0 != 0) {
        Hotkey "^!LButton", (*) => startMenu.Show()
        Hotkey "^!RButton", (*) => closeMenu.Show()
        Hotkey "^!MButton", (*) => restartMenu.Show()
    }
}

; --------------------- MENU EVENT RESPONSE --------------------------
LoadScript(mode) {
    global
    ; 先把磁盘配置读回内存：后面一律读 CONF 对象即可 ——
    ; 既不用每脚本一次整文件 IniRead，也不会有"内存值/文件值"两套真相（手改 setting.ini 也能即时生效）
    CONF.ReadFile()

    scripts := ScanScripts()

    ; 重建前先清空：否则磁盘上已删除/改名的脚本会留在菜单里，点下去就是「文件不存在」
    scriptMap := Map()

    ; 收集被忽略的附加脚本，供托盘菜单只读展示（[Setting] showIgnored=1 时打开）
    ignoredScriptList := Array()
    ignoredMenu.Delete
    for , scriptItem in scripts {
        if (scriptItem.isIgnore) {
            ignoredScriptList.Push(scriptItem.relPath)
        }
    }
    if (ShowIgnoredScripts() && ignoredScriptList.Length > 0) {
        AddIgnoredMenu()
    }

    if (mode = 1) {
        ; 源码管理模式：脚本类型来自 setting.ini，配置键与脚本 ID 相同（相对路径去掉 .ahk）
        known := Map()
        for , scriptItem in scripts {
            known[scriptItem.id] := scriptItem
        }

        for , scriptItem in scripts {
            if (!(CONF.SCRIPTS.Has(scriptItem.id))) {
                CONF.SCRIPTS.%scriptItem.id% := 0
            }
        }

        ; 清理已经从磁盘上消失的脚本。遍历期间不删除，先收集再删。
        stale := Array()
        for scriptName, scriptType in CONF.SCRIPTS {
            if (!known.Has(scriptName)) {
                stale.Push(scriptName)
            }
        }
        for , scriptName in stale {
            CONF.SCRIPTS.Delete(scriptName)
        }

        for scriptName, scriptType in CONF.SCRIPTS {
            if (!known.Has(scriptName) || known[scriptName].isIgnore) {
                continue
            }
            scriptItem := known[scriptName]
            scriptTypeNum := scriptType + 0
            running := IsScriptRunning(scriptItem.relPath, scriptItem.fileName)

            ; 菜单名与字符模式保持一致：都去掉 ! / + 前缀，否则同一脚本换模式后名字会多个符号
            ; （注意别叫 menuLabel —— AHK 标识符大小写不敏感，会和函数 MenuLabel 撞名）
            displayLabel := StripPrefix(scriptItem.displayName)
            if (scriptTypeNum = typeEnum["ONCE"]) {
                ; ONCE 脚本正在运行时不出现在菜单里，沿用旧行为
                if (!running) {
                    CreateTaskInfo(scriptItem.id, scriptItem.relPath, scriptItem.folder, displayLabel, scriptTypeNum, 0)
                }
            } else {
                CreateTaskInfo(scriptItem.id, scriptItem.relPath, scriptItem.folder, displayLabel, scriptTypeNum, running)
            }
        }
        CONF.WriteFile()
    } else {
        ; 字符模式：! → TEMP，+ → ONCE，无前缀 → DAEMON。子目录里的脚本同样生效。
        for , scriptItem in scripts {
            if (scriptItem.isIgnore) {
                continue
            }
            CreateTaskInfo(scriptItem.id, scriptItem.relPath, scriptItem.folder, StripPrefix(scriptItem.displayName), ScriptTypeByPrefix(scriptItem.fileName), IsScriptRunning(scriptItem.relPath, scriptItem.fileName))
        }
    }
}

OpenTask(id, *) {
    scriptItem := scriptMap[id]
    RunScript(scriptItem.relPath)
    if (scriptItem.scriptType != typeEnum["ONCE"]) {
        UpdateTaskStatus(id, 1)
        RecreateMenu()
    }
    return
}

RestartTask(id, *) {
    scriptItem := scriptMap[id]
    ; 先等旧实例退干净再启动，否则慢退出的脚本会和新实例并存
    CloseScriptWindow(ScriptWindowTitle(scriptItem.relPath, scriptItem.fileName))
    RunScript(scriptItem.relPath)
    UpdateTaskStatus(id, 1)
    return
}

CloseTask(id, *) {
    scriptItem := scriptMap[id]
    ; 只有确认窗口真的关掉了才改状态；否则菜单会显示"已关闭"但进程还在
    if (CloseScriptWindow(ScriptWindowTitle(scriptItem.relPath, scriptItem.fileName))) {
        UpdateTaskStatus(id, 0)
    }
    RecreateMenu()
    return
}

OpenAllTask(*) {
    for id, scriptItem in scriptMap {
        If (scriptItem.status = 0) {
            if (scriptItem.scriptType == typeEnum["DAEMON"]) {
                RunScript(scriptItem.relPath)
                UpdateTaskStatus(id, 1)
            }
        }
    }
    RecreateMenu()
}

CloseAllTask(*) {
    for id, scriptItem in scriptMap {
        If (scriptItem.status = 1) {
            ; 退出流程里每个脚本只等 600ms，脚本多时不至于拖很久
            if (CloseScriptWindow(ScriptWindowTitle(scriptItem.relPath, scriptItem.fileName), 600)) {
                UpdateTaskStatus(id, 0)
            }
        }
    }
    RecreateMenu()
}

CreateTaskInfo(id, relPath, folder, displayName, type, status := 0) {
    SplitPath relPath, &fileName
    scriptObj := Object()
    scriptObj.id := id
    scriptObj.relPath := relPath
    scriptObj.fileName := fileName
    scriptObj.folder := folder
    scriptObj.displayName := displayName
    scriptObj.scriptType := type
    scriptObj.status := status
    scriptMap[id] := scriptObj
    return scriptObj
}

UpdateTaskStatus(id, status := 1) {
    if (scriptMap.Has(id)) {
        scriptMap[id].status := status
    }
}

ProManager(*) {
    ; 不写 global 的话这两个赋值会创建局部变量，窗口复用就不生效了
    global pmGui, pmLV
    if (!IsObject(pmGui)) {
        pmGui := Gui()
        WindowsTheme.SetWindowAttribute(pmGui, !sysThemeMode)
        pmGui.SetFont("s9", "Arial")
        pmLV := pmGui.Add("ListView", "x2 y0 w760 h500", [lGUIIndex, lGUIPid, lGUIScriptname, lGUIMemory])
        pmLV.ModifyCol()
        pmLV.ModifyCol(2, "Integer")
        pmLV.ModifyCol(3, "260")
        pmGui.Title := "Process List"
        WindowsTheme.SetWindowTheme(pmGui, !sysThemeMode)
    }
    pmLV.Delete()
    for id, scriptItem in scriptMap {
        If (scriptItem.status = 1) {
            title := ScriptWindowTitle(scriptItem.relPath, scriptItem.fileName)
            if (title = "") {
                continue
            }
            procId := ""
            memory := ""
            try procId := WinGetPID(title)
            if (procId != "") {
                try memory := GetProcessMemoryInfo(procId)
            }
            ; ListView 没有 Count 属性，只有 GetCount() 方法；
            ; 上面刚 Delete 过，所以行号就是 GetCount() + 1（从 1 开始）
            pmLV.Add(, pmLV.GetCount() + 1, procId, scriptItem.relPath, memory)
        }
    }
    pmGui.Show
}

ShowTray(*) {
    A_TrayMenu.Show
}

; 分组标题和只读清单项的占位回调，这些项都被禁用，点了不会有动作
Noop(*) {
}

ChangeToSCMode(*) {
    prefixLen := StrLen(A_ScriptDir "\scripts\")

    ; 必须先把清单收集完再改名：文件循环中途重命名会让同一个文件被枚举两次
    ; （旧名一次、新名一次），新名那一遍没有 !/+ 前缀，会在下面的 else 分支里被误记成 DAEMON。
    ; 循环里同时把目录也存下来，免得再依赖 A_LoopFileDir（循环变量出了循环就失效）。
    files := Array()
    Loop Files A_ScriptDir "\scripts\*.ahk", "R" {
        files.Push({ path: A_LoopFilePath, dir: A_LoopFileDir })
    }

    skipped := Array()          ; 因重名而未改名的脚本，最后统一提示
    for , f in files {
        relPath := SubStr(f.path, prefixLen + 1)
        SplitPath relPath, &fileName, &folder, , &displayName
        menuName := StripPrefix(displayName)
        ; 配置键必须用重命名之后的名字：LoadScript 按新名扫描，用旧名写进去会被当 stale 删掉
        id := (folder = "") ? menuName : folder "\" menuName
        first := SubStr(fileName, 1, 1)
        if (first = "!" || first = "+") {
            newPath := f.dir . "\" menuName . ".ahk"
            ; 同目录里已存在改名后的文件（例如 !Foo.ahk 与 Foo.ahk 并存）→ 跳过。
            ; 否则 FileMove 的覆盖参数会静默丢掉其中一个文件，这是本流程唯一的丢数据风险点。
            if (FileExist(newPath)) {
                skipped.Push(relPath)
                continue
            }
            ; 判断用内存里的 CONF 而不是 IniRead：本函数刚写进去的值必须能立刻被看到
            CONF.SCRIPTS.%id% := (first = "!") ? 1 : 0
            FileMove f.path, newPath, true
        } else if (!(CONF.SCRIPTS.Has(id))) {
            CONF.SCRIPTS.%id% := 2
        }
    }
    CONF.WriteFile()

    if (skipped.Length > 0) {
        msg := "以下脚本改名后与同目录已有文件重名，已跳过：`n`n"
        for , p in skipped {
            msg .= p "`n"
        }
        msg .= "`n请手动改名或删除其中一个后重试。"
        MsgBox(msg, appName " · mode sc")
    }
}

SwitchLanguage(ItemName, ItemPos, MyMenu) {
    CONF.Setting.language := ItemName
    CONF.WriteFile()          ; 立刻落盘：否则进程被强杀时语言选择会丢
    InitialLanguage()
    CreateLangMenu()
    CreateTrayMenu()
    RecreateMenu()
}

InitialLanguage(*) {
    LANG_PATH := A_ScriptDir "\lang\" CONF.Setting.language ".ini"

    ; 每个读取都必须带默认值：IniRead 省略 Default 时，键 / 段 / 文件任一缺失都会抛 OSError，
    ; 而语言菜单是按 lang\ 目录下的 *.ini 列出来的 —— 多一个杂散文件就能把界面点崩。
    ; 缺键时回落到英文文案，至少界面还能用。
    global lTrayExit := IniRead(LANG_PATH, "Tray", "exit", "Exit")
    global lTrayReload := IniRead(LANG_PATH, "Tray", "reload", "Reload")
    global lTrayProcMan := IniRead(LANG_PATH, "Tray", "procman", "Process Manager")
    global lTrayLang := IniRead(LANG_PATH, "Tray", "lang", "Language")
    global lTrayCloseAll := IniRead(LANG_PATH, "Tray", "closeall", "Close All")
    global lTrayClose := IniRead(LANG_PATH, "Tray", "close", "Close")
    global lTrayRestart := IniRead(LANG_PATH, "Tray", "restart", "Restart")
    global lTrayStart := IniRead(LANG_PATH, "Tray", "start", "Start")
    global lTrayIgnored := IniRead(LANG_PATH, "Tray", "ignored", "Ignored Scripts")

    global lGUIIndex := IniRead(LANG_PATH, "GUI", "index", "Index")
    global lGUIMemory := IniRead(LANG_PATH, "GUI", "memory", "Memory")
    global lGUIPid := IniRead(LANG_PATH, "GUI", "pid", "PID")
    global lGUIScriptname := IniRead(LANG_PATH, "GUI", "scriptname", "Script Name")
}

ReloadTray(*) {
    CreateLangMenu()
    LoadScript(CONF.Setting.mode)
    CreateTrayMenu()
    ; 必须走 RecreateMenu：CreateMenu 只加不删，连续重新加载会把旧条目堆在菜单里，
    ; 而旧条目绑定的脚本 ID 在重建后已经不存在了
    RecreateMenu()
    OpenAllTask()
    Return
}

ExitTray(*) {
    CloseAllTask()
    CONF.WriteFile()
    ExitApp
    Return
}

CreateTrayMenu(*) {
    ; A_TrayMenu := A_TrayMenu
    if (A_IsCompiled) {
        if (sysThemeMode) {
            TraySetIcon(A_ScriptName, -159)
        } else {
            TraySetIcon(A_ScriptName, -160)
        }
    } else {
        if (sysThemeMode) {
            TraySetIcon(A_ScriptDir "\icons\main_light.ico")
        } else {
            TraySetIcon(A_ScriptDir "\icons\main_dark.ico")
        }
    }
    A_IconTip := appName
    A_TrayMenu.Delete
    A_TrayMenu.ClickCount := 1
    A_TrayMenu.Add appName, ShowTray
    A_TrayMenu.ToggleEnable(appName)
    A_TrayMenu.Default := appName
    A_TrayMenu.Add
    A_TrayMenu.Add lTrayStart, startMenu
    A_TrayMenu.Add
    A_TrayMenu.Add lTrayRestart, restartMenu
    A_TrayMenu.Add lTrayClose, closeMenu
    A_TrayMenu.Add lTrayCloseAll, CloseAllTask
    A_TrayMenu.Add
    A_TrayMenu.Add lTrayLang, langMenu
    A_TrayMenu.Add lTrayProcMan, ProManager
    if (ShowIgnoredScripts() && ignoredScriptList.Length > 0) {
        A_TrayMenu.Add
        A_TrayMenu.Add lTrayIgnored, ignoredMenu
    }
    A_TrayMenu.Add
    A_TrayMenu.Add lTrayReload, ReloadTray
    A_TrayMenu.Add lTrayExit, ExitTray
}

CreateLangMenu(*) {
    langMenu.Delete
    Loop Files A_ScriptDir "\lang\*.ini" {
        SplitPath A_LoopFileName, , , , &FileNameNoExt
        langMenu.Add(FileNameNoExt, SwitchLanguage)
    }
    langMenu.Check(CONF.Setting.language)
}

CreateMenu(*) {
    startMenu.Add(lTrayStart, Noop)
    startMenu.ToggleEnable(lTrayStart)
    startMenu.Default := lTrayStart
    startMenu.Add

    closeMenu.Add(lTrayClose, Noop)
    closeMenu.ToggleEnable(lTrayClose)
    closeMenu.Default := lTrayClose
    closeMenu.Add

    restartMenu.Add(lTrayRestart, Noop)
    restartMenu.ToggleEnable(lTrayRestart)
    restartMenu.Default := lTrayRestart
    restartMenu.Add

    unOpenScriptListTemp := Array()
    unOpenScriptListOnce := Array()
    unOpenScriptListDaemon := Array()

    OpenScriptListTemp := Array()
    OpenScriptListDaemon := Array()

    ; 三段互斥：ONCE 只进「未运行」列表，写成分开的 if 会让 ONCE 脚本再被塞进 DAEMON 组、菜单里出现两次
    for id, scriptItem in scriptMap {
        if (scriptItem.scriptType = typeEnum["ONCE"]) {
            unOpenScriptListOnce.Push(id)
        } else if (scriptItem.scriptType = typeEnum["TEMP"]) {
            If (scriptItem.status = 0) {
                unOpenScriptListTemp.Push(id)
            } else {
                OpenScriptListTemp.Push(id)
            }
        } else {
            If (scriptItem.status = 0) {
                unOpenScriptListDaemon.Push(id)
            } else {
                OpenScriptListDaemon.Push(id)
            }
        }
    }

    AddMenuItem(unOpenScriptListTemp, 0, unOpenScriptListTemp.Length > 0)
    AddMenuItem(unOpenScriptListOnce, 0, unOpenScriptListOnce.Length > 0)
    AddMenuItem(unOpenScriptListDaemon, 0, false)

    AddMenuItem(OpenScriptListTemp, 1, OpenScriptListTemp.Length > 0)
    AddMenuItem(OpenScriptListDaemon, 1, false)
}

RecreateMenu(*) {
    startMenu.Delete
    closeMenu.Delete
    restartMenu.Delete

    CreateMenu()

}

; --------------------- MENU FUNCTION --------------------------


AddMenuItem(list, status := 0, split := true) {
    if (list.Length < 1) {
        return
    }
    tree := BuildMenuTree(list)

    if (status = 1) {
        AddMenuTree(tree, restartMenu, RestartTask)
        AddMenuTree(tree, closeMenu, CloseTask)
        if (split = true) {
            restartMenu.Add
            closeMenu.Add
        }
    } else {
        AddMenuTree(tree, startMenu, OpenTask)
        if (split = true) {
            startMenu.Add
        }
    }
}

; 递归把菜单树铺进目标菜单：子文件夹先建同名子菜单，根目录脚本直接平铺
AddMenuTree(node, targetMenu, callback) {
    folderNames := Array()
    for name, child in node.Folders {
        folderNames.Push(name)
    }
    folderNames.sort("C")

    for , name in folderNames {
        submenu := Menu()
        targetMenu.Add(name, submenu)
        AddMenuTree(node.Folders[name], submenu, callback)
    }

    ; 按显示名排序，中间的 tab 只作为同名时的兜底分隔
    sortKeys := Array()
    byKey := Map()
    for , scriptItem in node.Items {
        sortKey := scriptItem.displayName . "`t" . scriptItem.id
        sortKeys.Push(sortKey)
        byKey[sortKey] := scriptItem
    }
    sortKeys.sort("C")

    usedLabels := Map()
    for , sortKey in sortKeys {
        scriptItem := byKey[sortKey]
        label := MenuLabel(node.Folders, usedLabels, scriptItem)
        usedLabels[label] := 1
        targetMenu.Add(label, callback.Bind(scriptItem.id))
    }
}

; 附加脚本清单：只读子菜单，方便核对哪些文件被当成附加脚本跳过了
AddIgnoredMenu(*) {
    ignoredScriptList.sort("C")
    for , relPath in ignoredScriptList {
        ignoredMenu.Add(relPath, Noop)
        ignoredMenu.Disable(relPath)
    }
}

DetectConfig(section, name) {
    global CONF_PATH
    result := IniRead(CONF_PATH, section, name, false)
    return result
}

; --------------------- FILE STRUCTURE SUPPORT --------------------------
; scripts 目录支持任意层级的子文件夹：
;   1. 递归扫描 *.ahk
;   2. 文件名前缀 ! / + 的规则在任何层级都生效
;   3. 托盘菜单按子文件夹名分组，根目录脚本仍然平铺
;   4. 不同文件夹里的同名脚本靠分组 + 相对路径后缀区分
;   5. 被其他脚本 #Include 引用的文件视为「附加脚本」，不进菜单也不自动启动

; 相对路径（相对 scripts 目录）→ 绝对路径
ScriptPath(relPath) {
    return A_ScriptDir "\scripts\" relPath
}

; 启动脚本。路径加引号，兼容目录名或整体路径含空格的情况。
RunScript(relPath) {
    Run '"' A_ScriptDir "\scripts\" relPath '"'
}

; 返回脚本主窗口的标题；不在运行则返回空串。
; AHK 主窗口标题可能是「脚本完整路径」也可能是「裸文件名」，两种都试一遍，避免漏判。
ScriptWindowTitle(relPath, fileName) {
    full := A_ScriptDir "\scripts\" relPath " - AutoHotkey"
    if WinExist(full) {
        return full
    }
    bare := fileName " - AutoHotkey"
    if WinExist(bare) {
        return bare
    }
    return ""
}

IsScriptRunning(relPath, fileName) {
    return ScriptWindowTitle(relPath, fileName) != ""
}

; 关闭脚本窗口并等它真正消失（最多 timeoutMs 毫秒），返回是否已关闭。
; 不等的话，慢退出的脚本会与紧接着启动的新实例并存（重启场景最明显）。
CloseScriptWindow(title, timeoutMs := 2000) {
    if (title = "" || !WinExist(title)) {
        return 1
    }
    WinClose(title)
    deadline := A_TickCount + timeoutMs
    while (WinExist(title) && A_TickCount < deadline) {
        Sleep 50
    }
    return !WinExist(title)
}

; 去掉文件名里的 ! / + 标记与可选序号（正则与旧版保持一致）
StripPrefix(name) {
    static NeedleRegEx := "(\+|\!)(\s)?([0-9]+.\s)?"
    return RegExReplace(name, NeedleRegEx)
}

; 字符模式下的类型判定：! → TEMP，+ → ONCE，无前缀 → DAEMON
ScriptTypeByPrefix(fileName) {
    if (SubStr(fileName, 1, 1) = "!") {
        return typeEnum["TEMP"]
    }
    if (SubStr(fileName, 1, 1) = "+") {
        return typeEnum["ONCE"]
    }
    return typeEnum["DAEMON"]
}

; 是否展示被忽略的附加脚本清单（setting.ini → [Setting] showIgnored=1）
ShowIgnoredScripts() {
    return (DetectConfig("Setting", "showIgnored") + 0) = 1
}

; 相对路径中任意一层目录名以 "_" 开头 → 整棵子树跳过
HasIgnorePrefix(folderPath) {
    if (folderPath = "") {
        return 0
    }
    for , segment in StrSplit(folderPath, "\") {
        if (SubStr(segment, 1, 1) = "_") {
            return 1
        }
    }
    return 0
}

IsAbsolutePath(path) {
    return (SubStr(path, 2, 2) = ":\") || (SubStr(path, 1, 2) = "\\")
}

; 规范化路径：统一 / 与 \、展开 . 与 ..、去掉重复分隔符，便于比较
NormalizePath(path) {
    parts := Array()
    for , segment in StrSplit(StrReplace(path, "/", "\"), "\") {
        if (segment = "" || segment = ".") {
            continue
        }
        if (segment = "..") {
            if (parts.Length > 0) {
                parts.Pop()
            }
            continue
        }
        parts.Push(segment)
    }
    if (parts.Length < 1) {
        return ""
    }
    result := parts[1]
    Loop parts.Length - 1 {
        result .= "\" parts[A_Index + 1]
    }
    return result
}

; 递归扫描 scripts 目录，返回脚本信息数组。每项字段：
;   id          唯一标识 = 相对路径去掉 .ahk，同时也是 SC 模式的配置键
;   relPath     相对路径，如 "EverythingToolbar\Everything_Toolbar.ahk"
;   fileName    裸文件名，如 "Everything_Toolbar.ahk"
;   folder      相对目录，根目录脚本为 ""
;   displayName 去掉扩展名的文件名（未去前缀标记）
;   hasPrefix   是否带 ! / + 标记
;   isIgnore    是否「附加脚本」（不进菜单、不自动启动）
ScanScripts() {
    scripts := Array()
    prefixLen := StrLen(A_ScriptDir "\scripts\")
    Loop Files A_ScriptDir "\scripts\*.ahk", "R" {
        relPath := SubStr(A_LoopFilePath, prefixLen + 1)
        SplitPath relPath, &fileName, &folder, , &displayName

        if (HasIgnorePrefix(folder)) {
            continue
        }

        item := Object()
        item.id := SubStr(relPath, 1, -4)
        item.relPath := relPath
        item.fileName := fileName
        item.folder := folder
        item.displayName := displayName
        item.hasPrefix := (SubStr(fileName, 1, 1) = "!" || SubStr(fileName, 1, 1) = "+") ? 1 : 0
        item.isIgnore := (SubStr(fileName, 1, 1) = "_") ? 1 : 0
        scripts.Push(item)
    }
    MarkIncludeScripts(scripts)
    return scripts
}

; 解析所有脚本里的 #Include / #IncludeAgain 指令，把「被引用」的文件标记为附加脚本。
; 任何读取或解析失败都不做标记（fail-open）：宁可多显示一个，也不误藏。
MarkIncludeScripts(scripts) {
    included := Map()
    for , item in scripts {
        for , target in ReadIncludeTargets(item) {
            for , hit in ResolveIncludePath(target, item) {
                included[StrLower(NormalizePath(hit))] := 1
            }
        }
    }
    for , item in scripts {
        if (included.Has(StrLower(NormalizePath(ScriptPath(item.relPath)))) && !item.hasPrefix) {
            item.isIgnore := 1                    ; 带 ! / + 标记的脚本按用户意图保留
        }
    }
}

; 读出一个脚本里的 #Include 目标（未解析的路径字符串）。
; 结果按文件修改时间缓存 —— 重新加载时没改动过的脚本不会重读，脚本多了也不会卡。
ReadIncludeTargets(item) {
    fullPath := ScriptPath(item.relPath)
    try mtime := FileGetTime(fullPath, "M")
    catch {
        return Array()
    }
    if (includeCache.Has(fullPath)) {
        cached := includeCache[fullPath]
        if (cached.mtime = mtime) {
            return cached.targets
        }
    }
    targets := ParseIncludeTargets(fullPath, item)
    includeCache[fullPath] := { mtime: mtime, targets: targets }
    return targets
}

; 编码兜底链：先按 UTF-8 读（带 BOM 的文件由 BOM 决定真实编码），
; 一段 #Include 都没找到时，再依次试 UTF-16（带 BOM）、UTF-16-RAW（无 BOM）、系统 ANSI（中文机器上即 GBK）。
; 不做兜底的话，GBK 存盘的脚本会被解成乱码 → 它引用的库文件漏过滤，而且完全不报错。
ParseIncludeTargets(fullPath, item) {
    for , enc in ["UTF-8", "UTF-16", "UTF-16-RAW", "CP0"] {
        try content := FileRead(fullPath, enc)
        catch {
            continue
        }
        targets := ExtractIncludeTargets(content, item)
        if (targets.Length > 0) {
            return targets
        }
    }
    return Array()
}

; 从脚本文本里抽出 #Include / #IncludeAgain 的目标
ExtractIncludeTargets(content, item) {
    targets := Array()
    Loop Parse content, "`n", "`r" {
        if !RegExMatch(A_LoopField, "i)^[ `t]*#Include(Again)?[ `t]+(.+?)[ `t]*$", &m) {
            continue
        }
        t := RegExReplace(m.2, "\s+;.*$")     ; 去掉行尾注释
        t := RegExReplace(t, "i)^\*i[ `t]+")  ; #Include *i FileName
        t := Trim(t, " `t")
        ; 参数允许用单/双引号包起来（文档明确允许），先剥掉再判断
        ; 注意 SubStr 的负长度是"省略末尾 N 个字符"，剥一层引号用 -1
        if (t != "") {
            first := SubStr(t, 1, 1)
            if ((first = Chr(34) || first = "'") && SubStr(t, -1) = first) {
                t := SubStr(t, 2, -1)
            }
        }
        t := ExpandIncludeVars(t, item)
        if (t = "" || InStr(t, "<") = 1 || InStr(t, "%") = 1) {
            continue                          ; <Lib> 与仍含未支持变量的写法交给 AHK 自己解析
        }
        targets.Push(t)
    }
    return targets
}

; 展开 #Include 里允许使用的内建变量（挑文档列出、实际会用到的那些）
ExpandIncludeVars(target, item) {
    if (!InStr(target, "%")) {
        return target
    }
    scriptDir := A_ScriptDir "\scripts"
    if (item.folder != "") {
        scriptDir .= "\" item.folder
    }
    vars := Map(
        "A_ScriptDir", scriptDir,
        "A_LineFile", ScriptPath(item.relPath),
        "A_WorkingDir", A_WorkingDir,
        "A_AppData", A_AppData,
        "A_MyDocuments", A_MyDocuments,
        "A_ProgramFiles", A_ProgramFiles,
        "A_Temp", A_Temp,
        "A_WinDir", A_WinDir
    )
    for name, value in vars {
        target := StrReplace(target, "%" name "%", value)
    }
    return target
}

; 解析 #Include 的目标，返回命中的绝对路径数组。
; 绝对路径直接用；相对路径先按「引用者所在目录」找（文档规定的默认基准），再退回 scripts 根目录与程序目录。
; 注意：AHK v2 里 #Include 跟目录名只是「改变后续 #Include / FileInstall 的基准目录」，
; 并不包含该目录下的文件（那是 v1 的行为），所以这里不做目录展开 ——
; 否则会把 AHK 其实从未包含的文件也一并隐藏掉。
ResolveIncludePath(target, item) {
    candidates := Array()
    if IsAbsolutePath(target) {
        candidates.Push(target)
    } else {
        if (item.folder != "") {
            candidates.Push(A_ScriptDir "\scripts\" item.folder "\" target)
        }
        candidates.Push(A_ScriptDir "\scripts\" target)
        candidates.Push(A_ScriptDir "\" target)
    }

    hits := Array()
    for , candidate in candidates {
        ; FileExist 对目录也返回非空（"D"），所以要显式排掉目录
        if (FileExist(candidate) && !DirExist(candidate)) {
            hits.Push(candidate)
            Break                                 ; 按优先级取第一个命中的基准路径
        }
    }
    return hits
}

; 按子目录把脚本整理成菜单树：{ Folders: Map(文件夹名 → 子节点), Items: Array(脚本项) }
BuildMenuTree(list) {
    root := NewMenuNode()
    for , id in list {
        scriptItem := scriptMap[id]
        node := root
        if (scriptItem.folder != "") {
            for , segment in StrSplit(scriptItem.folder, "\") {
                if (!node.Folders.Has(segment)) {
                    node.Folders[segment] := NewMenuNode()
                }
                node := node.Folders[segment]
            }
        }
        node.Items.Push(scriptItem)
    }
    return root
}

NewMenuNode() {
    node := Object()
    node.Folders := Map()
    node.Items := Array()
    return node
}

; 生成菜单标签。同层里脚本显示名与文件夹名、或与另一个脚本的显示名撞车时，
; 补上相对路径，保证任何层级的同名脚本都能区分。
MenuLabel(nodeFolders, usedLabels, scriptItem) {
    label := scriptItem.displayName
    if (nodeFolders.Has(label) || usedLabels.Has(label)) {
        label := label . "  (" . scriptItem.relPath . ")"
    }
    return label
}

; --------------------- FUNCTION --------------------------

; 给定进程PID，获取其内存消耗
GetProcessMemoryInfo(PID) {
    size := 440
    pmcex := Buffer(size, 0) ; V1toV2: if 'pmcex' is a UTF-16 string, use 'VarSetStrCapacity(&pmcex, size)'
    ret := ""

    hProcess := DllCall("OpenProcess", "UInt", 0x400 | 0x0010, "Int", 0, "Ptr", PID, "Ptr")
    if (hProcess) {
        if (DllCall("psapi.dll\GetProcessMemoryInfo", "Ptr", hProcess, "Ptr", pmcex, "UInt", size))
            ret := NumGet(pmcex, (A_PtrSize = 8 ? "16" : "12"), "UInt") / 1024 . " K"
        DllCall("CloseHandle", "Ptr", hProcess)
    }
    return ret
}
