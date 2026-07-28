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

> ⚠️ Windows 注意
> - `window_set_mouse_passthrough()` 在 macOS / Linux 只塑形**輸入**，在 Windows 卻是用 `SetWindowRgn()` 實作的——**遮罩以外的區域連畫都不會畫**。
>   所以貼著寵物輪廓的遮罩會讓對話泡泡整塊消失，而且**無聲失敗**：沒有錯誤、log 裡什麼都沒有，寵物就是安靜地不講話。
>   解法：`pet.gd` 的 `_refresh_mask()` 在 `WindowController.passthrough_clips_rendering()` 為真時改用 `ChatPanel.get_chrome_rect()`（泡泡 + 尾巴 + 陰影 + 輸入框），其他平台維持原本只含輸入框的行為——那邊泡泡是純顯示的，放大遮罩只會白白吃掉本該穿透到桌面的點擊。
>   泡泡會隨著文字打字而長大，遮罩得跟著更新，所以 `_refresh_mask()` 從 `_refresh_hit_region()` 拆出來由 `_process` 驅動；後者還要重建泡泡樣式與重排輸入框，不能每幀跑。
>   `set_hit_region()` 會擋掉沒變動的 region——`SetWindowRgn` 每次呼叫都強制重繪，而泡泡出現時 brain 進入 `TALK`、寵物站著不動，region 多半是不變的。
> - `screen_get_scale()` **只有 macOS 有實作**，Windows 一律回 1.0，所以上面 Retina 那套 DPI 縮放在 Windows 完全沒作用——125% 螢幕上寵物與右鍵選單都偏小，而且 `_scale_menu_theme()` 因為 `is_equal_approx(s, 1.0)` 直接 early-return，選單根本沒縮放過。
>   解法是 `WindowController.display_scale()`：`screen_get_scale()` 大於 1 就用它（macOS），否則退回 `screen_get_dpi() / 96`（Windows／Linux 回報的是 DPI 不是倍率）。
>   **不要把結果取整**。像素美術偏好整數倍率，但 125% 就是 125%——取整回 1.0 正是原本的 bug，取整到 2.0 則會讓寵物大到誇張。實測 1.25 倍下 pixel art 沒有破圖。
> - 沒有 Windows 憑證庫後端，`SecretStore` 落到 `Backend.NONE`，API key 會明文存進 `config.cfg`。
> - 顯卡驅動若不支援 Vulkan，Godot 會自動退到 Direct3D 12，透明與 passthrough 都照常運作。

### Phase 2 — 動畫狀態機（1–2 天）
**改用 Codex Pets 的素材生態**，不自己畫也不在 repo 放任何美術：

- 格式（跨 codex-pets.net / petdex 通用）：`pet.json` + `spritesheet.webp`，8 欄、每格 192×208，**每列 = 一個動畫狀態**（列數不固定，見下）
- 執行時讀 `~/.codex/pets/{pet-id}/`，也就是 `npx codex-pets add <id>` 的安裝位置
- 授權：CLI／網站／格式是 MIT，但**素材不是**。原創預設 CC BY-NC-SA 4.0；第三方角色同人只允許非商業個人使用。所以美術絕不進 repo，授權責任留在使用者端
- 沒安裝任何 pet 時 fallback 回程式繪製的預設造型

格式的坑：
- **列數會變，絕對不能寫死**。舊 sheet 是 9 列，`spriteVersionNumber: 2` 的是 11 列（1536×2288），而 `pet.json` 對此隻字未提。原本 `ROWS := 9` 寫死，整除檢查就把所有 v2 pack 擋在門外——而且失敗方式很糟：只 push_warning 然後**默默退回程式繪製的預設造型**，使用者看到的是「下載的造型沒有生效」，不會聯想到格式版本。
  正解：格子寬 = 圖寬 / 8，格子高由 192:208 比例推出，列數 = 圖高 / 格子高，全程整數運算，除不盡就當作壞檔而不是四捨五入
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

- `detail: low` 下約 570 prompt tokens，是純文字對話的好幾倍
- **每次截圖前都先問你**（「要讓我看一下你現在的螢幕嗎？」好／不要／每次都可以）。同意過「每次都可以」才不再問。不定時、不主動、不進 nudge
- **打字問也算數，而且有兩條觸發路徑**：
  - `VisionService.wants_a_look()` 在送出前先用片語比對（「我在幹嘛」「看一下我的螢幕」…），命中就直接去要權限。不花錢、不會失手
  - 模型也可以在情緒標記的位置改輸出 `[look]`，涵蓋片語表抓不到的（「這個錯誤是什麼意思」）
- **只靠 `[look]` 是行不通的，這是踩過的坑**：`gpt-5.4-nano` **從來不輸出 `[look]`** —— 明顯需要截圖的問題實測 0/12，`gpt-5.4-mini` 是 9/9，而且不該截的問題兩邊都不會亂截。nano 拿到圖是看得懂的，它只是永遠不會開口要，所以整個功能在當時設定的模型上等於不存在。因此才同時要本地觸發**和**把 `DEFAULT_MODEL` 換成 mini
- **拒絕之後不能只是把 `[look]` 吃掉**：人設寫著「需要看螢幕就只輸出 `[look]`」，小模型會聽人設而不聽附加的但書，於是它再要一次、標記又被吃掉，寵物就整句話都沒了。要用 `build_system_prompt(false)` 把 `## 看螢幕` 整段從人設裡拿掉那一輪
- 連帶修掉：`_on_finished` 原本在 `_clean_reply` 是空的時候退回原始文字，會讓一個裸的 `[look]` 直接顯示在泡泡裡、還寫進歷史
- **拒絕了還是要有回答**。選單按「不要」只要一句「好啦，那我不看」就好，但打字問的那句已經躺在歷史裡了，得用 `answer_without_looking()` 讓她閉著眼睛回答
- `[look]` 的處理要 **deferred**：它跑在 provider 自己的 chunk signal 裡，當場關掉 HTTP client 會讓 `_poll_body` 讀到已經消失的 client
- macOS 需要螢幕錄製權限，而且**沒授權是無聲失敗** —— 你會拿到只有桌布的圖，模型就認真跟你討論桌布。用平均局部對比偵測後**用問的**（「是不是還沒給我權限？」），因為真的很乾淨的桌面也會觸發同一個判斷。匯出的 .app 是另一個 binary，要另外授權
- `FLAG_EXCLUDE_FROM_CAPTURE` **只在截圖那一瞬間開**。一直開著的話寵物在任何截圖裡都不存在 —— 你想截圖分享也截不到，我也沒辦法用截圖驗證。開了要等一兩個 frame 才生效
- **視覺回應標記為 ephemeral**：留在最近對話裡（追問才有上下文），但不摺進 summary、不抽成 facts、**不寫進磁碟**。否則瞄到一次私密內容就會變成之後每次請求都重送的「事實」
- `persona.md` 要明確開例外。原本寫「你看不到螢幕」，模型就算拿到圖也會回「我又沒長眼睛」
- 後記：縮圖 + JPEG + data URL 那段（`image_to_data_url()`）現在不只這裡用，拖進來的圖片
  也走同一條，改它要記得另一個呼叫端。見下面 2026-07-28 那節

