# Godot AI 桌面寵物 — 開發規劃

## 0. 選型結論

| 項目 | 決定 | 理由 |
|---|---|---|
| 引擎 | Godot 4.x 最新 stable | 4.x 才有 per-pixel 透明視窗 + `window_set_mouse_passthrough` |
| 語言 | GDScript | 迭代快、不需處理 .NET 在 macOS 的簽章／匯出麻煩。效能瓶頸在網路不在腳本 |
| 形態 | 桌面寵物：無邊框 + 透明 + always-on-top，視窗會移動 | |
| 美術 | 2D 精靈動畫（`AnimatedSprite2D` + `SpriteFrames`） | |
| LLM | 抽象 `LLMProvider` 介面，實作 Claude + OpenAI + Mock | 開發期用 Mock 不燒錢 |
| TTS | `DisplayServer.tts_speak()`（系統語音，免費、零依賴） | 之後可換雲端 TTS |
| STT | `AudioStreamMicrophone` + `AudioEffectCapture` → WAV → Whisper API | |
| 平台 | macOS 優先（開發機），架構保持跨平台 | |

---

## 1. 專案結構

```
godot_pet/
├─ project.godot
├─ .gitignore                      # 排除 export/, .godot/, secrets
├─ autoload/
│  ├─ config.gd                    # 讀 user://config.cfg + 環境變數（API key）
│  ├─ event_bus.gd                 # 全域 signal 匯流排，解耦各系統
│  ├─ pet_state.gd                 # 飢餓/精力/心情/好感 + 存檔
│  ├─ llm_service.gd               # 對話編排：組 prompt、呼叫 provider、串流轉發
│  ├─ memory_store.gd              # 短期對話窗 + 長期事實/摘要
│  ├─ tts_service.gd
│  └─ stt_service.gd
├─ llm/
│  ├─ llm_provider.gd              # 抽象基底 class
│  ├─ providers/claude_provider.gd
│  ├─ providers/openai_provider.gd
│  ├─ providers/mock_provider.gd
│  └─ sse_client.gd                # HTTPClient 執行緒化串流讀取 + SSE 解析
├─ pet/
│  ├─ pet.tscn / pet.gd            # 根節點：組裝以下三者
│  ├─ pet_visual.gd                # AnimatedSprite2D 控制、動畫切換
│  ├─ pet_brain.gd                 # 行為 FSM：idle/walk/sleep/talk/drag
│  └─ window_controller.gd         # 視窗位置/大小/passthrough 區域
├─ ui/
│  ├─ speech_bubble.tscn / .gd     # 逐字顯示、自動換行、指向寵物
│  ├─ chat_input.tscn / .gd
│  └─ settings_panel.tscn / .gd    # API key、模型、人設、音量
├─ assets/sprites/, assets/audio/
└─ prompts/
   ├─ persona.md                   # 角色人設（可被使用者編輯）
   └─ system_template.md           # 組裝模板：人設 + 狀態 + 記憶 + 行為指令
```

**核心解耦原則**：`pet_brain`（行為）不直接呼叫 `llm_service`，全部透過 `event_bus` 的 signal。這樣之後換 LLM、換美術、加語音都不用動彼此。

EventBus 建議 signal：
```gdscript
signal user_said(text: String)
signal reply_chunk(text: String)        # 串流片段
signal reply_finished(full_text: String)
signal emotion_changed(emotion: String) # LLM 指定的情緒
signal action_requested(action: String) # LLM 想做的動作（跳、睡、走過來）
signal state_tick(state: Dictionary)
```

---

## 2. 分階段里程碑

每個階段都有明確的「做完長什麼樣」，做完才進下一階段。

### Phase 0 — 環境（0.5h）
- 安裝 Godot 4.x（`brew install --cask godot` 或官網下載）
- 建立專案、`git init`、寫 `.gitignore`
- **驗收**：空專案跑得起來，`.godot/` 沒被 commit

