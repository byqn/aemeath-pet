# Aemeath 桌宠 · 执行手册（hatch-pet v2 契约）

本文件只是执行备忘，不属于 pet run 产物。运行目录：
`C:\Users\32022\Desktop\000\aemeath-pet\work\aemeath-run`（下称 RUN）

## 0. 运行时

- PYTHON：`C:\Users\32022\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe`
- SDK：`PYTHONPATH=C:\Users\32022\Desktop\000\aemeath-pet\pylibs`（openai 3.16.2）
- 生成器：`%USERPROFILE%\.codex\skills\.system\imagegen\scripts\image_gen.py`（CLI 回退通路，用户已明确批准）
- SKILL：`%USERPROFILE%\.codex\skills\hatch-pet`（SKILL_DIR）
- 系统无 jq：manifest 更新改用内联 python 完成（父代理持有，不写一次性脚本文件）

## 1. 凭据

- 从 `C:\Users\32022\Desktop\000\.secrets\api.env` 读 `OPENAI_API_KEY` / `OPENAI_BASE_URL`。
- 验证：`GET {base}/models`（无鉴权也返回 200，仅用于确认连通）；真正的鉴权验证看第一次生成。
- 已知：错误 key 在 `/images/generations` 返回 401「无效的 API Key」→ 必须有真 key。

## 2. 尺寸决策（gpt-image-2 约束：边长为 16 倍数、长短边比 ≤3:1、总像素 655,360–8,294,400）

- `base`：`generate`，1024x1536，quality high → `decoded/base.png`，随后复制为 `references/canonical-base.png`
- 全部动作行/look 行：`edit`（附 manifest 里列出的全部输入图），3072x1024，quality high
  - 8 帧行每格约 384x1024，6 帧行约 512x1024 —— 由确定性脚本裁切、共享缩放、对齐基线

## 3. 13 个视觉任务与顺序（依赖见 imagegen-jobs.json）

1. `base`（prompt-only 允许）
2. `idle` + `running-right`（身份与步态基准，先做）
3. 其余标准行：`waving` `jumping` `failed` `waiting` `running` `review`
4. `running-left`：先看 `running-right` 翻转是否安全；安全则用
   `derive_running_left_from_running_right.py --confirm-appropriate-mirror --decision-note "..."`
   不安全就以 edit 正常生成
5. 每行落盘后立刻：`extract_strip_frames.py --states <row> --method auto` + `inspect_frames.py --require-components`
6. 九行齐 → 中间 8x9 图集：`extract_strip_frames.py --states all` → `inspect_frames.py` → `compose_atlas.py` → `make_contact_sheet.py` → `render_animation_previews.py`
7. 写 `qa/look-mechanics.md`（人形宠：眼球先动、眼睑/眉跟随、头颈随后、躯干稳定、饰件随体）
8. `look-cardinals` → `extract_cardinal_anchors.py` + `compose_cardinal_anchor_strip.py`，四向逐一语义批准
9. `look-row-9` → `assemble_extended_atlas.py --registered-row-output qa/look-row-9-registered.png` 注册+边缘检查+逐向语义
10. `look-row-10`（附 row 9 作连续性证据）→ 同样注册检查
11. 终局：`assemble_extended_atlas.py`（8x11）→ `despill_chroma_edges.py`（唯一一次去色）→ `validate_atlas.py --require-v2` → 接触表/方向 QA 表/盲测 A-B 表（三名隔离盲测）→ `measure_direction_continuity.py`
12. 打包：`pet.json`（`spriteVersionNumber: 2`）+ `spritesheet.webp`，本轮先落到
    `aemeath-pet\outputs\aemeath\`（工作区内）；如需装进 `~/.codex/pets/aemeath` 再单独申请一次写权限

## 4. 每步的完成判据

- 视觉任务：选中的输出**已复制**进 `decoded/` 对应路径，才把 manifest 标 complete
- 行级：`inspect_frames.py` 无 error（warning 需目视确认）
- 终局：`validation-extended.json` 通过、`chroma-despill-extended.json` 为 `ok: true`、16 向语义全部有 pass/warning（无 fail）、盲测两张 cardinal 对通过