### 計畫外 — 介面整理（已完成）

輸入框、對話泡泡、右鍵選單三個地方原本都還是 Godot 預設外觀。整成一套：`ui/style.gd`（`PetStyle`）收所有顏色與邊，兩種表面**刻意對立** —— 寵物講的話是「紙」（暖白、圓角、有尾巴），App 問你的事是「墨」（深色板，讓選單不會看起來像角色在講話），只用一個柿子色重點色。

- **深色選單不只是品味問題**：`PopupMenu` 的打勾／單選圖示來自引擎預設主題，是接近白色的，淺色板上會完全看不見，而且沒有 per-item 的 icon modulate 可以補救
- 右鍵選單從 20 項攤平改成四個子選單（造型／大小／語言模型／行為）+ 常用的四項；「行為」關掉 `hide_on_checkable_item_selection`，四個開關可以連著按
- **記憶改成獨立視窗**（`ui/memory_panel.gd`），可逐則刪除。原本是選單項目把整串事實倒進對話泡泡 —— 泡泡會定時淡出，答案會在讀到一半時消失；而且只能讀不能改的清單，等於只能整個清掉
- **截圖同意視窗重寫**：要回答的是「拍多少、傳給誰、留多久」這三件事，而且動作要寫在按鈕上（「好，看這一次」而不是「好」）。「以後都不用問我」做成整個視窗裡最安靜的按鈕 —— 它是這裡唯一一個「不再點它也收不回來」的答案

踩到的坑：

- **StyleBoxFlat 的 shadow 是自己形狀的實心放大複製，畫在自己底下**（連被自己蓋住的部分也畫），而且沒有模糊。半透明底色的 focus box 不會發光，只會被染成陰影的顏色 —— 輸入框看起來整個變成鮭魚粉
- **stylebox 的 content margin 會決定控制項的最小尺寸**，不只是內距。四邊平均給 16 就把版面算好的高度蓋掉了，藥丸變成圓角方塊
- 節點 `_ready()` 裡建好的東西是在知道螢幕縮放之前建的，所以 `MemoryPanel` 改成第一次開啟時才建
- **`_on_pet_moved` 沒有重推遮罩**：視窗掛在螢幕外，可見範圍一變，泡泡與輸入框會在視窗內橫移，而 Windows 的遮罩會裁掉繪製 —— 症狀是泡泡或輸入框某一側被切掉，看起來時有時無。最好重現的方式是開著輸入框拖動寵物（拖曳也會把 brain 踢出 `TALK`，放開後牠就帶著輸入框走掉）

### 計畫外 — 跨平台（打包完成，實機未驗）

原本只有 macOS 一個 preset。現在 `export_presets.cfg` 有三個，`Windows`（x86_64）
和 `Linux`（x86_64）都能從 macOS 交叉匯出，template 一樣放在
`export_templates/4.7.1.stable/`（從同一包 `.tpz` 挑 `windows_*.exe` 與
`linux_*.x86_64` 複製過去即可，不用重載）。

**匯出成功不代表跑得起來。** 這兩個 build 從來沒有在真的 Windows／Ubuntu 上執行過，
下面「還沒驗」的部分就是字面意思。

程式碼裡本來就已經處理掉的（不是這次才做的）：

- `WindowController.display_scale()` —— `screen_get_scale()` **只有 macOS 有實作**，
  其他平台一律回 1.0。Windows／Linux 走 `screen_get_dpi() / 96`，而且不取整數
- `passthrough_clips_rendering()` —— Windows 用 `SetWindowRgn()` 實作 passthrough，
  遮罩外**連畫都不畫**，所以遮罩要放大到 `ChatPanel.get_chrome_rect()`
- `PetPack` 找不到 `HOME` 會退 `USERPROFILE`
- 透明／置頂／無邊框都在 `project.godot`，不是平台專屬設定

這次補的：**Windows 的憑證儲存**（原本只有 macOS 與 Linux，Windows 會直接掉回明文
`config.cfg`）。做法與取捨寫在 CLAUDE.md「Windows has no usable credential-store
CLI」。連帶把 `SecretStore.read()` 加了 per-process 快取 —— 它是**每次對話都會呼叫**
的，PowerShell 冷啟動要接近一秒而且卡主執行緒。快取要小心的地方：`write()` 靠讀回來
比對驗證自己，那條路徑必須繞過快取，否則 macOS 的 128 字元截斷防護會變成空轉。

還沒驗，而且需要真的機器：

- **Ubuntu 的 Wayland 是最大風險，而且可能是擋死的**。Wayland 協定不讓 client 自己
  決定視窗位置，而「走到右下角」「拖著牠移動」正是這隻寵物的核心行為。
  `screen_get_image()` 在 Wayland 下要走 portal，未必接得到。短期只承諾 X11
  （`--display-driver x11`，或登入時選 Ubuntu on Xorg）—— 但 X11 也不是沒事，見下
