# 银发食堂助餐补贴监管系统

本项目是基于 SQL Server、Flask 与 DeepSeek 的助餐补贴监管与智能问答系统。系统将老人账户、就餐、补贴、助餐点、结算单和异常预警等业务数据集中管理，并允许用户使用自然语言查询数据库。

## 主要功能

- 使用中文问题生成 SQL Server 只读查询语句
- 展示生成的 SQL、查询结果表格与中文分析
- 自动阻止删除、修改、建表和执行存储过程等危险 SQL
- 展示正常账户老人、累计就餐记录、累计补贴金额、待处理预警和正常运营助餐点等核心指标
- 点击顶部指标查看统计图表与对应明细记录
- 支持查询老人、就餐、补贴、结算、助餐点和异常预警数据
- 支持通过 ngrok 固定域名提供公网 HTTPS 访问

## 技术架构

| 层次 | 技术 | 作用 |
| --- | --- | --- |
| 前端 | HTML、CSS、JavaScript | 问答交互、结果表格、统计卡片和可视化详情 |
| 后端 | Python、Flask | API 路由、SQL 安全校验、数据库查询和结果序列化 |
| 大模型 | DeepSeek Chat API | 自然语言转 SQL 与查询结果解读 |
| 数据库 | SQL Server、pyodbc | 保存并查询业务数据 |
| 公网访问 | ngrok | 使用固定域名将本地 Flask 服务映射为公网 HTTPS 地址 |

## 项目结构

```text
.
├─ app.py                    # Flask 后端、DeepSeek 调用和查询接口
├─ index.html                # 前端页面
├─ requirements.txt          # Python 依赖
├─ .env.example              # 环境变量示例
├─ public_share.ps1          # 公网分享脚本
├─ 启动公网分享.bat           # 双击启动公网分享
├─ sql/                      # SQL Server 建表、数据和触发器脚本
└─ docs/                     # 数据库设计与系统实现文档
```

## 本地运行

### 1. 准备数据库

在 SQL Server Management Studio 中创建数据库 `Subsidy_system`，然后严格依次执行：

1. `sql/建表.sql`
2. `sql/触发器代码.sql`
3. `sql/完整数据导出.sql`

`建表.sql` 会插入少量初始数据。当前版本的 `完整数据导出.sql` 会在事务中临时停用触发器、清空这些初始数据、导入最终完整数据并重新启用触发器，因此可以重复执行并得到一致结果。

`完整数据导出.sql` 会覆盖现有业务数据。执行前请先阅读 [数据库复刻与使用注意事项](数据库复刻与使用注意事项.md)，并备份需要保留的数据。

### 2. 安装依赖

```powershell
pip install -r requirements.txt
```

电脑还需要安装与 Python 位数一致的 **ODBC Driver 17 for SQL Server** 或更新版本。

### 3. 配置环境变量

复制环境变量示例：

```powershell
Copy-Item .env.example .env
```

然后编辑 `.env`：

```ini
DEEPSEEK_API_KEY=你的DeepSeek_API_Key
DEEPSEEK_MODEL=deepseek-chat

DB_DRIVER=ODBC Driver 17 for SQL Server
DB_SERVER=你的SQL_Server服务器名称
DB_NAME=Subsidy_system
DB_TRUSTED_CONNECTION=yes
```

`.env` 包含密钥和本机数据库配置，已经被 `.gitignore` 排除，禁止上传到 GitHub。

### 4. 启动网站

```powershell
python app.py
```

浏览器访问：

```text
http://127.0.0.1:5000
```

可用以下地址检查数据库连接：

```text
http://127.0.0.1:5000/api/test_db
```

## 固定公网网址

当前项目使用的固定公网网址为：

```text
https://throwing-company-evil.ngrok-free.dev
```

使用方法：

1. 注册 ngrok 账户并完成 Authtoken 配置。
2. 下载 Windows 版 `ngrok.exe`，放在项目根目录。
3. 双击 `启动公网分享.bat`。
4. 脚本会自动检查并启动 Flask，然后使用上述固定域名启动 ngrok。

电脑或脚本重新启动后，网址保持不变。但运行网站的电脑必须保持开机、联网，并保持公网分享窗口开启。

## API 接口

| 接口 | 方法 | 说明 |
| --- | --- | --- |
| `/api/ask` | POST | 接收自然语言问题并返回 SQL、查询结果和分析 |
| `/api/quick_stats` | GET | 返回页面顶部核心指标 |
| `/api/stat_detail/<metric>` | GET | 返回指标图表数据和明细记录 |
| `/api/suggested_questions` | GET | 返回推荐问题 |
| `/api/test_db` | GET | 检查数据库连接状态 |

## 安全说明

- 后端只允许执行 `SELECT` 或 `WITH` 开头的只读 SQL。
- 系统会拒绝包含写入、删除、建表、执行存储过程等关键字的 SQL。
- 请勿将 `.env`、DeepSeek API Key、数据库密码或本机日志上传到公开仓库。
- 公网开放期间，运行网站的电脑必须保持开机，并保持 Flask 与 ngrok 持续运行。

## 设计文档

完整的数据库设计、触发器、Python 可视化和 AI 问答系统实现说明位于 `docs` 文件夹。其中：

- `第7章_Python交互与可视化.docx`：Python 数据交互与可视化实现
- `第8章_AI智能问答与Web交互系统设计与实现.docx`：DeepSeek、NL2SQL、Web 页面、公网访问与安全控制实现
