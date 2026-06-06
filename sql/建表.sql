USE Subsidy_system;
GO

-- 先删除依赖最多的子表
DROP TABLE IF EXISTS AbnormalWarning;
DROP TABLE IF EXISTS DiningRecord;
DROP TABLE IF EXISTS SettlementSheet;
DROP TABLE IF EXISTS SubsidyQualification;

-- 再删除父表
DROP TABLE IF EXISTS Elderly;
DROP TABLE IF EXISTS DiningPoint;
DROP TABLE IF EXISTS SubsidyRule;
DROP TABLE IF EXISTS AuditLog;
CREATE TABLE Elderly (
    ElderlyID NVARCHAR(32) PRIMARY KEY,
    Name NVARCHAR(50) NOT NULL,
    IDCard NVARCHAR(18) NOT NULL UNIQUE,
    Gender NVARCHAR(10) NOT NULL CHECK (Gender IN ('男', '女')),
    Age INT NOT NULL CHECK (Age >= 60),
    ContactPhone NVARCHAR(11) NOT NULL,
    Address NVARCHAR(200) NOT NULL,
    AccountStatus NVARCHAR(20) NOT NULL DEFAULT '正常' CHECK (AccountStatus IN ('正常', '冻结', '注销')),
    RegisterTime DATETIME2 NOT NULL DEFAULT GETDATE()
);
CREATE TABLE SubsidyQualification (
    QualificationID NVARCHAR(32) PRIMARY KEY,
    ElderlyID NVARCHAR(32) NOT NULL FOREIGN KEY REFERENCES Elderly(ElderlyID),
    SubsidyType NVARCHAR(20) NOT NULL CHECK (SubsidyType IN ('低保', '特困', '高龄', '普通')),
    SubsidyLevel NVARCHAR(20) NOT NULL CHECK (SubsidyLevel IN ('一级', '二级', '三级')),
    ApplyTime DATETIME2 NOT NULL DEFAULT GETDATE(),
    AuditTime DATETIME2 NULL,
    AuditStatus NVARCHAR(20) NOT NULL DEFAULT '待审核' CHECK (AuditStatus IN ('待审核', '审核通过', '审核驳回')),
    EffectiveDate DATE NOT NULL,
    ExpiryDate DATE NOT NULL,
    QualificationStatus NVARCHAR(20) NOT NULL DEFAULT '生效' CHECK (QualificationStatus IN ('生效', '失效', '暂停')),
    CONSTRAINT CHK_ExpiryDate_GT_EffectiveDate CHECK (ExpiryDate > EffectiveDate)   -- ✅ 表级约束
);
CREATE TABLE DiningPoint (
    DiningPointID NVARCHAR(32) PRIMARY KEY,
    DiningPointName NVARCHAR(100) NOT NULL,
    BusinessAddress NVARCHAR(200) NOT NULL,
    ResponsibleName NVARCHAR(50) NOT NULL,
    ContactPhone NVARCHAR(11) NOT NULL,
    BusinessLicenseNo NVARCHAR(50) NOT NULL UNIQUE,
    FoodLicenseNo NVARCHAR(50) NOT NULL UNIQUE,
    OpenTime DATE NOT NULL,
    OperationStatus NVARCHAR(20) NOT NULL DEFAULT '正常运营' CHECK (OperationStatus IN ('正常运营', '暂停营业', '注销')),
    SettlementAccount NVARCHAR(200) NOT NULL
);
CREATE TABLE SubsidyRule (
    RuleID NVARCHAR(32) PRIMARY KEY,
    SubsidyType NVARCHAR(20) NOT NULL CHECK (SubsidyType IN ('低保', '特困', '高龄', '普通')),
    SubsidyLevel NVARCHAR(20) NOT NULL CHECK (SubsidyLevel IN ('一级', '二级', '三级')),
    SubsidyRatio DECIMAL(5,4) NOT NULL CHECK (SubsidyRatio BETWEEN 0 AND 1),
    SingleSubsidyLimit DECIMAL(10,2) NOT NULL CHECK (SingleSubsidyLimit >= 0),
    MonthlySubsidyLimit DECIMAL(10,2) NOT NULL CHECK (MonthlySubsidyLimit >= 0),
    ApplicableDescription NVARCHAR(500) NOT NULL,
    RuleEffectiveDate DATE NOT NULL,
    RuleExpiryDate DATE NOT NULL,
    RuleStatus NVARCHAR(20) NOT NULL DEFAULT '启用' CHECK (RuleStatus IN ('启用', '禁用')),
    CONSTRAINT CHK_RuleExpiryDate_GT_RuleEffectiveDate CHECK (RuleExpiryDate > RuleEffectiveDate)   -- ✅ 表级约束
);
CREATE TABLE DiningRecord (
    DiningRecordID NVARCHAR(32) PRIMARY KEY,
    ElderlyID NVARCHAR(32) NOT NULL FOREIGN KEY REFERENCES Elderly(ElderlyID),
    DiningPointID NVARCHAR(32) NOT NULL FOREIGN KEY REFERENCES DiningPoint(DiningPointID),
    DiningTime DATETIME2 NOT NULL,
    MealName NVARCHAR(100) NOT NULL,
    MealOriginalPrice DECIMAL(10,2) NOT NULL,
    Quantity INT NOT NULL,
    TotalConsumeAmount DECIMAL(10,2) NOT NULL,
    SubsidyAmount DECIMAL(10,2) NOT NULL,
    ActualPayAmount DECIMAL(10,2) NOT NULL,
PayMethod NVARCHAR(20) NOT NULL,
FaceCompareScore DECIMAL(5,4) NULL CHECK (FaceCompareScore BETWEEN 0 AND 1),
    SettlementStatus NVARCHAR(20) NOT NULL DEFAULT '待结算' CHECK (SettlementStatus IN ('待结算', '已结算', '结算异常'))
);
CREATE TABLE SettlementSheet (
    SettlementSheetID NVARCHAR(32) PRIMARY KEY,
    DiningPointID NVARCHAR(32) NOT NULL FOREIGN KEY REFERENCES DiningPoint(DiningPointID),
    SettlementPeriod NVARCHAR(7) NOT NULL CHECK (SettlementPeriod LIKE '____-__'),
    GenerateTime DATETIME2 NOT NULL DEFAULT GETDATE(),
    TotalDiningCount INT NOT NULL,
    TotalConsumeAmount DECIMAL(10,2) NOT NULL,
    TotalSubsidyAmount DECIMAL(10,2) NOT NULL,
    TotalActualPayAmount DECIMAL(10,2) NOT NULL,
    AuditTime DATETIME2 NULL,
    AuditStatus NVARCHAR(20) NOT NULL DEFAULT '待审核',
    SettlementStatus NVARCHAR(20) NOT NULL DEFAULT '待结算' CHECK (SettlementStatus IN ('待结算', '已结算', '结算失败')),
    SettlementCompleteTime DATETIME2 NULL
);
CREATE TABLE AbnormalWarning (
    WarningID NVARCHAR(32) PRIMARY KEY,
    DiningRecordID NVARCHAR(32) NOT NULL UNIQUE FOREIGN KEY REFERENCES DiningRecord(DiningRecordID),
    ElderlyID NVARCHAR(32) NOT NULL FOREIGN KEY REFERENCES Elderly(ElderlyID),
    DiningPointID NVARCHAR(32) NOT NULL FOREIGN KEY REFERENCES DiningPoint(DiningPointID),
    WarningTime DATETIME2 NOT NULL DEFAULT GETDATE(),
    AbnormalType NVARCHAR(30) NOT NULL CHECK (AbnormalType IN ('重复就餐', '超额补贴', '身份异常', '其他')),
    AbnormalDescription NVARCHAR(500) NOT NULL,
    RiskLevel NVARCHAR(10) NOT NULL DEFAULT '中' CHECK (RiskLevel IN ('低', '中', '高')),
    HandleStatus NVARCHAR(20) NOT NULL DEFAULT '待处理' CHECK (HandleStatus IN ('待处理', '处理中', '已处理', '已忽略')),
    Handler NVARCHAR(50) NULL,
    HandleTime DATETIME2 NULL,
    HandleResult NVARCHAR(1000) NULL
);
CREATE TABLE AuditLog (
    LogID INT IDENTITY(1,1) PRIMARY KEY,
    TableName NVARCHAR(100) NOT NULL,
    OperationType NVARCHAR(20) NOT NULL,
    RecordID NVARCHAR(32) NOT NULL,
    FieldName NVARCHAR(100) NULL,
    OldValue NVARCHAR(MAX) NULL,
    NewValue NVARCHAR(MAX) NULL,
    Operator NVARCHAR(50) NOT NULL DEFAULT USER_NAME(),
    OperationTime DATETIME2 NOT NULL DEFAULT GETDATE()
);
-- ============================================================
-- 1. 老人表测试数据
-- ============================================================
INSERT INTO Elderly VALUES ('E001', '张建国', '350201194501011234', '男', 78, '13800000001', '厦门市思明区中山路1号', '正常', GETDATE());
INSERT INTO Elderly VALUES ('E002', '李淑芬', '350201195003021245', '女', 75, '13800000002', '厦门市湖里区华昌路2号', '正常', GETDATE());
INSERT INTO Elderly VALUES ('E003', '王德明', '350201194807031256', '男', 77, '13800000003', '厦门市集美区石鼓路3号', '正常', GETDATE());
INSERT INTO Elderly VALUES ('E004', '刘桂英', '350201195212041267', '女', 73, '13800000004', '厦门市海沧区沧林路4号', '正常', GETDATE());
INSERT INTO Elderly VALUES ('E005', '赵德胜', '350201194310051278', '男', 82, '13800000005', '厦门市同安区中山路5号', '正常', GETDATE());