- Windows 的 DPAPI 那條路完全沒跑過。設計上失敗會被 `write()` 的讀回驗證擋下來，
  `Config.set_secret()` 回 false，UI 會照實說「這台機器沒有安全儲存」—— 是安全地降級，
  不是掉 key，但「能用」還是要有人真的按一次
- 三個平台的螢幕擷取權限模型都不一樣

### 2026-07-28 —— Ubuntu 24.04 / GNOME on X11 實機跑過了（從原始碼，不是 export）

Godot 4.7.1 官方 Linux build，`--headless --import` 全過，執行走 Vulkan Forward+。
透明、無邊框、置頂、passthrough 都正常。**匯出的 build 仍然沒跑過**，這次驗的是原始碼。

上面「X11 應該沒這些問題」是錯的：

- **mutter 會把整個視窗壓回 `_NET_WORKAREA` 裡面**，於是「視窗刻意 overhang 出螢幕
  邊緣、讓寵物走到角落」整段失效 —— 寵物拖得動，但差 220px 到不了右下角。細節與最後
  的作法（`ANCHOR_RATIO` 降級成預設值，`_anchor` 改成可動，並在啟動 park 時順便量這個
  WM 會不會夾）寫在 CLAUDE.md「GNOME won't let it hang off」。
  `FLAG_POPUP` 想繞過 WM —— Godot 對主視窗直接拒絕；把視窗放大到塞不進 work area 更慘，
  會被釘死在 work area 原點完全不能動
- `screen_get_scale()` 回 1.0，如預期走 `screen_get_dpi() / 96` 的退路。這台 DPI 81，
  算出來 `maxf(1.0, 0.84)` = 1.0，所以 DPI 那條路在這台機器上其實沒被真的考驗到
- 憑證儲存要 `libsecret-tools`（`secret-tool`），Ubuntu 桌面預設**沒裝**。gnome-keyring
  本身有在跑，所以只差那支 CLI。沒裝的話 `SecretStore.is_available()` 回 false、
  `Config.set_secret()` 回 false，UI 會照實說是明文 —— 降級是對的，但第一次用的人
  會直接撞到
- TTS 的 `speech-dispatcher` 這台預設就有（`speech-dispatcher-espeak-ng`）。原本那條
  「沒裝是無聲失敗」的風險仍然成立，只是 Ubuntu 桌面預設不會踩到

### 2026-07-28 —— 四個功能一起進來

游標反應與拖曳手感／拖檔案給寵物／會提到記憶的搭話／照使用者節奏挑搭話時機。四個各自
獨立做完再合，共用的東西（`_apply_pose()`、`_step_drag()`、`ask_about_image()`、
`nudges.json`）沒有互相蓋掉，EventBus 那條線也守住了 —— `pet.gd` 還是只做接線，
而且沒有任何一條「主動」路徑會打到 LLM。

**驗到什麼程度**：`--headless --import` 全過（這是唯一的靜態檢查），review 另外抓出兩個
真的會壞的地方並修掉（見下）。**macOS 與 Windows 一次都沒跑過，export build 也沒有**；
Linux 這邊除了下面特別註明的以外，也沒有留下逐項實機驗證的紀錄。每一段的「還沒驗」都是
字面意思。

#### 游標反應與拖曳物理

游標靠近時寵物會朝它偏一點、微微挺起來，遠了淡掉；抓起來壓扁；放開是「先撞一下再彈回來」
不是瞬間歸位；拖著走的時候身體會落後游標並跟著傾斜。

- 現在有四條會動 sprite 的通道（朝向／游標傾斜與挺身／被抓的壓扁／拖曳落後的傾斜），
  全部收進 `PetVisual._apply_pose()`。原本是誰最後呼叫誰就直接寫 `_sprite.offset`，
  等於互相蓋掉 —— `set_facing()` 會把游標剛擺好的 offset 洗掉。以後要加「寵物看起來怎樣」
  的東西，是在那個函式裡加一條通道，不是再寫一次 sprite
- 放開改成進 `Mode.SETTLE`，跟 `DRAG` 共用 `_step_drag()`。它沒有自己的動畫列也不需要，
  `_resolve_row()` 本來就會退回 idle，`drag` 一直都是這樣

踩到的坑（兩個都是 review 才抓出來的）：

- **SETTLE 不能只靠距離判斷結束**。落點是游標算出來的原始座標，而寵物常常不被允許站在
  那裡 —— 在右下角（牠的預設家）放開、游標又在螢幕邊界外，`set_pet_screen_position()`
  每一步都會夾，距離永遠收斂不到。結果是這一輪執行裡 brain 再也回不到 `IDLE`
  （不走路、不睡覺、不會醒），傾斜卡在半路，而且 `pet_moved` **每一幀**都在發，
  每幀重排聊天 UI、重推遮罩。改成「到位**或**卡住不動」都算結束，順便讓 `_step_drag()`
  在座標沒變時不要寫視窗
- **壓扁通道要有單一擁有者**。放開的落地是 0.34 秒的 tween，在那段時間內再抓一次，
  舊 tween 會在新的抓取底下繼續把壓扁值推回 0 —— 被抓著的寵物自己彈回原狀，而且游標反應
  （判斷條件正是「壓扁為 0」）會在拖曳中途被重新啟動
- `_enter(Mode.TALK)` 裡那行 `drag_lean_changed(0.0)` 是必要的不是裝飾。
  `on_talk_started()` 只擋著不打斷進行中的 `DRAG`，所以 TALK 可以直接從 SETTLE 進來，
  這時沒有任何東西會再把傾斜推回去，剛落地就開聊天欄的話傾斜就凍在半空

