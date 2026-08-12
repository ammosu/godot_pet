# 桌寵對桌面合成器的成本

一份改進建議。起因是查「為什麼 GNOME 的檔案管理器開資料夾很慢」，一路查下來發現
**是這隻寵物讓整個桌面的視窗開啟都慢了 2 倍以上**，跟被開的資料夾無關。

量測環境：2026-08-11，Ubuntu 24.04.4 LTS / X11 / GNOME / RTX 4090 / NVMe。
節流帶來的 CPU 與耗電改善各平台通用；「視窗開啟慢 2 倍」這個數字是 X11 特有的，
macOS 的 Quartz 合成模型不同，需要另外量。

**量了兩輪，跑在兩個不同的 build 上。** 第一輪是 `599544f`（Forward+ / Vulkan），
第二輪是 `8c0463b`（GL Compatibility —— 見建議 4，那條路已經被別的理由走完了）。
兩輪的絕對值不可直接比，第二輪的縮圖快取是熱的；可以比的是倍率，而**倍率沒有變**。
這一點本身就是結論：換掉 renderer 沒有讓這個問題變小。

## 實測證據

用 `kill -STOP` / `-CONT` 暫停與恢復寵物行程，重複量測。C 組是恢復後的回測，
用來排除「剛好那段時間比較閒」的雜訊 —— 它完整復現了 A 組。

### 開一個無關的視窗（gnome-calculator，單純 GTK4 程式）

第一輪，`599544f` / Forward+：

| 情境 | 三次量測 | 平均 |
|---|---|---|
| A：寵物執行中 | 1.64 / 1.44 / 1.71 s | **1.60 s** |
| B：寵物暫停 | 0.70 / 0.75 / 0.57 s | **0.67 s** |
| C：恢復後回測 | 1.79 / 1.71 s | **1.75 s** |

### 開一個項目多的資料夾

第二輪，`8c0463b` / GL Compatibility，`~/下載`（238 項），縮圖快取熱，
桌面全程無人操作：

| 情境 | 視窗出現 | 完全載入 |
|---|---|---|
| A：寵物**沒有執行** | 1.02 / 0.83 / 0.93 s → **0.93 s** | 3.86 / 3.14 / 3.51 s → **3.50 s** |
| B：寵物執行中 | 2.16 / 1.93 / 2.04 s → **2.05 s** | 8.04 / 7.98 / 8.78 s → **8.27 s** |
| C：寵物 SIGSTOP（回測） | 1.01 / 1.05 / 1.09 s → **1.05 s** | 3.58 / 3.65 / 3.54 s → **3.59 s** |

**2.20 倍 / 2.36 倍。** C 組復現 A 組，所以差距是寵物造成的，不是快取隨著測試愈跑愈熱。
這一輪的 A 組是**真的沒有 godot 行程**而不只是暫停，兩者結果一致，等於也驗證了第一輪
用 SIGSTOP 當對照組的作法沒有偏差。

### 降幀率買到了多少（零程式碼實測）

Godot 內建 `--max-fps`，所以建議 1 的整個前提不用寫任何程式就能量。同一組資料夾量測，
同樣的安靜桌面：

| 寵物狀態 | 視窗出現 | 完全載入 | 寵物自身 CPU |
|---|---|---|---|
| 不執行 | **0.93 s** | **3.50 s** | — |
| 60 fps（現況） | 2.05 s | 8.27 s | 13.5% |
| `--max-fps 30` | 1.29 s | 7.83 s | 9.0% |
| `--max-fps 12` | **1.00 s** | 6.88 s | 5.6% |

**這張表把「一個 2 倍」拆成了兩個不同的成本，而它們的成因不一樣：**

- **「視窗出現」幾乎完全由幀率決定。** 12 fps 把它從 2.05 s 拉回 1.00 s，離沒有寵物的
  0.93 s 只差 0.07 s —— 等於整個成本都回收了。
- **「完全載入」幾乎完全不由幀率決定。** 從 60 降到 12（送幀量剩五分之一）只買到
  8.27 → 6.88 s，而基準線是 3.50 s。**剩下的 3.4 秒，降幀率碰不到。**

這正好回答了文件前面那段「SIGSTOP 沒有區分兩種成因」的保留。兩種成因都真的存在：
持續的 damage 事件確實讓視窗**映射**變貴，但讓清單**逐項填滿**變貴的是別的東西 ——
最可能是那個透明置頂視窗本身的**存在與面積**，因為 nautilus 每畫一格清單，合成器都得把
它底下那塊重混一次，而寵物永遠蓋在最上層。

寵物自身的 CPU 則乾淨地跟著幀率走：13.5% → 9.0% → 5.6%，不成正比是因為有大約 4% 的
固定成本。

### 關掉走路買不到東西，而原因值得記下來

那 3.4 秒的第一個嫌疑犯是走路：走一步是移動視窗，而視窗移動 damage **兩塊**區域而不是
一塊。「到處走」本來就是出貨的設定（`行為` 選單，`config.cfg` 的 `[pet] roaming`，
`pet.gd:196`、`2583-2587`），所以這一項同樣零程式碼可測。同一組量測，同樣 `--max-fps 12`：

