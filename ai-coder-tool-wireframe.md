# AI Coder Automation Tool — Wireframe & Pseudocode

Design reference for a hotkey-triggered coding assistant. AHK (Windows) is the primary build target; a Linux-equivalent stack is included as an appendix for later.


---

## Core concept

AHK is the nervous system: it listens for triggers, grabs context, and moves text in/out. All the "intelligence" lives in a real AI model API call.

```
[TRIGGER] → [CONTEXT CAPTURE] → [PROMPT BUILD] → [API CALL] → [RESPONSE HANDLING/INSERT]
```

---

## Windows (AutoHotkey) — file layout

```
/ai-coder/
  main.ahk              ← hotkey bindings only, dispatches to pipeline.ahk
  pipeline.ahk          ← the 5-stage flow, mode-agnostic
  config.ini            ← API key, model name, hotkeys (gitignored)
  prompts.ini           ← per-mode system prompts + instruction templates
  state/
    last_clipboard.tmp  ← scratch file for clipboard restore logic
    log.txt             ← request/response log for debugging
  lib/
    http.ahk            ← BuildRequest(), SendRequest(), HandleTimeout()
    json.ahk            ← third-party parse/stringify
    clipboard.ahk        ← CaptureSelection(), RestoreClipboard()
    ui.ahk               ← ShowStatus(), ShowTooltip(), ShowError()
```

---

## Modes

### Mode A — Generate (cursor in empty space, comment → code)

```
ON HOTKEY (e.g. Ctrl+Alt+G):
    SelectCurrentLine()              // grab the comment line user just typed
    comment = CaptureViaClipboard()
    RestoreClipboard()

    IF comment is empty:
        ShowError("Nothing to generate from")
        RETURN

    prompt = BuildPrompt(template="generate", context=comment, lang=DetectLangFromFileExt())
    ShowStatus("Thinking...")

    response = SendRequest(prompt)   // blocking, with timeout

    IF response.error:
        ShowError(response.error)
        RETURN

    code = StripMarkdownFences(response.text)
    InsertAtCursor(code)
    ShowStatus("Done")
```

### Mode B — Selection-based (explain / refactor / fix / add tests)

One hotkey per action, sharing the same skeleton — only the template name and insertion behavior differ.

```
ON HOTKEY (e.g. Ctrl+Alt+F for "fix"):
    selection = CaptureSelectionViaClipboard()
    RestoreClipboard()

    IF selection is empty:
        ShowError("Nothing selected")
        RETURN

    prompt = BuildPrompt(template="fix", context=selection, lang=DetectLangFromFileExt())
    ShowStatus("Thinking...")
    response = SendRequest(prompt)

    IF response.error:
        ShowError(response.error)
        RETURN

    SWITCH mode:
        CASE "fix", "refactor":
            code = StripMarkdownFences(response.text)
            ReplaceSelection(code)       // selection is still active: Send {Delete} then paste
        CASE "add_tests":
            code = StripMarkdownFences(response.text)
            InsertBelowSelection(code)   // don't overwrite original
        CASE "explain":
            ShowTooltip(response.text, duration=8000)   // never touches the file
```

### Mode C — Freeform (ad-hoc question via popup)

```
ON HOTKEY (e.g. Ctrl+Alt+Space):
    userInput = ShowInputBox("Ask the AI coder:")

    IF userInput is empty OR cancelled:
        RETURN

    prompt = BuildPrompt(template="freeform", context=userInput)
    ShowStatus("Thinking...")
    response = SendRequest(prompt)

    IF response.error:
        ShowError(response.error)
        RETURN

    ShowTooltip(response.text)   // freeform defaults to display-only, not insertion
    // optional: Ctrl+Alt+V = "paste last response" if they decide they want it in the file
```

---

## Shared sub-flows (used by all three modes)

