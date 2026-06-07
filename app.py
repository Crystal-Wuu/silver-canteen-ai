"""
银发食堂助餐补贴监管系统 - AI 智能问答后端

功能：
1. 将自然语言问题转换为 SQL Server 查询语句
2. 安全校验并执行只读 SELECT 查询
3. 使用大模型或本地摘要生成中文数据解读

运行前请准备：
pip install flask pyodbc python-dotenv openai
"""

from __future__ import annotations

import json
import os
import re
import time
from collections import defaultdict, deque
from datetime import date, datetime
from decimal import Decimal
from threading import Lock
from typing import Any, Optional

import pyodbc
from flask import Flask, jsonify, render_template, request

try:
    from dotenv import load_dotenv
except ImportError:
    load_dotenv = None

try:
    from openai import OpenAI
except ImportError:
    OpenAI = None

if load_dotenv:
    load_dotenv()

app = Flask(__name__, template_folder=".")


DB_CONFIG = {
    "driver": os.getenv("DB_DRIVER", "ODBC Driver 17 for SQL Server"),
    "server": os.getenv("DB_SERVER", r".\SQLEXPRESS"),
    "database": os.getenv("DB_NAME", "Subsidy_system"),
    "trusted_connection": os.getenv("DB_TRUSTED_CONNECTION", "yes"),
    "encrypt": os.getenv("DB_ENCRYPT", "no"),
    "trust_server_certificate": os.getenv("DB_TRUST_SERVER_CERTIFICATE", "yes"),
    "uid": os.getenv("DB_USER", ""),
    "pwd": os.getenv("DB_PASSWORD", ""),
}

DEEPSEEK_API_KEY = os.getenv("DEEPSEEK_API_KEY", "").strip()
DEEPSEEK_MODEL = os.getenv("DEEPSEEK_MODEL", "deepseek-chat")
RATE_LIMIT_REQUESTS = int(os.getenv("RATE_LIMIT_REQUESTS", "10"))
RATE_LIMIT_WINDOW_SECONDS = int(os.getenv("RATE_LIMIT_WINDOW_SECONDS", "300"))

request_history: dict[str, deque[float]] = defaultdict(deque)
request_history_lock = Lock()


def get_llm_client() -> Optional[Any]:
    if not DEEPSEEK_API_KEY or OpenAI is None:
        return None
    return OpenAI(api_key=DEEPSEEK_API_KEY, base_url="https://api.deepseek.com")


def client_ip() -> str:
    forwarded = request.headers.get("CF-Connecting-IP") or request.headers.get("X-Forwarded-For")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.remote_addr or "unknown"


def is_rate_limited() -> bool:
    now = time.time()
    cutoff = now - RATE_LIMIT_WINDOW_SECONDS
    ip = client_ip()
    with request_history_lock:
        history = request_history[ip]
        while history and history[0] < cutoff:
            history.popleft()
        if len(history) >= RATE_LIMIT_REQUESTS:
            return True
        history.append(now)
    return False


def get_connection() -> pyodbc.Connection:
    parts = [
        f"DRIVER={{{DB_CONFIG['driver']}}}",
        f"SERVER={DB_CONFIG['server']}",
        f"DATABASE={DB_CONFIG['database']}",
        f"Encrypt={DB_CONFIG['encrypt']}",
        f"TrustServerCertificate={DB_CONFIG['trust_server_certificate']}",
    ]
    if DB_CONFIG["uid"]:
        parts.extend([f"UID={DB_CONFIG['uid']}", f"PWD={DB_CONFIG['pwd']}"])
    else:
        parts.append(f"Trusted_Connection={DB_CONFIG['trusted_connection']}")
    return pyodbc.connect(";".join(parts) + ";")


def json_value(value: Any) -> Any:
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.strftime("%Y-%m-%d %H:%M:%S")
    if isinstance(value, date):
        return value.strftime("%Y-%m-%d")
    if isinstance(value, Decimal):
        return float(value)
    return value


def execute_select(sql: str) -> tuple[list[str], list[list[Any]]]:
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute(sql)
        columns = [desc[0] for desc in cursor.description] if cursor.description else []
        rows = [
            [json_value(item) for item in row]
            for row in cursor.fetchall()
        ] if cursor.description else []
    return columns, rows


