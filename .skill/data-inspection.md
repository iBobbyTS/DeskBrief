# Data Inspection

适用场景：

- 确认截屏有没有真正落盘
- 查分析运行记录、分类结果、日报结果
- 排查设置持久化问题
- 快速验证某个功能改动是否影响 SQLite 或本地文件

关键落盘位置：

- Release / 生产 bundle id：`com.iBobby.DeskBrief2`
- Debug / 开发 bundle id：`com.iBobby.DeskBrief.dev`
- 非 sandbox Release Application Support 目录：`~/Library/Application Support/DeskBrief/`
- 非 sandbox Release 数据库：`~/Library/Application Support/DeskBrief/desk-brief.sqlite`
- 旧 Sandboxed Release 数据库：`~/Library/Containers/com.iBobby.DeskBrief2/Data/Library/Application Support/DeskBrief/desk-brief.sqlite`
- Sandboxed Debug 数据库：`~/Library/Containers/com.iBobby.DeskBrief.dev/Data/Library/Application Support/DeskBrief/desk-brief.sqlite`
- 正式截屏目录：`~/Library/Application Support/DeskBrief/screenshots/`
- 预览截屏目录：`~/Library/Application Support/DeskBrief/screenshots/preview/`
- 模型测试临时截屏目录：`~/Library/Application Support/DeskBrief/screenshots/temp/`

数据库主表：

- `category_rules`
- `analysis_runs`
- `analysis_results`
- `daily_reports`
- `app_logs`

注意：

- `离开` 不再持久化为数据库表；报告窗口会根据相邻成功分析结果之间的空白，在内存中派生展示。
- 运行时错误排查优先看 `app_logs`。`error` 表示需要修复或用户处理的失败；`log` 表示可忽略的取消、无活动、生命周期调试或已恢复状态。

设置存储位置：

- `UserDefaults`
  保存定时、语言、provider、base URL、model name、imageAnalysisMethod 等普通设置。
- `Keychain`
  保存数据库密钥和两套 API key：
  - 数据库：Release service `com.iBobby.DeskBrief` / Debug service `com.iBobby.DeskBrief.dev`，account `database-passphrase.main`
  - 截屏分析：`model-api-key.screenshot-analysis`
  - 工作内容总结：`model-api-key.work-content-summary`
  - Keychain item 必须能按 UTF-8 解码；读到无法解码的 Data 时按凭据损坏处理，不要当作缺失密钥或空 API key。

数据库检查注意：

- 运行库默认是明文 SQLite；只有用户在 设置-通用-数据库设置 开启数据库加密后，运行库才使用 SQLCipher。
- App 内部业务表建表、CRUD 和查询走 GRDB `DatabaseQueue` / Record / Query Interface；不要再新增业务 store 层 `sqlite3_*` 查询。低层 SQL 仅用于 SQLCipher 管理、迁移/检查工具和测试辅助。
- 加密状态下，系统 `sqlite3` 只能用于明文备份或测试临时库；直接读加密运行库预期会失败。
- 明文状态下，可以直接用系统 `sqlite3` 读取运行库。注意这也意味着任何能读到这个文件的 App 都可以读数据。
- 检查加密运行库时，优先创建 `/private/tmp` 下的临时 Swift/SQLCipher 工具，通过 Keychain 读取 `database-passphrase.main` 后打开数据库。不要把这类一次性检查工具提交到仓库。

容器数据合并：

- 使用 `python3 scripts/merge_container_data.py` 先做只读 dry-run；确认统计后再加 `--apply`。
- 正式合并前必须退出 DeskBrief。脚本会再次检查进程，并自动把容器外目标目录备份到桌面的时间戳目录。
- 自增 ID 会安全重映射；业务唯一键冲突保留容器外版本。同名但内容不同的截图会以 `-container-N` 改名保留。
- 脚本只支持 schema v1 明文 SQLite；任一数据库已启用 SQLCipher 时会拒绝执行。

明文备份或测试库常用命令：

```sh
sqlite3 "$HOME/Library/Application Support/DeskBrief/desk-brief.sqlite" '.tables'
```

```sh
sqlite3 "$HOME/Library/Application Support/DeskBrief/desk-brief.sqlite" \
  "select id,status,model_name,total_items,success_count,failure_count,average_item_duration_seconds from analysis_runs order by id desc limit 20;"
```

```sh
sqlite3 "$HOME/Library/Application Support/DeskBrief/desk-brief.sqlite" \
  "select id,datetime(captured_at,'unixepoch','localtime'),category_name,substr(ifnull(summary_text,''),1,80) from analysis_results order by id desc limit 20;"
```

```sh
sqlite3 "$HOME/Library/Application Support/DeskBrief/desk-brief.sqlite" \
  "select id,datetime(day_start,'unixepoch','localtime'),is_temporary,substr(daily_summary_text,1,120) from daily_reports order by day_start desc limit 20;"
```

```sh
sqlite3 "$HOME/Library/Application Support/DeskBrief/desk-brief.sqlite" \
  "select datetime(created_at,'unixepoch','localtime'),level,source,substr(message,1,160) from app_logs order by created_at desc limit 50;"
```

```sh
ls -lah "$HOME/Library/Application Support/DeskBrief/screenshots" | tail
```

额外事实：

- 截屏文件名格式是 `yyyyMMdd-HHmm-i<minutes>.jpg`。
- 预览截屏会带 `-preview` 后缀。
- 模型测试临时截屏会带 `-model-test` 后缀。
- `AppDatabase.listScreenshotFiles` 通过文件名反推时间和时长，所以改文件命名规则时必须同步更新解析逻辑。
- 临时日报状态存储在 `daily_reports.is_temporary`，不要用文本前缀判断。
