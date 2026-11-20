#Requires AutoHotkey v2.0

ShowStatus(text) {
    ToolTip(text)
}

ClearStatus() {
    ToolTip()
}

ShowError(text, mode := "") {
    ToolTip("[!] " text)
    SetTimer(() => ToolTip(), -4000)
    Log(mode, "ERROR: " text)
}

Log(mode, msg) {
    DirCreate(A_ScriptDir "\state")
    line := FormatTime(, "yyyy-MM-dd HH:mm:ss") " [" mode "] " msg "`n"
    FileAppend(line, A_ScriptDir "\state\log.txt", "UTF-8")
}

global AnswerGui := ""

; Shows long text in a window: selectable, Copy button, Esc or Close to dismiss
ShowAnswerWindow(text, title := "AI Coder") {
    global AnswerGui
    if IsObject(AnswerGui)
        try AnswerGui.Destroy()

    g := Gui("+AlwaysOnTop", title)
    g.MarginX := 12, g.MarginY := 12
    g.SetFont("s10", "Consolas")
    g.AddEdit("w820 h460 ReadOnly VScroll", StrReplace(StrReplace(text, "`r`n", "`n"), "`n", "`r`n"))
    g.SetFont("s9", "Segoe UI")
    g.AddButton("w90", "Copy").OnEvent("Click", (*) => CopyAnswer(text))
    g.AddButton("x+10 w90 Default", "Close").OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    g.OnEvent("Close", (*) => g.Destroy())
    g.Show()
    AnswerGui := g
}

CopyAnswer(text) {
    A_Clipboard := text
    ToolTip("Copied")
    SetTimer(() => ToolTip(), -800)
}