-- ============================================================
-- 2. 助餐点表测试数据
-- ============================================================
INSERT INTO DiningPoint VALUES ('D001', '中山路社区食堂', '厦门市思明区中山路10号', '李店长', '13900000001', '91350200MA001', 'JY135020100001', '2020-01-01', '正常运营', '厦门银行思明支行');
INSERT INTO DiningPoint VALUES ('D002', '湖里老年餐厅', '厦门市湖里区华昌路20号', '王店长', '13900000002', '91350200MA002', 'JY135020100002', '2020-03-01', '正常运营', '厦门银行湖里支行');
INSERT INTO DiningPoint VALUES ('D003', '集美爱心食堂', '厦门市集美区石鼓路30号', '张店长', '13900000003', '91350200MA003', 'JY135020100003', '2021-01-01', '正常运营', '厦门银行集美支行');

-- ============================================================
-- 3. 补贴规则表测试数据
-- ============================================================
INSERT INTO SubsidyRule VALUES ('R001', '低保', '一级', 0.80, 10.00, 200.00, '低保老人一级补贴，补贴80%，单次上限10元，月上限200元', '2025-01-01', '2025-12-31', '启用');
INSERT INTO SubsidyRule VALUES ('R002', '特困', '一级', 0.90, 12.00, 250.00, '特困老人一级补贴，补贴90%，单次上限12元，月上限250元', '2025-01-01', '2025-12-31', '启用');
INSERT INTO SubsidyRule VALUES ('R003', '高龄', '二级', 0.50, 8.00, 150.00, '80岁以上高龄老人二级补贴，补贴50%，单次上限8元，月上限150元', '2025-01-01', '2025-12-31', '启用');
INSERT INTO SubsidyRule VALUES ('R004', '普通', '三级', 0.30, 5.00, 100.00, '普通老人三级补贴，补贴30%，单次上限5元，月上限100元', '2025-01-01', '2025-12-31', '启用');