還沒驗：手感（落後多少、彈多大、落地那一下的大小）本來就只能用眼睛判斷，而這組數字還沒有
在真的用一陣子之後回頭調過。`DRAG_LEAN_REFERENCE` 這類常數都有乘 `get_ui_scale()`，但這台
算出來就是 1.0，跟 DPI 那條路一樣沒被真的考驗到 —— Retina 與 125% 上會不會太誇張不知道。

#### 拖檔案給寵物看

把檔案拖到寵物身上 → 文字檔讀前 4000 bytes、圖片走既有的 `image_url` 那條路 → 寵物照
內容回話。讀不了的（資料夾、太大、不認得的副檔名、空檔、路徑不見了）也一定會講一句，
不會沉默。

- **`Window.files_dropped` 不受 passthrough 遮罩塑形**。它走的是 OS 原生的
  drag-and-drop 目標註冊，跟遮罩塑形的那套點擊測試是兩回事，所以視窗那一大塊透明的
  overhang 區域裡隨便哪裡放開都會觸發 —— 包含右下角壓在底下的桌面圖示。所以
  `WindowController` 只負責回報（視窗座標），由 `pet.gd` 用 `_pet_box` 判斷是不是真的
  丟在寵物身上；不然把檔案拖過寵物丟到桌面會被劫走。
  （這句是從「兩套機制本來就分開」推的，不是三個平台都量過。不過那個命中測試怎樣都要做：
  Windows 的遮罩本來就被放大到整塊聊天面板了）
- **另開一條 `file_content_said`，不重用 `user_said`**。`LLMService` 在 `user_said` 上
  還掛著看螢幕的本地片語比對，那是為「一句短短的打字提問」寫的盲目子字串比對，檔案內容、
  甚至只是檔名（`我的螢幕錄影.mp4`）都會誤觸 —— 這個 repo 自己的 PLAN.md 裡就有
  「我在幹嘛」四個字。TTS 與 PetState 要的還是原本那套反應（停止念稿、算一次互動），
  所以它們把既有的 handler 也接到新 signal 上
- 圖片走 `ask_about_image()` 但 `ephemeral = false`。看螢幕是「剛好瞄到什麼」，不該變成
  永久事實；使用者特地拖過來的檔案是他自己要給的，跟一般對話一樣進歷史
- Windows 給回來的是反斜線路徑，而 `String.get_file()` / `get_extension()` 只認 `/`，
  沒正規化的話會看起來「沒有目錄也沒有副檔名」。進 `handle_drop()` 第一件事就是換掉
- `persona.md` 要跟看螢幕一樣開例外，不然模型會對著明明貼在訊息裡的內容說「我看不到檔案」

已知還沒補的：圖片那條直接呼叫 `ask_about_image()`，沒有發 `file_content_said`，所以丟
一張圖不會打斷正在念的 TTS、也不算一次互動 —— 丟文字檔兩件事都有。

還沒驗：整條路徑除了 `--headless --import` 之外沒有留下實機驗證紀錄。macOS 與 Windows 的
`files_dropped` 行為都沒試過（Windows 那邊遮罩同時還在裁繪製），反斜線那段自然也從來沒有
真的跑過 Windows。

#### 會提到記憶的主動搭話

`nudges.json` 多了第四池 `memory`，裡面是 `{fact}` 樣板而不是完整句子，挑的時候從
`MemoryStore.facts()` 填進去 —— **一樣不叫 LLM**，跟其他三池一樣便宜。

- facts 是某個模型某個時候寫出來的自由文字，不是這邊控制的東西，所以 `_usable_facts()`
  先擋掉超過 30 字的、還有帶句末標點的：把一個完整句子塞進「你記得你{fact}耶」，等於把
  兩句話沒有連接詞地黏在一起
- 有得用的時候也只有 40% 機率挑它，免得同幾個事實變成口頭禪；最近用過的三個會避開，但
  只存在記憶體、不落盤 —— 跟 `_last_nudge_at`、`_quiet_target` 一樣，重開忘記可以接受

還沒驗：要先累積出 facts 才看得到，而 facts 得真的走 API 才抽得出來（mock 抽不出東西），
所以這池實際唸出來像不像人話，還沒有在真的用了一陣子的記憶上看過。

#### 照使用者的節奏挑搭話時機

`autoload/presence_service.gd`：每 30 秒取一次最上層 App 的名字與停留時間，給 Nudger
決定「什麼時候講」。同一個 App 連續 45 分鐘就給一句休息提醒（新的 `focus` 池；原本放在
`lonely` 裡那句「你已經盯著螢幕好久了」現在有真的依據，搬過去了）。

- 蒐集的東西刻意薄：只有一個不透明的 App 識別字（Linux 取 WM_CLASS 的 class 那半、
  macOS 取 process name），**絕不碰視窗標題** —— 文件名、訊息、網址都住在那裡。
  不寫檔、不寫 log，只存在記憶體與 EventBus 上
- 同意拆成兩個 key：`consented` 給過就一直有效，`enabled` 是當下的開關。跟看螢幕不一樣
  的地方在於，看螢幕每次都問（每次截圖都是一個獨立決定），而背景輪詢沒有「就這一次」
  這種選項 —— 這裡唯一能按的「好」本身就是長期同意，所以按鈕也照那個意思做成整個視窗裡
  最安靜的那個
- **Windows 直接回報不支援，是刻意的**。`GetForegroundWindow()` 從 PowerShell 走要
  `Add-Type` 編一段 P/Invoke，每開一次 `powershell.exe` 都要付一遍，就是 CLAUDE.md 講
  `CredRead` 時那個「將近一秒」—— 差別在這個會掛在無人看管的計時器上跑一整天，而
  SecretStore 有快取只付一次。選單那項直接 disable，不要每 30 秒卡一下
- macOS 走 `osascript`，**第一次呼叫就是會跳出「控制 System Events」權限的那次**。所以
  `grant_consent()` 立刻取樣一次而不是等計時器 —— 權限視窗要在使用者還盯著剛按下的對話框
  時出現。`_run()` 的 timeout 也是為它準備的：沒人回答的權限視窗會一直掛著