### Phase 1 — 透明桌寵視窗（1 天）★ 最容易卡的一關
專案設定：
```
display/window/size/transparent = true
display/window/per_pixel_transparency/allowed = true
display/window/size/borderless = true
display/window/size/always_on_top = true
rendering/viewport/transparent_background = true
```
程式面：
```gdscript
func _ready() -> void:
    get_viewport().transparent_bg = true
    var w := get_window()
    w.transparent = true
    w.borderless = true
    w.always_on_top = true
```
- 視窗尺寸 = 寵物大小 + 泡泡預留空間；用 `DisplayServer.window_set_position()` 讓寵物在桌面移動
- 滑鼠穿透：每次寵物位置變動時更新
  ```gdscript
  DisplayServer.window_set_mouse_passthrough($HitArea.polygon)
  # 傳空陣列 [] 可還原成整個視窗都吃事件
  ```
- 拖曳：`_input` 抓 `InputEventMouseMotion` + 左鍵按住 → 改視窗座標
- 右鍵選單：設定 / 退出

**驗收**：一隻 sprite 浮在桌面上，可拖曳，點寵物以外的區域會點到後面的 app，Cmd+Q 或選單能退出。

> ⚠️ macOS 注意
> - 編輯器內 F5 執行時透明視窗常顯示異常，用「單獨執行」或直接跑 export 出來的 binary 驗證。
> - always-on-top 視窗**壓不過**其他 App 的全螢幕 Space —— 這是 macOS 的行為，Godot 沒暴露 `NSWindow.level` 設定。若非要，得寫 GDExtension 改 window level。先接受這個限制。
> - `per_pixel_transparency/allowed` 在 export preset 也要開，不然打包出來是黑底。
> - PopupMenu 預設會嵌在遊戲視窗內被裁掉，必須關掉 `display/window/subwindows/embed_subwindows`。
> - **Retina**：Godot 的 `Window.size` 與 `screen_get_usable_rect()` 都是**實體像素**（實測：2940×1912 的螢幕回報 2940 寬，`screen_get_scale()` = 2.0）。
>   所以 320px 視窗在 Retina 上只有 160 點，寵物看起來只有一半大。
>   解法：視窗尺寸 = 設計尺寸 × `screen_get_scale()`，同時把 Visual 節點 `scale` 設成同樣倍率。
>   **不要**用 `content_scale_factor`——那會讓 viewport 座標與視窗像素脫鉤，而 `window_set_mouse_passthrough()` 要的是視窗像素，會導致點擊區域錯位。
>   Phase 2 的 sprite 素材要用 2x 解析度。

### Phase 2 — 動畫狀態機（1–2 天）
**改用 Codex Pets 的素材生態**，不自己畫也不在 repo 放任何美術：

- 格式（跨 codex-pets.net / petdex 通用）：`pet.json` + `spritesheet.webp`，8 欄 × 9 列、每格 192×208，共 72 格，**每列 = 一個動畫狀態**
- 執行時讀 `~/.codex/pets/{pet-id}/`，也就是 `npx codex-pets add <id>` 的安裝位置
- 授權：CLI／網站／格式是 MIT，但**素材不是**。原創預設 CC BY-NC-SA 4.0；第三方角色同人只允許非商業個人使用。所以美術絕不進 repo，授權責任留在使用者端
- 沒安裝任何 pet 時 fallback 回程式繪製的預設造型

格式的兩個坑：
- `pet.json` **完全沒宣告幀數與列名**。幀數靠掃描：格子由左至右排，遇到第一個空格就是該列結尾
- 列的語意也沒宣告，且兩個生態的命名不一致 → 內建預設對映表 + 右鍵「校準動畫列」逐列播放給人眼確認
- 動作幀（揮法杖、張手）的包圍盒遠大於待機姿勢。**貼螢幕邊緣定位與點擊區域要用 idle 那列的框**，用全表聯集會讓寵物浮在離邊緣很遠的地方

- `pet_brain.gd` 用單純的 enum FSM（不用 AnimationTree，overkill）：
  - `IDLE` → 隨機時間後 → `WALK`（隨機挑螢幕上一點，視窗漸進移動）→ 回 `IDLE`
  - 被拖曳 → `DRAG`；放開 → 掉落回 `IDLE`
  - 收到 `reply_chunk` → `TALK`；`reply_finished` 後回 `IDLE`
  - 精力低 → `SLEEP`
- 動畫朝向：走左邊時 `flip_h = true`