| 12 fps | 視窗出現 | 完全載入 | 寵物 CPU |
|---|---|---|---|
| 會走路 | 1.00 s | 6.88 s | 5.6% |
| 不走路 | 1.11 s | 7.05 s | 4.8% |

**沒有差別**，在雜訊之內。原因是同一次量測裡順手取樣的視窗位置：138 次取樣，相異位置
**只有一個**（`1480,320`）—— 寵物走路時，視窗**根本沒有移動過**。

那個座標正是 CLAUDE.md「GNOME won't let it hang off」那節記的數字：mutter 把視窗釘在
工作區角落，寵物是在**視窗內部**走（`_clamp_anchor()`）。所以在這台機器上，走路從來就
不會產生視窗移動的 damage，關掉它自然買不到任何東西。

**這個結論是 X11 / mutter 特有的。** macOS 允許視窗overhang，那裡走路是真的會移動視窗，
答案可能不同 —— 但 macOS 的成本結構本來就要另外量（見文件開頭）。

### 縮小視窗也買不到東西

下一個嫌疑犯是面積：合成器每幀重混的是面積，而這個視窗絕大部分是全透明的空氣。
`BASE_SIZE`（`window_controller.gd:17`）是唯一決定它的常數，所以測法是把它從
`440x760` 改成 `240x260` —— **面積剩 18.7%**（334,400 → 62,400 像素）—— 量完還原。
`xdotool` 確認視窗真的變成 240x260 才開始量。

| `--max-fps 12` 下的變因 | 視窗出現 | 完全載入 |
|---|---|---|
| 滿版 440x760、會走路（基準） | 1.00 s | 6.88 s |
| 不走路 | 1.11 s | 7.05 s |
| 面積剩 18.7% | 1.09 s | **6.73 s** |
| （沒有寵物） | 0.93 s | 3.50 s |

**也沒有差別。** 面積砍到五分之一買回 0.15 秒，在雜訊之內。

### 那 3.3 秒是 Godot 的，不是「這種視窗」的

三個變因都量過，結論一致：

| 變因 | 對「視窗出現」 | 對「完全載入」 |
|---|---|---|
| 幀率 60 → 12 | **2.05 → 1.00 s，全額回收** | 8.27 → 6.88 s，只買到 1.4 s |
| 走路 → 不走路 | 無 | 無 |
| 面積 → 18.7% | 無 | 無 |

剩下約 3.3 秒不隨幀率、不隨移動、不隨面積變化，看起來像是「畫面上存在一個 ARGB
永遠置頂視窗」的固定成本 —— 如果是那樣，換掉 Godot 也救不了，因為任何工具做出同一種
視窗都會付一樣的錢。

**這個推論是錯的，而且錯得可以量。** 對照組是一個約 40 行的 GTK3 視窗
（`probe_window.py`）：同樣 440x760、同樣 ARGB（`xwininfo` 確認 Depth 32）、同樣
always-on-top（`_NET_WM_STATE_ABOVE`）、同樣 click-through、同樣停在 `1480,320`、
同樣以 12 fps 重畫一塊寵物大小的區域 —— **實際畫了 243 次 / 20 秒 = 12.15 fps，
數過的**。它不是遊戲引擎，沒有 GL swapchain。

| 12 fps 等級的重畫率 | 視窗出現 | 完全載入 |
|---|---|---|
| 什麼都沒有 | 0.93 s | 3.50 s |
| GTK 探針：透明 + 置頂（模仿寵物） | 0.95 s | **3.11 s** |
| GTK 探針：不透明 + 置頂 | 0.82 s | 2.94 s |
| GTK 探針：透明 + 不置頂 | 0.94 s | 3.37 s |
| **Godot 寵物** | 1.00 s | **6.88 s** |

**GTK 探針的成本是零** —— 三種變體全都落在「什麼都沒有」的雜訊範圍內，透明與置頂
都不要錢。所以那 3.3 秒不是視窗的種類，是 **Godot 本身**。

領先的假說（**尚未驗證**）：Godot 透過 **OpenGL swapchain** present，而 GTK3 的探針
是用 cairo / XRender 畫的。在合成器底下，一個 GL client 的每次 present 都產生新的 buffer
要被取用，而畫面上同時有 Godot、nautilus（GTK4，也是 GL）與 gnome-shell 三方在 NVIDIA
驅動上排隊。這個形狀能解釋所有觀察：不隨面積縮放（成本在 present 本身而不在像素數）、
不隨走路變化、而降幀率只買到一部分（60 → 12 買回 1.4 s）。

### 成本是每次 present 的，而且藏起視窗就消失

兩個零程式碼的實驗把上面那個假說的兩半分開了：

| | 視窗出現 | 完全載入 | 寵物 CPU |
|---|---|---|---|
| 沒有寵物 | 0.93 s | **3.50 s** | — |
| 寵物 60 fps | 2.05 s | 8.27 s | 13.5% |
| 寵物 30 fps | 1.29 s | 7.83 s | 9.0% |
| 寵物 12 fps | 1.00 s | 6.88 s | 5.1% |
| **寵物 1 fps** | 1.05 s | **3.54 s** | 3.2% |
| **寵物 12 fps，視窗 `xdotool windowunmap`** | 0.93 s | **3.33 s** | 4.8% |