```
FUNCTION CaptureSelectionViaClipboard():
    savedClip = ClipboardAll()      // snapshot whatever was there
    Clipboard = ""                  // clear so we can detect failure
    Send ^c
    ClipWait(timeout=1)             // wait briefly for clipboard to populate
    result = Clipboard
    RETURN result

FUNCTION RestoreClipboard():
    Clipboard = savedClip           // put the user's original clipboard back

FUNCTION BuildPrompt(template, context, lang):
    systemText = prompts.ini[template].system
    instructionText = prompts.ini[template].instruction
    RETURN {
        system: systemText,
        messages: [{ role: "user", content: instructionText + "\n\n" + context }]
    }

FUNCTION SendRequest(prompt):
    TRY:
        body = JSON.stringify(prompt)
        rawResponse = http.Post(apiUrl, headers, body, timeout=15s)
        parsed = JSON.parse(rawResponse)
        RETURN { text: parsed.content[0].text, error: null }
    CATCH timeout:
        RETURN { text: null, error: "Request timed out" }
    CATCH networkError:
        RETURN { text: null, error: "No connection" }
    CATCH apiError (e.g. 401, 429):
        RETURN { text: null, error: ParseApiError(rawResponse) }
```

---

## State / feedback flow (runs alongside every mode)

```
ShowStatus(text):
    update tray icon tooltip to text
    (optional) flash tray icon color while "Thinking..." is active

ShowError(text):
    tray balloon / tooltip, distinct icon or color from ShowStatus
    always log to state/log.txt with timestamp + which mode triggered it

ShowTooltip(text, duration):
    render near cursor, auto-dismiss after duration OR on next keypress
```

---

## Deliberately left open (decide during build, not now)

- Exact prompt wording per template — lives in `prompts.ini`, tune after first real use
- Which model/provider `http.ahk` hits — abstracted behind one function so swapping providers means editing one file
- Per-language system prompt variants (Python vs JS vs etc.) — `DetectLangFromFileExt()` is a stub for now; can start hardcoded to one language and generalize later
- Undo granularity per editor — test empirically once `InsertAtCursor` / `ReplaceSelection` exist

## Build order recommendation

1. `lib/clipboard.ahk` — everything else depends on reliable capture/restore
2. `lib/http.ahk` + `lib/json.ahk` — get one successful round-trip API call working standalone (hardcode a test prompt, confirm it returns parsed text)
3. `pipeline.ahk` — wire capture → prompt → request → insert for Mode B (fix) first, since it's the most useful single mode to validate end-to-end
4. `main.ahk` — hotkey bindings once the pipeline function signature is stable
5. Add Mode A (generate) and Mode C (freeform) once Mode B is proven
6. `lib/ui.ahk` (status/tooltip/error) — layer in once the happy path works, so failures are visible from day one of real use

## Known constraints from design discussion

- No reliable way to read Copilot's inline ghost-text suggestions in VS Code (not real buffer text until accepted; UI Automation route is undocumented/fragile — not worth building on). Treat this tool and Copilot as independent; avoid hotkey collisions with Tab/Esc.
- Multi-turn/autonomous follow-up (planner model deciding next steps, feeding real build/test output back into the loop) is a deliberate v2 — build and actually use the single-model pipeline above first before adding that complexity.

---

# Appendix — Linux Mint equivalent

Same 5-stage logic, different mechanics. Cinnamon/X11 today — note that `xdotool` stops working if this ever moves to Wayland (replacement would be `ydotool`).

### Stage mapping

| Stage | Windows (AHK) | Linux (AutoKey + xdotool) |
|---|---|---|
| Trigger | `::hotkey::` / `Hotkey` directive | `sxhkd` config entry or AutoKey's hotkey binding |
| Context capture | `Send ^c` → read `Clipboard`, restore after | `xdotool key ctrl+c` → read via `xclip -o`, restore after |
| Prompt build | AHK string concat + `.ini` templates | Python string templating + same `.ini`/`.json` templates |
| API call | `WinHttpRequest` COM object or `curl.exe` | Python `requests` library |
| Response parse | Third-party AHK JSON lib | Python built-in `json` module |
| Insertion | `Send` the text, or `Clipboard :=` + `Send ^v` | `xdotool type`, or `xclip` + `xdotool key ctrl+v` |
| Status/tooltip | AHK `ToolTip` / tray icon | `notify-send` or AutoKey's popup |

### File layout

```
~/.config/ai-coder/
  config.ini
  prompts.ini           ← same format/content as the Windows version
  sxhkdrc                ← hotkey → script mappings
  state/
    log.txt
  lib/
    pipeline.py          ← mirrors pipeline.ahk
    http_client.py        ← same function names as the AHK version
    clipboard.py
    notify.py
```