-- ============================================================
-- 4. 补贴资格表测试数据
-- ============================================================
INSERT INTO SubsidyQualification VALUES ('Q001', 'E001', '低保', '一级', GETDATE(), GETDATE(), '审核通过', '2025-01-01', '2025-12-31', '生效');
INSERT INTO SubsidyQualification VALUES ('Q002', 'E002', '高龄', '二级', GETDATE(), GETDATE(), '审核通过', '2025-01-01', '2025-12-31', '生效');
INSERT INTO SubsidyQualification VALUES ('Q003', 'E003', '普通', '三级', GETDATE(), GETDATE(), '审核通过', '2025-01-01', '2025-12-31', '生效');
INSERT INTO SubsidyQualification VALUES ('Q004', 'E004', '特困', '一级', GETDATE(), GETDATE(), '审核通过', '2025-01-01', '2025-12-31', '生效');
INSERT INTO SubsidyQualification VALUES ('Q005', 'E005', '高龄', '二级', GETDATE(), GETDATE(), '审核通过', '2025-01-01', '2025-12-31', '生效');

-- 老人E001（低保一级）的就餐记录
INSERT INTO DiningRecord VALUES ('DR001', 'E001', 'D001', '2025-05-20 12:00:00', '厦门沙茶面套餐', 18.00, 1, 18.00, 10.00, 8.00, '支付宝', NULL, '已结算');
INSERT INTO DiningRecord VALUES ('DR002', 'E001', 'D001', '2025-05-21 12:00:00', '同安封肉套餐', 15.00, 1, 15.00, 10.00, 5.00, '其他', NULL, '已结算');
INSERT INTO DiningRecord VALUES ('DR003', 'E001', 'D001', '2025-05-22 12:00:00', '海蛎煎套餐', 12.00, 1, 12.00, 9.60, 2.40, '微信', NULL, '待结算');   -- 改：未结算 → 待结算