- **`--max-fps 1` 完全回到基準線。** 所以不存在「有一個活著的 GL swapchain 就要付錢」
  的靜態成本 —— 成本是**每次 present** 的，Godot 裡還有旋鈕可轉。
- **把視窗 unmap 也完全回到基準線**，而行程仍在跑、仍在算（CPU 4.8%，跟顯示時的 5.1%
  幾乎一樣）。所以關鍵不是這個程式在做什麼，是**那個視窗有沒有在被合成**。

**但曲線不是線性的，而且形狀很重要。** 以基準線 3.50 s 為零點，超出的部分是
60 fps → 4.77 s、30 fps → 4.33 s、12 fps → 3.38 s、1 fps → **0.04 s**。
從 60 降到 12（present 少了五分之四）只買回 1.4 s，從 12 降到 1 卻買回 3.3 s。
也就是說**只要持續以某個速率 present，成本就幾乎滿載**，要到極低的速率才會崩塌。

### 懸崖在 6 和 12 fps 之間

轉折點量出來了，而且很陡：

| 寵物幀率 | 完全載入 | 超出基準線 3.50 s | 寵物 CPU |
|---|---|---|---|
| 1 | 3.54 s | +0.04（1%） | 3.2% |
| 3 | 3.56 s | +0.06（2%） | 3.6% |
| **6** | 3.89 s | **+0.39（11%）** | 4.3% |
| **12** | 6.88 s | **+3.38（97%）** | 5.1% |
| 30 | 7.83 s | +4.33 | 9.0% |
| 60 | 8.27 s | +4.77 | 13.5% |

**6 fps 幾乎免費，12 fps 幾乎滿載。** 兩者之間就是全部的錢。這不是一條可以「再壓一點
就再省一點」的曲線，而是一個要跨過的門檻 —— 從 60 一路降到 12 只買回 29%，最後那一步
從 12 到 6 買回剩下的 88%。

對應到美術：idle 那列是 6 格共 1.10 秒，**平均 5.45 fps**，最短的一格是 0.110 秒
（9.09 fps）。所以 6 fps 對 idle 是**幾乎但不完全**無損 —— 兩格 0.110 秒的畫格會被
0.167 秒的幀間隔吃掉。這是這整份文件裡唯一一個真正的取捨，而且它現在有價碼：
**那兩個畫格值 3 秒。**

第一輪，`599544f` / Forward+，239 項的資料夾，縮圖快取冷：

| 情境 | 視窗出現 | 完全載入 |
|---|---|---|
| A：寵物執行中 | 2.29 / 2.69 s | **15.39 s** |
| B：寵物暫停 | 1.09 / 1.16 s | **7.56 s** |

倍率 2.10 / 2.04，與第二輪一致。絕對值差這麼多是縮圖：`~/下載` 裡有 55 個
png / svg / pdf，第一輪多半在現產縮圖，那是一次性的成本，重量不會再現。

清單項目越多，差距越大 —— 逐項填清單的每一幀都要等合成器。

### 寵物自身的佔用

第一輪（`599544f` / Forward+，一次 6 天連續執行的 lifetime 平均）：

- 連續執行 5 天 23 小時，累計 CPU **13 小時 53 分**
- 穩定佔用 **7.6–9.7% CPU**
- 暫停它，Xorg 的閒置 CPU 從 2.3% 降到 1.0%

第二輪（`8c0463b` / GL Compatibility，啟動後 3 分鐘的單一 20 秒取樣）：

- 寵物自身 **14.0% CPU**
- Xorg **7.5%**；暫停寵物後 **1.0%**

第二輪兩個數字都比第一輪高，但**不要當成回歸來讀**。量測形狀不同（20 秒取樣 vs
6 天平均），而且這個 build 還多了 companion profile、語音輸入這些新東西，renderer 只是
候選解釋之一。要下結論得用同一種形狀重量。兩輪之間唯一穩定的是**暫停寵物後的 Xorg 1.0%**
—— 也就是說寵物執行時 Xorg 多花的那幾個百分點，兩輪都完全歸因於它。

## 機制

被拖慢的那一端，特徵很明確。對 Nautilus 冷啟動做 strace（72,707 行）：

- user space CPU 只用了 **1.2 秒**，major page fault **+2**
- 除 `poll()` 外，所有 syscall 累計 **不到 0.25 秒**（檔案相關的全部加起來 < 0.02 秒）
- 其餘時間全部阻塞在 `poll()` 等 X11 socket 回應，另有 **2021 次 `sched_yield`**

也就是說它既不是在算、也不是在讀，是在**等合成器交出下一幀**。

而這個視窗是**透明、always-on-top**（`window_controller.gd:77-80`）。這種視窗的每一幀
都會迫使合成器重新混合它底下那塊螢幕區域 —— 而它永遠蓋在最上層，所以永遠有東西在它底下。

> **後來的量測把這段的因果縮小了。** 一個屬性完全相同的 GTK3 視窗（透明、置頂、
> click-through、同樣 12 fps）成本是**零**，見下面「那 3.3 秒是 Godot 的」。所以
> 「透明置頂視窗很貴」本身是錯的；貴的是**由 Godot 送出**的那些幀。這段講的頻率不對稱
> 仍然成立，而且仍然是「視窗出現」那一項的正解 —— 只是它解釋不了全部。

關鍵的不對稱在這裡：