- 取不到樣不等於「切到沒有 App」。一次讀失敗不可以把累積的專注時間歸零
- `_run()` 明確 close 掉 stdio。SecretStore 是一次性寫入可以交給 refcount，這個是活到
  行程結束的重複計時器，漏掉一個 pipe handle 就是慢性 fd 洩漏

還沒驗：

- **macOS 那條完全沒跑過**：Automation 權限提示長什麼樣、使用者按拒絕之後 `osascript`
  是回錯誤還是就卡著，都不知道
- Linux 要 `xprop`（`x11-utils`）。這台 Ubuntu 24.04 上有，而且是被別的套件帶進來的、
  不是手動裝的，但沒查證是不是每台桌面都會有 —— 沒有的話 `is_supported()` 回 false、
  選單那項直接 disable，跟缺 `secret-tool` 一樣是安全地降級。另外 Wayland 下
  `_NET_ACTIVE_WINDOW` 根本不存在，一律回不支援 —— 跟視窗定位一樣，這個功能也只承諾 X11
- 45 分鐘門檻 + 共用的 35 分鐘理由冷卻，等於一個長時段大約每 35 分鐘會被唸一次。這組數字
  沒有真的連續用一整天測過，「關心」與「嘮叨」的界線要實際用過才知道

### 2026-07-28 —— 對話記錄視窗（已完成）

記憶其實一直都在存，缺的是**看得見**。氣泡是「講話」，行為也像講話：一次一句、最多撐 22
秒、長回覆還會在氣泡裡自己捲走。那對一隻寵物是對的，對「回頭找牠剛剛說了什麼」是沒用的。
`ui/chat_log_panel.gd` 補的是另外那一半，選單第四項「對話記錄…」開，跟 `MemoryPanel`
一樣是獨立的 OS 視窗（子視窗嵌入全域關掉，寵物自己的視窗小到裝不下東西）。

獨立視窗還順帶避開一整類麻煩：它跟寵物視窗的 passthrough mask 無關，所以 Windows 上那條
「mask 會連畫面一起裁掉」的規則碰不到它。

- **不做常駐對話面板，是刻意的**。輸入框一旦變成固定的聊天視窗，這東西就從桌寵變成一隻長得
  像寵物的 ChatGPT，氣泡跟走動都退化成裝飾。氣泡留著當主要出口，這個視窗是「翻回去看」的
  地方，看完就關
- 資料只從 `MemoryStore` 讀，不自己留一份 —— 跟 Phase 9 把歷史所有權收攏到一處是同一個
  理由
- **清空只丟 history，保留 summary 和 facts**。這是三層架構本來就能表達、但一直沒有出口的
  語意：忘掉我們剛剛聊什麼，但別忘記我是誰。要全部忘光是隔壁視窗的「全部忘掉」
- 清空前會先問一次（按鈕自己變成問句），跟 `MemoryPanel` 的「真的全部忘掉？」同一招。丟掉
  的逐字對話沒有任何地方找得回來
- 摺疊中途被清空，回來的摘要必須丟掉。`MemoryStore._epoch` 就是為此存在 —— 不然使用者按下
  清空的那批對話，會由一個還在飛的背景請求寫進永久層，正好是清空唯一必須排除的結果
- ephemeral（看螢幕的回答）在清單裡照顯示，但標成「這則關掉就忘了」。看得到才知道那個承諾
  是真的
- 確認清空的那句話**不記進 history**（`_on_pet_nudged` 的 `record` 參數）。不然清完會剩下
  一則「我已經清空了」躺在那裡，計數停在 1，看起來像只清了一半。順手把
  `_on_memories_changed` 那句也改成一樣

踩到的兩個 Godot 細節：

- `HBoxContainer` 裡只給 `SIZE_SHRINK_END` **沒有用**。HBox 把不 expand 的子節點按最小寬度
  一個接一個排，SHRINK_END 沒有空間可以靠 —— 每一列都貼左，而「哪一邊」是這個清單裡唯一
  在說話者是誰的東西。要 `SIZE_EXPAND | SIZE_SHRINK_END`
- 清空按鈕原本用 `make_ghost_button`，結果這視窗**唯一的重點動作**看起來像 disabled，旁邊
  的「關閉」反而像真正的按鈕。改回普通 themed button

沒驗：實際用滑鼠點過（這台沒有 xdotool，沒辦法合成點擊），上面的狀態都是用暫時的除錯掛鉤
驅動再截圖確認的。

### 2026-07-28 —— 小遊戲「接東西」（已完成）

到目前為止跟寵物的互動只有兩種：講話，和點一下。「餵食」是選單裡的一行字，按下去牠說謝謝
—— 那是**指令**，不是**一起做一件事**。這個補的是後者。

`ui/catch_game.gd` 是場地，`ui/game_panel.gd` 是視窗。跟記憶、對話記錄一樣是獨立的 OS
視窗，理由也一樣：子視窗嵌入全域關掉、寵物視窗小到裝不下、而且順帶完全避開 passthrough
mask 那一整類麻煩。

- **場上的角色就是桌面上那一隻**，不是通用替身 —— 這是整件事的重點，不然就只是一個內建在
  桌寵裡的小遊戲，而不是「跟你的寵物玩」。所以 `PetVisual.state_rows()` 才存在：遊戲要拿
  到的不是 pack，是**解析完的**列對照表，因為使用者的 `[pet_rows]` 修正、以及某些 pack
  根本沒有某個狀態時該借哪一列，正好是遊戲自己會猜錯的兩件事 —— 猜錯的結果就是寵物在漏接
  的時候笑
- 尺寸也跟著 `PetVisual` 的規矩走：量 idle 那一列的角色高度，不是 cell。四個 pack 填滿
  cell 的程度從 76% 到 95%，照 cell 縮放會讓遊戲裡的寵物跟桌面上的一大一小
- 沒裝 pack 就用 `FallbackBlob`（為此補了 `class_name`）。同樣的理由：桌面上是誰，場上
  就該是誰
