# Dispatch Orchestration Skill

[English](README.md) | 繁體中文

整套 skill 的路由表（什麼任務讀哪份）在 [zakk-workflow 的 README](https://github.com/Zakk-LLM/zakk-workflow/blob/main/README.zh-CN.md#与其他-skill-的边界)。

<!-- skill-map -->
## 總圖

```text
任務進來
 ├─ 定結構 ─────▶ zakk-architecture ──介面取值──▶ web-ui
 ├─ 一次改動 ───▶ zakk-maintain ─┬─ 計劃、落倉、門禁、報告 ─▶ zakk-workflow
 │                              ├─ 判 diff ──────────────▶ zakk-review ─▶ zakk-workflow
 │                              └─ 派工 ─────────────────▶ dispatch --engine omp | codex | opencode
 └─ 任何中文 ───▶ chinese-skill（橫切，每份都讀）
```
<!-- /skill-map -->

Dispatch 把工作分派給 omp、Codex 或 OpenCode 工作代理；協調者保留規劃、監督、審查、
commit、merge 與發佈。三個引擎共用執行目錄、難度分級、依賴排序、審查閘門與原子整合，
但各自保留存取邊界、模型控制、事件格式、逾時行為與 resume ID。使用時需要 Python 3.11
或更新版本、Bash，以及至少一個已完成設定的引擎 CLI。

## 選擇引擎

| 引擎 | 唯讀語義 | 適合的工作 |
|---|---|---|
| omp | `read-only` 沒有 `bash` 或寫入工具。這些設定檔名稱是 omp 自己的。 | 不執行檢查的閱讀、研究與審查 |
| Codex | `read-only` 可執行命令，但核心會阻擋寫入；這個名稱不能沿用到姊妹引擎。 | 必須執行測試、linter 或門禁的稽核 |
| OpenCode | `read-only` 是 plan 模式；執行命令要用 `inspect`。這些設定檔名稱是 opencode 自己的。 | 用 `read-only` 規劃；用 `inspect` 執行測試與 linter |

選擇 tier、設定檔、旗標或限制前，先讀 `references/engines/<engine>.md`。工作代理的輸出
只是主張；協調者必須讀真實 diff、執行檢查並寫下審查結論。

## 安裝

```bash
git clone <repository-url> dispatch
cd dispatch
./install.sh
```

預設會為 Claude、Codex、OpenCode、omp 與共用的 `~/.agents/skills/dispatch` 位置建立連結。
`./install.sh --copy`、`--status` 與 `--uninstall` 分別執行對應的生命週期操作；指定目標名稱
可限制操作範圍。

## 檢查

```bash
sh scripts/check-all.sh
```

這條命令會檢查共用入口契約、三份引擎表、工作代理提示範本的證據規則、shell 語法、
混合引擎行為與 installer 生命週期控制。

## 授權

MIT