| | 頻率 |
|---|---|
| 視窗送出新幀 | **60 fps**（`project.godot` 的 `run/max_fps=60`） |
| 畫面內容實際變化 | **最多約 9 fps** |

`pets/pet_pack.gd` 的 `V2_FRAME_DURATIONS` 裡，所有 row 最短的一幀是 **0.110 秒**，
其餘多在 0.12–0.32 秒之間；沒有逐幀時長的 pack 走 `DEFAULT_FPS := 8.0`。

**每 6–7 幀裡有 5–6 幀畫的是跟上一幀一模一樣的東西**，但合成器每一幀都得重算。

> 注意：SIGSTOP 證明的是「這個行程造成 2 倍差距」，它沒有區分
> 「60fps 的持續 damage」與「透明置頂視窗本身讓視窗映射變貴」兩種成因。
> 下面的建議依預期效益排序，但**都需要用文末的 benchmark 實測確認**，不要假設。

## 專案內的熱點

行號對到 `8c0463b`。

| 位置 | 每幀做的事 | 有無 gating |
|---|---|---|
| `project.godot:13` | `run/max_fps=60` | 固定值 |
| `pet/pet_visual.gd:151` → `173` | `DisplayServer.mouse_get_position()` | 無，idle 時持續跑 |
| `pet/pet_brain.gd:92` | 狀態機遞減計時 | 只在 `_paused` 時停 |
| `pet/pet.gd:273` | 按住時輪詢游標；`285` 才是泡泡遮罩 | 有，見下 |
| `pet/fallback_blob.gd:20` | `queue_redraw()` | 有，`if not visible` |
| `pet/window_controller.gd:250` | WM 探測（`_probe_wm` 在 `242`） | 有，`set_process(false)` |
| `ui/chat_panel.gd:217` | 泡泡打字與重新定位 | 有，`if not _bubble.visible` |
| `ui/games/mini_game.gd:207` | 遊戲 tick + `queue_redraw()` | 有，`is_visible_in_tree()` |

`pet.gd` 那一列在 `8c0463b`（修好跨桌面拖曳）之後變了，不再只是刷遮罩：`_process` 現在
還負責在按住期間輪詢全域游標位置，由 `pet.gd:461` 的 `set_process(true)` 與 `493` 的還原
開關。所以在 Linux 與 macOS 上它只在按住時跑，Windows 因為遮罩會裁切繪製而始終開著。

多數 `_process` 已經用 `set_process(false)` 收得很乾淨（`codex_cli`、`work_service`、
`recorder_service`、`speech_input_service`、`openai_provider`、`window_controller` 都是），
其餘的靠 `visible` 早退。真正沒收的只剩 `max_fps` 與那個游標查詢兩項。

## 建議

### 1. 按狀態動態調整 `Engine.max_fps`（**已實作**：`autoload/frame_budget.gd`）

> **已經做了，2026-08-12。** 下面保留原本的推理與那張表，因為它們仍然是設計依據；
> 差異只有兩處，兩處都是量出來的：`idle` 是 **6 不是 12**（懸崖在兩者之間），而需求
> 是**堆疊**的而非單一數字 —— `FrameBudget` 收下每個來源的需求並取最大值，所以面板、
> 對話框和小遊戲不再繼承發呆寵物的幀率。`pet.gd::_register_window_frame_rates()`
> 走訪 Window 子節點自動掛上，聊天輸入框因為不是獨立視窗而單獨處理。
> 驗證：`--print-fps` 40 秒內 27 筆 6（發呆）、3 筆 30（走路）。
> 測試在 `tests/test_frame_budget.tscn`，其中一項專門守住「idle 不得高於 6」。

`Engine.max_fps` 可以在執行期直接寫入，Godot 4.7 文件有明示：

```gdscript
Engine.max_fps = 60
```

而 `pet_brain.gd:_enter()` 已經 emit `state_changed`，是現成的掛載點 —— **不需要動狀態機本身**，
接那個 signal 就好。`_enter()` 現在有**七個**分支（`pet_brain.gd:173-197`）：六個固定值
`idle` / `walk` / `sleep` / `drag` / `settle` / `talk`，加上 `f8b884c` 帶進來的 `Mode.AMBIENT`
—— 而它送出的是 `_ambient_state`，一個由 skin 的 `companion.json` 定義的**任意 StringName**
（`pet_brain.gd:63`、`229`）。所以下面那個 `.get(state, 30)` 的 fallback 不是防呆，
它是 AMBIENT 的正式路徑，而 30 對一個最多 9 fps 的 sprite 循環來說已經偏保守。

> 別跟 `PetVisual` 的動畫解析搞混：那邊會把 `drag`、`settle` 併回 **idle 那一列圖**
> （沒有 pack 提供拖曳動畫），所以 `pet_visual.gd` 與 CLAUDE.md 都寫著
> 「aliases DRAG's animation state to idle」。那是**選圖**的行為，
> **brain 的 signal 仍然送原本的值**，這裡可以放心分開給不同的 fps。