- **場上唯一的紅色，是不能接的那一個**。食物需要好幾個飽和色才分得出來，這跟 `PetStyle`
  開頭「只有一個柿子色」的規矩是衝突的，所以這一面換一條規矩來守：能吃的是米白、綠、青，
  加分的星星是金色，辣椒是唯一的紅。把好東西跟壞東西看錯是這個遊戲最不能發生的失敗
- 漏掉辣椒**不扣任何東西**。放它過去是正確打法，場上不該有任何懲罰打對的地方
- 三個難度，最高分**各記各的**（`config.cfg` 的 `[game]`）。共用一份的話，第一次去玩
  手忙腳亂就會讓悠哉的紀錄永遠沒有意義，反之亦然
- 玩到一半改難度會**中止**當局，而且是 abandon 不是 finish —— 規則中途換掉的分數沒有意
  義，更不該進紀錄表
- 遊戲會加飽食度（牠確實吃下去了），但**上限鎖死**在一次餵食的三分之一以下
  （`PetState.PLAY_FULLNESS_CAP`）。不鎖的話「玩到牠不餓」會悄悄取代餵食，而那是比兩者
  都差的循環
- 結束後說的那句話由 `pet.gd` 出，不是 `GamePanel` —— 視窗知道分數和紀錄，但「寵物怎麼
  反應」從來只有組裝根知道。破紀錄是唯一值得換一句話的結果，所以 `played` 訊號把
  `record` 一起帶出來
- 選單走 **遊戲 → 接東西…** 而不是平鋪一行。平鋪的話第二個遊戲會變成跟「餵食」「回到角落」
  並排的另一個頂層項目；包起來它只是第一個的兄弟，選單就停在這一層不再長

鍵盤與滑鼠共用同一條軸，誰後動誰贏。兩個都要，是因為這個視窗是用滑鼠從右鍵選單開的，然後
會被握著玩一分鐘 —— 那正是方向鍵開始比較舒服的時候。

踩到的三件事：

- **視窗裡每一顆按鈕都必須 `FOCUS_NONE`**。有焦點的 `Button` 會把左右方向鍵吃掉當焦點導
  覽，而左右方向鍵就是這個遊戲的操作。點過一次難度之後就再也走不動
- 鍵盤用 `Input.is_key_pressed()` 輪詢，不用事件，而且**要檢查視窗有沒有焦點**。焦點跑掉
  時按著的鍵永遠不會送出放開事件，事件版會讓寵物一直撞牆；更糟的是你切過去的那個 App 裡
  按方向鍵，還在操作一個你已經看不到的遊戲
- `CenterContainer` 裡放會自動換行的 `Label`，兩者會互相塌陷 —— 容器照內容決定寬度，而自
  動換行的 label 沒有堅持的寬度。開場提示因此被切成六行的「點一下開 / 始」。改成不換行、
  自己手動斷行

沒驗：實際用鍵盤玩過（這台沒有 xdotool，合成不了按鍵）。使用者手動玩過一局確認可玩，最高
分 9 有正確存回 `config.cfg`；其餘畫面狀態是用暫時的除錯掛鉤驅動再截圖確認的。也沒有人從
頭到尾跑滿一場手忙腳亂，所以那條難度曲線的後段（`MAX_SPEEDUP` 撞頂之後）沒有人看過。

### 2026-07-28 —— 再兩個遊戲，以及把「遊戲」拆成一個底座（已完成）

`GamePanel` 原本寫死 `CatchGame`。要放第三個遊戲，先拆：`ui/games/mini_game.gd` 是「一個
遊戲是什麼」，`GamePanel` 只認得那個介面。視窗周邊的東西（場地外框、分數、每個難度各自的
紀錄、開場與結束的橫幅、寵物、以及「這裡沒有任何東西可以拿到焦點」這條規矩）全部只寫一次。

**三個遊戲是三個不同的動詞**，這是選題的唯一標準：

| 遊戲 | 問你什麼 | 怎麼結束 |
|---|---|---|
| 接東西 | **在哪裡**，持續地 | 漏三個 |
| 跳過去 | **什麼時候**，一次 | 撞三次 |
| 翻翻看 | **記得什麼** | 配完整盤 |

三個都做反應遊戲的話，那就是同一個遊戲換三次漆。桌寵是一個人想事情的時候會看一眼的東西，
不是只有在手忙的時候才有用。

- **跳過去只有一顆按鈕，而且沒有二段跳**。二段跳會把每一次沒抓準的起跳都變成可以補救的，那
  之後這遊戲就不再關於那個判斷了。空白鍵／↑／W／點一下都能跳 —— 沒被教過的人會亂試的那
  四種，而橫幅只放得下兩種
- **翻翻看是唯一「完成」而不是「失敗」結束的**，所以它沒有那排命數點（`uses_lives()` 回
  false），分數是配完一盤花了你幾次錯誤。難度是盤面大小加上翻錯後停留的時間 —— 標籤直接寫
  `3×4` `4×4` `4×5`，因為這個遊戲沒有任何東西會變快，套「悠哉／手忙腳亂」是說謊
- 共用的兩塊：`game_pet.gd` 畫寵物（拿 `PetVisual.state_rows()`，理由同上一節），
  `game_art.gd` 畫其他所有東西。後者**每個形狀都不假設背後是什麼顏色** —— 同一個甜甜圈在
  一個遊戲裡畫在近黑的場地上，在另一個遊戲裡畫在紙色的牌上，第一版用場地色挖洞，結果在牌
  上留下一塊髒污。所以甜甜圈是 `draw_arc` 畫的環，眼睛用具名的 `GAME_ITEM_INK`
- 圖案從 8 種加到 **10 種**，因為翻翻看最大盤是 10 對。八種的話會有兩種各出現四張 —— 聽起
  來比較難，實際上比較簡單，因為四張裡任兩張都算配對。補的兩種挑的是剩下的色域：沒有藍色，
  也沒有深綠