DB_SCHEMA = """
你是“银发食堂助餐补贴监管系统”的数据分析助手。数据库为 SQL Server。

核心表：
1. Elderly 老人信息
   ElderlyID, Name, IDCard, Gender, Age, ContactPhone, Address, AccountStatus, RegisterTime
2. SubsidyQualification 补贴资格
   QualificationID, ElderlyID, SubsidyType, SubsidyLevel, ApplyTime, AuditTime, AuditStatus,
   EffectiveDate, ExpiryDate, QualificationStatus
3. DiningPoint 助餐点
   DiningPointID, DiningPointName, BusinessAddress, ResponsibleName, ContactPhone,
   BusinessLicenseNo, FoodLicenseNo, OpenTime, OperationStatus, SettlementAccount
4. SubsidyRule 补贴规则
   RuleID, SubsidyType, SubsidyLevel, SubsidyRatio, SingleSubsidyLimit, MonthlySubsidyLimit,
   ApplicableDescription, RuleEffectiveDate, RuleExpiryDate, RuleStatus
5. DiningRecord 就餐记录
   DiningRecordID, ElderlyID, DiningPointID, DiningTime, MealName, MealOriginalPrice, Quantity,
   TotalConsumeAmount, SubsidyAmount, ActualPayAmount, PayMethod, FaceCompareScore, SettlementStatus
6. SettlementSheet 结算单
   SettlementSheetID, DiningPointID, SettlementPeriod, GenerateTime, TotalDiningCount,
   TotalConsumeAmount, TotalSubsidyAmount, TotalActualPayAmount, AuditTime, AuditStatus,
   SettlementStatus, SettlementCompleteTime
7. AbnormalWarning 异常预警
   WarningID, DiningRecordID, ElderlyID, DiningPointID, WarningTime, AbnormalType,
   AbnormalDescription, RiskLevel, HandleStatus, Handler, HandleTime, HandleResult
8. AuditLog 审计日志
   LogID, TableName, OperationType, RecordID, FieldName, OldValue, NewValue, Operator, OperationTime

常用视图：
View_ElderlyDiningDetail 老人就餐明细视图
View_DiningPointMonthlySubsidy 助餐点月度补贴汇总视图

SQL 规则：
- 只生成 SELECT 或 WITH 开头的查询。
- 使用 SQL Server 语法，例如 TOP N、GETDATE()、DATEADD，不要使用 LIMIT。
- 中文字符串必须使用 N'中文'。
- 尽量给结果加清晰的中文别名和 ORDER BY。
- 若用户问系统介绍、功能说明等不需要查库的问题，needs_db=false。

重要枚举值（SQL 条件必须使用数据库真实存储值，不得自行扩写）：
- AbnormalWarning.RiskLevel：N'高'、N'中'、N'低'。用户说“高风险”时必须查询 N'高'，不能查询 N'高风险'。
- AbnormalWarning.HandleStatus：N'待处理'、N'处理中'、N'已处理'、N'已忽略'。
- AbnormalWarning.AbnormalType：N'重复就餐'、N'超额补贴'、N'身份异常'、N'其他'。
- Elderly.AccountStatus：N'正常'、N'冻结'、N'注销'。
- DiningPoint.OperationStatus：N'正常运营'、N'暂停营业'、N'注销'。
- DiningRecord.SettlementStatus：N'待结算'、N'已结算'、N'结算异常'。
- SettlementSheet.AuditStatus：N'待审核'、N'已审核'、N'审核通过'。
- SettlementSheet.SettlementStatus：N'待结算'、N'已结算'、N'结算失败'。
- SubsidyQualification.SubsidyType：N'低保'、N'特困'、N'高龄'、N'普通'。用户说“高龄补贴资格”时必须查询 SubsidyType=N'高龄'。
- SubsidyQualification.AuditStatus：N'待审核'、N'审核通过'、N'审核驳回'。
- SubsidyQualification.QualificationStatus：N'生效'、N'失效'、N'暂停'。

意图判断规则：
- 用户说“给我、查询、列出、查看、多少、统计、哪些、所有、名单、记录、资格、状态、预警、结算”等词时，通常需要查询数据库，needs_db=true。
- 只有用户明确询问系统介绍、功能说明、使用帮助等不依赖业务数据的问题，needs_db=false。
"""

NL2SQL_SYSTEM = DB_SCHEMA + """
请把用户中文问题转换成 JSON，格式必须严格如下：
{
  "needs_db": true,
  "sql": "SELECT ...",
  "explanation": "这条 SQL 的查询目的"
}
或：
{
  "needs_db": false,
  "sql": null,
  "explanation": "直接回答用户的问题"
}
只输出 JSON，不要输出 Markdown。
"""

INTERPRET_SYSTEM = DB_SCHEMA + """
用户提出问题后，系统已执行 SQL 并得到结果。
请用简洁、专业、适合监管人员阅读的中文解释查询结果。
要求：
1. 概括关键发现。
2. 说明是否存在风险、异常或值得关注的管理问题。
3. 必要时给出监管或运营建议。
不要重复大段 SQL，不要输出 JSON。
"""

FORBIDDEN_SQL = re.compile(
    r"\b(INSERT|UPDATE|DELETE|DROP|TRUNCATE|ALTER|CREATE|MERGE|EXEC|EXECUTE|GRANT|REVOKE|BACKUP|RESTORE|xp_)\b",
    re.IGNORECASE,
)


def clean_model_json(text: str) -> dict[str, Any]:
    text = text.strip()
    text = re.sub(r"^```(?:json)?\s*", "", text, flags=re.IGNORECASE)
    text = re.sub(r"\s*```$", "", text)
    match = re.search(r"\{.*\}", text, flags=re.DOTALL)
    if match:
        text = match.group(0)
    return json.loads(text)


