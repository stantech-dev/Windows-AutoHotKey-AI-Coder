#Requires AutoHotkey v2.0

global Busy := false

; Mode B: capture selection -> prompt -> API -> apply result to selection
RunSelectionMode(mode) {
    global Busy
    if Busy {
        ShowStatus("Still working on the previous request...")
        SetTimer(() => ToolTip(), -1500)
        return
    }
    Busy := true
    try {
        selection := CaptureSelection()
        RestoreClipboard()
        if selection = "" {
            ShowError("Nothing selected", mode)
            return
        }

        ; Guard: refuse oversized input before spending a request
        maxChars := Integer(IniRead(A_ScriptDir "\config.ini", "api", "max_input_chars", "12000"))
        if StrLen(selection) > maxChars {
            ShowError("Selection too large (" StrLen(selection) " chars, limit " maxChars "). Select a smaller block, e.g. one function.", mode)
            return
        }

        prompt := BuildPrompt(mode, selection, DetectLang())
        if !prompt {
            ShowError("No template '" mode "' in prompts.ini", mode)
            return
        }

        winBefore := WinExist("A")
        ShowStatus("Thinking...")
        response := SendRequest(prompt)
        ClearStatus()

        if response.error != "" {
            ShowError(response.error, mode)
            return
        }

        ; Guard: a cut-off reply must never touch the file
        if response.HasProp("truncated") && response.truncated {
            ShowError("Response was cut off (hit max_tokens) - nothing changed", mode)
            return
        }

        switch mode {
            case "fix", "refactor":
                result := ApplyEditBlocks(selection, response.text)
                if result.error != "" {
                    ShowError(result.error, mode)
                    Log(mode, "Model reply was: " SubStr(response.text, 1, 500))
                    return
                }
                if result.count = 0 {
                    ShowStatus("No changes needed")
                    SetTimer(() => ToolTip(), -1500)
                    Log(mode, "NO_CHANGES")
                    return
                }
                restoreTo := 0
                if !ClaimWindow(winBefore, &restoreTo) {
                    A_Clipboard := result.text
                    ShowError("Editor window closed - result copied to clipboard instead", mode)
                    return
                }
                PasteText(result.text)   ; selection is still active, so paste replaces it
                ReleaseWindow(restoreTo)
                Log(mode, "OK " result.count " edit(s) via " LastModelUsed ", " StrLen(selection) " -> " StrLen(result.text) " chars")
                ShowStatus("Done (" result.count " edit(s)) via " LastModelUsed)

            case "add_tests":
                tests := StripMarkdownFences(response.text)
                tests := RTrim(tests, "`r`n `t")
                if tests = "" {
                    ShowError("Model returned nothing usable", mode)
                    return
                }
                RegExMatch(selection, "^[ \t]*", &im)
                tests := IndentBlock(tests, im[0])
                restoreTo := 0
                if !ClaimWindow(winBefore, &restoreTo) {
                    A_Clipboard := tests
                    ShowError("Editor window closed - result copied to clipboard instead", mode)
                    return
                }
                Send("{End}")                          ; collapse selection to the end of the selected block
                PasteText("`n`n" tests)
                ReleaseWindow(restoreTo)
                Log(mode, "OK via " LastModelUsed ", " StrLen(selection) " chars in, " StrLen(tests) " out")
                ShowStatus("Tests added via " LastModelUsed)

            case "explain":
                restoreTo := 0
                ClaimWindow(winBefore, &restoreTo)     ; best-effort only; explain never writes to the file
                Log(mode, "OK via " LastModelUsed ", " StrLen(selection) " chars in")
                ShowAnswerWindow(response.text, "Explain - " LastModelUsed)
                ReleaseWindow(restoreTo)
        }
        SetTimer(() => ToolTip(), -1500)
    } finally {
        Busy := false
    }
}

