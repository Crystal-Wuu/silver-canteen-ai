USE Subsidy_system; 
GO

-- 触发器1：就餐记录插入触发器
-- 使用 CREATE OR ALTER，重复执行本文件时不会因触发器已存在而失败。
CREATE OR ALTER TRIGGER trg_before_insert_dining
ON DiningRecord
INSTEAD OF INSERT
AS
BEGIN
    SET NOCOUNT ON;
    -- 直接插入就餐记录，同时计算补贴
    INSERT INTO DiningRecord (
        DiningRecordID, ElderlyID, DiningPointID, DiningTime,
        MealName, MealOriginalPrice, Quantity, TotalConsumeAmount,
        SubsidyAmount, ActualPayAmount, PayMethod, SettlementStatus, FaceCompareScore
    )
    SELECT 
        i.DiningRecordID,
        i.ElderlyID,
        i.DiningPointID,
        i.DiningTime,
        i.MealName,
        i.MealOriginalPrice,
        i.Quantity,
        i.TotalConsumeAmount,
        -- ================= 补贴金额计算 =================
        CASE 
            -- 异常情况：短时内在不同地点使用 或 身份异常 → 补贴为0
            WHEN EXISTS (
                SELECT * FROM DiningRecord dr
                WHERE dr.ElderlyID = i.ElderlyID
                  AND dr.DiningPointID != i.DiningPointID
                  AND ABS(DATEDIFF(MINUTE, dr.DiningTime, i.DiningTime)) <= 15
            ) THEN 0
            WHEN i.FaceCompareScore IS NOT NULL AND i.FaceCompareScore < 0.8 THEN 0
            -- 没有有效资格 → 补贴为0
            WHEN Q.QualificationID IS NULL THEN 0
            ELSE
                -- 有资格，计算理论补贴（受单次上限限制）
                CASE 
                    WHEN i.TotalConsumeAmount * R.SubsidyRatio <= R.SingleSubsidyLimit
                    THEN i.TotalConsumeAmount * R.SubsidyRatio
                    ELSE R.SingleSubsidyLimit
                END
                -- 再受月度剩余限制（减去超额部分）
                - CASE 
                    -- 本月已用补贴（子查询）
                    WHEN ISNULL((
                        SELECT SUM(SubsidyAmount)
                        FROM DiningRecord dr2
                        WHERE dr2.ElderlyID = i.ElderlyID
                          AND YEAR(dr2.DiningTime) = YEAR(i.DiningTime)
                          AND MONTH(dr2.DiningTime) = MONTH(i.DiningTime)
                    ), 0) + 
                    CASE 
                        WHEN i.TotalConsumeAmount * R.SubsidyRatio <= R.SingleSubsidyLimit
                        THEN i.TotalConsumeAmount * R.SubsidyRatio
                        ELSE R.SingleSubsidyLimit
                    END > R.MonthlySubsidyLimit
                    THEN (
                        -- 超额数值 = (已用 + 本次理论) - 月上限
                        ISNULL((
                            SELECT SUM(SubsidyAmount)
                            FROM DiningRecord dr2
                            WHERE dr2.ElderlyID = i.ElderlyID
                              AND YEAR(dr2.DiningTime) = YEAR(i.DiningTime)
                              AND MONTH(dr2.DiningTime) = MONTH(i.DiningTime)
                        ), 0) 
                        + CASE 
                            WHEN i.TotalConsumeAmount * R.SubsidyRatio <= R.SingleSubsidyLimit
                            THEN i.TotalConsumeAmount * R.SubsidyRatio
                            ELSE R.SingleSubsidyLimit
                          END
                        - R.MonthlySubsidyLimit
                    )
                    ELSE 0
                END
        END AS SubsidyAmount,
        -- ================= 实付金额 = 总消费 - 补贴 （补贴重复刚才的计算）=================
        i.TotalConsumeAmount - 
        -- 重复刚才计算补贴的内容
        CASE 
            WHEN EXISTS (
                SELECT * FROM DiningRecord dr
                WHERE dr.ElderlyID = i.ElderlyID
                  AND dr.DiningPointID != i.DiningPointID
                  AND ABS(DATEDIFF(MINUTE, dr.DiningTime, i.DiningTime)) <= 15
            ) THEN 0
            WHEN i.FaceCompareScore IS NOT NULL AND i.FaceCompareScore < 0.8 THEN 0
            WHEN Q.QualificationID IS NULL THEN 0
            ELSE
                CASE 
                    WHEN i.TotalConsumeAmount * R.SubsidyRatio <= R.SingleSubsidyLimit
                    THEN i.TotalConsumeAmount * R.SubsidyRatio
                    ELSE R.SingleSubsidyLimit
                END
                - CASE 
                    WHEN ISNULL((
                        SELECT SUM(SubsidyAmount)
                        FROM DiningRecord dr2
                        WHERE dr2.ElderlyID = i.ElderlyID
                          AND YEAR(dr2.DiningTime) = YEAR(i.DiningTime)
                          AND MONTH(dr2.DiningTime) = MONTH(i.DiningTime)
                    ), 0) + 
                    CASE 
                        WHEN i.TotalConsumeAmount * R.SubsidyRatio <= R.SingleSubsidyLimit
                        THEN i.TotalConsumeAmount * R.SubsidyRatio
                        ELSE R.SingleSubsidyLimit
                    END > R.MonthlySubsidyLimit
                    THEN (
                        ISNULL((
                            SELECT SUM(SubsidyAmount)
                            FROM DiningRecord dr2
                            WHERE dr2.ElderlyID = i.ElderlyID
                              AND YEAR(dr2.DiningTime) = YEAR(i.DiningTime)
                              AND MONTH(dr2.DiningTime) = MONTH(i.DiningTime)
                        ), 0) 
                        + CASE 
                            WHEN i.TotalConsumeAmount * R.SubsidyRatio <= R.SingleSubsidyLimit
                            THEN i.TotalConsumeAmount * R.SubsidyRatio
                            ELSE R.SingleSubsidyLimit
                          END
                        - R.MonthlySubsidyLimit
                    )
                    ELSE 0
                END
        END AS ActualPayAmount,
        i.PayMethod,
        '待结算',
        i.FaceCompareScore
    FROM inserted i
    LEFT JOIN SubsidyQualification Q 
        ON i.ElderlyID = Q.ElderlyID
        AND Q.QualificationStatus = '生效'
        AND i.DiningTime BETWEEN Q.EffectiveDate AND Q.ExpiryDate
    LEFT JOIN SubsidyRule R 
        ON Q.SubsidyType = R.SubsidyType
        AND Q.SubsidyLevel = R.SubsidyLevel
        AND R.RuleStatus = '启用'
        AND i.DiningTime BETWEEN R.RuleEffectiveDate AND R.RuleExpiryDate;

    -- ================= 插入预警记录 =================
    -- 这里需要基于同样的条件判断，单独再写一次 INSERT ... SELECT
    -- 但为了简单，我们可以只针对异常情况插入预警
    INSERT INTO AbnormalWarning (
        WarningID, DiningRecordID, ElderlyID, DiningPointID,
        WarningTime, AbnormalType, AbnormalDescription, RiskLevel, HandleStatus
    )
    SELECT 
        -- 生成一个临时ID（使用时间+随机数）
        CONCAT('W', FORMAT(GETDATE(), 'yyyyMMddHHmmss'), ABS(CHECKSUM(NEWID())) % 10000),
        i.DiningRecordID,
        i.ElderlyID,
        i.DiningPointID,
        GETDATE(),
        CASE 
            WHEN EXISTS (
                SELECT * FROM DiningRecord dr
                WHERE dr.ElderlyID = i.ElderlyID
                  AND dr.DiningPointID != i.DiningPointID
                  AND ABS(DATEDIFF(MINUTE, dr.DiningTime, i.DiningTime)) <= 15
            ) THEN '重复就餐'
            WHEN i.FaceCompareScore IS NOT NULL AND i.FaceCompareScore < 0.8 THEN '身份异常'
            WHEN Q.QualificationID IS NOT NULL 
                 AND (i.TotalConsumeAmount * R.SubsidyRatio) > R.MonthlySubsidyLimit   -- 简化的超额判断，没有减已用
            THEN '超额补贴'
            ELSE '其他'
        END,
        CASE 
            WHEN EXISTS (
                SELECT * FROM DiningRecord dr
                WHERE dr.ElderlyID = i.ElderlyID
                  AND dr.DiningPointID != i.DiningPointID
                  AND ABS(DATEDIFF(MINUTE, dr.DiningTime, i.DiningTime)) <= 15
            ) THEN '同一老人15分钟内在不同助餐点就餐'
            WHEN i.FaceCompareScore IS NOT NULL AND i.FaceCompareScore < 0.8 THEN '人脸比对分值低于0.8'
            WHEN Q.QualificationID IS NOT NULL 
                 AND (i.TotalConsumeAmount * R.SubsidyRatio) > R.MonthlySubsidyLimit
            THEN '本次补贴金额超过月度上限'
            ELSE '异常就餐行为'
        END,
        CASE 
            WHEN EXISTS (
                SELECT * FROM DiningRecord dr
                WHERE dr.ElderlyID = i.ElderlyID
                  AND dr.DiningPointID != i.DiningPointID
                  AND ABS(DATEDIFF(MINUTE, dr.DiningTime, i.DiningTime)) <= 15
            ) OR (i.FaceCompareScore IS NOT NULL AND i.FaceCompareScore < 0.8) THEN '高'
            ELSE '中'
        END,
        '待处理'
    FROM inserted i
    LEFT JOIN SubsidyQualification Q 
        ON i.ElderlyID = Q.ElderlyID
        AND Q.QualificationStatus = '生效'
        AND i.DiningTime BETWEEN Q.EffectiveDate AND Q.ExpiryDate
    LEFT JOIN SubsidyRule R 
        ON Q.SubsidyType = R.SubsidyType
        AND Q.SubsidyLevel = R.SubsidyLevel
        AND R.RuleStatus = '启用'
        AND i.DiningTime BETWEEN R.RuleEffectiveDate AND R.RuleExpiryDate
    WHERE 
        EXISTS (
            SELECT * FROM DiningRecord dr
            WHERE dr.ElderlyID = i.ElderlyID
              AND dr.DiningPointID != i.DiningPointID
              AND ABS(DATEDIFF(MINUTE, dr.DiningTime, i.DiningTime)) <= 15
        )
        OR (i.FaceCompareScore IS NOT NULL AND i.FaceCompareScore < 0.8)
        OR (Q.QualificationID IS NOT NULL AND (i.TotalConsumeAmount * R.SubsidyRatio) > R.MonthlySubsidyLimit);
