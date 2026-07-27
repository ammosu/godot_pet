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
- API key **絕不寫進程式碼**：`Config.get_secret()` 依序讀取 環境變數 → **OS 憑證庫** → 專案／執行檔旁的 `.env` → `user://config.cfg`
  - 憑證庫：macOS 用 `security`（Keychain）、Linux 用 `secret-tool`（libsecret，需 `apt install libsecret-tools`）、其他平台退回明文設定檔並讓 UI 說清楚
  - 右鍵選單「設定 OpenAI API key」→ 遮蔽輸入框貼上 → 存進 Keychain，`.env` 就不需要了
  - **不做 OAuth**：OpenAI 的第三方 "Sign in with ChatGPT" 2025 年announce 過但至今只在 Codex 自家工具出貨；外面流通的做法是冒用 Codex CLI 的 client_id 去花訂閱額度，這個專案不做

實作時踩到的三個坑：
- 密鑰盡量走 **stdin 不要走 argv**（`ps` 對同使用者的行程是可見的）。用 `OS.execute_with_pipe()` 拿到 stdio 再寫入。macOS 的 `security -w` 不帶值時會互動式詢問**兩次**，所以要送兩遍
- **但 `security` 從 stdin 讀密碼會在 128 字元靜默截斷**，exit code 還是 0、什麼都不說 —— 而 OpenAI 的 project key 是 164 字元。所以**每次寫入都要讀回來比對**，對不上就改走 argv（argv 沒有長度限制）。一把在 `ps` 裡閃現一瞬間的 key，遠比一把被默默砍半、事後只看得到 401 的 key 好處理
- **存進去的值必須是 ASCII**。`security find-generic-password -w` 遇到非 ASCII 會印出沒有任何標記的 hex，而字面值 `deadbeef` 讀回來也是 `deadbeef` —— 兩者無法區分。所以寫入時就擋掉，不要在讀取時猜
- 對話泡泡：`RichTextLabel` + `visible_characters` 做打字效果

實作時踩到的坑：
- **啟動預設值不能寫回設定檔**。`set_provider()` 原本每次都存檔，導致第一次跑的預設值（那時還沒有 openai）被寫死，之後自動偵測永遠失效。改成只有使用者從選單選擇才存
- **泡泡邊界要對「螢幕」不是「視窗」**。視窗刻意溢出螢幕邊緣好讓寵物貼角落，泡泡只對視窗做 clamp 會跑到螢幕外。而且光 clamp 位置不夠——泡泡固定寬度比螢幕上剩的空間還寬時，寬度也要跟著縮
- `EventBus.pet_moved` 必須在 `park_at_default_spot()` **之前**連接，否則停靠那一次移動不會通知到 UI

**驗收**：打字送出 → 泡泡逐字出現回應 → 3 秒後淡出。Mock 與真 API 可用設定切換。

### Phase 4 — 真串流（1 天）
Godot 的 `HTTPRequest` 是一次性的，拿不到串流。要串流得用 `HTTPClient`：
- 開一條 `Thread`，`HTTPClient.connect_to_host()` → `request()` → 迴圈 `poll()` + `read_response_body_chunk()`
- 解析 SSE：以 `\n\n` 切事件，取 `data: ` 後的 JSON，累積 `content_block_delta` 的 `text`
- 用 `call_deferred()` 把 chunk 丟回主執行緒發 signal（Godot 的 signal 不是 thread-safe）
- 一定要處理：中途取消、超時、429/5xx 退避重試、網路斷線

**驗收**：回應像真的在打字，中途可按 ESC 打斷。

### Phase 5 — 讓 LLM 驅動動畫（1 天）★ 這步是「活起來」的關鍵
**採用內嵌標記，不用 tool use。** 標記不多花一次 round-trip，而且**跟串流相容** —
情緒在最前面幾個 token 就知道了，寵物在講完整句話之前就先做出表情。
tool use 比較可靠，但要嘛多一輪往返、要嘛得在串流裡處理 tool block，對這個用途不划算。

- system prompt 要求每則回話開頭標 `[happy]` 之類，只能從六個裡挑：
  `neutral` / `happy` / `excited` / `sad` / `greeting` / `sleepy`
- `LLMService` 在串流中剝掉標記才送進泡泡；歷史紀錄也存剝掉後的版本
- 模型不聽話（沒標記、標記沒閉合）→ 掃過 24 字就放棄，整段當內文送出

**串流解析要小心**：標記可能被切成 `[hap` + `py]` 兩個 chunk。文字要先扣住不送，
等標記確定成立或確定不存在才放行，否則泡泡會閃過半截標記。