def is_safe_sql(sql: str) -> bool:
    if not sql or not isinstance(sql, str):
        return False
    stripped = sql.strip()
    if not re.match(r"^(SELECT|WITH)\b", stripped, flags=re.IGNORECASE):
        return False
    if FORBIDDEN_SQL.search(stripped):
        return False
    if "--" in stripped or "/*" in stripped or "*/" in stripped:
        return False
    statements = [part.strip() for part in stripped.split(";") if part.strip()]
    return len(statements) <= 1


def normalize_generated_sql(sql: str) -> str:
    """纠正模型对数据库枚举值的常见自然语言扩写。"""
    literal_replacements = {
        "高风险": "高",
        "中风险": "中",
        "低风险": "低",
        "等待处理": "待处理",
        "正在处理": "处理中",
        "处理完成": "已处理",
        "正常营业": "正常运营",
        "有效": "生效",
        "有效资格": "生效",
        "高龄补贴": "高龄",
        "高龄补贴资格": "高龄",
        "低保补贴": "低保",
        "低保补贴资格": "低保",
        "特困补贴": "特困",
        "特困补贴资格": "特困",
        "普通补贴": "普通",
        "普通补贴资格": "普通",
    }
    normalized = sql
    for natural_value, database_value in literal_replacements.items():
        normalized = re.sub(
            rf"N?'{re.escape(natural_value)}'",
            f"N'{database_value}'",
            normalized,
            flags=re.IGNORECASE,
        )
    return normalized