END
GO


-- 触发器2：老人账户状态联动补贴资格
CREATE OR ALTER TRIGGER trg_after_update_elderly_status
ON Elderly
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    
    -- 当老人的 AccountStatus 变为 '冻结' 或 '注销' 时，自动更新其补贴资格状态
    UPDATE SubsidyQualification
    SET QualificationStatus = CASE 
        WHEN i.AccountStatus = '冻结' THEN '暂停'
        WHEN i.AccountStatus = '注销' THEN '失效'
        ELSE QualificationStatus
    END
    FROM SubsidyQualification Q
    INNER JOIN inserted i ON Q.ElderlyID = i.ElderlyID
    WHERE i.AccountStatus IN ('冻结', '注销')
      AND Q.QualificationStatus = '生效';   -- 只修改当前生效的资格
END
GO

-- 触发器3：保证同一老人同一时间只有一份生效补贴资格 + “高龄”和“特困”补贴老人的年龄自动校验
CREATE OR ALTER TRIGGER trg_before_insert_update_subsidy_qualification
ON SubsidyQualification
INSTEAD OF INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. 唯一性检查
    IF EXISTS (
        SELECT *
        FROM inserted i
        WHERE i.QualificationStatus = '生效'
          AND EXISTS (
              SELECT *
              FROM SubsidyQualification Q
              WHERE Q.ElderlyID = i.ElderlyID
                AND Q.QualificationID != i.QualificationID
                AND Q.QualificationStatus = '生效'
                AND Q.EffectiveDate <= i.ExpiryDate
                AND Q.ExpiryDate >= i.EffectiveDate
          )
    )
    BEGIN
        RAISERROR('该老人已有生效的补贴资格，且时间重叠，无法再次设为生效', 16, 1);
        ROLLBACK;
        RETURN;
    END;

    -- 2. 处理 INSERT 操作
    IF EXISTS (SELECT * FROM inserted) AND NOT EXISTS (SELECT * FROM deleted)
    BEGIN
        INSERT INTO SubsidyQualification (
            QualificationID, ElderlyID, SubsidyType, SubsidyLevel,
            ApplyTime, AuditTime, AuditStatus, EffectiveDate, ExpiryDate, QualificationStatus
        )
        SELECT 
            i.QualificationID,
            i.ElderlyID,
            i.SubsidyType,
            i.SubsidyLevel,
            i.ApplyTime,
            -- 年龄不符时，审核时间设为当前时间，否则用原值
            CASE 
                WHEN (i.SubsidyType = '高龄' AND e.Age < 80) 
                     OR (i.SubsidyType = '特困' AND e.Age < 65) 
                THEN GETDATE()
                ELSE i.AuditTime
            END,
            -- 年龄不符时，审核状态设为“审核驳回”，否则用原值
            CASE 
                WHEN (i.SubsidyType = '高龄' AND e.Age < 80) 
                     OR (i.SubsidyType = '特困' AND e.Age < 65) 
                THEN '审核驳回'
                ELSE i.AuditStatus
            END,
            i.EffectiveDate,
            i.ExpiryDate,
            i.QualificationStatus
        FROM inserted i
        LEFT JOIN Elderly e ON i.ElderlyID = e.ElderlyID;
    END
    -- 3. 处理 UPDATE 操作
    ELSE IF EXISTS (SELECT * FROM inserted) AND EXISTS (SELECT * FROM deleted)
    BEGIN
        UPDATE sq
        SET 
            ElderlyID = i.ElderlyID,
            SubsidyType = i.SubsidyType,
            SubsidyLevel = i.SubsidyLevel,
            ApplyTime = i.ApplyTime,
            AuditTime = CASE 
                WHEN (i.SubsidyType = '高龄' AND e.Age < 80) 
                     OR (i.SubsidyType = '特困' AND e.Age < 65) 
                THEN GETDATE()
                ELSE i.AuditTime
            END,
            AuditStatus = CASE 
                WHEN (i.SubsidyType = '高龄' AND e.Age < 80) 
                     OR (i.SubsidyType = '特困' AND e.Age < 65) 
                THEN '审核驳回'
                ELSE i.AuditStatus
            END,
            EffectiveDate = i.EffectiveDate,
            ExpiryDate = i.ExpiryDate,
            QualificationStatus = i.QualificationStatus
        FROM SubsidyQualification sq
        INNER JOIN inserted i ON sq.QualificationID = i.QualificationID
        LEFT JOIN Elderly e ON i.ElderlyID = e.ElderlyID;
    END