BuildPrompt(template, context, lang := "") {
    f := A_ScriptDir "\prompts.ini"
    sys := IniRead(f, template, "system", "")
    ins := IniRead(f, template, "instruction", "")
    if sys = "" || ins = ""
        return ""
    sys := StrReplace(sys, "\n", "`n")
    ins := StrReplace(ins, "\n", "`n")
    if lang != ""
        sys .= "`nThe code comes from a file with extension ." lang "."
    return Map("system", sys, "user", ins "`n`n" context)
}

; Stub: guess the language from the file extension in the active window title
DetectLang() {
    title := WinGetTitle("A")
    if RegExMatch(title, "i)\.(py|js|ts|jsx|tsx|ahk|html|css|java|cs|cpp|c|go|rs|php|rb|sh|sql|json)\b", &m)
        return m[1]
    return ""
}

; Applies SEARCH/REPLACE blocks to `original`. All-or-nothing.
; Returns {text, error, count}
ApplyEditBlocks(original, reply) {
    eol := InStr(original, "`r`n") ? "`r`n" : "`n"
    src := StrSplit(StrReplace(original, "`r`n", "`n"), "`n")
    reply := StrReplace(reply, "`r`n", "`n")

    if Trim(reply, "`n `t") = "NO_CHANGES"
        return {text: "", error: "", count: 0}

    pos := 1
    count := 0
    while RegExMatch(reply, "s)<<<<<<<[ \t]*SEARCH[ \t]*\n(.*?)\n=======[ \t]*\n(.*?)\n?>>>>>>>[ \t]*REPLACE", &m, pos) {
        pos := m.Pos + m.Len
        count++
        if m[1] = ""
            return {text: "", error: "Edit " count " has an empty SEARCH block", count: count}
        sLines := StrSplit(m[1], "`n")
        rLines := (m[2] = "") ? [] : StrSplit(m[2], "`n")

        idx := FindLines(src, sLines)
        if idx = 0
            return {text: "", error: "Edit " count " doesn't match your code - nothing changed", count: count}
        if idx = -1
            return {text: "", error: "Edit " count " matches several places - nothing changed", count: count}

        newSrc := []
        loop idx - 1
            newSrc.Push(src[A_Index])
        for l in rLines
            newSrc.Push(l)
        tail := idx + sLines.Length - 1
        loop src.Length - tail
            newSrc.Push(src[tail + A_Index])
        src := newSrc
    }

    if count = 0
        return {text: "", error: "Model reply had no valid edit blocks - nothing changed", count: 0}

    out := ""
    for i, l in src
        out .= (i > 1 ? eol : "") l
    return {text: out, error: "", count: count}
}

; Finds `needle` (array of lines) in `src`, ignoring trailing whitespace.
; Returns start index, 0 if not found, -1 if it matches more than once.
FindLines(src, needle) {
    n := needle.Length
    found := 0
    i := 1
    while i + n - 1 <= src.Length {
        ok := true
        loop n {
            if RTrim(src[i + A_Index - 1]) != RTrim(needle[A_Index]) {
                ok := false
                break
            }
        }
        if ok {
            if found
                return -1
            found := i
        }
        i++
    }
    return found
}

; Used by later modes (generate, tests) that insert raw code
StripMarkdownFences(text) {
    text := Trim(text, "`r`n")
    if RegExMatch(text, "s)``````[^\r\n]*\R(.*?)\R?``````", &m)
        return m[1]
    return text
}

global LastResponse := ""

; Sends a prompt with status/error/truncation handling.
; Returns the reply text, or "" on failure (the error is already shown).
AskModel(mode, prompt) {
    ShowStatus("Thinking...")
    response := SendRequest(prompt)
    ClearStatus()
    if response.error != "" {
        ShowError(response.error, mode)
        return ""
    }
    if response.HasProp("truncated") && response.truncated {
        ShowError("Response was cut off (hit max_tokens) - nothing inserted", mode)
        return ""
    }
    return response.text
}


