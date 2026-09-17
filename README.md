# tmuxline

tz 与 biai 两台机器共用的 tmux 状态栏:Claude Code / Codex 会话状态点、状态持续时长、账号额度(5h / 7d / Fable / Codex)与到重置时的用量预测。

仓库是这套文件的唯一正本;本机通过 `install.sh` 把实际位置(`~/.claude`、`~/.codex`、`~/.tmux.conf`)链接到仓库,改仓库即改现场,提交记录就是变更历史。

## 目录

| 仓库路径 | 安装位置 | 作用 |
| --- | --- | --- |
| `tmux.conf` | `~/.tmux.conf` | tmux 主配置;末尾 `source-file` 引入下面两份状态栏片段 |
| `claude/tmux-status-stage-section.conf` | `~/.claude/` | 两行状态栏样式(与 biai 一致的基线) |
| `claude/tmux-status-extra.conf` | `~/.claude/` | 叠加规则:响应式收缩、圆点修正、运行时长 |
| `claude/tmux-claude-usage.sh` | `~/.claude/` | 额度段渲染器(每 2 秒被状态栏调用;参数 `claude` / `codex`) |
| `claude/tmux-claude-usage-poll.sh` | `~/.claude/` | Claude 额度轮询器:拉官方用量接口,写 `*-api.dat` 与 `*-7d.hist`,算 24h 燃速 |
| `claude/tmux-claude-usage-rate.sh` | `~/.claude/` | 周燃速 / 上周终值计算函数(轮询器引用) |
| `claude/tmux-usage-compact.sh` | `~/.claude/` | 窄屏用的紧凑额度段 `C95 F70 X47` |
| `claude/tmux-claude-age.sh` | `~/.claude/` | 状态持续时长、闪烁开关、残留清理、tmux 运行时长 |
| `claude/tmux-claude-hook.sh` | `~/.claude/` | Claude Code hooks 调用,写分屏变量 `@claude_state` |
| `claude/statusline-command.sh` | `~/.claude/` | Claude Code 自己的底部状态行(模型 / 思考深度 / 上下文占比 / 路径) |
| `claude/settings-hooks.snippet.json` | —(参考) | `~/.claude/settings.json` 里需要的 `hooks` 与 `statusLine` 段,手工合并 |
| `codex/hooks.json` | `~/.codex/hooks.json` | Codex hooks,调用下面的钩子脚本 |
| `codex/tmux-codex-hook.sh` | `~/.codex/` | 写分屏变量 `@codex_state` |
| `codex/tmux-codex-quota-refresh.py` | `~/.codex/` | Codex 额度刷新:用 `~/.codex/auth.json` 的令牌拉官方用量接口(失败退回 app-server 代理),写缓存与 `*-7d.hist`,同算法算 24h 燃速;只用 Python 标准库 |
| `tests/` | — | `tests/run.sh` 跑全部测试(bash 燃速函数 / 渲染器 / codex 侧 python),不碰真实数据 |

运行期数据(`*.dat` / `*.hist` / `*.state` / `*.last` / `*.lock`)留在 `~/.claude` 与 `~/.local/state/tmux-codex-quota/`,不入库。

## 安装

```bash
git clone https://github.com/Moshuiwang/tmuxline ~/project/tmuxline
~/project/tmuxline/install.sh          # 已有的真实文件先备份到 ~/.claude/tmux-status-backup-<时刻>/ 再换成链接
~/project/tmuxline/install.sh --check  # 核对每个目标是否已链接到仓库
```

另需:
- `~/.claude/settings.json` 合并 `claude/settings-hooks.snippet.json` 的 `hooks` 与 `statusLine` 段;
- `jq`、`curl`、`flock`、Python 3.12+(`tmux-claude-age.sh` 等只用 bash);仓库外没有其他依赖(2026-09-17 起 Codex 刷新不再引用本机 `~/ai-usage-widget`)。

## 额度预测规则(2026-09-17 起)

`7d 21% → 110%` 箭头后是「到重置时会用到多少」,取两者较高:
1. **本周平均节奏**:已用 ÷ 窗口已过比例;窗口已过不足 5% 时改用上周终值当节奏(周初不再空白);
2. **最近 24h 燃速外推**:跨周重置也连续。

取较高者的用意:停一天不会塌成「没风险」(回落到周平均),猛干一天当天就报出来。改完当天 24h 燃速要攒 6 小时历史才出数,「上周终值」要等下一次周重置。

## 修改流程

1. 改仓库里的文件(现场是链接,立即生效;`tmux.conf` 改动需 `prefix + r` 重载);
2. `tests/run.sh` 全绿;真实跑一次轮询器核对数据文件;
3. 提交、推送;另一台机器 `git pull` 即同步(首次用 `install.sh`)。