**這個 pack 的實際列對映**（原本的猜測錯了三列，而且**沒有睡覺動畫**）：

| 列 | 內容 | 對映 |
|---|---|---|
| 0 | 站著眨眼 | idle |
| 1 | 走路 | walk |
| 2 | 跑步 | run |
| 3 | 舉手打招呼 | wave ← greeting |
| 4 | 張嘴說話 | talk ← neutral |
| 5 | 大哭抓馬尾 | sad |
| 6 | 雙手交握閉眼 | sleep（勉強代用）← sleepy |
| 7 | 法杖蓄力 | excited |
| 8 | 光球 + 閃光 + 笑 | happy |

列語意每個 pack 都不一樣，所以可在 `user://config.cfg` 用 `[pet_rows]` 逐隻覆寫，不必改程式。

**驗收**：說「哈囉好久不見」→ 模型回 `[greeting]` → 寵物播揮手動畫再講話。

### Phase 6 — 狀態系統與主動行為（1–2 天）
- `autoload/pet_state.gd`：`fullness` / `energy` / `mood` / `affection`，0–100
  - **全部設計成「越高越好」**，這樣一條衰減規則就通吃，不用為飢餓值反過來寫
  - `mood` 不是獨立衰減，而是往 `_mood_target()` 靠攏，而 target 由飽食度與精力算出來 → 又餓又累的寵物自然會心情差
- 每秒 tick 衰減；存 `user://state.json`，啟動時用時間差補算離線期間
  - 離線期間**當作在睡覺**：精力回復、飽食度下降。回來看到一隻睡飽但肚子餓的寵物，比看到一具屍體好
  - 補算上限 24 小時，出國兩週回來才不會全部歸零
- 狀態注入 system prompt，用**質性描述不用數字**（「很餓，可以抱怨一下」），模型照著演的成功率高很多
- 狀態驅動動畫：energy < 20 → `SLEEP`；> 55 才醒。戳醒有 90 秒寬限期，否則下一個 idle 循環又立刻睡回去
- 主動說話：`autoload/nudger.gd`
  - **台詞從 `prompts/nudges.json` 的預寫池挑，不叫 LLM**。閒置的寵物每幾分鐘打一次 API 是純燒錢，而且差別看不出來 —— 主動搭話之所以有生命感是**時機**不是**詞句**。使用者真的回話才進 LLM
  - 三層冷卻：全域 8 分鐘、同一個理由 35 分鐘、閒置門檻 12–25 分鐘隨機（免得像 cron job）
  - 主動講的話要用 `LLMService.note_pet_said()` 寫進歷史，不然模型下一句會自相矛盾

數值調整都在 `pet_state.gd` 的 `DECAY` / `STARTING` 常數。飽食度設成約 14 小時見底 —— 再快的話光一個晚上八小時就會餓死，每天早上都是同一個狀態。

**驗收**：放著不管，寵物會自己喊餓、自己去睡覺；關掉八小時再開，是睡飽但很餓的狀態。

### Phase 7 — TTS（0.5 天）
```gdscript
# 專案設定需開 audio/general/text_to_speech = true
var voices := DisplayServer.tts_get_voices_for_language("zh")
DisplayServer.tts_speak(text, voice_id, 50, 1.2, 1.0, utt_id, true)  # pitch 調高比較像寵物
DisplayServer.tts_set_utterance_callback(DisplayServer.TTS_UTTERANCE_ENDED, _on_done)
```
- 串流時**按句子**送 TTS（遇到 `。！？\n` 就送一句），不要等全文講完才開口。沒標點的長句累積到 40 字也會先送，不然會一路沉默到最後
- `tts_speak` 預設是**排隊**不是插隊，所以一句一句送會自然接續。使用者送新訊息時 `tts_stop()` 打斷
- **語言代碼是連字號**：Godot 回報 `zh-TW`，但 `OS.get_locale()` 給的是 `zh_TW`。`tts_get_voices_for_language()` 是前綴比對，用底線會**靜默比對不到**然後 fallback 去拿清單第一個聲音 —— 在這台機器上碰巧是中文的 Meijia，換一台就會用英文聲音念中文
- `TTS_UTTERANCE_BOUNDARY` 回呼可拿到字元位置 → 可拿來做嘴巴開合同步（未做，pixel art 沒有嘴型幀）

**驗收**：回應同時有聲音，選單可關掉，送新訊息會打斷上一句。

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
三層，由便宜到貴：

| 層 | 內容 | 成本 |
|---|---|---|
| history | 最近 16 則原文，**會存檔**，重開接續 | 每次請求都送 |
| summary | 更舊的對話摺疊成一段敘述 | 每 12 則一次 API |
| facts | 關於使用者的長期事實 | 同上，一起抽出 |