def build_deterministic_sql(question: str) -> Optional[dict[str, Any]]:
    """处理枚举值明确的高置信度查询，避免模型误判意图或扩写数据库值。"""
    q = re.sub(r"\s+", "", question.strip())

    subsidy_type = next((value for value in ["低保", "特困", "高龄", "普通"] if value in q), None)
    if subsidy_type and any(word in q for word in ["补贴", "资格", "享受", "领取"]):
        only_active = not any(word in q for word in ["全部状态", "所有状态", "失效", "暂停"])
        status_filter = "AND sq.QualificationStatus = N'生效'" if only_active else ""
        if any(word in q for word in ["多少", "几人", "人数", "统计", "数量"]):
            return {
                "needs_db": True,
                "sql": f"""
SELECT
    sq.SubsidyType AS 补贴类型,
    COUNT(DISTINCT sq.ElderlyID) AS 老人人数
FROM SubsidyQualification sq
WHERE sq.SubsidyType = N'{subsidy_type}'
  {status_filter}
GROUP BY sq.SubsidyType
""".strip(),
                "explanation": f"统计具有{subsidy_type}补贴资格的老人人数。"
            }
        return {
            "needs_db": True,
            "sql": f"""
SELECT
    e.ElderlyID AS 老人编号,
    e.Name AS 姓名,
    e.Gender AS 性别,
    e.Age AS 年龄,
    sq.SubsidyType AS 补贴类型,
    sq.SubsidyLevel AS 补贴等级,
    sq.AuditStatus AS 审核状态,
    sq.QualificationStatus AS 资格状态,
    sq.EffectiveDate AS 生效日期,
    sq.ExpiryDate AS 失效日期
FROM SubsidyQualification sq
JOIN Elderly e ON sq.ElderlyID = e.ElderlyID
WHERE sq.SubsidyType = N'{subsidy_type}'
  {status_filter}
ORDER BY e.Age DESC, e.ElderlyID
""".strip(),
            "explanation": f"列出所有具有{subsidy_type}补贴资格的老人及其资格状态。"
        }

    qualification_status = next((
        database_value
        for natural_value, database_value in [
            ("有效", "生效"), ("生效", "生效"), ("失效", "失效"), ("暂停", "暂停")
        ]
        if natural_value in q
    ), None)
    qualification_audit_status = next((
        value for value in ["待审核", "审核通过", "审核驳回"] if value in q
    ), None)
    if "资格" in q and any([
        qualification_status,
        qualification_audit_status,
        any(word in q for word in ["给我", "查询", "列出", "查看", "所有", "哪些", "名单"])
    ]):
        filters = []
        if qualification_status:
            filters.append(f"sq.QualificationStatus = N'{qualification_status}'")
        if qualification_audit_status:
            filters.append(f"sq.AuditStatus = N'{qualification_audit_status}'")
        where_clause = f"WHERE {' AND '.join(filters)}" if filters else ""
        return {
            "needs_db": True,
            "sql": f"""
SELECT
    e.ElderlyID AS 老人编号,
    e.Name AS 姓名,
    e.Gender AS 性别,
    e.Age AS 年龄,
    sq.SubsidyType AS 补贴类型,
    sq.SubsidyLevel AS 补贴等级,
    sq.AuditStatus AS 审核状态,
    sq.QualificationStatus AS 资格状态,
    sq.EffectiveDate AS 生效日期,
    sq.ExpiryDate AS 失效日期
FROM SubsidyQualification sq
JOIN Elderly e ON sq.ElderlyID = e.ElderlyID
{where_clause}
ORDER BY sq.SubsidyType, e.Age DESC, e.ElderlyID
""".strip(),
            "explanation": "按指定资格状态或审核状态列出补贴资格老人。"
        }

    if "高龄老人" in q and not any(word in q for word in ["补贴", "资格"]):
        return {
            "needs_db": True,
            "sql": """
SELECT
    ElderlyID AS 老人编号,
    Name AS 姓名,
    Gender AS 性别,
    Age AS 年龄,
    ContactPhone AS 联系电话,
    AccountStatus AS 账户状态,
    Address AS 地址
FROM Elderly
WHERE Age >= 80
ORDER BY Age DESC, ElderlyID
""".strip(),
            "explanation": "列出所有年龄不低于80岁的高龄老人。"
        }

    account_status = next((value for value in ["正常", "冻结", "注销"] if value in q), None)
    if account_status and any(word in q for word in ["账户", "账号", "老人", "名单"]):
        return {
            "needs_db": True,
            "sql": f"""
SELECT
    ElderlyID AS 老人编号,
    Name AS 姓名,
    Gender AS 性别,
    Age AS 年龄,
    ContactPhone AS 联系电话,
    AccountStatus AS 账户状态,
    Address AS 地址
FROM Elderly
WHERE AccountStatus = N'{account_status}'
ORDER BY Age DESC, ElderlyID
""".strip(),
            "explanation": f"列出账户状态为{account_status}的老人。"
        }

    risk_level = next((value for natural, value in [("高风险", "高"), ("中风险", "中"), ("低风险", "低")] if natural in q), None)
    handle_status = next((value for value in ["待处理", "处理中", "已处理", "已忽略"] if value in q), None)
    abnormal_type = next((value for value in ["重复就餐", "超额补贴", "身份异常", "其他"] if value in q), None)
    if any([risk_level, handle_status, abnormal_type]) and any(word in q for word in ["预警", "异常", "风险", "记录", "名单", "数据"]):
        filters = []
        if risk_level:
            filters.append(f"aw.RiskLevel = N'{risk_level}'")
        if handle_status:
            filters.append(f"aw.HandleStatus = N'{handle_status}'")
        if abnormal_type:
            filters.append(f"aw.AbnormalType = N'{abnormal_type}'")
        return {
            "needs_db": True,
            "sql": f"""
SELECT
    aw.WarningID AS 预警编号,
    e.Name AS 老人姓名,
    dp.DiningPointName AS 助餐点,
    aw.AbnormalType AS 异常类型,
    aw.RiskLevel AS 风险等级,
    aw.HandleStatus AS 处理状态,
    aw.WarningTime AS 预警时间,
    aw.AbnormalDescription AS 异常说明
FROM AbnormalWarning aw
JOIN Elderly e ON aw.ElderlyID = e.ElderlyID
JOIN DiningPoint dp ON aw.DiningPointID = dp.DiningPointID
WHERE {" AND ".join(filters)}
ORDER BY aw.WarningTime DESC
""".strip(),
            "explanation": "按指定风险等级、异常类型或处理状态查询异常预警。"
        }

    operation_status = next((
        database_value
        for natural_value, database_value in [
            ("正常运营", "正常运营"), ("正常营业", "正常运营"),
            ("暂停营业", "暂停营业"), ("暂停运营", "暂停营业"), ("注销", "注销")
        ]
        if natural_value in q
    ), None)
    if operation_status and any(word in q for word in ["助餐点", "食堂", "餐厅"]):
        return {
            "needs_db": True,
            "sql": f"""
SELECT
    DiningPointID AS 助餐点编号,
    DiningPointName AS 助餐点名称,
    BusinessAddress AS 地址,
    ResponsibleName AS 负责人,
    ContactPhone AS 联系电话,
    OperationStatus AS 运营状态
FROM DiningPoint
WHERE OperationStatus = N'{operation_status}'
ORDER BY DiningPointID
""".strip(),
            "explanation": f"列出运营状态为{operation_status}的助餐点。"
        }

    settlement_status = next((value for value in ["待结算", "已结算", "结算失败"] if value in q), None)
    audit_status = next((value for value in ["待审核", "审核通过", "已审核"] if value in q), None)
    if any([settlement_status, audit_status]) and any(word in q for word in ["结算", "结算单", "审核"]):
        filters = []
        if settlement_status:
            filters.append(f"ss.SettlementStatus = N'{settlement_status}'")
        if audit_status:
            filters.append(f"ss.AuditStatus = N'{audit_status}'")
        return {
            "needs_db": True,
            "sql": f"""
SELECT
    ss.SettlementSheetID AS 结算单号,
    dp.DiningPointName AS 助餐点,
    ss.SettlementPeriod AS 结算期,
    ss.TotalDiningCount AS 就餐人次,
    ss.TotalSubsidyAmount AS 补贴总额,
    ss.AuditStatus AS 审核状态,
    ss.SettlementStatus AS 结算状态
FROM SettlementSheet ss
JOIN DiningPoint dp ON ss.DiningPointID = dp.DiningPointID
WHERE {" AND ".join(filters)}
ORDER BY ss.SettlementPeriod DESC, ss.SettlementSheetID
""".strip(),
            "explanation": "按指定审核状态或结算状态查询结算单。"
        }

    return None


