# 造型包的小夥伴設定

Godot Pet 仍直接讀取 Codex Pets / petdex 的 `pet.json` 與圖集格式。若一個
造型代表的不是一般寵物，可以在同一個資料夾加入選用的
`companion.json`；既有造型包完全不用修改。

所有造型都是同一位小夥伴的不同呈現，因此狀態、羈絆與記憶在換造型時
不會重置。`companion.json` 只決定目前造型如何稱呼及表現這些資料。

## 檔案配置

```text
my-character/
├── pet.json
├── spritesheet.webp
├── companion.json
└── nudges.json
```

後兩個檔案都是選用。`nudgesPath` 只能指向造型包內的相對路徑。路徑含
`..`、使用絕對位置或檔案讀不到時，程式會安全退回共用內容。

## 完整範例：機器小夥伴

```json
{
  "schemaVersion": 1,
  "selfName": "阿光",
  "nudgesPath": "nudges.json",
  "states": {
    "energy": {
      "label": "運算餘裕",
      "grades": ["快進入休眠", "有點遲鈍", "運作正常", "反應很快"]
    },
    "mood": {
      "label": "情緒模組",
      "grades": ["很低落", "有點悶", "平穩", "很開心"]
    },
    "bond": {
      "label": "同步程度",
      "grades": ["剛連線", "逐漸熟悉", "彼此信任", "非常有默契"]
    }
  },
  "care": {
    "enabled": true,
    "label": "電量",
    "grades": ["即將沒電", "電量偏低", "還夠用", "電力充足"],
    "actionLabel": "充電",
    "starting": 70,
    "decayPerMinute": 0.12,
    "amount": 35,
    "moodAmount": 2,
    "gameTreatAmount": 0,
    "gameTreatCap": 0,
    "replies": [
      {"emotion": "happy", "text": "充電完成，謝謝你。"}
    ]
  },
  "bondStages": [
    {"minimum": 0, "label": "剛連線"},
    {"minimum": 25, "label": "逐漸熟悉", "emotion": "happy", "line": "我開始認得你的習慣了。"},
    {"minimum": 50, "label": "彼此信任", "emotion": "happy", "line": "你的指示，我現在很放心。"},
    {"minimum": 75, "label": "非常有默契", "emotion": "excited", "line": "我們的同步率好像到新高了。"}
  ],
  "returnGreeting": {
    "minimumMinutes": 60,
    "emotion": "greeting",
    "lines": ["重新偵測到你了。", "歡迎回來，系統一切正常。"]
  },
  "ambientBehaviours": [
    {"state": "wave", "minimumBond": 25, "weight": 1, "duration": 2.2},
    {"state": "excited", "minimumBond": 50, "weight": 0.5, "duration": 2.0}
  ]
}
```

`nudges.json` 沿用內建檔案的 pool 格式。照顧不足的 pool 建議命名為
`care`；為了相容既有檔案，`hungry` 也仍然有效。

## 不需要照顧值的角色

人形朋友或純助理角色可以保留精力、心情與羈絆，但拿掉主要照顧動作：

```json
{
  "schemaVersion": 1,
  "selfName": "小岑",
  "care": { "enabled": false }
}
```

此時根選單不會顯示餵食／充電列，狀態視窗與模型提示詞也不會提到 care。

## 相容與優先順序

- 沒有 `companion.json`：使用舊有寵物行為，名稱取自 `pet.json`。
- 檔案格式錯誤：只回退互動設定，圖集仍可正常載入。
- persona 不從外部造型包自動載入。請在「造型 → 編輯這個造型的個性」
  預覽並親手套用；這條邊界避免下載一張圖時也把 system prompt 控制權交出去。
- 未知欄位會被忽略；目前唯一支援的 `schemaVersion` 是 `1`。

狀態值都維持在 `0–100` 且越高越好。介面只呈現四段質性文字，不顯示
百分比或進度條。
