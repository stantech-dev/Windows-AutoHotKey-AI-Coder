# Windows AutoHotKey AI Coder

A hotkey-triggered AI coding assistant for Windows, built on AutoHotkey v2. It lets you generate, fix, refactor, explain, and test code directly inside your editor, without leaving the keyboard or copy-pasting into a browser tab.

AHK handles capture, prompting, and insertion. All the actual intelligence comes from a real AI model API call, routed through [FreeLLMAPI](https://github.com/tashfeenahmed/freellmapi) or any OpenAI/Anthropic-compatible endpoint (Groq, etc.).

## Features

- **Generate** — write a comment, get the implementation below it. Sees the rest of your file for context (imports, naming, style) so output matches your codebase instead of guessing.
- **Fix** — select broken code, get it fixed in place. Uses a search/replace edit-block format rather than rewriting the whole selection, so untouched code is never at risk and a bad model reply can't silently wipe out working code.
- **Refactor** — same edit-block safety model as Fix, for readability/structure cleanup without behavior changes.
- **Add tests** — generates tests below your selection without touching the original code.
- **Explain** — shows an explanation in a popup window. Never modifies your file or clipboard.
- **Plan + Fill** — turn a one-line goal comment into a skeleton of smaller tagged steps, then generate each step in order, with every step seeing the code written above it.
- **Freeform** — ask an ad-hoc question via popup, get the answer in a readable window. Can paste just the code portion back into your file on request.
- **Typed markers** — every action above also has a typed trigger (e.g. type `;;go` at the end of a comment) as an alternative to pressing a hotkey, scoped to actual editor windows only.
- **Model fallback** — define a list of models; if one is rate-limited, erroring, or down, the tool automatically retries with the next, and loops back with backoff if all are temporarily exhausted.
- **Background-safe** — you can alt-tab away while a request is in flight. The tool reclaims focus just long enough to insert the result, then gives it back.

## Requirements

- Windows
- [AutoHotkey v2.0](https://www.autohotkey.com/)
- An API key for whichever backend you point it at (a free [Groq](https://console.groq.com) key, or a [FreeLLMAPI](https://github.com/tashfeenahmed/freellmapi) instance, or Anthropic/OpenAI directly)

## Setup

1. Clone the repo.
2. Copy `config.ini.example` to `config.ini`.
3. Fill in your API key and endpoint details in `config.ini`:

   ```ini
   [api]
   provider=openai
   key=YOUR_API_KEY_HERE
   models=auto
   url=http://localhost:PORT/v1/chat/completions
   max_tokens=3000
   max_input_chars=12000
   context_chars=8000
   ```

   - `provider` — `openai` for any OpenAI-compatible endpoint (Groq, FreeLLMAPI, etc.), or `anthropic` for Anthropic's native API.
   - `models` — a comma-separated list, tried in order with automatic fallback (e.g. `openai/gpt-oss-120b,llama-3.3-70b-versatile`). Use `auto` if your endpoint handles routing itself (FreeLLMAPI).
   - `max_input_chars` — selections larger than this are rejected before an API call is made, to avoid wasting a request on something guaranteed to hit a token limit.

4. Run `main.ahk`. A green **H** icon in your system tray means it's active.

## Hotkeys

| Hotkey | Action |
|---|---|
| `Ctrl+Alt+G` | Generate code from the comment on the current line |
| `Ctrl+Alt+F` | Fix the selected code |
| `Ctrl+Alt+R` | Refactor the selected code |
| `Ctrl+Alt+E` | Explain the selected code (read-only) |
| `Ctrl+Shift+Alt+T` | Add tests for the selected code |
| `Ctrl+Alt+L` | Turn a goal comment into a step-by-step plan |
| `Ctrl+Alt+N` | Generate the next planned step |
| `Ctrl+Alt+A` | Generate all remaining planned steps |
| `Ctrl+Alt+X` | Abort a fill-in-progress or an in-flight request |
| `Ctrl+Alt+Space` | Ask a freeform question |
| `Ctrl+Alt+V` | Paste the last freeform answer into the file |

## Typed markers

Type these at the end of a comment line (inside a recognized editor window) instead of pressing a hotkey:

`;;go` · `;;plan` · `;;next` · `;;fill` · `;;ask` · `;;paste`

`;;fix` is the exception: type it on its own line directly below a block of code, and it fixes everything above it up to the previous blank line.

## How it stays safe to use

- **Fix and Refactor never do a blind full-selection rewrite.** The model returns targeted search/replace blocks; if a block doesn't match your code exactly, or the model's reply looks cut off, nothing is applied and your file is left untouched.
- **Oversized selections are rejected locally** before any API call, based on `max_input_chars`.
- **A closed editor window never causes a lost result.** If the target window is gone by the time a response arrives, the result is copied to your clipboard instead of silently discarded.
- All activity (success, errors, which model answered) is logged to `state/log.txt` for debugging. This file is gitignored since it can contain fragments of your code.

## Known limitations

- Fix/Refactor depend on the model copying your existing lines exactly to locate the edit. Weaker models sometimes paraphrase instead of quoting, which surfaces as a "doesn't match your code" error rather than a bad edit — the file stays safe either way, but the action fails.
- Generate has no awareness of code *below* your cursor, only above it.
- Plan/Fill is a chain of independent requests; nothing runs or tests the code in between steps, so an early wrong assumption can carry into later ones. Review before trusting a multi-step fill.
- Prompts in `prompts.ini` are a starting point, not tuned for every language — edit them if a mode consistently produces output you don't like.

## Project structure

```
ai-coder/
  main.ahk              hotkey + typed-marker bindings
  pipeline.ahk           the mode logic (generate, fix, plan, fill, etc.)
  config.ini             your local API key + settings (gitignored)
  config.ini.example     template for config.ini
  prompts.ini            per-mode system prompts + instructions
  state/
    log.txt              request/response log (gitignored)
  lib/
    http.ahk             API calls, model fallback, retry logic
    json.ahk             JSON parse/stringify (third-party, see credits)
    clipboard.ahk         capture/restore/paste helpers
    ui.ahk                status tooltips, error display, answer window
```

## Credits

- `lib/json.ahk` is from [thqby/ahk2_lib](https://github.com/thqby/ahk2_lib), used under its original license.
- Model routing/fallback tested against [FreeLLMAPI](https://github.com/tashfeenahmed/freellmapi) and [Groq](https://groq.com).