def build_local_sql(question: str) -> dict[str, Any]:
    q = question.strip()

    deterministic = build_deterministic_sql(q)
    if deterministic:
        return deterministic

    if any(word in q for word in ["介绍", "功能", "能做什么", "怎么用", "帮助"]):
        return {
            "needs_db": False,
            "sql": None,
            "explanation": "本系统支持用自然语言查询老人信息、补贴资格、助餐点运营、就餐记录、结算单和异常预警，并展示自动生成的 SQL 与查询结果。",
        }

    if any(word in q for word in ["高风险", "风险预警", "异常预警", "预警"]):
        return {
            "needs_db": True,
            "sql": """
SELECT TOP 50
    aw.WarningID AS 预警编号,
    e.Name AS 老人姓名,
    dp.DiningPointName AS 助餐点,
    aw.AbnormalType AS 异常类型,
    aw.RiskLevel AS 风险等级,
    aw.HandleStatus AS 处理状态,
    aw.WarningTime AS 预警时间,
    aw.AbnormalDescription AS 异常说明
FROM AbnormalWarning aw
JOIN Elderly e ON aw.ElderlyID = e.ElderlyID
JOIN DiningPoint dp ON aw.DiningPointID = dp.DiningPointID
WHERE aw.RiskLevel = N'高' OR aw.HandleStatus IN (N'待处理', N'处理中')
ORDER BY aw.WarningTime DESC
""".strip(),
            "explanation": "查询高风险或尚未处理完成的异常预警，便于监管人员优先处置。",
        }

    if any(word in q for word in ["助餐点", "食堂", "餐厅"]) and any(word in q for word in ["排行", "排名", "次数", "人次"]):
        return {
            "needs_db": True,
            "sql": """
SELECT
    dp.DiningPointName AS 助餐点,
    COUNT(*) AS 就餐人次,
    SUM(dr.TotalConsumeAmount) AS 消费总额,
    SUM(dr.SubsidyAmount) AS 补贴总额
FROM DiningRecord dr
JOIN DiningPoint dp ON dr.DiningPointID = dp.DiningPointID
GROUP BY dp.DiningPointName
ORDER BY 就餐人次 DESC, 补贴总额 DESC
""".strip(),
            "explanation": "按助餐点统计就餐人次、消费总额和补贴总额，并按人次排序。",
        }

    if any(word in q for word in ["补贴类型", "资格", "补贴人数", "低保", "特困", "高龄"]):
        return {
            "needs_db": True,
            "sql": """
SELECT
    sq.SubsidyType AS 补贴类型,
    sq.SubsidyLevel AS 补贴等级,
    COUNT(DISTINCT sq.ElderlyID) AS 老人人数,
    SUM(ISNULL(dr.SubsidyAmount, 0)) AS 已发放补贴
FROM SubsidyQualification sq
LEFT JOIN DiningRecord dr ON sq.ElderlyID = dr.ElderlyID
WHERE sq.QualificationStatus = N'生效'
GROUP BY sq.SubsidyType, sq.SubsidyLevel
ORDER BY 老人人数 DESC, 已发放补贴 DESC
""".strip(),
            "explanation": "统计生效补贴资格下各补贴类型的人数与已产生的补贴金额。",
        }

    if any(word in q for word in ["结算", "结算单"]):
        return {
            "needs_db": True,
            "sql": """
SELECT TOP 50
    ss.SettlementSheetID AS 结算单号,
    dp.DiningPointName AS 助餐点,
    ss.SettlementPeriod AS 结算期,
    ss.TotalDiningCount AS 就餐人次,
    ss.TotalConsumeAmount AS 消费总额,
    ss.TotalSubsidyAmount AS 补贴总额,
    ss.AuditStatus AS 审核状态,
    ss.SettlementStatus AS 结算状态
FROM SettlementSheet ss
JOIN DiningPoint dp ON ss.DiningPointID = dp.DiningPointID
ORDER BY ss.SettlementPeriod DESC, ss.TotalSubsidyAmount DESC
""".strip(),
            "explanation": "查看各助餐点结算单的审核、结算和补贴汇总情况。",
        }

    if any(word in q for word in ["老人", "高龄", "年龄", "名单"]):
        age_match = re.search(r"(\d{2,3})\s*岁", q)
        age = int(age_match.group(1)) if age_match else 80
        return {
            "needs_db": True,
            "sql": f"""
SELECT TOP 50
    ElderlyID AS 老人编号,
    Name AS 姓名,
    Gender AS 性别,
    Age AS 年龄,
    ContactPhone AS 联系电话,
    AccountStatus AS 账户状态,
    Address AS 地址
FROM Elderly
WHERE Age >= {age}
ORDER BY Age DESC, ElderlyID
""".strip(),
            "explanation": f"查询年龄不低于 {age} 岁的老人名单。",
        }

    return {
        "needs_db": True,
        "sql": """
SELECT TOP 20
    dr.DiningRecordID AS 就餐记录编号,
    e.Name AS 老人姓名,
    dp.DiningPointName AS 助餐点,
    dr.DiningTime AS 就餐时间,
    dr.MealName AS 餐食名称,
    dr.TotalConsumeAmount AS 消费金额,
    dr.SubsidyAmount AS 补贴金额,
    dr.ActualPayAmount AS 实付金额,
    dr.SettlementStatus AS 结算状态
FROM DiningRecord dr
JOIN Elderly e ON dr.ElderlyID = e.ElderlyID
JOIN DiningPoint dp ON dr.DiningPointID = dp.DiningPointID
ORDER BY dr.DiningTime DESC
""".strip(),
        "explanation": "默认查询最近的就餐记录明细，展示老人、助餐点、消费和补贴情况。",
    }