```gdscript
# Sprite frames update at ~9 fps at most (see V2_FRAME_DURATIONS in pet_pack.gd:
# the shortest frame in any row is 0.110s; packs without per-frame timing use
# DEFAULT_FPS := 8.0). Anything above that redraws identical pixels.
const FPS_BY_STATE := {
    # 6, not 12. The compositor cost falls off a cliff between the two: 12 fps
    # costs 97% of the full penalty and 6 fps costs 11% (measured — see "懸崖在
    # 6 和 12 fps 之間"). It is not quite lossless, since the idle row's two
    # 0.110s frames don't fit a 0.167s interval, and that is the price.
    &"idle":    6,
    &"sleep":   3,   # free, and nothing is moving
    # DRAG, SETTLE and TALK are entered because the *user is handling the pet*,
    # and someone dragging the pet is not simultaneously waiting for a folder to
    # open. They buy responsiveness with a cost nobody is there to pay.
    &"drag":   60,   # follows the cursor — must stay responsive
    &"settle": 60,   # glides back to a valid spot; same reasoning as drag
    &"talk":   30,   # bubble types itself out and _refresh_mask() follows it
    # WALK is the exception, and the expensive one: the pet decides to walk by
    # itself, so it happens *while* you are opening that folder. 30 fps here
    # costs +4.33s every time it takes a stroll. See below.
    &"walk":   30,
}

func _on_state_changed(state: StringName) -> void:
    Engine.max_fps = FPS_BY_STATE.get(state, 30)
```

`talk` 已經涵蓋泡泡打字（`pet.gd:285` 的 `_refresh_mask()`）。

**但 `Engine.max_fps` 是 process 全域的，這是這條建議最大的坑。** 記憶、逐字稿、我做的東西、
工作、電腦狀況、各種設定對話框 —— 每一個都是同一個 process 裡的真實 OS 視窗，共用同一個
main loop。照上表直接套下去，使用者在寵物發呆時捲逐字稿、或盯著工作面板的輸出，就會拿到
6–12 fps 的介面，那讀起來就是壞掉。

所以需求值要用**堆疊**而不是直接賦值，而且 push 的時機不只是 mini-game 開始，是**任何附屬
視窗變成可見**。`ui/games/mini_game.gd:210` 已經用 `is_visible_in_tree()` 早退，但它一旦可見
就每幀 `queue_redraw()`，正是最需要高 fps 的那種內容。

注意 `project.godot` 沒設 `vsync_mode`，預設是 Enabled，因此 `max_fps` 本來就受螢幕更新率封頂；
**往下調仍然有效**，往上調沒有意義。

還有一項要親眼看過再決定：`idle: 6` 同時也蓋到游標靠近時的 lean / perk easing。那一段是
**逐幀真的在變**的內容，不是重畫同樣的像素，6 fps 幾乎確定會有感 —— 它屬於下面「成功標準」
的目視檢查，不能只看數字過關。一個折衷是把游標進入 notice 半徑當成一個臨時的需求值
（跟附屬視窗共用同一個堆疊），因為那也是使用者正在看著寵物的時刻。

**`walk` 是這張表唯一沒解決的格子。** 它 30 fps，而且是寵物**自己**決定要走的 ——
不像拖曳和講話，它會正好發生在你開資料夾的時候，每次值 +4.33 秒。三條路：

1. **走路也壓到 6 fps**，配合第 7 項（把移動對齊 sprite 換格）讓它不至於一格一格跳。
2. **預設不要到處走**（`行為` 選單那個現成的開關）。單獨量的時候它一毛錢都省不到 ——
   因為當時 idle 和 walk 都被壓在同一個 12 fps —— 但在這張表底下它的意義完全不同：
   不走路，寵物就永遠停在 6 fps 那一格。
3. 接受它。走路是偶發且短暫的，代價只在那幾秒內。

**實測，不是預期**（見上面的「降幀率買到了多少」）：12 fps 把「視窗出現」從 2.05 s 拉回
1.00 s，等於全額回收；寵物自身 CPU 從 13.5% 降到 5.6%。但「完全載入」只從 8.27 降到
6.88 s，基準線是 3.50 s —— **這條建議救不了那一項**，別把它當成完整的解法。剩下的部分
是下面第 6 項。

### 2. 節流 `DisplayServer.mouse_get_position()`

`pet_visual.gd:173` 在 `_update_cursor_reaction()` 裡每幀查一次游標位置。
在 X11 上這是一次**同步的 X server round-trip**，而這段程式碼正好 gating 在 `idle` ——
也就是最常發生的狀態。

暫停寵物時 Xorg 閒置 CPU 從 2.3% → 1.0%，這一項是其中一個來源。

建議用累加器降到 10 Hz 左右。游標反應是「靠近會抬頭」這種緩慢的情緒回饋，
本來就有 easing（註解自己寫了 “eases rather than snaps”），10 Hz 取樣不會有感：

```gdscript
const CURSOR_POLL_INTERVAL := 0.1
var _cursor_poll_accum := 0.0
var _cursor_pos_cache := Vector2i.ZERO

# Inside _update_cursor_reaction(). On X11 mouse_get_position() is a synchronous
# round-trip to the X server, and this runs while the pet is idle — which is most
# of its life. The reaction is already eased, so a 10 Hz sample reads the same.
_cursor_poll_accum += delta
if _cursor_poll_accum >= CURSOR_POLL_INTERVAL:
    _cursor_poll_accum = 0.0
    _cursor_pos_cache = DisplayServer.mouse_get_position()
# Everything downstream uses _cursor_pos_cache; the easing still runs per-frame
# on delta, so the motion stays smooth.
```