- 遊戲物件建好就留著（`GamePanel._swap_field`），換回去不用重建，也不會每次都從 pack 重
  切一次 sprite
- 選單 id 從 `GAME_BASE` 起算，所以 `_build_games_menu()` 直接照 `GamePanel.GAMES` 長。
  注意 `_on_menu_pressed` 每一個 base 判斷都是「大於等於」，所以 400 必須排在 300 前面

寫壞又抓回來的兩個：

- **跳過去的碰撞高度判斷本來恆為真**。寫成兩個矩形相比時，`feet` 和 `ground` 差的就是
  `_air`，整條式子化簡成 `-_air - height < 0` —— 永遠成立，每一次跳都是假的。這個遊戲只有
  一條軸，判斷就該寫成「離地多高」：`_air < 障礙高度`
- **撞到的障礙物滑出畫面時照樣給分**。所以一場什麼都沒跳過的run 也有分數，那個數字的意思
  正好相反。截圖看到「自動開局、沒有任何輸入、結束時 2 分」才發現

`class_name` 不是常數運算式，所以註冊表用 `preload()` 路徑。把 `CatchGame` 放進那個 const
陣列是整個檔案的 parse error，而且會連 `pet.gd` 一起拖下去。

沒驗：翻翻看和跳過去我都沒有真的用鍵盤玩過（一樣是 xdotool），使用者手動按過說沒問題。全部
十種圖案在牌面尺寸下的辨識度、以及「已配對」的淡化狀態，是把整盤 4×5 強制翻開截圖確認的。

### 2026-07-28 —— 讓寵物會產出檔案，以及選模型（已完成）

三件一起進來：右鍵選單能選模型、一個寵物專用的產出資料夾與它的視窗、還有把 Codex CLI 接成
「幫我做個東西」的後端。

**選模型。** `OpenAIProvider.MODELS` 是清單，id 是打 `/v1/models` 抄回來的，不是憑印象寫的
—— 這個世代根本沒有 `gpt-5.6` 這個 id，是 `-sol` / `-luna` / `-terra`。選單裡只有「量過的」
警告才會標註，所以 `gpt-5.4-nano` 寫著「看不懂螢幕」（它 `[look]` 是 0/12），其他都不寫。
還是把 nano 列出來，因為它是最便宜的聊天方式，不問螢幕的人應該可以在知情的狀況下選它。

`MODEL_BASE` 是 500，而且必須排在 `GAME_BASE`(400) 前面檢查 —— `_on_menu_pressed` 每一條
判斷都是「大於等於」，這個坑之前小遊戲那次就踩過一次了。

**產出資料夾。** `OutboxService` 只認一個資料夾（本機是 `~/文件/GodotPet`）。刻意不用
`user://`：埋在 `~/.local/share` 底下就失去意義了，寵物做的東西的價值就在於你找得到、打得開。

**檔名一律不可信** —— 寵物自己的匯出是安全的，但「做東西」那條路的檔名來自模型輸出，而模型
的輸入本來就包含使用者拖進來的檔案內容、以及截圖裡讀得到的字，兩個都是可以被塞進一句話的
地方。所以消毒過的結果（實測）：

| 輸入 | 輸出 |
|---|---|
| `../../../etc/passwd` | `passwd.md` |
| `/etc/shadow` | `shadow.md` |
| `..\..\windows\system32\evil.exe` | `evil.exe.md` |
| `.bashrc` | `bashrc.md` |
| `run.sh` | `run.sh.md` |
| `a/b/c.txt` | `c.txt` |
| 空字串 / `...` | `小紙條.md` |

副檔名是白名單而且沒有任何可執行的東西；不在名單上的不會被丟掉，而是併進主檔名，所以
`run.sh` 變成 `run.sh.md` —— 不能跑，但看得出當初要的是什麼。同名絕不覆蓋，`note.md` 寫兩次
會得到 `note.md` 和 `note-2.md`。

**沒有逐檔詢問的對話框**，這是刻意的。跟看螢幕不一樣，寫進一個為此存在的資料夾不會把東西送
去任何地方、也不會破壞任何東西；它的風險是「亂」，而對付亂的方法是看得見 —— `OutboxPanel`
是第三個跟記憶、對話記錄同形狀的視窗，每一行都能單獨刪掉。

**先做不需要模型的那半邊是對的。** 對話記錄的「存成檔案」完全不呼叫 API，是這個 app 裡唯一
能在關掉 LLM 的狀態下產生檔案的功能 —— 也正因為如此，資料夾那一整套在 agent 還沒接上以前
就能測完。ephemeral 的那幾則在 Markdown 裡保留「這則關掉就忘了」的註記，不然一份匯出就把
看螢幕的回答偷偷升格成永久紀錄，那正是 ephemeral 存在要擋的事。

**Codex 只接「做東西」，不接聊天。** 在這台機器上量的（ChatGPT Plus、`gpt-5.6-sol`）：

| | 閒聊一輪 | 成功寫檔一輪 |
|---|---|---|
| 耗時 | 5–6 秒 | 約 9 秒 |
| input tokens | 約 15.7k | 約 31.6k（一半命中 cache） |
| output tokens | 25–36 | 約 100 |

決定性的兩點：**完全沒有 token 串流**（`--json` 只給一個裝著整段回覆的 `item.completed`，
96 個 feature flag 裡也沒有相關選項），這一次打掉打字機效果、情緒標記提早到達、以及 TTS
逐句念三件事；而每句閒聊 15.7k input token，等於在寵物自己那 1–2k 的 prompt 上疊了約 14k
的 agent 架構，聊天路徑一點都用不到。同樣的代價放在做檔案上就完全合理。

沒有自己做 OAuth。`codex login` 已經處理完了，`~/.codex/auth.json` 是 CLI 自己的檔案，這個
repo 一行都不讀 —— 跟 `SecretStore` 呼叫 `security` / `secret-tool` / `powershell` 同一個
形狀。冒用 Codex client id 去花 ChatGPT 額度這件事，跟之前一樣不做。