-- 老人E002（高龄二级）的就餐记录
INSERT INTO DiningRecord VALUES ('DR004', 'E002', 'D002', '2025-05-20 12:30:00', '花生汤套餐', 18.00, 1, 18.00, 8.00, 10.00, '其他', NULL, '已结算');
INSERT INTO DiningRecord VALUES ('DR005', 'E002', 'D002', '2025-05-21 12:30:00', '薄饼套餐', 15.00, 1, 15.00, 7.50, 7.50, '微信', NULL, '待结算');   -- 改：未结算 → 待结算

-- 老人E003（普通三级）的就餐记录
INSERT INTO DiningRecord VALUES ('DR006', 'E003', 'D003', '2025-05-20 12:00:00', '姜母鸭套餐', 15.00, 1, 15.00, 4.50, 10.50, '支付宝', NULL, '已结算');
INSERT INTO DiningRecord VALUES ('DR007', 'E003', 'D003', '2025-05-21 12:00:00', '土笋冻套餐', 12.00, 1, 12.00, 3.60, 8.40, '其他', NULL, '待结算');   -- 改：未结算 → 待结算

-- 老人E004（特困一级）的就餐记录
INSERT INTO DiningRecord VALUES ('DR008', 'E004', 'D001', '2025-05-22 12:00:00', '厦门炒米粉', 18.00, 1, 18.00, 12.00, 6.00, '其他', NULL, '待结算');   -- 改：未结算 → 待结算

-- 老人E005（高龄二级）的就餐记录
INSERT INTO DiningRecord VALUES ('DR009', 'E005', 'D002', '2025-05-23 12:00:00', '烧肉粽套餐', 15.00, 1, 15.00, 7.50, 7.50, '其他', NULL, '待结算');   -- 改：未结算 → 待结算
-- ============================================================
-- 6. 结算单表测试数据
-- ============================================================

INSERT INTO SettlementSheet VALUES ('S001', 'D001', '2025-05', GETDATE(), 4, 63.00, 41.60, 21.40, NULL, '待审核', '待结算', NULL);
INSERT INTO SettlementSheet VALUES ('S002', 'D002', '2025-05', GETDATE(), 3, 48.00, 23.00, 25.00, NULL, '待审核', '待结算', NULL);
INSERT INTO SettlementSheet VALUES ('S003', 'D003', '2025-05', GETDATE(), 2, 27.00, 8.10, 18.90, NULL, '待审核', '待结算', NULL);

-- ============================================================
-- 7. 异常预警表测试数据
-- ============================================================
INSERT INTO AbnormalWarning VALUES ('W001', 'DR001', 'E001', 'D001', GETDATE(), '重复就餐', '该老人一小时内连续两次就餐', '中', '待处理', NULL, NULL, NULL);
INSERT INTO AbnormalWarning VALUES ('W002', 'DR004', 'E002', 'D002', GETDATE(), '超额补贴', '该老人本月累计补贴已超过月上限', '高', '处理中', '张监管员', NULL, NULL);
INSERT INTO AbnormalWarning VALUES ('W003', 'DR006', 'E003', 'D003', GETDATE(), '身份异常', '老人身份证信息与系统记录不符', '高', '待处理', NULL, NULL, NULL);
-- 为就餐记录表的外键字段创建索引
CREATE INDEX idx_diningrecord_elderlyid ON DiningRecord(ElderlyID);
CREATE INDEX idx_diningrecord_diningpointid ON DiningRecord(DiningPointID);
CREATE INDEX idx_diningrecord_diningtime ON DiningRecord(DiningTime);

-- 为就餐记录表补充索引
CREATE INDEX idx_diningrecord_settlementstatus ON DiningRecord(SettlementStatus);

