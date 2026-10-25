# 给 Codex：输出 Meyrin 听写词汇表

负责人用 Meyrin（美玲）语音听写给 Claude Code / Codex 下指令，主要说普通话，夹很多英文技术词。识别用的是 Gemini Live `gemini-3.5-transcribe-live`，它的 `inputAudioTranscription.customVocabulary` 是一个字符串列表：列在里面的词更容易被认对。

现在的列表在 `~/Library/Application Support/AISM/meiling-terms.json`（JSON 字符串数组，AISM 每次新建听写会话时读取）。Claude 已经根据自己的记忆补了一批。**你的任务：根据你（Codex）这边的记忆和历史，再找出负责人常说、但识别器容易听错的词，按下面的格式输出一个候选文件。** 不要改 `meiling-terms.json` 本身，合并由 Claude 或负责人来做。

## 1. 从哪里找

按价值从高到低：

1. `~/.codex/dictation-history/`：负责人以前的听写记录。**最有价值**：识别错的地方（同音字、英文词被拆开或写成中文）就是最该加的词。对照上下文判断原词是什么。
2. `~/.codex/history.jsonl`：负责人打给你的指令原文，看他实际怎么写这些词（大小写、连字符）。
3. `~/.codex/memories/`（`MEMORY.md`、`memory_summary.md`、`raw_memories.md`、`rollout_summaries/`）：项目名、芯片和器件型号、工具名。
4. `~/.codex/AGENTS.md` 和各项目里的 `AGENTS.md`。

`~/.codex/sessions/` 有 3 GB，不要全读；需要确认某个词的写法时再按关键词搜。

## 2. 什么词要收

- 项目名、产品名、角色名：例如 X10A、Tab5、Luna、Meyrin、aism、VEDA。
- 芯片、模组、器件型号：例如 CCM4202S、ICN7352、ESP32-P4。
- 工具、框架、库、协议：例如 ESP-IDF、LVGL、TinyUSB、libASPL。
- 负责人会念出来的代码标识符、命令、配置项：例如 sdkconfig、menuconfig、app-flash。
- 少见的中文领域词：例如 同传、上屏、指纹模组。写准确的汉字。
- 负责人自己的写法优先：他写 "aism" 就不要改成 "AISM"。

## 3. 什么词不要收

- 普通词：任何识别器都不会听错的中英文常用词，例如 file、test、测试、修改。
- **负责人平时用中文说的英文概念词**：例如 microphone、memory、bug、chat、context window、prompt caching。2026-10-25 实测：这类词在表里时，他说的中文会被写成英文（“麦克风”→“microphone”），还会把读音相近的话拉过去（“可以有声音了”→“Luna 来了”）。只收他本来就用英文说的专有名词、型号、工具名。
- 念不出来的东西：路径、URL、哈希、commit ID、版本号（0.7.83）、引脚号（G53）、寄存器地址、整句话。超过 4 个词的短语也不要。
- **个人信息和机密**：人名、邮箱、电话、账号 ID、API key、token、密码，一律不要。虚构角色名和产品名可以。
- `meiling-terms.json` 里已经有的词（不分大小写比较）。

## 4. 输出格式

写到 `~/Library/Application Support/AISM/vocab/codex-candidates.json`（目录不存在就建），UTF-8，JSON 数组：

```json
[
  {"term": "CCM4202S", "why": "安全芯片，QRUM 测试", "source": "memories"},
  {"term": "上屏", "why": "听写里常说，曾被识别成“上评”", "source": "dictation-history"}
]
```

- `term`：要放进词表的写法，和打字时一模一样。
- `why`：一句话说明为什么收；如果是从识别错误里发现的，写出错成了什么。
- `source`：`dictation-history`、`history`、`memories`、`agents` 或 `sessions` 之一。
- 按重要性排序：负责人当前的工作（Tab5 / X10A、aism、Meyrin）排在前面。
- 数量 100–300 条，宁缺毋滥。服务器对词表有上限（2026-10-25 实测：1000 条可以，1200 条直接断开连接，听写整个不能用），AISM 只取前 1000 条，所以合并后的总数要留在 1000 以内。词也不是越多越好：词表会把发音相近的话往表里的词上拉。

拿不准的词不要放进这个文件，另外写在 `~/Library/Application Support/AISM/vocab/codex-unsure.md`，每行一个词加原因。

## 5. 完成后

回复负责人三件事：收了多少条、最重要的 30 条、拿不准的有哪些。不要提交、不要推送任何仓库。
