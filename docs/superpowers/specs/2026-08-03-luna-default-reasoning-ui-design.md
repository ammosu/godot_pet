# Luna 預設模型與動態推理強度介面

## 目標

把寵物聊天的 OpenAI 預設模型從 `gpt-5.4-mini` 改成
`gpt-5.6-luna`，並讓使用者能在既有「語言模型」選單看見及調整
`reasoning_effort`。這項設定只影響寵物聊天的 Chat Completions 請求；
Codex CLI 登入、Codex 工作模型、TTS、提示詞與記憶格式不在範圍內。

## 模型清單與預設

- `OpenAIProvider.DEFAULT_MODEL` 改為 `gpt-5.6-luna`。
- 保留所有既有模型，新增 `gpt-5.6-luna` 與 `gpt-5.6-terra`；既有
  `gpt-5.6-sol` 保留。
- 「預設」註記從 `gpt-5.4-mini` 移到 `gpt-5.6-luna`。
- 未設定 `openai_model` 的使用者會採用 Luna；使用者已明確選過的模型
  仍由 `config.cfg` 覆寫，不會被升級強制改掉。

## 推理強度資料模型

新增六個可顯示的推理強度：

| ID | 介面文字 |
|---|---|
| `none` | 不推理 |
| `low` | 低 |
| `medium` | 中 |
| `high` | 高 |
| `xhigh` | 極高 |
| `max` | 最大 |

`[llm] reasoning_effort` 儲存使用者偏好，未設定時預設為 `none`。每個模型
項目同時宣告它支援的強度，避免用模型名稱字串推測能力：目前 5.4／5.5
支援 `none` 到 `xhigh`，5.6 Luna／Terra／Sol 支援全部六級。

程式分開處理「偏好值」與「實際值」：

- 偏好值是設定檔中的選擇。
- 實際值若受目前模型限制，會降到該模型支援的最高值。
- 例如偏好是 `max`、模型切到 5.5 時，介面與請求顯示／使用 `xhigh`；切回
  5.6 時恢復 `max`。自動相容不覆寫偏好，因此切換模型不會破壞使用者原本
  的選擇。
- 未知或損壞的偏好值安全回到 `none`。

## 介面

既有「語言模型」子選單維持同一入口：

- OpenAI provider 列顯示有效狀態，例如
  `OpenAI · gpt-5.6-luna · 推理 none`。
- 模型單選列之後加入「推理強度」區段，列出六個中文標籤並附原始 ID。
- 目前模型不支援的列保持可見但停用；例如 5.5 下的 `max` 會停用並用
  tooltip 說明最高支援 `xhigh`。
- 有效強度的列打勾。選擇可用列後立即存入設定並重建選單，不需重啟。
- 新增獨立的 reasoning menu ID 範圍，並維持現有由高 ID 到低 ID 判斷的
  事件分派順序，避免與模型、工作區或語音項目衝突。

## 請求資料流

1. `LLMService` 從 OpenAI provider 取得模型清單、推理清單與有效推理值。
2. 選單透過 `LLMService.select_reasoning_effort()` 儲存使用者偏好。
3. `OpenAIProvider._build_payload()` 每次請求重新讀取目前模型與偏好，算出
   有效值。
4. Chat Completions payload 同時送出 `model` 與 `reasoning_effort`；Luna 的
   初始請求因此明確使用 `none`，不依賴模型服務端預設。

模型切換及 reasoning 切換都不取消已送出的回覆；新設定從下一次請求生效，
和現有模型切換行為一致。

## 錯誤與相容性

- UI 不允許選取目前模型不支援的強度。
- 設定檔若由外部寫入不相容組合，provider 在送出前使用有效值，避免 API
  因 `max` 搭配舊模型而拒絕請求。
- OpenAI API 的一般 HTTP／串流錯誤仍走既有錯誤處理，不新增重試或 fallback
  模型。
- 本次不調整提示詞。Luna 對 `[look]` 等寵物行為的品質若有實測退步，另開
  一次針對性修改，不把未量測的 prompt 變更混入模型切換。

## 驗證

先新增會失敗的自動化測試，再做最小實作。測試涵蓋：

- 未覆寫時預設為 `gpt-5.6-luna` 與 `none`。
- 模型清單保留舊項目並包含 Luna、Terra、Sol，且只有 Luna 標為預設。
- 六個 reasoning ID 與介面標籤完整。
- 5.6 支援 `max`；5.4／5.5 將 `max` 的有效值降為 `xhigh`。
- 未知 reasoning 值回到 `none`。
- Chat Completions payload 帶入有效的 `model` 與 `reasoning_effort`。
- 選單的勾選、停用狀態及選取後持久化正確。

完成後執行相關 Godot 測試、完整既有測試，以及一次極短的 Luna
`reasoning_effort: none` 串流請求，確認帳號、模型與現有 Chat Completions
串流實作相容。線上 smoke test 只驗證協定，不評估回答品質。

## 非目標

- 不改用 Responses API，也不加入 persisted reasoning、Pro mode、工具呼叫或
  prompt cache 設定。
- 不更動 Codex CLI 的 `gpt-5.6-sol` 工作模型或任何登入方式。
- 不移除舊模型、不重寫既有使用者的 `openai_model`，也不更動 TTS。
