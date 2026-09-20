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
;@Ahk2Exe-SetVersion 0.0.1
;@Ahk2Exe-SetCopyright Jacques Yip (2022-2023) / modified by wfwuestc (2026)
;@Ahk2Exe-SetOrigFilename AHK2ManagerEx.exe
;@Ahk2Exe-SetMainIcon icons\main_light.ico
;@Ahk2Exe-AddResource icons\main_dark.ico, 160
; --------------------- GLOBAL --------------------------

#Requires AutoHotkey >=v2.0

#Include <Array>
#Include <WindowsTheme>
#Include <JSON>
#Include <ConfMan>

SetWorkingDir A_ScriptDir
#SingleInstance Force
SetTitleMatchMode 1
DetectHiddenWindows 1
FileEncoding "UTF-8-RAW"

FolderCheckList := ["lang", "scripts", "icons", "lib"]
for item in FolderCheckList
    If !FileExist(A_ScriptDir "\" item) {
        DirCreate(A_ScriptDir "\" item)
    }

FileInstall(".\lang\en_us.ini", ".\lang\en_us.ini", 1)
FileInstall(".\lang\zh_cn.ini", ".\lang\zh_cn.ini", 1)

Paths := EnvGet("PATH")
EnvSet("PATH", A_ScriptDir "\bin`;" Paths)
SplitPath A_ScriptName, , , , &appName

global sysThemeMode := RegRead("HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize", "SystemUsesLightTheme")

global CONF_PATH := A_ScriptDir "\setting.ini"
CONF := ConfMan.GetConf(CONF_PATH)
CONF.Setting := {
    language: "en_us",
    mode: 0
}
CONF.SCRIPTS := {}
CONF.COUNTSDAEMON := {}
CONF.COUNTSONCE := {}
CONF.COUNTSTEMP := {}
CONF.Setting.SetOpts("PARAMS")
CONF.COUNTSDAEMON.SetOpts("PARAMS")
CONF.COUNTSONCE.SetOpts("PARAMS")
CONF.COUNTSTEMP.SetOpts("PARAMS")
CONF.SCRIPTS.SetOpts("PARAMS")

If !FileExist(CONF_Path) {
    FileAppend "", CONF_Path
}
If (FileRead(CONF_Path) = "") {
    CONF.WriteFile()
}
CONF.ReadFile()

If !FileExist(A_ScriptDir "\lang") {
    DirCreate(A_ScriptDir "\lang")
}

If (A_IsCompiled = 1) {
    FileInstall(".\lang\en_us.ini", "lang\en_us.ini", 1)
    FileInstall(".\lang\zh_cn.ini", "lang\zh_cn.ini", 1)
}

global typeEnum := Map("ONCE", 0, "TEMP", 1, "DAEMON", 2)

; global scriptList := Array()
; scriptMap 的键是脚本的唯一 ID：相对 scripts 目录的路径去掉 .ahk
; 例如根目录的 "Obsidian"、子目录的 "EverythingToolbar\Everything_Toolbar"
global scriptMap := Map()

; 被判定为「附加脚本」的清单（被 #Include 引用、或文件名以 _ 开头），只在菜单里做只读展示
global ignoredScriptList := Array()
global ignoredMenu := Menu()

unOpenScriptListTemp := Array()
unOpenScriptListOnce := Array()
unOpenScriptListDaemon := Array()

OpenScriptListTemp := Array()
OpenScriptListDaemon := Array()

global langMenu := Menu()
global startMenu := Menu()
global restartMenu := Menu()
global closeMenu := Menu()

WindowsTheme.SetAppMode(!sysThemeMode)

if (A_Args.Length > 0) {
    switch A_Args[1], false {
        case "mode":
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

Persistent
Return

; --------------------- SHORTCUTS --------------------------

; Ctrl + Alt + LButton, 启动
^!LButton:: {
    startMenu.Show
    Return
}

; Ctrl + Alt + RButton, 关闭
^!RButton:: {
    closeMenu.Show
    Return
}

; Ctrl + Alt + MButton, 重启
^!MButton:: {
    restartMenu.Show
    Return
}

; Win + Shift + R, 重新加载
#+r:: ReloadTray

; --------------------- MENU EVENT RESPONSE --------------------------
LoadScript(mode) {
    global
    scripts := ScanScripts()

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
            if (!(DetectConfig("SCRIPTS", scriptItem.id))) {
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
            try CONF.COUNTSDAEMON.Delete(scriptName)
            try CONF.COUNTSONCE.Delete(scriptName)
            try CONF.COUNTSTEMP.Delete(scriptName)
        }

        for scriptName, scriptType in CONF.SCRIPTS {
            if (!known.Has(scriptName) || known[scriptName].isIgnore) {
                continue
            }
            scriptItem := known[scriptName]
            scriptTypeNum := scriptType + 0
            running := IsScriptRunning(scriptItem.relPath, scriptItem.fileName)

            if (scriptTypeNum = typeEnum["DAEMON"]) {
                if (!(DetectConfig("COUNTSDAEMON", scriptName))) {
                    once := IniRead(CONF_PATH, "COUNTSONCE", scriptName, 0)
                    temp := IniRead(CONF_PATH, "COUNTSTEMP", scriptName, 0)
                    CONF.COUNTSDAEMON.%scriptName% := (once > temp) ? once : temp
                }
                if (IniRead(CONF_PATH, "COUNTSONCE", scriptName, -1) >= 0) {
                    CONF.COUNTSONCE.Delete(scriptName)
                }
                if (IniRead(CONF_PATH, "COUNTSTEMP", scriptName, -1) >= 0) {
                    CONF.COUNTSTEMP.Delete(scriptName)
                }
                CreateTaskInfo(scriptItem.id, scriptItem.relPath, scriptItem.folder, scriptItem.displayName, scriptTypeNum, running, A_Index)
            } else if (scriptTypeNum = typeEnum["TEMP"]) {
                if (!(DetectConfig("COUNTSTEMP", scriptName))) {
                    daemon := IniRead(CONF_PATH, "COUNTSDAEMON", scriptName, 0)
                    once := IniRead(CONF_PATH, "COUNTSONCE", scriptName, 0)
                    CONF.COUNTSTEMP.%scriptName% := (daemon > once) ? daemon : once
                }
                if (IniRead(CONF_PATH, "COUNTSDAEMON", scriptName, -1) >= 0) {
                    CONF.COUNTSDAEMON.Delete(scriptName)
                }
                if (IniRead(CONF_PATH, "COUNTSONCE", scriptName, -1) >= 0) {
                    CONF.COUNTSONCE.Delete(scriptName)
                }
                CreateTaskInfo(scriptItem.id, scriptItem.relPath, scriptItem.folder, scriptItem.displayName, scriptTypeNum, running, A_Index)
            } else {
                if (!(DetectConfig("COUNTSONCE", scriptName))) {
                    daemon := IniRead(CONF_PATH, "COUNTSDAEMON", scriptName, 0)
                    temp := IniRead(CONF_PATH, "COUNTSTEMP", scriptName, 0)
                    CONF.COUNTSONCE.%scriptName% := (daemon > temp) ? daemon : temp
                }
                if (IniRead(CONF_PATH, "COUNTSDAEMON", scriptName, -1) >= 0) {
                    CONF.COUNTSDAEMON.Delete(scriptName)
                }
                if (IniRead(CONF_PATH, "COUNTSTEMP", scriptName, -1) >= 0) {
                    CONF.COUNTSTEMP.Delete(scriptName)
                }
                ; ONCE 脚本正在运行时不出现在菜单里，沿用旧行为
                if (!running) {
                    CreateTaskInfo(scriptItem.id, scriptItem.relPath, scriptItem.folder, scriptItem.displayName, scriptTypeNum, 0, A_Index)
                }
            }
        }
        CONF.WriteFile()
    } else {
        ; 字符模式：! → TEMP，+ → ONCE，无前缀 → DAEMON。子目录里的脚本同样生效。
        for , scriptItem in scripts {
            if (scriptItem.isIgnore) {
                continue
            }
            CreateTaskInfo(scriptItem.id, scriptItem.relPath, scriptItem.folder, StripPrefix(scriptItem.displayName), ScriptTypeByPrefix(scriptItem.fileName), IsScriptRunning(scriptItem.relPath, scriptItem.fileName), A_Index)
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
    if (title := ScriptWindowTitle(scriptItem.relPath, scriptItem.fileName)) {
        WinClose(title)
    }
    RunScript(scriptItem.relPath)
    UpdateTaskStatus(id, 1)
    return
}

CloseTask(id, *) {
    scriptItem := scriptMap[id]
    if (title := ScriptWindowTitle(scriptItem.relPath, scriptItem.fileName)) {
        WinClose(title)
    }
    UpdateTaskStatus(id, 0)
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
            if (title := ScriptWindowTitle(scriptItem.relPath, scriptItem.fileName)) {
                WinClose(title)
            }
            UpdateTaskStatus(id, 0)
        }
    }
    RecreateMenu()
}

CreateTaskInfo(id, relPath, folder, displayName, type, status := 0, index := 0) {
    SplitPath relPath, &fileName
    scriptObj := Object()
    scriptObj.id := id
    scriptObj.relPath := relPath
    scriptObj.fileName := fileName
    scriptObj.folder := folder
    scriptObj.displayName := displayName
    scriptObj.scriptType := type
    scriptObj.status := status
    scriptObj.index := index
    scriptMap[id] := scriptObj
    return scriptObj
}

UpdateTaskStatus(id, status := 1) {
    if (scriptMap.Has(id)) {
        scriptMap[id].status := status
    }
}

ProManager(*) {
    WmiInfo := GetWMI("AutoHotkey.exe")
    ShowIndex := 0
    PMGui := Gui()
    WindowsTheme.SetWindowAttribute(PMGui, !sysThemeMode)
    PMGui.SetFont("s9", "Arial")
    PMLV := PMGui.Add("ListView", "x2 y0 w760 h500", [lGUIIndex, lGUIPid, lGUIScriptname, lGUIMemory])
    for id, scriptItem in scriptMap {
        If (scriptItem.status = 1) {
            title := ScriptWindowTitle(scriptItem.relPath, scriptItem.fileName)
            if (title = "") {
                continue
            }
            ShowIndex += 1
            try procId := WinGetPID(title)
            try memory := GetProcessMemoryInfo(procId)
            PMLV.Add(, ShowIndex, procId, scriptItem.relPath, memory)
        }
    }
    PMLV.ModifyCol()
    PMLV.ModifyCol(2, "Integer")
    PMLV.ModifyCol(3, "260")
    PMGui.Title := "Process List"
    WindowsTheme.SetWindowTheme(PMGui, !sysThemeMode)
    PMGui.Show
}

ShowTray(*) {
    A_TrayMenu.Show
}

Test(ItemName, ItemPos, MyMenu) {
    MsgBox("You selected" ItemName)
}

ChangeToSCMode(*) {
    prefixLen := StrLen(A_ScriptDir "\scripts\")
    Loop Files A_ScriptDir "\scripts\*.ahk", "R" {
        relPath := SubStr(A_LoopFilePath, prefixLen + 1)
        SplitPath relPath, &fileName, &folder, , &displayName
        id := (folder = "") ? displayName : folder "\" displayName
        menuName := StripPrefix(displayName)
        if (SubStr(fileName, 1, 1) = "!") {
            CONF.SCRIPTS.%id% := 1
            FileMove A_LoopFilePath, A_LoopFileDir . "\" menuName . ".ahk", true
            CONF.WriteFile()
        } else if (SubStr(fileName, 1, 1) = "+") {
            CONF.SCRIPTS.%id% := 0
            FileMove A_LoopFilePath, A_LoopFileDir . "\" menuName . ".ahk", true
            CONF.WriteFile()
        } else {
            if (!(DetectConfig("SCRIPTS", id))) {
                CONF.SCRIPTS.%id% := 2
            }
        }
    }
}

SwitchLanguage(ItemName, ItemPos, MyMenu) {
    CONF.Setting.language := ItemName
    InitialLanguage()
    CreateLangMenu()
    CreateTrayMenu()
    CreateMenu()
}

InitialLanguage(*) {
    LANG_PATH := A_ScriptDir "\lang\" CONF.Setting.language ".ini"

    global lTrayExit := IniRead(LANG_PATH, "Tray", "exit")
    global lTrayReload := IniRead(LANG_PATH, "Tray", "reload")
    global lTrayProcMan := IniRead(LANG_PATH, "Tray", "procman")
    global lTrayLang := IniRead(LANG_PATH, "Tray", "lang")
    global lTrayCloseAll := IniRead(LANG_PATH, "Tray", "closeall")
    global lTrayClose := IniRead(LANG_PATH, "Tray", "close")
    global lTrayRestart := IniRead(LANG_PATH, "Tray", "restart")
    global lTrayStart := IniRead(LANG_PATH, "Tray", "start")
    global lTrayIgnored := IniRead(LANG_PATH, "Tray", "ignored", "Ignored Scripts")

    global lGUIIndex := IniRead(LANG_PATH, "GUI", "index")
    global lGUIMemory := IniRead(LANG_PATH, "GUI", "memory")
    global lGUIPid := IniRead(LANG_PATH, "GUI", "pid")
    global lGUIScriptname := IniRead(LANG_PATH, "GUI", "scriptname")
}

ReloadTray(*) {
    CreateLangMenu()
    LoadScript(CONF.Setting.mode)
    CreateTrayMenu()
    CreateMenu()
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
    startMenu.Add(lTrayStart, Test)
    startMenu.ToggleEnable(lTrayStart)
    startMenu.Default := lTrayStart
    startMenu.Add

    closeMenu.Add(lTrayClose, Test)
    closeMenu.ToggleEnable(lTrayClose)
    closeMenu.Default := lTrayClose
    closeMenu.Add

    restartMenu.Add(lTrayRestart, Test)
    restartMenu.ToggleEnable(lTrayRestart)
    restartMenu.Default := lTrayRestart
    restartMenu.Add

    unOpenScriptListTemp := Array()
    unOpenScriptListOnce := Array()
    unOpenScriptListDaemon := Array()

    OpenScriptListTemp := Array()
    OpenScriptListDaemon := Array()


    for id, scriptItem in scriptMap {
        if (scriptItem.scriptType = typeEnum["ONCE"]) {
            unOpenScriptListOnce.Push(id)
        }
        if (scriptItem.scriptType = typeEnum["TEMP"]) {
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


AddMenuItem(list, status := 0, split := true, title := "") {
    if (list.Length < 1) {
        return
    }
    list.sort("C")
    tree := BuildMenuTree(list)

    if (status = 1) {
        if (title != "") {
            restartMenu.Add(title, Test)
            closeMenu.Add(title, Test)
        }
        AddMenuTree(tree, restartMenu, RestartTask)
        AddMenuTree(tree, closeMenu, CloseTask)
        if (split = true) {
            restartMenu.Add
            closeMenu.Add
        }
    } else {
        if (title != "") {
            startMenu.Add(title, Test)
        }
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

    ; 按显示名排序（与旧版 list.sort("C") 一致），中间的 tab 只作为同名时的兜底分隔
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
        ignoredMenu.Add(relPath, Test)
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
        try content := FileRead(ScriptPath(item.relPath), "UTF-8")
        catch {
            continue
        }
        Loop Parse content, "`n", "`r" {
            if !RegExMatch(A_LoopField, "i)^[ `t]*#Include(Again)?[ `t]+(.+?)[ `t]*$", &m) {
                continue
            }
            t := RegExReplace(m.2, "\s+;.*$")     ; 去掉行尾注释
            t := RegExReplace(t, "i)^\*i[ `t]+")  ; #Include *i FileName
            t := Trim(t, " `t`"")
            if (t = "" || InStr(t, "<") = 1 || InStr(t, "%") = 1) {
                continue                          ; <Lib> 与含变量的写法交给 AHK 自己解析，这里不处理
            }
            for , hit in ResolveIncludePath(t, item) {
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

; 解析 #Include 的目标，返回命中的绝对路径数组（目录形式会展开成多个文件）。
; 绝对路径直接用；相对路径先按「引用者所在目录」找，再退回 scripts 根目录与程序目录。
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
        if DirExist(candidate) {
            Loop Files RTrim(candidate, "\") "\*.ahk" {
                hits.Push(A_LoopFilePath)         ; #Include DirName\ 形式
            }
        } else if (FileExist(candidate) && !DirExist(candidate)) {
            hits.Push(candidate)
        }
        if (hits.Length > 0) {
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

; 给定进程名称，返回该进程的所有信息
GetWMI(ProcessName) {
    objWMI := ComObjGet("winmgmts:\\.\root\cimv2")    ; 连接到WMI服务
    StrSql := 'SELECT * FROM Win32_Process WHERE Name=""'
    StrSql .= ProcessName
    StrSql .= '""'
    Info := objWMI.ExecQuery(StrSql)
    Return Info
}

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
