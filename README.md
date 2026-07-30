# Godot Pet

一隻住在桌面角落的桌寵。透明、無邊框、永遠在最上層，點牠以外的地方會直接穿透到後面的
視窗。牠會自己走動、發呆、肚子餓，也可以跟你聊天 —— 對話走 OpenAI 的串流 API，情緒由
模型自己標，動畫跟著情緒換。

用 Godot 4.7 + GDScript 寫的個人專案。

## 造型素材

專案內建一份原創的「芽尾」[Codex Pets](https://codex-pets.net/) / petdex v2
sprite pack，沒有安裝或選擇其他造型時就會使用它。11 列圖集包含待機、左右移動、揮手、
跳躍、失敗、等待、工作、檢查，以及會追著游標看的 16 個方向。

社群造型仍然不會放進這個 repo。格式與工具是 MIT，但社群素材不是 —— 原創作品預設
CC BY-NC-SA，第三方角色的同人只允許個人非商業使用。程式只從你自己的安裝位置讀取，
授權關係就留在你跟素材作者之間，不會因為經過這個 repo 而被重新散布。

## 需求

- **Godot 4.7**（開發與驗證都在 4.7.1 stable）。從 [godotengine.org](https://godotengine.org/)
  下載即可，不需要 .NET 版
- 想真的聊天的話要一支 **OpenAI API key**。沒有 key 也跑得動，會退到 mock provider 講罐頭台詞
- Linux 額外需要 `libsecret-tools`（憑證儲存）與 `speech-dispatcher`（語音，Ubuntu 桌面預設就有）

## 跑起來

```sh
godot --path .                       # 直接跑
godot --headless --import --path .   # 匯入素材 + 檢查所有腳本能不能 parse
```

第二行是這個專案唯一的靜態檢查（**沒有測試**），改完腳本一定要跑，並且在輸出裡 grep
`SCRIPT ERROR|Parse Error|Failed to load`。它抓不到全部 —— 有些錯誤要到腳本第一次被載入才
會浮出來，所以執行時的 log 也要看。

打包：

```sh
godot --headless --path . --export-release "macOS"   "build/Godot Pet.app"
godot --headless --path . --export-release "Windows" "build/windows/Godot Pet.exe"
godot --headless --path . --export-release "Linux"   "build/linux/GodotPet.x86_64"
```

三個 preset 都能從任一平台交叉匯出。匯出需要對應版本的 export templates，而且
`rendering/textures/vram_compression/import_etc2_astc` 必須保持開啟，否則 arm64／universal
build 會直接被拒絕。

## 設定 API key

右鍵選單 →「語言模型」→「更換 OpenAI API key」，貼上按 Enter。key 會進作業系統的憑證庫：

| 平台 | 後端 |
|---|---|
| macOS | Keychain（`security`） |
| Linux | libsecret / GNOME Keyring（`secret-tool`，需 `apt install libsecret-tools`） |
| Windows | DPAPI（`ConvertFrom-SecureString`，密文放 `user://secrets/`） |
| 其他 | 退回明文設定檔，而且 UI 會**照實說出來** |

`Config.get_secret()` 的查找順序是：環境變數 → 憑證庫 → 執行檔／專案旁的 `.env` →
`config.cfg`。

**打包出來的 build 讀不到 `res://.env`**，所以一台從原始碼跑得好好的機器，打包後會突然掉回
mock。key 要從選單設定，那條路兩邊都讀得到。

## 造型

```sh
npx codex-pets add <pet-id>
```

裝到 `~/.codex/pets/{id}/`，重開寵物後右鍵選單「造型」就會出現。格式的坑不少（列數不固定、
幀數與列語意都沒宣告），細節在 CLAUDE.md。選單裡有「校準動畫列」可以逐列播放給人眼確認，
對不上的話可以用 `config.cfg` 的 `[pet_rows]` 區段逐隻覆寫，不用改程式。

不同 pack 的角色在 cell 裡佔的比例差很多（實測 76%～95%），所以繪製時會先正規化到一致的
身高，你選的大小再乘上去。

`spriteVersionNumber: 2` 的 11 列造型會使用各自的左右移動列；如果第 9、10 列含完整的
16 方位視線，待機時還會隨游標方向切換頭部與視線，不再只做整隻水平翻轉。

## 功能

- **對話** —— OpenAI 串流。回覆開頭的 `[happy]` 之類的情緒標記決定講話時播哪個動畫，標記
  在進到對話框和歷史之前就被剝掉
- **記憶** —— 三層：近期逐字、較舊的摘要、關於你的長期事實。選單裡有一個視窗可以看牠記得
  什麼，每一條都能單獨刪掉
- **需求** —— 飽足、精力、心情、好感。心情不是獨立的，會朝著由飽足與精力算出來的目標漂移，
  所以又餓又累的寵物自然就會擺臭臉。關掉 app 的時間算牠在睡覺，上限一天
- **主動搭話** —— 台詞來自 `prompts/nudges.json`，**不呼叫 LLM**。閒著的寵物每幾分鐘打一次
  API 是純燒錢，而讓搭話有生命感的是時機不是措辭
- **看螢幕** —— 要你同意才會截圖。可以從選單叫，也可以直接問牠「看一下我在幹嘛」
- **拖檔案給牠** —— 把檔案拖到寵物身上，牠會讀完跟你聊。看起來裝密鑰的檔案（`.env`、`.pem`
  之類）會在讀取任何位元組之前就被擋掉
- **依你的節奏搭話** —— 要你同意後，牠會知道你在哪個 app 待了多久（**只有 app 名稱，永遠不碰
  視窗標題**），久坐不動會來叫你休息
- **語音** —— 系統內建語音（`DisplayServer.tts_speak()`），不花錢也不需要 API。句子邊串流邊念

## 隱私

這個專案的預設是「不問就不拿」：

- 螢幕**只有**你按下同意才會截取，而且不會定時跑、不會從主動搭話觸發。看螢幕得到的回覆會標成
  ephemeral —— 留在近期對話裡讓你能追問，但不會被摘要、不會變成長期事實、不會寫進 `memory.json`
- 前景 app 的偵測同樣要同意，而且只取 app 名稱
- API key 走憑證庫，傳給子行程時盡量走 stdin 而不是 argv（`ps` 對同一個使用者是全都看得到的）
- 執行時的資料全部在 `user://`，不在 repo 裡：`config.cfg`、`state.json`、`memory.json`

## 不用改程式就能調的東西

| 檔案 | 調什麼 |
|---|---|
| `prompts/persona.md` | 角色人設與回覆格式 |
| `prompts/nudges.json` | 主動搭話的台詞池（`hungry` / `tired` / `lonely` / `focus` / `cheerful` / `memory`） |
| `autoload/pet_state.gd` 的 `DECAY` / `STARTING` | 需求衰減速度與初始值 |
| `config.cfg` 的 `[pet_rows]` | 每隻寵物的動畫列對應 |

prompt 檔案要重開才生效。

## 平台狀態

老實說，因為「匯出成功」跟「跑得起來」是兩件事：

| 平台 | 狀態 |
|---|---|
| macOS | 開發機。Phase 10 之前的東西都在這裡驗過，之後加的（游標反應、拖檔案、記憶搭話、節奏感知）還沒回歸 |
| Linux（Ubuntu 24.04 / GNOME on X11） | **從原始碼**跑過。GNOME 的 mutter 不讓視窗超出工作區，那是繞過去了（見 CLAUDE.md）；匯出的 build 仍然沒跑過 |
| Linux（Wayland） | 沒支援。Wayland 不讓 client 自己決定視窗位置，而那正是這隻寵物在做的事 |
| Windows | **從來沒有執行過**。三個 preset 都能匯出，但那只代表打包這一步成功 |

macOS 要開螢幕錄製權限，而且**失敗是無聲的** —— 沒給權限的話截到的只有桌布跟自己的視窗，
不會報錯。每一個匯出的 binary 都要各自授權一次。

## 文件

- **`PLAN.md`** —— 活的設計文件。分階段里程碑、每個決定當初為什麼那樣選、以及一路上撞到的
  平台怪癖。想知道「為什麼是這樣」看這裡
- **`CLAUDE.md`** —— 架構說明，寫給要改這份程式碼的人（含 AI）。密度很高，而且幾乎每一段都
  是先講什麼壞掉了才講程式怎麼寫

## 授權

程式碼還沒有宣告授權。美術從來不在這個 repo 裡，授權關係留在 pack 作者與你之間 —— 見上面
「沒有截圖，這是故意的」。