- 全部存 `user://memory.json`
- **對話歷史的所有權移到 `MemoryStore`**，`LLMService` 不再自己留一份 —— 兩邊各存一份、其中一份要持久化，遲早不同步
- 摺疊用**另開一個 provider instance** 跑，它的 signal 根本沒接上 EventBus，所以摘要的 chunk 不可能漏進泡泡或被 TTS 念出來。比在主 provider 上加旗標安全
- 摺疊要**批次**（累積 12 則才做），每輪都摘要等於 API 呼叫翻倍
- mock provider 摘要不出東西，所以 `request_background()` 回 false，此時只在歷史真的爆掉（60 則）才丟棄最舊的
- 右鍵選單「你記得我什麼？」列出所有 facts、「全部忘掉」清空。**記憶不能被檢視就不能被信任** —— 一隻默默記著錯誤資訊的寵物比會忘記的更糟

抽事實的 prompt 要明確擋掉兩種東西，不然會塞滿垃圾：**推測**（「可能還有併發風險」）和**很快過期的事**（「今天開了四個會」）。後者留在 summary 就好。

**驗收**：關掉重開，寵物還記得你上次講的事。

### Phase 10 — 打包（1 天）

```sh
# 一次性：裝 export template（只需要 macos.zip，其他平台的不用）
curl -L -o /tmp/tpl.tpz https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_export_templates.tpz
unzip -q /tmp/tpl.tpz -d /tmp/tplx
mkdir -p ~/Library/Application\ Support/Godot/export_templates/4.7.1.stable
cp /tmp/tplx/templates/{macos.zip,version.txt} ~/Library/Application\ Support/Godot/export_templates/4.7.1.stable/

# 每次
godot --headless --path . --export-release "macOS" "build/Godot Pet.app"
tools/make_app_icon.sh   # 選用：Dock 圖示換成目前那隻寵物
```

`make_app_icon.sh` 從目前選用的 pack 抽出 idle 第一格做成 `.icns` 塞回 bundle 再重簽。
**素材不會進 repo**，產生出來的圖示只屬於你本機這份 build —— 別把帶著角色臉的 `.app` 給別人。
不跑這個腳本的話就維持專案自己的 `icon.svg`。

- **`rendering/textures/vram_compression/import_etc2_astc` 必須開**，否則 arm64／universal 匯出直接被擋
- `export_presets.cfg` **有進版控**：它帶著透明視窗和隱私權說明等設定，而 Godot 的簽章／公證機密是放在另一個 `export_credentials.cfg`（那個才要 ignore）
- codesign 用內建 ad-hoc 就能自己用。要給別人下載才需要 Apple Developer 帳號做 notarization，否則對方會看到「已損毀」
- **`.env` 不會進 .app**（`exclude_filter` 有擋，而且執行檔旁邊也沒有）。所以從原始碼跑得好好的機器，打包後會**默默降級成 mock**。啟動時偵測到「沒有 key 且正在用 mock」就讓寵物直接講出來，不要讓它看起來像壞掉
- 開機自動啟動：把 `.app` 拖到 `/Applications`，然後系統設定 → 一般 → 登入項目 → `+`

**驗收**：`.app` 雙擊就能跑、透明正常、Dock 有圖示、不需要終端機。

---

### 計畫外 — 看螢幕（已完成）
右鍵「看一下我的螢幕」→ `DisplayServer.screen_get_image()` → 縮到 768px、JPEG → 當作 `image_url` 送出。

- `gpt-5.4-nano` 支援 vision，`detail: low` 下約 570 prompt tokens，是純文字對話的好幾倍
- **只在明確要求時執行**。不定時、不主動、不進 nudge
- macOS 需要螢幕錄製權限，而且**沒授權是無聲失敗** —— 你會拿到只有桌布的圖，模型就認真跟你討論桌布。用平均局部對比偵測後**用問的**（「是不是還沒給我權限？」），因為真的很乾淨的桌面也會觸發同一個判斷。匯出的 .app 是另一個 binary，要另外授權
- 寵物自己的視窗設 `FLAG_EXCLUDE_FROM_CAPTURE`，免得它拍到自己的對話泡泡
- **視覺回應標記為 ephemeral**：留在最近對話裡（追問才有上下文），但不摺進 summary、不抽成 facts、**不寫進磁碟**。否則瞄到一次私密內容就會變成之後每次請求都重送的「事實」
- `persona.md` 要明確開例外。原本寫「你看不到螢幕」，模型就算拿到圖也會回「我又沒長眼睛」

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