def generate_sql(question: str) -> dict[str, Any]:
    deterministic = build_deterministic_sql(question)
    if deterministic:
        deterministic["source"] = "rule"
        return deterministic

    client = get_llm_client()
    if client is None:
        result = build_local_sql(question)
        result["source"] = "local"
        return result

    response = client.chat.completions.create(
        model=DEEPSEEK_MODEL,
        messages=[
            {"role": "system", "content": NL2SQL_SYSTEM},
            {"role": "user", "content": question},
        ],
        temperature=0.1,
        max_tokens=1200,
    )
    result = clean_model_json(response.choices[0].message.content or "")
    query_markers = ["给我", "查询", "列出", "查看", "统计", "多少", "所有", "哪些", "名单", "记录", "资格", "状态", "预警", "结算"]
    if not result.get("needs_db") and any(marker in question for marker in query_markers):
        result = build_local_sql(question)
        result["source"] = "rule-fallback"
        return result
    result["source"] = "llm"
    return result


def local_interpret(question: str, sql: str, columns: list[str], rows: list[list[Any]]) -> str:
    if not columns:
        return "本次查询没有返回表格字段，建议检查问题是否需要进一步限定查询范围。"
    if not rows:
        return "本次查询没有匹配到数据。可以尝试放宽时间、状态或人员条件后再次查询。"

    lines = [
        f"本次共查询到 {len(rows)} 条记录。",
        f"结果字段包括：{'、'.join(columns[:8])}{'等' if len(columns) > 8 else ''}。",
    ]
    numeric_summary = []
    for idx, col in enumerate(columns):
        values = [row[idx] for row in rows if isinstance(row[idx], (int, float))]
        if values:
            numeric_summary.append(f"{col}合计约 {sum(values):.2f}")
    if numeric_summary:
        lines.append("关键数值：" + "；".join(numeric_summary[:3]) + "。")
    lines.append("建议结合生成的 SQL 与明细表核对异常项，重点关注高风险预警、待处理记录和补贴金额较高的对象。")
    return "\n".join(lines)


def interpret_result(question: str, sql: str, columns: list[str], rows: list[list[Any]]) -> str:
    client = get_llm_client()
    if client is None:
        return local_interpret(question, sql, columns, rows)

    preview = rows[:30]
    payload = {
        "question": question,
        "sql": sql,
        "row_count": len(rows),
        "columns": columns,
        "preview_rows": preview,
    }
    response = client.chat.completions.create(
        model=DEEPSEEK_MODEL,
        messages=[
            {"role": "system", "content": INTERPRET_SYSTEM},
            {"role": "user", "content": json.dumps(payload, ensure_ascii=False, indent=2)},
        ],
        temperature=0.4,
        max_tokens=900,
    )
    return (response.choices[0].message.content or "").strip()


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/ask", methods=["POST"])
def ask():
    if is_rate_limited():
        return jsonify({
            "error": f"请求过于频繁，请稍后再试。每位访问者 {RATE_LIMIT_WINDOW_SECONDS // 60} 分钟最多提问 {RATE_LIMIT_REQUESTS} 次。"
        }), 429

    payload = request.get_json(silent=True) or {}
    question = str(payload.get("question", "")).strip()
    if not question:
        return jsonify({"error": "问题不能为空"}), 400
    if len(question) > 500:
        return jsonify({"error": "问题过长，请控制在 500 个字符以内"}), 400

    try:
        nl2sql = generate_sql(question)
    except Exception as exc:
        return jsonify({"error": f"生成 SQL 失败：{exc}"}), 500

    if not nl2sql.get("needs_db"):
        return jsonify({
            "question": question,
            "mode": "knowledge",
            "source": nl2sql.get("source", "local"),
            "sql": None,
            "sql_explanation": "",
            "columns": [],
            "rows": [],
            "row_count": 0,
            "interpretation": nl2sql.get("explanation", ""),
        })

    sql = normalize_generated_sql(str(nl2sql.get("sql") or "").strip())
    if not is_safe_sql(sql):
        return jsonify({
            "error": "生成的 SQL 未通过安全检查。系统只允许执行 SELECT/WITH 查询。",
            "sql": sql,
        }), 403

    try:
        columns, rows = execute_select(sql)
    except Exception as exc:
        return jsonify({
            "error": f"SQL 执行失败：{exc}",
            "sql": sql,
            "sql_explanation": nl2sql.get("explanation", ""),
        }), 500

    try:
        interpretation = interpret_result(question, sql, columns, rows)
    except Exception as exc:
        interpretation = local_interpret(question, sql, columns, rows)
        interpretation += f"\n\n提示：AI 解读调用失败，已使用本地摘要。错误信息：{exc}"

    return jsonify({
        "question": question,
        "mode": "nl2sql",
        "source": nl2sql.get("source", "local"),
        "sql": sql,
        "sql_explanation": nl2sql.get("explanation", ""),
        "columns": columns,
        "rows": rows,
        "row_count": len(rows),
        "interpretation": interpretation,
    })


