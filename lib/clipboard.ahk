#Requires AutoHotkey v2.0

; Holds the user's original clipboard between Capture and Restore
global SavedClip := ""

; Copies the current selection and returns it as text.
; Returns "" if nothing was selected / copy failed.
CaptureSelection(timeout := 1) {
    global SavedClip
    SavedClip := ClipboardAll()   ; snapshot everything (text, images, files)
    A_Clipboard := ""             ; clear so we can detect a failed copy
    Send("^c")
    if !ClipWait(timeout) {
        RestoreClipboard()
        return ""
    }
    text := A_Clipboard
    if Trim(text, "`r`n `t") = ""
        return ""
    return text
}

; Grabs the current line (for Generate mode: the comment the user just typed)
CaptureCurrentLine(timeout := 1) {
    global SavedClip
    SavedClip := ClipboardAll()
    A_Clipboard := ""
    Send("{End}+{Home}+{Home}")   ; select whole line from column 0 (second Home beats VS Code's smart-Home)
    Send("^c")
    if !ClipWait(timeout) {
        RestoreClipboard()
        return ""
    }
    text := A_Clipboard
    if Trim(text, "`r`n `t") = ""
        return ""
    return text
}

; Puts the user's original clipboard back
RestoreClipboard() {
    global SavedClip
    if SavedClip != "" {
        A_Clipboard := SavedClip
        SavedClip := ""
    }
}

; Inserts text at the cursor via clipboard paste (fast, handles multi-line + indentation)
; Preserves the user's clipboard around the paste.
PasteText(text) {
    backup := ClipboardAll()
    A_Clipboard := text
    ClipWait(1)
    Send("^v")
    Sleep(150)                    ; let the target app read the clipboard BEFORE we restore
    A_Clipboard := backup
}

; Copies everything from the start of the document to the caret.
; The caret must already be collapsed at the end of the current line.
; Leaves the caret where it was. Returns "" on failure.
CaptureAboveCursor(timeout := 1) {
    A_Clipboard := ""
    Send("^+{Home}")
    Send("^c")
    ok := ClipWait(timeout)
    Send("{Right}")          ; collapse the selection back to the end of the line
    return ok ? A_Clipboard : ""
}

; Copies from the caret to the end of the document, then puts the caret back.
; Restores the user's clipboard itself.
CaptureBelowCursor(timeout := 1) {
    backup := ClipboardAll()
    A_Clipboard := ""
    Send("^+{End}")
    Send("^c")
    ok := ClipWait(timeout)
    Send("{Left}")                 ; collapse the selection back to where it started
    text := ok ? A_Clipboard : ""
    A_Clipboard := backup
    return text
}