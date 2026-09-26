# aemeath-pet

《鸣潮》爱弥斯（Aemeath）风格的 v2 桌面宠生成流水线：按 hatch-pet 规范生成 13 项视觉素材，再确定性提取帧、组装图集、QA 并打包为可交付桌宠。

## 当前状态

**代码与流程已完成并通过离线校验；图像素材尚未生成（0/13）。**

| 项目 | 状态 |
| --- | --- |
| 项目结构预检 | ✅ 通过（13 项任务清单无错误） |
| 13 项 CLI 请求 payload dry-run | ✅ 全部通过（未调用 API） |
| hatch-pet 工具链 | ✅ 15 个工具全部就位 |
| 视觉素材生成 | ❌ 0/13 |
| base 图 / 扩展图集 / 交付 ZIP | ❌ 未生成 |

阻塞点：图像生成鉴权不可用。

- imagegen CLI 需要有效的 `OPENAI_API_KEY`，此前尝试被 OpenAI 返回 `401 invalid_api_key`。
- DSH 内置生图提示 `ChatGPT sign-in needs to be renewed`。

## 目录

```
build_aemeath_pet.ps1     端到端编排：生成 → 组装 → QA → 打包（不自动批准审核）
run_imagegen_job.ps1      单任务 CLI 执行器（含脱敏失败诊断）
run_imagegen_secure.ps1   本机隐藏提示输入密钥，用完即清
dryrun_imagegen_plan.ps1  13 项 payload 离线校验
assemble_standard_pet.ps1 帧提取与组装
finalize_v2_qa.ps1        最终 QA
package_v2_pet.ps1        打包交付
validate_project_setup.py 结构与清单校验
work/aemeath-run/         任务清单、提示词、QA 记录
```

## 运行

生成需要你自己的 OpenAI API 密钥，只在本机隐藏提示中输入：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\run_imagegen_secure.ps1 -JobId base
```

离线校验（不联网）：

```powershell
.\build_aemeath_pet.ps1 -PlanOnly        # 只看依赖顺序与各任务状态
.\build_aemeath_pet.ps1 -DryRun          # 演练，不调用任何 API
.\run_imagegen_job.ps1 -JobId base -DryRun
python .\validate_project_setup.py
```

审核（必须由人目视后执行，不会自动通过）：

```powershell
.\approve_imagegen_job.ps1 -JobId base -DecisionNote "<至少12字的目视依据>" -ConfirmVisualReview
```

## 仓库说明

大型本地依赖与模型权重（`locallibs/`、`models/`、`pylibs/`，约 1.9 GB）以及凭据相关的探测脚本已通过 `.gitignore` 排除，不入库。仓库内不含任何密钥。