**不接管道（pipe）是這裡最重要的工程決定。** `FileAccess.get_line()` / `get_buffer()` 在
pipe 上會**阻塞**到有位元組為止，而這個 agent 一想就是好幾秒，從 `_process` 輪詢它會直接凍住
視窗，Godot 也沒有「有沒有資料可讀」的測試。放著不讀更糟：OS 緩衝區一滿，子行程就卡在寫入
永遠不結束。所以改成用 `/bin/sh -c` 啟動，stdout、stderr、stdin 全部重導向：收尾那句話從
`-o` 拿，做了什麼檔案則是比對資料夾前後的差異。關掉 **stdin** 也是必要的 —— 新版 CLI 就算
已經有 prompt 參數還是會再讀 stdin，接到終端機就會一直等下去。

**絕不繼承 `~/.codex/config.toml`。** 它釘著使用者自己工作用的模型，過期的那個會被直接拒絕，
而錯誤訊息長得像帳號問題（*"not supported when using Codex with a ChatGPT account"*），完全
看不出跟寵物有什麼關係。每次都用 `-m` 明講。

**Ubuntu 24.04 的沙箱要先修。** `codex exec -s workspace-write` 用 bubblewrap 建沙箱，而
Ubuntu 24.04 設了 `kernel.apparmor_restrict_unprivileged_userns=1`，且 `/usr/bin/bwrap`
沒有 setuid，所以每次寫檔都失敗在 `bwrap: loopback: Failed RTM_NEWADDR`，agent 重試四次之後
只回報一句含糊的「工作區沙箱發生權限錯誤」—— 50 秒、約 150k input token 換來零產出。

解法是 `/etc/apparmor.d/bwrap`：一個 `flags=(unconfined)` 加 `userns,` 的具名 profile，照
Ubuntu 自己的 `/etc/apparmor.d/flatpak` 抄。比另一個常見解法（`sysctl` 全機器關掉）窄得多，
但確實會讓所有呼叫 bwrap 的程式都恢復這個能力。修完有回頭確認沙箱**還是會關人**：叫它寫
`-C` 根目錄以外的路徑會被拒絕、也沒有檔案產生。注意 `workspace-write` 模式下 `/tmp` 也是可
寫的，那是 CLI 的預設，不是我們給的。

沒驗：Windows 直接回報不支援（啟動器是 `/bin/sh`），macOS 沒試過。選單項在偵測不到 `codex`
時是 disabled 而不是隱藏 —— 跟 `PresenceService` 同一個判斷，會消失的功能等於沒人知道它存在。

`pkill -f "godot --path"` 這個指令從 agent 的 shell 跑會殺掉自己（自己的命令列裡就有那串），
要用 `pkill -f "godot --pat[h]"`。

### 2026-07-28 —— 沒登入過 Codex 的人也能從介面登入（已完成）

原本「幫我做個東西」預設使用者已經在終端機跑過 `codex login`。現在寵物自己問。

`autoload/codex_cli.gd` 管帳號，`MakerService` 管工作。**一樣沒有自己做 OAuth、也不讀任何
token** —— 兩條路都是啟動廠商自己的 `codex login`，`~/.codex/auth.json` 是它的檔案，這個
repo 一行都不碰。選單項目在沒帳號時**仍然可用**：有沒有 CLI 和有沒有帳號是兩件事，只有後者
問一下就能解決。

- **`--with-api-key`（走 stdin）**：直接用這個 app 已經存著的 key，不用瀏覽器。key 走 stdin
  不進 argv，理由跟 `SecretStore` 一樣 —— `ps` 會把別人的 argv 給同一個使用者看。代價是照
  API 計費而不是訂閱。
- **`--device-auth`，而不是預設的 localhost 流程**：預設那條會綁 `localhost:1455` 並在
  **這台機器**開瀏覽器，而那正是遠端桌面 / headless 會踩空的假設 —— CLI 自己的輸出就寫著
  「On a remote or headless machine? Use `codex login --device-auth` instead.」。device auth
  給的是一個短網址加九個字元，這是氣泡裝得下的東西，400 字元的 OAuth URL 不是。預設那條唯一
  白送的好處是幫你開瀏覽器，所以拿到網址後我們自己開。

實測（全程用隔離的 `CODEX_HOME`，沒碰到真正的 `~/.codex`，mtime 前後一致）：

- 未登入時 `login status` exit 1 → 對話框正確跳出
- 點「用我存的 API key」→ 寵物說「用你的 API key 登好了，那我開始做。」→ **輸入框自動接上**
- 點「用 ChatGPT 帳號登入」→ 幾秒後氣泡：「我開了登入頁，輸入這組碼就好：W6J9-CQ3LW（已經
  幫你複製了）」，跟 CLI log 裡的代碼一致

沒驗：真的完成 OAuth 交換那一步（需要使用者本人的瀏覽器和帳號），所以 device 這條的
`login_finished(true)` 和「登完自動接上做東西」還沒有人跑過。API key 那條的自動接上有驗到。

三個坑：

- **`\u` 在 Godot 的 RegEx 裡是非法的**。它是 PCRE2，要寫 `\x1b`。而且失敗得很安靜 ——
  `sub()` 直接回空字串，結果是代碼永遠找不到、寵物一句話都不說，log 才看得到
  `PCRE2 does not support \F, \L, \l, \N{name}, \U, or \u`。
- **CLI 就算 stdout 導到檔案還是會上色**，所以比對前一定要先剝掉 ANSI escape。
- `is_logged_in()` 要快取。`codex login status` 要 60–90ms，每次開選單都跑一次會頓。

驗證方法本身也升級了：這次全程在**隔離的 X display 上點**，沒有動到使用者的滑鼠。做法記在
CLAUDE.md 沒有、但值得記的一句：寵物會走動，UI 自動化前先把 `[pet] roaming` 設成 false，
否則座標追不上。

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
