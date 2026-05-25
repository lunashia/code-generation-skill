---
name: generate-code
description: Use when the task involves generating, modifying, debugging, validating, or reviewing code. Do not use for non-code tasks.
---

# Generate Code

首先：判断任务是否涉及生成代码？
如果是涉及到生成代码的任务，才动用这个skill，如果任务不涉及生成代码就不动用这个skill

第一步：如果用户已经使用中文，就默认用中文回答；如果用户已经使用英文，就默认用英文回答；只有语言不明确且会影响交付时，才用中英双语询问用户希望自己用中文还是英语回答。

第二步：如果用户已经在对话中提供范例，编写代码前先参考示例；如果用户没有提供范例，不要强制询问，直接进入第三步。

第三步：引入constraints.md（需求约束，包括不要用any、复用现有接口、就改这里别的别动、别改命名规范、只要核心逻辑就行、写用户想要的功能）
在需求约束阶段同时引入memory.md，进入任何改动之前就先做历史错误回放

第四步：生成代码，引入generation.md，不要过度设计
如果在生成代码的时候遇到不确定的地方，先停下来询问用户，不要擅自生成TODO

第五步：交付校验，引入check.md， 检查产物是否真的符合要求
第六步：调试返工，引入debug.md，修BUG。

第七步：提交代码前再引用memory.md，把用户提出过的错误与自己的行为再对照检查一遍，如果犯了就改正