做完第 1 項後這一項的絕對值會變小（幀數本來就少了），但兩者是乘算關係，仍值得做。

### 3. ~~`low_processor_mode`~~（重測過了，在這個專案上無效）

`OS.set_low_processor_usage_mode(true)` 讓引擎「只在畫面需要更新時才繪製」。
但 Godot 官方文件明確警告：**有持續動畫或使用 `TIME` 的 shader 時，重繪還是會持續發生**。

這一節原本的結論是「寵物的 idle 本身就是循環動畫，所以開了也不會有想像中的效果」，
只建議在 `SLEEP` 期間打開：

```gdscript
OS.low_processor_usage_mode = (state == &"sleep")
```

**那個結論可能否定得太快了，值得實測。** 官方那句警告的意思是「重繪不會降到零」，
不是「重繪會維持在 60」。如果 `AnimatedSprite2D` 只在**換格時**弄髒畫布，送幀率就會自動
落在 sprite 自己的速率 —— 那正是第 1 項想用查表達成的結果，只是由引擎自己決定。

而且它順手解決了第 1 項最大的坑：**`Engine.max_fps` 是 process 全域的，「髒了沒」不是。**
一個正在被捲動的面板每幀都弄髒自己，自動拿到滿速；同一時間發呆的寵物不會。查表做不到
這件事，除非為每個附屬視窗手動維護需求堆疊。

**量了，沒有用。** `application/run/low_processor_mode=true` 加進 `project.godot`
（那個設定確實存在，預設 `false`），拿掉所有 `--max-fps`，用 `--print-fps` 讀實際幀率：

| | 回報的 fps | 寵物 CPU |
|---|---|---|
| `low_processor_mode` 關 | 58-59 | 16.2% |
| `low_processor_mode` 開 | 58-59 | 12.8% |

**繪製次數完全沒變**，只有 CPU 略降。所以有東西每幀都在弄髒畫布。

第一個嫌疑犯是 `_apply_pose()`：它由 `_update_cursor_reaction()` 每幀呼叫，而
`AnimatedSprite2D` 的 `set_offset()` / `set_flip_h()` **無條件呼叫 `queue_redraw()`**，
沒有相等比較 —— 寵物 idle 而游標在遠處時（牠大部分的人生）就是在重寫同一個姿勢。
`pet_visual.gd:215` 其實已經有一個這種守衛，但只蓋到「不合格」那條分支。

**補上守衛也沒有用。** 在 `_apply_pose()` 前面加了「與上次相同就直接返回」的記憶
（測試全過，`test_pet_visual` 13 checks 照樣通過），再量一次：仍然 58-60 fps，
CPU 16.2% → 15.6%，在雜訊內。所以那不是（或不只是）元凶，而那個守衛買不到可量測的東西，
**已經回退** —— 沒有量到好處的複雜度不留，這份文件已經在第 6 項上學過一次。

真正每幀弄髒畫布的是什麼，還沒查出來。在查出來之前這條路是死的，
需要的東西改走第 1 項的需求堆疊。

診斷用：編輯器的 **Debug > Debug Canvas Item Redraws** 會把實際重繪的區域標色，
可以直接看出哪些東西在偷偷重畫。

### 4. 渲染器（**已經換了，而且沒有解決問題**）

這一節原本寫的是「`project.godot` 現在是 Forward Plus，改成 `gl_compatibility` 可能更輕，
但透明可能會壞，待測先別改」。它已經過期了：`df065f5` 把 `renderer/rendering_method` 換成
`gl_compatibility`（`project.godot:63-64`），**但理由跟效能無關** —— 是 Windows 實機在
Forward+ 編譯 Vulkan pipeline 時冷啟動 heap corruption，外加寵物周圍一塊不透明黑區
（CLAUDE.md:239-245）。

所以那三項檢查裡的前兩項等於已經被實際使用回答了：透明與 click-through 在
GL Compatibility 下正常，這份文件的第二輪量測就是在那個 build 上跑的。**只有第三項還開著：
macOS 上是否同樣成立，目前沒有任何紀錄說量過。** 那是這一節唯一還需要做的事，而且它現在
是個既成事實的回歸風險，不是一個可選的實驗。

至於效能：**倍率沒有變**（第一輪 2.10 / 2.04，第二輪 2.20 / 2.36）。換 renderer 沒有讓
合成器的負擔變小，這也符合機制上的預期 —— 問題是**送幀的頻率**，不是每一幀畫得多貴。
這反而加強了第 1、2 項才是正解的論證。

### 5. ~~`msaa_2d=2`~~（已移除）

這一節原本建議「留著」2× MSAA，理由是 `fallback_blob.gd` 的向量邊緣需要它。
同一個 commit（`df065f5`）已經把 `anti_aliasing/quality/msaa_2d` 從 `project.godot`
整行拿掉了，現在全檔 grep 不到 `msaa`。

看起來是換 renderer 的附帶結果，不是針對這個取捨做的決定。**還沒有人看過備援臉現在長怎樣**
—— 它只在沒有 sprite pack 可載入時出現，所以這是個低頻但確實存在的視覺回歸，
值得在那個情境下看一眼再決定要不要補回來。