END
GO

-- 触发器4：结算单审核状态变更时进行业务联动
CREATE OR ALTER TRIGGER trg_after_update_settlementsheet
ON SettlementSheet
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- 防止同一个助餐点同一周期生成多张结算单（即使有唯一约束，这里也做友好提示）
    IF EXISTS (
        SELECT *
        FROM inserted i
        WHERE EXISTS (
            SELECT *
            FROM SettlementSheet S
            WHERE S.DiningPointID = i.DiningPointID
              AND S.SettlementPeriod = i.SettlementPeriod
              AND S.SettlementSheetID != i.SettlementSheetID
        )
    )
    BEGIN
        RAISERROR('该助餐点在本周期已存在结算单，不能重复生成', 16, 1);
        ROLLBACK;
        RETURN;
    END;

    -- 当审核状态变为“审核通过”时，可以自动记录审核完成时间（如果之前未记录）
    UPDATE SettlementSheet
    SET AuditTime = GETDATE()
    FROM SettlementSheet S
    INNER JOIN inserted i ON S.SettlementSheetID = i.SettlementSheetID
    WHERE i.AuditStatus = '审核通过'
      AND S.AuditTime IS NULL;

    -- 当结算状态变为“已结算”时，自动记录结算完成时间
    UPDATE SettlementSheet
    SET SettlementCompleteTime = GETDATE()
    FROM SettlementSheet S
    INNER JOIN inserted i ON S.SettlementSheetID = i.SettlementSheetID
    WHERE i.SettlementStatus = '已结算'
      AND S.SettlementCompleteTime IS NULL;