@app.route("/api/quick_stats")
def quick_stats():
    queries = {
        "active_elders": "SELECT COUNT(*) FROM Elderly WHERE AccountStatus = N'正常'",
        "monthly_dining": "SELECT COUNT(*) FROM DiningRecord",
        "monthly_subsidy": "SELECT ISNULL(SUM(SubsidyAmount), 0) FROM DiningRecord",
        "pending_warnings": "SELECT COUNT(*) FROM AbnormalWarning WHERE HandleStatus IN (N'待处理', N'处理中')",
        "active_points": "SELECT COUNT(*) FROM DiningPoint WHERE OperationStatus = N'正常运营'",
    }
    try:
        stats: dict[str, Any] = {}
        with get_connection() as conn:
            cursor = conn.cursor()
            for key, sql in queries.items():
                cursor.execute(sql)
                stats[key] = json_value(cursor.fetchone()[0])
        stats["llm_enabled"] = bool(get_llm_client())
        return jsonify(stats)
    except Exception as exc:
        return jsonify({"error": str(exc), "llm_enabled": bool(get_llm_client())}), 500


STAT_DETAILS = {
    "elders": {
        "title": "正常账户老人",
        "summary": "按年龄段查看正常账户老人分布，并浏览老人基础信息。",
        "chart_sql": """
            SELECT
                CASE
                    WHEN Age < 70 THEN N'60-69岁'
                    WHEN Age < 80 THEN N'70-79岁'
                    ELSE N'80岁及以上'
                END AS 年龄段,
                COUNT(*) AS 人数
            FROM Elderly
            WHERE AccountStatus = N'正常'
            GROUP BY CASE
                WHEN Age < 70 THEN N'60-69岁'
                WHEN Age < 80 THEN N'70-79岁'
                ELSE N'80岁及以上'
            END
            ORDER BY 年龄段
        """,
        "detail_sql": """
            SELECT TOP 100
                ElderlyID AS 老人编号, Name AS 姓名, Gender AS 性别, Age AS 年龄,
                ContactPhone AS 联系电话, Address AS 地址, RegisterTime AS 注册时间
            FROM Elderly
            WHERE AccountStatus = N'正常'
            ORDER BY Age DESC, ElderlyID
        """,
        "unit": "人",
    },
    "dining": {
        "title": "累计就餐记录",
        "summary": "按助餐点查看累计服务人次，并浏览最近的就餐记录。",
        "chart_sql": """
            SELECT dp.DiningPointName AS 助餐点, COUNT(*) AS 就餐人次
            FROM DiningRecord dr
            JOIN DiningPoint dp ON dp.DiningPointID = dr.DiningPointID
            GROUP BY dp.DiningPointName
            ORDER BY 就餐人次 DESC
        """,
        "detail_sql": """
            SELECT TOP 100
                dr.DiningRecordID AS 记录编号, e.Name AS 老人姓名,
                dp.DiningPointName AS 助餐点, dr.DiningTime AS 就餐时间,
                dr.MealName AS 餐食名称, dr.TotalConsumeAmount AS 消费金额,
                dr.SubsidyAmount AS 补贴金额, dr.ActualPayAmount AS 实付金额,
                dr.SettlementStatus AS 结算状态
            FROM DiningRecord dr
            JOIN Elderly e ON e.ElderlyID = dr.ElderlyID
            JOIN DiningPoint dp ON dp.DiningPointID = dr.DiningPointID
            ORDER BY dr.DiningTime DESC
        """,
        "unit": "次",
    },
    "subsidy": {
        "title": "累计补贴金额",
        "summary": "按补贴类型查看累计发放金额，并浏览补贴金额较高的就餐记录。",
        "chart_sql": """
            SELECT sq.SubsidyType AS 补贴类型, SUM(dr.SubsidyAmount) AS 补贴金额
            FROM DiningRecord dr
            JOIN SubsidyQualification sq ON sq.ElderlyID = dr.ElderlyID
            GROUP BY sq.SubsidyType
            ORDER BY 补贴金额 DESC
        """,
        "detail_sql": """
            SELECT TOP 100
                dr.DiningRecordID AS 记录编号, e.Name AS 老人姓名,
                sq.SubsidyType AS 补贴类型, sq.SubsidyLevel AS 补贴等级,
                dp.DiningPointName AS 助餐点, dr.DiningTime AS 就餐时间,
                dr.TotalConsumeAmount AS 消费金额, dr.SubsidyAmount AS 补贴金额
            FROM DiningRecord dr
            JOIN Elderly e ON e.ElderlyID = dr.ElderlyID
            JOIN SubsidyQualification sq ON sq.ElderlyID = dr.ElderlyID
            JOIN DiningPoint dp ON dp.DiningPointID = dr.DiningPointID
            ORDER BY dr.SubsidyAmount DESC, dr.DiningTime DESC
        """,
        "unit": "元",
    },
    "warnings": {
        "title": "待处理预警",
        "summary": "查看尚未完成处理的预警风险等级分布及具体记录。",
        "chart_sql": """
            SELECT RiskLevel AS 风险等级, COUNT(*) AS 预警数量
            FROM AbnormalWarning
            WHERE HandleStatus IN (N'待处理', N'处理中')
            GROUP BY RiskLevel
            ORDER BY CASE RiskLevel WHEN N'高' THEN 1 WHEN N'中' THEN 2 ELSE 3 END
        """,
        "detail_sql": """
            SELECT TOP 100
                aw.WarningID AS 预警编号, e.Name AS 老人姓名,
                dp.DiningPointName AS 助餐点, aw.AbnormalType AS 异常类型,
                aw.RiskLevel AS 风险等级, aw.HandleStatus AS 处理状态,
                aw.WarningTime AS 预警时间, aw.AbnormalDescription AS 异常说明,
                aw.Handler AS 处理人
            FROM AbnormalWarning aw
            JOIN Elderly e ON e.ElderlyID = aw.ElderlyID
            JOIN DiningPoint dp ON dp.DiningPointID = aw.DiningPointID
            WHERE aw.HandleStatus IN (N'待处理', N'处理中')
            ORDER BY CASE aw.RiskLevel WHEN N'高' THEN 1 WHEN N'中' THEN 2 ELSE 3 END,
                     aw.WarningTime DESC
        """,
        "unit": "条",
    },
    "points": {
        "title": "正常运营助餐点",
        "summary": "查看各正常运营助餐点的累计服务量及运营基础信息。",
        "chart_sql": """
            SELECT dp.DiningPointName AS 助餐点, COUNT(dr.DiningRecordID) AS 服务人次
            FROM DiningPoint dp
            LEFT JOIN DiningRecord dr ON dr.DiningPointID = dp.DiningPointID
            WHERE dp.OperationStatus = N'正常运营'
            GROUP BY dp.DiningPointName
            ORDER BY 服务人次 DESC
        """,
        "detail_sql": """
            SELECT TOP 100
                dp.DiningPointID AS 助餐点编号, dp.DiningPointName AS 助餐点名称,
                dp.BusinessAddress AS 营业地址, dp.ResponsibleName AS 负责人,
                dp.ContactPhone AS 联系电话, dp.OpenTime AS 开业时间,
                COUNT(dr.DiningRecordID) AS 累计服务人次,
                ISNULL(SUM(dr.SubsidyAmount), 0) AS 累计补贴金额
            FROM DiningPoint dp
            LEFT JOIN DiningRecord dr ON dr.DiningPointID = dp.DiningPointID
            WHERE dp.OperationStatus = N'正常运营'
            GROUP BY dp.DiningPointID, dp.DiningPointName, dp.BusinessAddress,
                     dp.ResponsibleName, dp.ContactPhone, dp.OpenTime
            ORDER BY 累计服务人次 DESC
        """,
        "unit": "次",
    },
}