### 6. ~~沒有泡泡時把視窗縮小~~（**已量測，沒有用**）

這一項曾經是這份文件裡最看好的未測項目：`--max-fps 12` 留下 3.4 秒無法用幀率解釋，
而合成器每幀重混的是面積，視窗又遠大於寵物本身。

**量了，是錯的。** 面積砍到 18.7% 只買回 0.15 秒（見上面「縮小視窗也買不到東西」）。
提出來的複雜度 —— 動態 resize 與 mutter 打架、`_clamp_anchor()` 跟著變、passthrough 遮罩
與 `get_visible_area()` 全部要同步 —— 現在確定買不到任何東西，**不要做**。

留著這一節是因為那個推理讀起來完全合理，而它是錯的。下一個看起來同樣合理的省法，
也應該先用同一種方式量過再動手。

### 6b. 兩個已驗證有效的方向，加一個還沒量的數字

問題已經從「桌寵的視窗很貴」縮到「**Godot 每次 present 都很貴，而且要到極低速率才會
崩塌**」。透明、置頂、面積、走路全部排除，兩個原本打算做的一行診斷不必做了。

**已驗證能把成本完全消掉的有兩個，而且都不需要重寫：**

1. **在會痛的時候把視窗藏起來。** `xdotool windowunmap` 已經證明成本歸零而行程照跑。
   `PresenceService` 已經在取樣前景 app，所以「偵測到全螢幕 / 最大化視窗時 `hide()`」
   是現成的掛載點。要當心的是它會**真的看不到寵物**，所以觸發條件必須保守 ——
   全螢幕影片、簡報這種本來就不該有東西蓋在上面的場合。
2. **把 present 速率壓到轉折點以下。** 1 fps 已證明是免費的。轉折點在哪還沒量，
   而那是下一個該量的數字（見上一節）：低於 5.45 fps 就不必犧牲 idle 動畫。

第 3 項的 `low_processor_usage_mode` 在這個新脈絡下更值得試了：它讓 present 只在畫布
真的變髒時發生，而寵物 idle 的變髒速率正好是 5.45 fps。

**不要因此就去重寫。** 這個 app 已經不只是一隻會動的 sprite（串流聊天、五個面板、
七個小遊戲、三個 TTS 後端、sprite pack 載入器、三平台匯出），而代價是一個 238 項資料夾
多花 3.4 秒，且已知有兩個不必重寫的解法。那是產品判斷，不是技術判斷。

**這一切都是 X11 / mutter / NVIDIA 專屬的。** Wayland、macOS、Windows 完全沒有量過，
而 GL present 在合成器底下的待遇正是最可能因平台而異的東西 —— 而 macOS 是主要平台。

### 7. 把移動對齊 sprite 自己的時鐘

第 1 項只敢給 `walk` 30 fps，是因為走路時位置**每幀**都在更新，內容真的在變 ——
不像 idle 有 51/60 的幀是逐位元組相同的。

如果走路改成**只在 sprite 換格時前進一步**，那麼所有狀態的內容變化率都會真的落在 ≤9 fps，
這時候把幀率壓到接近 sprite 自己的速率就不再是妥協，而是剛好。傳統 sprite 桌寵就是這樣
動的，而且對像素美術來說，整數像素跳步比次像素滑動本來就更對。

注意這跟「把移動路徑預先算好」不是同一件事，後者沒有用：這裡付的成本是**送出去的幀**，
不是**算出來的幀**。被拖慢的那一端是卡在 `poll()` 等合成器交幀，不是在算東西，所以預先
算好路徑省的是寵物自己 CPU 裡的一小塊，對合成器毫無差別。有用的是**降低內容真正變化的
頻率**，那才讓低幀率變成無損。

同理，**完全不走路也買不到東西**（見上面「關掉走路買不到東西」）—— 在 mutter 底下視窗
根本不動，走路只是換了視窗內哪些像素在變，不是多開一塊 damage。這一項的價值因此不是
省成本，而是**讓第 1 項的 `walk` 不必特別放寬到 30 fps**，也就是讓那張表可以整體再往下壓。

## 驗證方法

`ab.py` —— 量測寵物對「開新視窗」的影響。放在專案外執行即可，不需要改任何程式碼，
`SIGSTOP` / `SIGCONT` 完全可逆：