; Mode C: ad-hoc question via popup -> answer in a window
RunFreeform() {
    global Busy, LastResponse
    if Busy {
        ShowStatus("Still working on the previous request...")
        SetTimer(() => ToolTip(), -1500)
        return
    }
    Busy := true
    try {
        ib := InputBox("Ask the AI coder:", "AI Coder", "w520 h140")
        if ib.Result != "OK" || Trim(ib.Value) = ""
            return

        prompt := BuildPrompt("freeform", Trim(ib.Value))
        if !prompt {
            ShowError("No template 'freeform' in prompts.ini", "freeform")
            return
        }

        reply := AskModel("freeform", prompt)
        if reply = ""
            return

        LastResponse := reply
        Log("freeform", "OK via " LastModelUsed ", " StrLen(reply) " chars")
        ShowAnswerWindow(reply, "AI Coder - " LastModelUsed)
    } finally {
        Busy := false
    }
}

; Pastes the last freeform answer (just the code block if there is one)
PasteLastResponse() {
    global LastResponse
    if LastResponse = "" {
        ShowError("No previous response to paste", "freeform")
        return
    }
    PasteText(StripMarkdownFences(LastResponse))
}

IndentBlock(text, indent) {
    if indent = ""
        return text
    out := ""
    for i, l in StrSplit(StrReplace(text, "`r`n", "`n"), "`n")
        out .= (i > 1 ? "`n" : "") (l = "" ? "" : indent l)
    return out
}

; Keeps the start of the file (imports/setup) plus the most recent code if the text is too long
TrimContext(text, maxChars := 8000, headChars := 1500) {
    if StrLen(text) <= maxChars
        return text
    return SubStr(text, 1, headChars) "`n... (middle of file omitted) ...`n" SubStr(text, -(maxChars - headChars))
}

global StopFill := false

; ---------- Mode A core: returns true on success, never touches the Busy flag ----------
GenerateCore() {
    line := CaptureCurrentLine()
    if line = "" {
        RestoreClipboard()
        ShowError("Nothing to generate from (write a comment on this line first)", "generate")
        return false
    }
    RegExMatch(line, "^[ \t]*", &im)
    indent := im[0]

    ; a pending ;;go tag (from Plan) is not part of the request; remember it so we can remove it afterwards
    tag := ""
    if RegExMatch(line, "[ \t]*;;go[ \t]*$", &tm)
        tag := tm[0]
    comment := Trim(RegExReplace(line, "[ \t]*;;go[ \t]*$", ""), " `t`r`n")
    if comment = "" {
        RestoreClipboard()
        ShowError("Nothing to generate from (only a marker on this line)", "generate")
        return false
    }

    Send("{End}")                              ; collapse the selection to the end of the comment line
    above := CaptureAboveCursor()              ; whole file down to the comment
    RestoreClipboard()
    if above = ""
        above := comment
    above := RegExReplace(above, "[ \t]*;;go[ \t]*$", "")
    ctxMax := Integer(IniRead(A_ScriptDir "\config.ini", "api", "context_chars", "8000"))

    prompt := BuildPrompt("generate", TrimContext(above, ctxMax), DetectLang())
    if !prompt {
        ShowError("No template 'generate' in prompts.ini", "generate")
        return false
    }

    winBefore := WinExist("A")
    reply := AskModel("generate", prompt)
    if reply = ""
        return false
    code := StripMarkdownFences(reply)
    code := RegExReplace(code, "^\s*\n", "")
    code := RTrim(code, "`r`n `t")
    if code = "" {
        ShowError("Model returned nothing usable", "generate")
        return false
    }

    code := IndentBlock(code, indent)
    restoreTo := 0
    if !ClaimWindow(winBefore, &restoreTo) {
        A_Clipboard := code
        ShowError("Editor window closed - result copied to clipboard instead", "generate")
        return false
    }
    Send("{End}")
    if tag != ""
        Send("{BackSpace " StrLen(tag) "}")
    PasteText("`n" code)
    ReleaseWindow(restoreTo)
    Log("generate", "OK via " LastModelUsed ", " StrLen(comment) " chars in, " StrLen(code) " out")
    ShowStatus("Done via " LastModelUsed)
    SetTimer(() => ToolTip(), -1200)
    return true
}