@app.route("/api/stat_detail/<metric>")
def stat_detail(metric: str):
    config = STAT_DETAILS.get(metric)
    if not config:
        return jsonify({"error": "未知统计指标"}), 404
    try:
        chart_columns, chart_rows = execute_select(config["chart_sql"])
        columns, rows = execute_select(config["detail_sql"])
        return jsonify({
            "title": config["title"],
            "summary": config["summary"],
            "unit": config["unit"],
            "chart_columns": chart_columns,
            "chart_rows": chart_rows,
            "columns": columns,
            "rows": rows,
            "row_count": len(rows),
        })
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500


@app.route("/api/suggested_questions")
def suggested_questions():
    return jsonify([
        {"category": "老人查询", "q": "列出所有80岁以上的高龄老人"},
        {"category": "老人查询", "q": "查询最近20条老人就餐记录"},
        {"category": "补贴分析", "q": "统计每种补贴类型的老人人数和已发放补贴金额"},
        {"category": "补贴分析", "q": "按助餐点统计就餐人次和补贴总额排行"},
        {"category": "结算监管", "q": "查看各助餐点结算单的审核和结算情况"},
        {"category": "风险预警", "q": "列出所有高风险或待处理的异常预警"},
        {"category": "系统说明", "q": "这个智能问答系统能做什么"},
    ])


@app.route("/api/test_db")
def test_db():
    try:
        with get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT DB_NAME()")
            db_name = cursor.fetchone()[0]
        return jsonify({
            "status": "ok",
            "database": db_name,
            "llm_enabled": bool(get_llm_client()),
        })
    except Exception as exc:
        return jsonify({
            "status": "error",
            "message": str(exc),
            "llm_enabled": bool(get_llm_client()),
        }), 500


if __name__ == "__main__":
    debug = os.getenv("FLASK_DEBUG", "0") == "1"
    app.run(
        debug=debug,
        use_reloader=False,
        host="0.0.0.0",
        port=int(os.getenv("PORT", "5000")),
    )