**驗收**：寵物自己在桌面上晃、會發呆、抓起來會掙扎、放開會回地面。

### Phase 3 — LLM 抽象層 + 文字對話（2 天）
`llm_provider.gd`：
```gdscript
class_name LLMProvider extends RefCounted

signal chunk_received(text: String)
signal tool_called(name: String, args: Dictionary)
signal finished(full_text: String)
signal failed(message: String)

func send(messages: Array[Dictionary], system: String, tools: Array) -> void:
    push_error("not implemented")
func cancel() -> void: pass
```
- 先做 `mock_provider.gd`（固定延遲 + 假逐字回應）→ 整條 UI 流程用 Mock 跑通再接真 API
- `claude_provider.gd`：`POST https://api.anthropic.com/v1/messages`，headers 需 `x-api-key`、`anthropic-version`
- API key **絕不寫進程式碼**：`Config` 依序讀取 環境變數 → `user://config.cfg`（`user://` 在 macOS 是 `~/Library/Application Support/Godot/app_userdata/<專案>/`，不在 repo 裡）
- 對話泡泡：`RichTextLabel` + `visible_ratio` 做打字效果；泡泡出現時放大視窗、消失時縮回

**驗收**：打字送出 → 泡泡逐字出現回應 → 3 秒後淡出。Mock 與真 API 可用設定切換。

### Phase 4 — 真串流（1 天）
Godot 的 `HTTPRequest` 是一次性的，拿不到串流。要串流得用 `HTTPClient`：
- 開一條 `Thread`，`HTTPClient.connect_to_host()` → `request()` → 迴圈 `poll()` + `read_response_body_chunk()`
- 解析 SSE：以 `\n\n` 切事件，取 `data: ` 後的 JSON，累積 `content_block_delta` 的 `text`
- 用 `call_deferred()` 把 chunk 丟回主執行緒發 signal（Godot 的 signal 不是 thread-safe）
- 一定要處理：中途取消、超時、429/5xx 退避重試、網路斷線

**驗收**：回應像真的在打字，中途可按 ESC 打斷。

### Phase 5 — 讓 LLM 驅動動畫（1 天）★ 這步是「活起來」的關鍵
兩種做法，建議 **A 起步、B 進階**：

**A. 內嵌標記**（簡單、與串流相容）
system prompt 要求模型在句首輸出 `[emotion:happy]`，解析後從顯示文字剔除、發 `emotion_changed`。
缺點：模型偶爾不聽話 → 要有 fallback。

**B. Tool use**（可靠）
定義工具給模型：
```json
{"name": "express", "input_schema": {"type":"object","properties":{
  "emotion": {"enum":["neutral","happy","sad","angry","sleepy","excited"]},
  "action":  {"enum":["none","jump","spin","come_closer","sleep"]}}}}
```
模型每次回應先呼叫 `express` 再講話。缺點：多一次 round-trip 或需處理串流中的 tool block。

**驗收**：說「你今天好棒」→ 寵物播 happy 動畫再回話。

### Phase 6 — 狀態系統與主動行為（1–2 天）
- `pet_state.gd`：`hunger` / `energy` / `mood` / `affection`，0–100
- 每秒 tick 衰減；存 `user://state.json`，**啟動時用時間差補算離線期間的衰減**（別讓關掉一週回來還是滿血）
- 狀態注入 system prompt：「你現在有點餓（hunger 25），語氣要帶點抱怨」
- 狀態驅動動畫：energy < 20 → 強制 `SLEEP`
- 主動說話：閒置 > N 分鐘、或某項狀態跨過門檻 → 觸發一句主動台詞
  - **省 token 技巧**：主動台詞用預寫台詞池（每個狀態 10 句）隨機挑，只有使用者真的回話才叫 LLM。不然放著不管一天燒掉一堆錢
- 互動：拖曳 → mood +；餵食選單 → hunger −

**驗收**：放著不管，寵物會自己喊餓、自己去睡覺；醒來狀態有正確衰減。

