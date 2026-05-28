# Generate Code Skill

是一套供 Codex 和 Claude 共用的代码生成工作流约束 skill 😂

## 背景

![Background](assets/background.svg)

## 目录结构

- `SKILL.md`：Codex 的 skill 入口
- `References/`：Codex 按需加载的参考文件
- `CLAUDE.md`：Claude 的项目级说明
- `.claude/skills/generate-code/`：Claude 的 skill 入口
- `agents/openai.yaml`：Codex 的界面元数据
- `scripts/check-sync.ps1`：Codex/Claude 双份文件同步检查脚本

## 使用方式

给 Codex 使用时，直接把这个仓库作为 skill 来源，并读取 `SKILL.md`。
给 Claude 使用时，保留仓库根目录可见，让 `CLAUDE.md` 和 `.claude/skills/generate-code/` 可被发现。

## 同步检查

运行以下命令检查 Codex 和 Claude 两套 skill 文件是否漂移：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\check-sync.ps1
```

## 注意事项

- `SKILL.md`、`References/`、`CLAUDE.md` 和 `.claude/skills/generate-code/` 要保持同步。
- 不要提交密钥、token 或本机专属路径。

### GitHub Traffic

![GitHub Traffic](assets/traffic.svg)

## 可感知结果

这个 skill 的目标不是让 AI 只说“代码写完了”，而是让每次代码交付都能被用户验收。

一次理想的交付结果应该包含：

- 需求 checklist：把用户真正要的结果拆成可检查条目
- 修改摘要：说明只改了哪些和本次需求直接相关的内容
- 验证结果：写清楚运行过什么命令，结果是什么
- 已知限制：说明还有哪些没有验证到，或者明确写“暂无”

也就是说，用户不需要先读完整个 diff，先看最终交付单就能判断：这次改动是否符合要求、是否跑过验证、还有没有残余风险。