END
GO

-- 触发器5：补贴资格表审计日志
CREATE OR ALTER TRIGGER trg_audit_subsidy_qualification
ON SubsidyQualification
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    -- ========== 处理 INSERT 操作 ==========
    IF EXISTS (SELECT * FROM inserted) AND NOT EXISTS (SELECT * FROM deleted)
    BEGIN
        INSERT INTO AuditLog(TableName, OperationType, RecordID, FieldName, OldValue, NewValue, Operator)
        SELECT 'SubsidyQualification', 'INSERT', i.QualificationID, 'QualificationID', NULL, i.QualificationID, SUSER_NAME() FROM inserted i
        UNION ALL
        SELECT 'SubsidyQualification', 'INSERT', i.QualificationID, 'ElderlyID', NULL, i.ElderlyID, SUSER_NAME() FROM inserted i
        UNION ALL
        SELECT 'SubsidyQualification', 'INSERT', i.QualificationID, 'SubsidyType', NULL, i.SubsidyType, SUSER_NAME() FROM inserted i
        UNION ALL
        SELECT 'SubsidyQualification', 'INSERT', i.QualificationID, 'SubsidyLevel', NULL, i.SubsidyLevel, SUSER_NAME() FROM inserted i
        UNION ALL
        SELECT 'SubsidyQualification', 'INSERT', i.QualificationID, 'ApplyTime', NULL, CAST(i.ApplyTime AS NVARCHAR(MAX)), SUSER_NAME() FROM inserted i
        UNION ALL
        SELECT 'SubsidyQualification', 'INSERT', i.QualificationID, 'AuditTime', NULL, CAST(i.AuditTime AS NVARCHAR(MAX)), SUSER_NAME() FROM inserted i
        UNION ALL
        SELECT 'SubsidyQualification', 'INSERT', i.QualificationID, 'AuditStatus', NULL, i.AuditStatus, SUSER_NAME() FROM inserted i
        UNION ALL
        SELECT 'SubsidyQualification', 'INSERT', i.QualificationID, 'EffectiveDate', NULL, CAST(i.EffectiveDate AS NVARCHAR(MAX)), SUSER_NAME() FROM inserted i
        UNION ALL
        SELECT 'SubsidyQualification', 'INSERT', i.QualificationID, 'ExpiryDate', NULL, CAST(i.ExpiryDate AS NVARCHAR(MAX)), SUSER_NAME() FROM inserted i
        UNION ALL
        SELECT 'SubsidyQualification', 'INSERT', i.QualificationID, 'QualificationStatus', NULL, i.QualificationStatus, SUSER_NAME() FROM inserted i;
    END

    -- ========== 处理 UPDATE 操作 ==========
    IF EXISTS (SELECT * FROM inserted) AND EXISTS (SELECT * FROM deleted)
    BEGIN
        INSERT INTO AuditLog (TableName, OperationType, RecordID, FieldName, OldValue, NewValue, Operator)
        SELECT 
            'SubsidyQualification',
            'UPDATE',
            COALESCE(d.QualificationID, i.QualificationID),
            'ElderlyID',
            CAST(d.ElderlyID AS NVARCHAR(MAX)),
            CAST(i.ElderlyID AS NVARCHAR(MAX)),
            SUSER_NAME()
        FROM deleted d
        INNER JOIN inserted i ON d.QualificationID = i.QualificationID
        WHERE ISNULL(d.ElderlyID, '') != ISNULL(i.ElderlyID, '')
        UNION ALL
        SELECT 
            'SubsidyQualification',
            'UPDATE',
            COALESCE(d.QualificationID, i.QualificationID),
            'SubsidyType',
            d.SubsidyType,
            i.SubsidyType,
            SUSER_NAME()
        FROM deleted d
        INNER JOIN inserted i ON d.QualificationID = i.QualificationID
        WHERE ISNULL(d.SubsidyType, '') != ISNULL(i.SubsidyType, '')
        UNION ALL
        SELECT 
            'SubsidyQualification',
            'UPDATE',
            COALESCE(d.QualificationID, i.QualificationID),
            'SubsidyLevel',
            d.SubsidyLevel,
            i.SubsidyLevel,
            SUSER_NAME()
        FROM deleted d
        INNER JOIN inserted i ON d.QualificationID = i.QualificationID
        WHERE ISNULL(d.SubsidyLevel, '') != ISNULL(i.SubsidyLevel, '')
        UNION ALL
        SELECT 
            'SubsidyQualification',
            'UPDATE',
            COALESCE(d.QualificationID, i.QualificationID),
            'ApplyTime',
            CAST(d.ApplyTime AS NVARCHAR(MAX)),
            CAST(i.ApplyTime AS NVARCHAR(MAX)),
            SUSER_NAME()
        FROM deleted d
        INNER JOIN inserted i ON d.QualificationID = i.QualificationID
        WHERE ISNULL(d.ApplyTime, '1900-01-01') != ISNULL(i.ApplyTime, '1900-01-01')
        UNION ALL
        SELECT 
            'SubsidyQualification',
            'UPDATE',
            COALESCE(d.QualificationID, i.QualificationID),
            'AuditTime',
            CAST(d.AuditTime AS NVARCHAR(MAX)),
            CAST(i.AuditTime AS NVARCHAR(MAX)),
            SUSER_NAME()
        FROM deleted d
        INNER JOIN inserted i ON d.QualificationID = i.QualificationID
        WHERE ISNULL(d.AuditTime, '1900-01-01') != ISNULL(i.AuditTime, '1900-01-01')
        UNION ALL
        SELECT 
            'SubsidyQualification',
            'UPDATE',
            COALESCE(d.QualificationID, i.QualificationID),
            'AuditStatus',
            d.AuditStatus,
            i.AuditStatus,
            SUSER_NAME()
        FROM deleted d
        INNER JOIN inserted i ON d.QualificationID = i.QualificationID
        WHERE ISNULL(d.AuditStatus, '') != ISNULL(i.AuditStatus, '')
        UNION ALL
        SELECT 
            'SubsidyQualification',
            'UPDATE',
            COALESCE(d.QualificationID, i.QualificationID),
            'EffectiveDate',
            CAST(d.EffectiveDate AS NVARCHAR(MAX)),
            CAST(i.EffectiveDate AS NVARCHAR(MAX)),
            SUSER_NAME()
        FROM deleted d
        INNER JOIN inserted i ON d.QualificationID = i.QualificationID
        WHERE ISNULL(d.EffectiveDate, '1900-01-01') != ISNULL(i.EffectiveDate, '1900-01-01')
        UNION ALL
        SELECT 
            'SubsidyQualification',
            'UPDATE',
            COALESCE(d.QualificationID, i.QualificationID),
            'ExpiryDate',
            CAST(d.ExpiryDate AS NVARCHAR(MAX)),
            CAST(i.ExpiryDate AS NVARCHAR(MAX)),
            SUSER_NAME()
        FROM deleted d
        INNER JOIN inserted i ON d.QualificationID = i.QualificationID
        WHERE ISNULL(d.ExpiryDate, '1900-01-01') != ISNULL(i.ExpiryDate, '1900-01-01')
        UNION ALL
        SELECT 
            'SubsidyQualification',
            'UPDATE',
            COALESCE(d.QualificationID, i.QualificationID),
            'QualificationStatus',
            d.QualificationStatus,
            i.QualificationStatus,
            SUSER_NAME()
        FROM deleted d
        INNER JOIN inserted i ON d.QualificationID = i.QualificationID
        WHERE ISNULL(d.QualificationStatus, '') != ISNULL(i.QualificationStatus, '');
    END

    -- ========== 处理 DELETE 操作 ==========
    IF EXISTS (SELECT * FROM deleted) AND NOT EXISTS (SELECT * FROM inserted)
    BEGIN
        INSERT INTO AuditLog (TableName, OperationType, RecordID, FieldName, OldValue, NewValue, Operator)
        SELECT 
            'SubsidyQualification',
            'DELETE',
            d.QualificationID,
            NULL,
            NULL,
            NULL,
            SUSER_NAME()
        FROM deleted d;
    END
