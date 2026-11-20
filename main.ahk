#Requires AutoHotkey v2.0
#SingleInstance Force
#Include lib\json.ahk
#Include lib\clipboard.ahk
#Include lib\http.ahk
#Include lib\ui.ahk
#Include pipeline.ahk

; ---------- Typed markers (only active inside the editors listed here) ----------
; To add an editor: Task Manager -> Details tab -> copy its .exe name.
EditorActive(*) {
    static editors := ["Code.exe", "Cursor.exe", "notepad++.exe", "sublime_text.exe", "notepad.exe"]
    for exe in editors {
        if WinActive("ahk_exe " exe)
            return true
    }
    return false
}

HotIf(EditorActive)
Hotstring(":*?:;;go",    (*) => RunGenerate())
Hotstring(":*?:;;plan",  (*) => RunPlan())
Hotstring(":*?:;;next",  (*) => RunFill(false))
Hotstring(":*?:;;fill",  (*) => RunFill(true))
Hotstring(":*?:;;ask",   (*) => RunFreeform())
Hotstring(":*?:;;paste", (*) => PasteLastResponse())
Hotstring(":*?:;;fix",   (*) => MarkerFix())
Hotstring(":*?:;;refactor", (*) => RunSelectionMode("refactor"))
Hotstring(":*?:;;explain",  (*) => RunSelectionMode("explain"))
Hotstring(":*?:;;tests",    (*) => RunSelectionMode("add_tests"))
HotIf()

; ---------- Hotkeys ----------
^!f::     RunSelectionMode("fix")
^!r::     RunSelectionMode("refactor")
^!e::     RunSelectionMode("explain")
^+!t::    RunSelectionMode("add_tests")
^!g::     RunGenerate()
^!l::     RunPlan()
^!n::     RunFill(false)
^!a::     RunFill(true)
^!x:: {
    StopFilling()
    AbortRequest := true
}
^!Space:: RunFreeform()
^!v::     PasteLastResponse()

; ---------- Temp test hotkeys (remove later) ----------
^!t:: {
    sel := CaptureSelection()
    RestoreClipboard()
    ToolTip(sel = "" ? "Nothing selected" : "Captured (" StrLen(sel) " chars):`n" SubStr(sel, 1, 200))
    SetTimer(() => ToolTip(), -3000)
}
^!p:: PasteText("// pasted by ai-coder`n")
^!h:: {
    r := SendRequest(Map("system", "You are a concise coding assistant.", "user", "Reply with exactly: round-trip OK"))
    MsgBox(r.error != "" ? "ERROR: " r.error : "RESPONSE: " r.text)
}