RunGenerate() {
    global Busy
    if Busy {
        ShowStatus("Still working on the previous request...")
        SetTimer(() => ToolTip(), -1500)
        return
    }
    Busy := true
    try {
        GenerateCore()
    } finally {
        Busy := false
    }
}

; ---------- Plan: goal comment -> tagged comment skeleton ----------
RunPlan() {
    global Busy
    if Busy {
        ShowStatus("Still working on the previous request...")
        SetTimer(() => ToolTip(), -1500)
        return
    }
    Busy := true
    try {
        line := CaptureCurrentLine()
        if line = "" {
            RestoreClipboard()
            ShowError("Write the goal as a comment on this line first", "plan")
            return
        }
        RegExMatch(line, "^[ \t]*", &im)
        indent := im[0]
        leader := "//"                                   ; reuse the comment style the user already typed
        if RegExMatch(line, "^[ \t]*(//|#|--|;|%)", &lm)
            leader := lm[1]

        Send("{End}")
        above := CaptureAboveCursor()
        RestoreClipboard()
        if above = ""
            above := Trim(line)
        ctxMax := Integer(IniRead(A_ScriptDir "\config.ini", "api", "context_chars", "8000"))

        prompt := BuildPrompt("plan", TrimContext(above, ctxMax), DetectLang())
        if !prompt {
            ShowError("No template 'plan' in prompts.ini", "plan")
            return
        }

        winBefore := WinExist("A")
        reply := AskModel("plan", prompt)
        if reply = ""
            return

        steps := []
        for raw in StrSplit(StrReplace(reply, "`r`n", "`n"), "`n") {
            t := Trim(raw, " `t`r")
            if RegExMatch(t, "i)^STEP:\s*(.+)$", &m)
                steps.Push({text: Trim(m[1]), fire: true})
            else if RegExMatch(t, "i)^NOTE:\s*(.+)$", &m)
                steps.Push({text: Trim(m[1]), fire: false})
        }
        if steps.Length = 0 {
            ShowError("Plan had no STEP lines - see state\log.txt", "plan")
            Log("plan", "Model reply was: " SubStr(reply, 1, 500))
            return
        }
        if steps.Length > 12
            steps.Length := 12

        skeleton := ""
        for i, s in steps
            skeleton .= (i > 1 ? "`n`n" : "") indent leader " " s.text (s.fire ? " `;`;go" : "")

        restoreTo := 0
        if !ClaimWindow(winBefore, &restoreTo) {
            A_Clipboard := skeleton
            ShowError("Editor window closed - result copied to clipboard instead", "plan")
            return
        }
        Send("{End}")
        PasteText("`n`n" skeleton)                      ; inserted via paste, so the tags stay inert
        Send("{Up " (2 * steps.Length) "}{End}")        ; caret back on the goal line, ready for ;;next / ;;fill
        ReleaseWindow(restoreTo)
        Log("plan", "OK via " LastModelUsed ", " steps.Length " steps")
        ShowStatus("Plan ready (" steps.Length " steps). Use `;`;next or `;`;fill")
        SetTimer(() => ToolTip(), -2500)
    } finally {
        Busy := false
    }
}

; ---------- Fill: find tagged comments and generate them ----------
; Moves the caret to the end of the first line (current line included) that ends with ;;go.
; Returns how many tagged lines exist from here down (0 = none, caret unmoved).
GotoNextMarker() {
    Send("{Home}")
    below := CaptureBelowCursor()
    RestoreClipboard()
    if below = ""
        return 0
    lines := StrSplit(StrReplace(below, "`r`n", "`n"), "`n")
    first := 0
    total := 0
    for i, l in lines {
        if RegExMatch(l, ";;go[ \t]*$") {
            total++
            if !first
                first := i
        }
    }
    if !first
        return 0
    if first > 1
        Send("{Down " (first - 1) "}")
    Send("{End}")
    return total
}