END
GO

-- 触发器6：补贴规则表审计日志
CREATE OR ALTER TRIGGER trg_audit_subsidy_rule
ON SubsidyRule
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    -- ========== INSERT 操作 ==========
    IF EXISTS (SELECT * FROM inserted) AND NOT EXISTS (SELECT * FROM deleted)
    BEGIN
        INSERT INTO AuditLog (TableName, OperationType, RecordID, FieldName, OldValue, NewValue, Operator)
        SELECT 'SubsidyRule', 'INSERT', i.RuleID, 'RuleID', NULL, i.RuleID, SUSER_NAME() FROM inserted i
        UNION ALL
        SELECT 'SubsidyRule', 'INSERT', i.RuleID, 'SubsidyType', NULL, i.SubsidyType, SUSER_NAME() FROM inserted i
        UNION ALL
        SELECT 'SubsidyRule', 'INSERT', i.RuleID, 'SubsidyLevel', NULL, i.SubsidyLevel, SUSER_NAME() FROM inserted i
        UNION ALL
        SELECT 'SubsidyRule', 'INSERT', i.RuleID, 'SubsidyRatio', NULL, CAST(i.SubsidyRatio AS NVARCHAR(MAX)), SUSER_NAME() FROM inserted i
        UNION ALL
        SELECT 'SubsidyRule', 'INSERT', i.RuleID, 'SingleSubsidyLimit', NULL, CAST(i.SingleSubsidyLimit AS NVARCHAR(MAX)), SUSER_NAME() FROM inserted i
        UNION ALL
        SELECT 'SubsidyRule', 'INSERT', i.RuleID, 'MonthlySubsidyLimit', NULL, CAST(i.MonthlySubsidyLimit AS NVARCHAR(MAX)), SUSER_NAME() FROM inserted i
        UNION ALL
        SELECT 'SubsidyRule', 'INSERT', i.RuleID, 'ApplicableDescription', NULL, i.ApplicableDescription, SUSER_NAME() FROM inserted i
        UNION ALL
        SELECT 'SubsidyRule', 'INSERT', i.RuleID, 'RuleEffectiveDate', NULL, CAST(i.RuleEffectiveDate AS NVARCHAR(MAX)), SUSER_NAME() FROM inserted i
        UNION ALL
        SELECT 'SubsidyRule', 'INSERT', i.RuleID, 'RuleExpiryDate', NULL, CAST(i.RuleExpiryDate AS NVARCHAR(MAX)), SUSER_NAME() FROM inserted i
        UNION ALL
        SELECT 'SubsidyRule', 'INSERT', i.RuleID, 'RuleStatus', NULL, i.RuleStatus, SUSER_NAME() FROM inserted i;
    END

    -- ========== UPDATE 操作 ==========
    IF EXISTS (SELECT * FROM inserted)
    BEGIN
        INSERT INTO AuditLog (TableName, OperationType, RecordID, FieldName, OldValue, NewValue, Operator)
        SELECT 
            'SubsidyRule',
            'UPDATE',
            COALESCE(d.RuleID, i.RuleID),
            'SubsidyType',
            d.SubsidyType,
            i.SubsidyType,
            SUSER_NAME()
        FROM deleted d
        INNER JOIN inserted i ON d.RuleID = i.RuleID
        WHERE ISNULL(d.SubsidyType, '') != ISNULL(i.SubsidyType, '')

        UNION ALL

        SELECT 
            'SubsidyRule',
            'UPDATE',
            COALESCE(d.RuleID, i.RuleID),
            'SubsidyLevel',
            d.SubsidyLevel,
            i.SubsidyLevel,
            SUSER_NAME()
        FROM deleted d
        INNER JOIN inserted i ON d.RuleID = i.RuleID
        WHERE ISNULL(d.SubsidyLevel, '') != ISNULL(i.SubsidyLevel, '')

        UNION ALL

        SELECT 
            'SubsidyRule',
            'UPDATE',
            COALESCE(d.RuleID, i.RuleID),
            'SubsidyRatio',
            CAST(d.SubsidyRatio AS NVARCHAR(MAX)),
            CAST(i.SubsidyRatio AS NVARCHAR(MAX)),
            SUSER_NAME()
        FROM deleted d
        INNER JOIN inserted i ON d.RuleID = i.RuleID
        WHERE ISNULL(d.SubsidyRatio, 0) != ISNULL(i.SubsidyRatio, 0)

        UNION ALL

        SELECT 
            'SubsidyRule',
            'UPDATE',
            COALESCE(d.RuleID, i.RuleID),
            'SingleSubsidyLimit',
            CAST(d.SingleSubsidyLimit AS NVARCHAR(MAX)),
            CAST(i.SingleSubsidyLimit AS NVARCHAR(MAX)),
            SUSER_NAME()
        FROM deleted d
        INNER JOIN inserted i ON d.RuleID = i.RuleID
        WHERE ISNULL(d.SingleSubsidyLimit, 0) != ISNULL(i.SingleSubsidyLimit, 0)

        UNION ALL

        SELECT 
            'SubsidyRule',
            'UPDATE',
            COALESCE(d.RuleID, i.RuleID),
            'MonthlySubsidyLimit',
            CAST(d.MonthlySubsidyLimit AS NVARCHAR(MAX)),
            CAST(i.MonthlySubsidyLimit AS NVARCHAR(MAX)),
            SUSER_NAME()
        FROM deleted d
        INNER JOIN inserted i ON d.RuleID = i.RuleID
        WHERE ISNULL(d.MonthlySubsidyLimit, 0) != ISNULL(i.MonthlySubsidyLimit, 0)

        UNION ALL

        SELECT 
            'SubsidyRule',
            'UPDATE',
            COALESCE(d.RuleID, i.RuleID),
            'ApplicableDescription',
            d.ApplicableDescription,
            i.ApplicableDescription,
            SUSER_NAME()
        FROM deleted d
        INNER JOIN inserted i ON d.RuleID = i.RuleID
        WHERE ISNULL(d.ApplicableDescription, '') != ISNULL(i.ApplicableDescription, '')

        UNION ALL

        SELECT 
            'SubsidyRule',
            'UPDATE',
            COALESCE(d.RuleID, i.RuleID),
            'RuleEffectiveDate',
            CAST(d.RuleEffectiveDate AS NVARCHAR(MAX)),
            CAST(i.RuleEffectiveDate AS NVARCHAR(MAX)),
            SUSER_NAME()
        FROM deleted d
        INNER JOIN inserted i ON d.RuleID = i.RuleID
        WHERE ISNULL(d.RuleEffectiveDate, '1900-01-01') != ISNULL(i.RuleEffectiveDate, '1900-01-01')

        UNION ALL

        SELECT 
            'SubsidyRule',
            'UPDATE',
            COALESCE(d.RuleID, i.RuleID),
            'RuleExpiryDate',
            CAST(d.RuleExpiryDate AS NVARCHAR(MAX)),
            CAST(i.RuleExpiryDate AS NVARCHAR(MAX)),
            SUSER_NAME()
        FROM deleted d
        INNER JOIN inserted i ON d.RuleID = i.RuleID
        WHERE ISNULL(d.RuleExpiryDate, '1900-01-01') != ISNULL(i.RuleExpiryDate, '1900-01-01')

        UNION ALL

        SELECT 
            'SubsidyRule',
            'UPDATE',
            COALESCE(d.RuleID, i.RuleID),
            'RuleStatus',
            d.RuleStatus,
            i.RuleStatus,
            SUSER_NAME()
        FROM deleted d
        INNER JOIN inserted i ON d.RuleID = i.RuleID
        WHERE ISNULL(d.RuleStatus, '') != ISNULL(i.RuleStatus, '');
    END

    -- ========== DELETE 操作 ==========
    IF EXISTS (SELECT * FROM deleted) AND NOT EXISTS (SELECT * FROM inserted)
    BEGIN
        INSERT INTO AuditLog (TableName, OperationType, RecordID, FieldName, OldValue, NewValue, Operator)
        SELECT 
            'SubsidyRule',
            'DELETE',
            d.RuleID,
            NULL,
            NULL,
            NULL,
            SUSER_NAME()
        FROM deleted d;
    END
END
GO

-- 触发器7：规则变更时自动禁用旧规则
CREATE OR ALTER TRIGGER trg_after_insert_update_subsidy_rule_disable_old
ON SubsidyRule
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE SubsidyRule
    SET RuleStatus = '禁用'
    FROM SubsidyRule sr
    INNER JOIN inserted i 
        ON sr.SubsidyType = i.SubsidyType 
        AND sr.SubsidyLevel = i.SubsidyLevel
    WHERE i.RuleStatus = '启用'
      AND sr.RuleID != i.RuleID
      AND sr.RuleStatus = '启用';
END
GO
