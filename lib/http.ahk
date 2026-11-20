#Requires AutoHotkey v2.0

global Cooldown := Map()        ; model -> A_TickCount when it may be tried again
global LastModelUsed := ""

; Tries each model in config.ini's `models` list until one answers.
; Returns {text, error, truncated?}
global AbortRequest := false

SendRequest(prompt, timeoutMs := 60000, maxWaitMs := 600000) {
    global Cooldown, LastModelUsed, AbortRequest
    AbortRequest := false
    cfg := A_ScriptDir "\config.ini"
    list := IniRead(cfg, "api", "models", "")
    if list = ""
        list := IniRead(cfg, "api", "model", "")

    models := []
    for m in StrSplit(list, ",", " `t")
        if m != ""
            models.Push(m)
    if models.Length = 0
        return {text: "", error: "No model listed in config.ini"}

    startTime := A_TickCount
    round := 0
    lastErr := ""

    loop {
        round++
        anyTried := false
        for model in models {
            if AbortRequest
                return {text: "", error: "Cancelled"}
            if A_TickCount - startTime > maxWaitMs
                return {text: "", error: "Gave up after " Round(maxWaitMs/1000) "s. Last: " lastErr}
            if Cooldown.Has(model) && A_TickCount < Cooldown[model]
                continue

            anyTried := true
            r := SendOnce(prompt, model, timeoutMs)
            if !(r.HasProp("retry") && r.retry) {
                LastModelUsed := model
                if r.HasProp("routed") && r.routed != ""
                    LastModelUsed := model " -> " r.routed
                return r
            }
            if r.cooldown > 0
                Cooldown[model] := A_TickCount + r.cooldown
            lastErr := model " -> " r.error
            Log("http", "Round " round " - falling back from " lastErr)
        }

        ; Every model is either cooling down or just failed this pass. Wait before trying again.
        soonest := 5000   ; floor, in case a model has no cooldown (e.g. "too large") - avoid a hot loop
        for model in models {
            if Cooldown.Has(model) {
                left := Cooldown[model] - A_TickCount
                if left > 0 && left < soonest
                    soonest := left
            }
        }
        remaining := maxWaitMs - (A_TickCount - startTime)
        if remaining <= 0
            return {text: "", error: "Gave up after " Round(maxWaitMs/1000) "s. Last: " lastErr}
        wait := Min(soonest, remaining, 60000)   ; never sleep more than 60s at a stretch, so Abort stays responsive

        secsLeft := Round(wait / 1000)
        loop secsLeft {
            if AbortRequest
                return {text: "", error: "Cancelled"}
            ShowStatus("All models limited - retrying in " (secsLeft - A_Index + 1) "s... (Ctrl+Alt+X to cancel)")
            Sleep(1000)
        }
    }
}

; One attempt against one model.
; On a failure another model might avoid, the result has retry=true and a cooldown in ms.
SendOnce(prompt, model, timeoutMs) {
    cfg := A_ScriptDir "\config.ini"
    provider := IniRead(cfg, "api", "provider", "openai")
    key := IniRead(cfg, "api", "key", "")
    url := IniRead(cfg, "api", "url", "")
    maxTok := Integer(IniRead(cfg, "api", "max_tokens", "3000"))

    if key = "" || InStr(key, "PASTE_YOUR")
        return {text: "", error: "No API key in config.ini"}
    if url = ""
        return {text: "", error: "Missing url in config.ini"}

    if provider = "anthropic" {
        body := JSON.stringify(Map(
            "model", model,
            "max_tokens", maxTok,
            "system", prompt["system"],
            "messages", [Map("role", "user", "content", prompt["user"])]
        ))
    } else {
        body := JSON.stringify(Map(
            "model", model,
            "max_tokens", maxTok,
            "messages", [
                Map("role", "system", "content", prompt["system"]),
                Map("role", "user", "content", prompt["user"])
            ]
        ))
    }

    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.SetTimeouts(5000, 5000, 15000, timeoutMs)
        req.Open("POST", url, false)
        if provider = "anthropic" {
            req.SetRequestHeader("x-api-key", key)
            req.SetRequestHeader("anthropic-version", "2023-06-01")
        } else {
            req.SetRequestHeader("Authorization", "Bearer " key)
        }
        req.SetRequestHeader("content-type", "application/json")
        req.Send(body)
        raw := ReadUtf8(req)
        status := req.Status
        routed := ""
        try routed := req.GetResponseHeader("X-Routed-Via")
    } catch as e {
        if InStr(e.Message, "timed out")
            return {text: "", error: "Request timed out", retry: true, cooldown: 30000}
        return {text: "", error: "No connection / request failed: " e.Message}
    }

    try {
        parsed := JSON.parse(raw)
    } catch {
        return {text: "", error: "Bad response (HTTP " status "): " SubStr(raw, 1, 200)
            , retry: status >= 500, cooldown: 30000}
    }

    if status != 200 {
        detail := ""
        if parsed.Has("error") && parsed["error"].Has("message")
            detail := parsed["error"]["message"]
        d := StrLower(detail)
        retry := false
        cooldown := 0
        if status = 429 {
            retry := true
            if InStr(d, "too large")
                cooldown := 0
            else if InStr(d, "per day") || InStr(d, "tpd") || InStr(d, "rpd")
                cooldown := 30 * 60 * 1000
            else
                cooldown := 60 * 1000
        } else if status = 413 {
            retry := true
        } else if status = 404 {
            retry := true
            cooldown := 60 * 60 * 1000
        } else if status >= 500 {
            retry := true
            cooldown := 30 * 1000
        }
        return {text: "", error: "HTTP " status (detail != "" ? ": " detail : ""), retry: retry, cooldown: cooldown}
    }

    truncated := false
    try {
        if provider = "anthropic" {
            truncated := parsed.Has("stop_reason") && parsed["stop_reason"] = "max_tokens"
            text := parsed["content"][1]["text"]
        } else {
            choice := parsed["choices"][1]
            truncated := choice.Has("finish_reason") && choice["finish_reason"] = "length"
            text := choice["message"]["content"]
        }
    } catch {
        if truncated
            return {text: "", error: "Cut off before any answer (token budget used up) - raise max_tokens"}
        return {text: "", error: "Unexpected response shape: " SubStr(raw, 1, 200)}
    }
    return {text: text, error: "", truncated: truncated, routed: routed}
}

ReadUtf8(req) {
    arr := req.ResponseBody
    pData := NumGet(ComObjValue(arr), 8 + A_PtrSize, "Ptr")
    size := arr.MaxIndex() + 1
    return StrGet(pData, size, "UTF-8")
}