RunFill(all := true) {
    global Busy, StopFill
    if Busy {
        ShowStatus("Still working on the previous request...")
        SetTimer(() => ToolTip(), -1500)
        return
    }
    Busy := true
    StopFill := false
    target := WinExist("A")
    done := 0
    failed := false
    try {
        loop 15 {                                       ; hard cap per run
            if StopFill
                break
            if !WinExist("ahk_id " target) {
                ShowError("Editor window closed - stopping", "fill")
                break
            }
            if WinExist("A") != target {
                WinActivate("ahk_id " target)
                if !WinWaitActive("ahk_id " target, , 2)
                    break
                Sleep(100)
            }
            if GotoNextMarker() = 0 {
                if done = 0
                    ShowError("No `;`;go comments found at or below the cursor", "fill")
                break
            }
            if !GenerateCore() {
                failed := true
                break
            }
            done++
            if !all
                break
            Sleep(1500)                                 ; breathing room for rate limits
        }
    } finally {
        Busy := false
    }
    if done > 0 && !failed {
        ShowStatus("Filled " done " step(s)" (StopFill ? " - stopped" : ""))
        SetTimer(() => ToolTip(), -2500)
    }
}

StopFilling() {
    global StopFill
    StopFill := true
    ShowStatus("Stopping after the current step...")
    SetTimer(() => ToolTip(), -1500)
}

; ---------- ;;fix typed on its own line: fix the block of code directly above ----------
; Selects the contiguous non-blank block above the caret (skipping blank lines directly above).
; Returns the number of lines in the block, 0 if there is none or the marker line isn't empty.
SelectBlockAbove(maxLines := 80) {
    above := CaptureAboveCursor()
    RestoreClipboard()
    if above = ""
        return 0
    lines := StrSplit(StrReplace(above, "`r`n", "`n"), "`n")
    if Trim(lines[lines.Length]) != ""
        return 0                                        ; the marker must be on its own line
    i := lines.Length - 1
    gap := 0
    while i >= 1 && Trim(lines[i]) = "" {
        gap++
        i--
    }
    n := 0
    while i >= 1 && Trim(lines[i]) != "" && n < maxLines {
        n++
        i--
    }
    if n = 0
        return 0
    Send("{Up " (gap + 1) "}{End}")                     ; end of the last code line
    if i >= 1
        Send("+{Up " n "}+{End}")                       ; select upward to the end of the line above the block
    else
        Send("+^{Home}")                                ; block starts at the top of the file
    return n
}

MarkerFix() {
    global Busy
    if Busy {
        ShowStatus("Still working on the previous request...")
        SetTimer(() => ToolTip(), -1500)
        return
    }
    if SelectBlockAbove() = 0 {
        ShowError("Put `;`;fix on its own line right below the code (it fixes the block above, up to the previous blank line)", "fix")
        return
    }
    RunSelectionMode("fix")
}

; Re-focuses winTarget if something else is now active, remembering what was
; active so the caller can switch back afterwards. False if winTarget is gone.
ClaimWindow(winTarget, &restoreTo) {
    restoreTo := WinExist("A")
    if !WinExist("ahk_id " winTarget)
        return false
    if restoreTo != winTarget {
        WinActivate("ahk_id " winTarget)
        if !WinWaitActive("ahk_id " winTarget, , 2)
            return false
        Sleep(100)
    }
    return true
}

; Switches focus back to whatever was active before ClaimWindow, if it still exists
ReleaseWindow(restoreTo) {
    if restoreTo && WinExist("ahk_id " restoreTo)
        WinActivate("ahk_id " restoreTo)
}