-- 为异常预警表的外键字段创建索引
CREATE INDEX idx_abnormalwarning_elderlyid ON AbnormalWarning(ElderlyID);
CREATE INDEX idx_abnormalwarning_diningpointid ON AbnormalWarning(DiningPointID);
CREATE INDEX idx_abnormalwarning_warningtime ON AbnormalWarning(WarningTime);

-- 为异常预警表补充索引
CREATE INDEX idx_abnormalwarning_handlestatus ON AbnormalWarning(HandleStatus);
CREATE INDEX idx_abnormalwarning_risklevel ON AbnormalWarning(RiskLevel);

-- 为结算单表创建索引和唯一约束
CREATE INDEX idx_settlementsheet_diningpointid ON SettlementSheet(DiningPointID);
CREATE UNIQUE INDEX uk_settlementsheet_diningpoint_period ON SettlementSheet(DiningPointID, SettlementPeriod);

-- 为补贴规则表创建索引和唯一约束
CREATE UNIQUE INDEX uk_subsidyrule_type_level ON SubsidyRule(SubsidyType, SubsidyLevel);
CREATE INDEX idx_subsidyrule_rulestatus ON SubsidyRule(RuleStatus);
CREATE INDEX idx_subsidyrule_effectivedate_expirydate ON SubsidyRule(RuleEffectiveDate, RuleExpiryDate);

-- 为审计日志表创建索引
CREATE INDEX idx_auditlog_table_record ON AuditLog(TableName, RecordID);
CREATE INDEX idx_auditlog_operationtime ON AuditLog(OperationTime);

USE Subsidy_system;
GO

-- ============================================================
-- 删除已存在的视图（避免重复创建错误）
-- ============================================================
DROP VIEW IF EXISTS View_ElderlyDiningDetail;
DROP VIEW IF EXISTS View_DiningPointMonthlySubsidy;
GO

-- 创建视图
CREATE VIEW View_ElderlyDiningDetail AS
SELECT 
    e.ElderlyID,
    e.Name,
    e.IDCard,
    dr.DiningRecordID,
    dr.DiningTime,
    dp.DiningPointName,
    dr.TotalConsumeAmount,
    dr.SubsidyAmount,
    dr.ActualPayAmount
FROM Elderly e
JOIN DiningRecord dr ON e.ElderlyID = dr.ElderlyID
JOIN DiningPoint dp ON dr.DiningPointID = dp.DiningPointID;
GO

CREATE VIEW View_DiningPointMonthlySubsidy AS
SELECT 
    dp.DiningPointID,
    dp.DiningPointName,
    YEAR(dr.DiningTime) AS 年份,
    MONTH(dr.DiningTime) AS 月份,
    COUNT(dr.DiningRecordID) AS 就餐人次,
    SUM(dr.TotalConsumeAmount) AS 总消费金额,
    SUM(dr.SubsidyAmount) AS 总补贴金额
FROM DiningPoint dp
JOIN DiningRecord dr ON dp.DiningPointID = dr.DiningPointID
GROUP BY dp.DiningPointID, dp.DiningPointName, YEAR(dr.DiningTime), MONTH(dr.DiningTime);
GO

-- ============================================================
-- 删除已存在的角色（避免重复创建错误）
-- ============================================================
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'ElderlyRole' AND type = 'R')
    DROP ROLE ElderlyRole;
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'DiningPointRole' AND type = 'R')
    DROP ROLE DiningPointRole;
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'SupervisorRole' AND type = 'R')
    DROP ROLE SupervisorRole;
GO

-- 创建角色
CREATE ROLE ElderlyRole;
CREATE ROLE DiningPointRole;
CREATE ROLE SupervisorRole;
GO

-- 授予权限
GRANT SELECT ON View_ElderlyDiningDetail TO ElderlyRole;
GRANT SELECT, INSERT ON DiningRecord TO DiningPointRole;
GRANT SELECT ON View_DiningPointMonthlySubsidy TO DiningPointRole;
GRANT SELECT ON Elderly TO SupervisorRole;
GRANT SELECT ON DiningPoint TO SupervisorRole;
GRANT SELECT ON DiningRecord TO SupervisorRole;
GRANT SELECT ON SubsidyRule TO SupervisorRole;
GRANT SELECT, UPDATE ON SettlementSheet TO SupervisorRole;
GRANT SELECT, UPDATE ON AbnormalWarning TO SupervisorRole;
GO