```python
#!/usr/bin/env python3
"""A/B：桌寵執行中 vs 暫停，對 GTK 視窗建立速度的影響。用法：python3 ab.py <godot_pid>"""
import subprocess, time, os, signal, sys

GODOT = int(sys.argv[1])

def windows():
    r = subprocess.run(["xdotool", "search", "--onlyvisible", "--name", "."],
                       capture_output=True, text=True)
    return set(r.stdout.split())

def measure(label):
    before = windows()
    t0 = time.time()
    p = subprocess.Popen(["gnome-calculator"], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    result = None
    while time.time() - t0 < 15:
        if windows() - before:
            result = time.time() - t0
            break
        time.sleep(0.03)
    print(f"[{label}] {result:.2f} 秒" if result else f"[{label}] 逾時", flush=True)
    time.sleep(0.5)
    try:
        os.killpg(os.getpgid(p.pid), signal.SIGTERM)
    except Exception:
        pass
    p.wait(timeout=5)
    time.sleep(1.2)
    return result

def godot(sig):
    try:
        os.kill(GODOT, sig)
    except ProcessLookupError:
        print("godot 不存在")

try:
    print("### A：寵物執行中 ###")
    godot(signal.SIGCONT); time.sleep(2)
    a = [measure(f"A{i}") for i in (1, 2, 3)]
    print("### B：寵物暫停 ###")
    godot(signal.SIGSTOP); time.sleep(2)
    b = [measure(f"B{i}") for i in (1, 2, 3)]
    print("### C：恢復後回測 ###")
    godot(signal.SIGCONT); time.sleep(2)
    c = [measure(f"C{i}") for i in (1, 2)]
    for name, xs in (("A 執行中", a), ("B 暫停", b), ("C 恢復後", c)):
        v = [x for x in xs if x]
        if v:
            print(f"{name} 平均：{sum(v)/len(v):.2f} 秒")
finally:
    godot(signal.SIGCONT)   # 無論如何都要恢復
    print(subprocess.run(["ps", "-o", "stat=", "-p", str(GODOT)],
                         capture_output=True, text=True).stdout.strip(),
          "（T = 仍暫停，要處理）")
```

改完程式後，改量「寵物執行中」這一組即可 —— 目標是讓它逼近上面 B 組的數字。

寵物自身的佔用則直接看：

```sh
pgrep -x godot | xargs -I{} ps -o pid,pcpu,time,etime -p {}
```

### 量資料夾要多兩件事，各踩過一次

第二輪的資料夾量測是 `ab.py` 的變體：每次量之前先 `nautilus -q`，讓每一次都是同樣的
冷行程；「視窗出現」用 `xdotool` 等一個標題含資料夾名的新視窗；「完全載入」對視窗連續
`xwd -id` 取樣，比較相鄰兩張的差異。`xwd -id` 在合成器底下讀的是該視窗自己的 backing
pixmap，所以永遠置頂的寵物不會漏進畫面裡，不需要裁切。

- **不要用「第一段穩定期」判定完全載入，要用「最後一次變動的時刻」。** 清單填到一半會停
  一下再繼續：實測那個空檔有 1.7 秒，而「連續 5 張相同就算穩定」在 1.14s 就宣告完成，
  真正的大片重繪其實發生在 3.3s。改成固定觀察 20 秒、回報期間最後一次變動，就沒有這個
  失效模式，代價是每次量固定多花 20 秒。
- **量測時的寵物跑在 `nice 5`，不是 `nice 0`。** 那些 build 都是從一個被 nice 過的
  shell 啟動的，而桌面 autostart 起來的寵物是 `nice 0`。所有比較彼此之間仍然公平
  （每一組都同樣是 nice 5，GTK 對照組也是），所以曲線形狀與 6/12 的懸崖不受影響；
  但**絕對的代價可能被低估**，因為載入資料夾正是有 CPU 競爭的時刻，一個被 nice 過的
  寵物在那當下會少送幾幀。要拿絕對數字對外講之前，用 `systemd-run --user` 起一個
  `nice 0` 的寵物重量一次。
- **這個指標要求桌面完全無人操作。** 它分不出「清單還在填」和「使用者移動了滑鼠」。
  第一次量的時候使用者仍在正常用電腦，三次裡有兩次整整 20 秒都在變動、完全量不出東西；
  請他停手之後重量，每一次都只剩 2 次變動事件，三次之間的變異幾乎消失。
  「視窗出現」那一欄則相對耐雜訊，因為它只涵蓋約 1 秒。

## 成功標準

用第二輪的數據當基準線 —— 那是現在的 build。第一輪的 gnome-calculator 數字是 Forward+
時代的舊錨點，留著對照，不必為它再要一次安靜的桌面：

- 寵物執行中，開 `~/下載`：視窗出現 **≤ 1.2 秒** —— `--max-fps 12` 已經達成（1.00 s）
- 完全載入 **≤ 4.5 秒** —— 已知有兩條路達成：`--max-fps 1`（3.54 s）與視窗 unmap
  （3.33 s）。兩者現在都還不是產品上可接受的形式，第 6b 項是把它們變成可接受形式的方向
- 寵物 idle 時自身 CPU **< 2%**（現況 14.0%）
- 寵物執行中的 Xorg **接近 1.0%**（現況 7.5%；暫停寵物時是 1.0%）
- 視覺上：走路、拖曳、打字的手感不變；idle 的呼吸與眨眼不卡頓；
  **游標靠近時的抬頭反應仍然是滑的** —— `idle: 12` 直接影響這一項
- 面板（記憶、逐字稿、工作…）捲動時仍然順 —— `max_fps` 是 process 全域的，這一項會壞

舊錨點：寵物執行中開 gnome-calculator ≤ 0.8 秒（Forward+ 時代現況 1.60 s，暫停 0.67 s）。

第三項是硬條件。這隻寵物的價值就是「看著它」，省 CPU 省到動作變頓就是白省。

## 還沒解決的

暫停寵物之後，gnome-shell 的閒置 CPU 只從 8.0% 降到 7.2% —— **剩下那 7.2% 不是寵物造成的**。
那台機器的 gnome-shell 當時已連續執行 16 天、累計 30.6 小時 CPU。
這部分與本專案無關，另外處理。