### Phase 7 — TTS（0.5 天）
```gdscript
# 專案設定需開 audio/general/text_to_speech = true
var voices := DisplayServer.tts_get_voices_for_language("zh")
DisplayServer.tts_speak(text, voice_id, 50, 1.2, 1.0, utt_id, true)  # pitch 調高比較像寵物
DisplayServer.tts_set_utterance_callback(DisplayServer.TTS_UTTERANCE_ENDED, _on_done)
```
- 串流時**按句子**送 TTS（遇到 `。！？\n` 就送一句），不要等全文講完才開口
- `TTS_UTTERANCE_BOUNDARY` 回呼可拿到字元位置 → 拿來做嘴巴開合同步

**驗收**：回應同時有聲音，講話時嘴巴動，設定裡可關掉。

### Phase 8 — 語音輸入（2 天，工程量最大）
- 專案設定 `audio/driver/enable_input = true`
- Audio bus 加 `Record` bus，掛 `AudioEffectCapture`；`AudioStreamPlayer` 播 `AudioStreamMicrophone` 導到該 bus
- `get_buffer()` 拿 stereo 32-bit float PCM → 轉 16-bit mono 16kHz → 自己組 WAV header
- VAD：算 RMS 音量，超過門檻開始錄、連續靜音 1.5 秒結束（別用 push-to-talk，桌寵按鍵很怪）
- 送 Whisper API（multipart/form-data）→ 拿到文字後走既有的 `user_said` 流程
- 熱詞喚醒（叫名字才聽）算加分項，先做「點一下寵物開始聽」

**驗收**：點寵物 → 說話 → 停頓 → 寵物聽懂並回應。

> ⚠️ macOS export 時必須在 preset 填 microphone usage description，不然打包後拿不到麥克風權限且不會報錯。

### Phase 9 — 記憶（1 天）
- 短期：最近 N 輪對話原文（N 依 token 預算，約 10–20 輪）
- 長期：每累積 M 輪就叫一次 LLM 產生摘要 + 抽取事實（「使用者養貓叫小咪」「使用者是工程師」），存 `user://memory.json`
- 組 system prompt = 人設 + 長期事實 + 摘要 + 當前狀態 + 短期對話
- 加個「忘記這件事」的指令與設定面板的記憶檢視／清除

**驗收**：關掉重開，寵物還記得你上次講的事。

### Phase 10 — 打包（1 天）
- macOS export preset：勾 per-pixel transparency、填麥克風權限說明
- 自簽 codesign（自己用就夠）；要給別人用得 Apple Developer 帳號做 notarization，不然對方會看到「已損毀」
- 設定面板要能填 API key（不能要求使用者去改環境變數）
- 開機自動啟動：加到 macOS 登入項目

---

## 3. 時程估計

| 階段 | 時間 | 備註 |
|---|---|---|
| Phase 0–2 | 3 天 | 有能動的桌寵 |
| Phase 3–5 | 4 天 | **MVP 完成點**：能聊天、有情緒 |
| Phase 6–7 | 3 天 | 有生命感 |
| Phase 8–10 | 4 天 | 完整體驗 |

**建議**：做到 Phase 5 就先停下來自己用幾天。桌寵這種東西「好不好玩」跟 prompt 與人設的關係，遠大於跟功能多寡的關係 —— 很可能你會發現該花時間的是調 persona，不是加語音。

---

## 4. 主要風險與對策

| 風險 | 對策 |
|---|---|
| macOS 透明視窗 / passthrough 行為不如預期 | **Phase 1 就驗證**，別等到最後。若真的不行，退回「一般小視窗但無邊框」也能用 |
| always-on-top 蓋不過全螢幕 App | 接受限制，或後期寫 GDExtension 調 NSWindow level |
| LLM 回應延遲讓寵物看起來很呆 | 收到請求立刻播「思考中」動畫 + 語助詞；串流讓第一個字盡早出現 |
| 主動說話狂燒 token | 預寫台詞池，只有真互動才呼叫 LLM；設每日 token 上限 |
| API key 外洩 | 只做本機自用就存 `user://`；要散佈給別人一定要走自架 proxy，不能內嵌 key |
| 卡在美術做不下去 | 用佔位素材，美術永遠放最後 |

---

## 5. 下一步

從 Phase 0 + Phase 1 開始 —— 先把「透明視窗桌寵能不能在你這台 macOS 上正常跑」這個最大不確定性驗掉，其他都是常規工程。
