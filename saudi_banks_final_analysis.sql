-- =====================================================================
-- saudi_banks : الطبقة التحليلية النهائية (MySQL 8.0+)
-- شغّل هذا الملف بعد saudi_banks_mysql.sql (مع تعديل segment إلى VARCHAR(60)).
-- المبالغ بملايين الريال السعودي.
-- =====================================================================
USE saudi_banks;

-- ---------------------------------------------------------------------
-- القسم 1: تصحيحات البيانات (كل تعديل موثّق في عمود notes)
-- الشرط AND ... IS NOT NULL / IS NULL يمنع تكرار الملاحظة عند إعادة التشغيل
-- ---------------------------------------------------------------------

-- تعبئة مخصصات الخسائر الائتمانية للأهلي (bank_id = 2) لسنة 2021 من نتائج أرقام السنوية
UPDATE annual_financials
SET provisions_ecl = 4022.73,
    notes = CONCAT_WS(' | ', notes,
        'provisions_ecl 2021 = Total Provisions per Argaam FY2022 results (SAR mn); net ECL charge alone is about 3.96bn per release text; includes merger-related charges')
WHERE bank_id = 2 AND fiscal_year = 2021 AND provisions_ecl IS NULL;

-- تعبئة مخصصات الخسائر الائتمانية للأهلي لسنة 2022 من نتائج أرقام السنوية
UPDATE annual_financials
SET provisions_ecl = 1685.48,
    notes = CONCAT_WS(' | ', notes,
        'provisions_ecl 2022 = Total Provisions per Argaam FY2022 results (SAR mn), equals net ECL charge 1.69bn per release text')
WHERE bank_id = 2 AND fiscal_year = 2022 AND provisions_ecl IS NULL;

-- تفريغ ROE المنشور لبنك BSF سنة 2021 لأنه لا ينسجم مع صافي الدخل وحقوق الملكية ولم يؤكده تقرير البنك
UPDATE annual_financials
SET roe_pct = NULL,
    notes = CONCAT_WS(' | ', notes,
        'roe_pct 2021 (19.94) removed: inconsistent with net_income/equity (about 9%) and unverified against BSF annual report; use v_bank_ratios.roe_avg_pct')
WHERE bank_id = 5 AND fiscal_year = 2021 AND roe_pct IS NOT NULL;

-- ---------------------------------------------------------------------
-- القسم 2: الـ VIEW (نسب الربحية والكفاءة والمخاطر لكل بنك لكل سنة)
-- نسب المتوسط تستعمل متوسط بداية السنة ونهايتها، فأول سنة لكل بنك NULL
-- cost_to_income و cost_of_risk تكونان NULL عندما تكون provisions_ecl فارغة
-- ملاحظة: SNB 2020 هو NCB قبل الاندماج مع سامبا (أبريل 2021)، فنمو 2021 غير قابل للمقارنة
-- ---------------------------------------------------------------------

-- إنشاء v_bank_ratios لحساب ROE وROA والتكلفة إلى الدخل وتكلفة المخاطر وحقوق الملكية إلى الأصول والنمو
CREATE OR REPLACE VIEW v_bank_ratios AS
WITH base AS (
    SELECT a.bank_id, b.name_en AS bank_name, a.fiscal_year,
           a.net_income, a.total_assets, a.total_equity,
           a.total_operating_income, a.total_operating_expenses, a.provisions_ecl,
           a.net_financing, a.customer_deposits,
           LAG(a.net_income)    OVER w AS prev_net_income,
           LAG(a.total_assets)  OVER w AS prev_assets,
           LAG(a.total_equity)  OVER w AS prev_equity,
           LAG(a.net_financing) OVER w AS prev_financing
    FROM annual_financials a
    JOIN bank b ON b.bank_id = a.bank_id
    WINDOW w AS (PARTITION BY a.bank_id ORDER BY a.fiscal_year)
)
SELECT bank_id, bank_name, fiscal_year, net_income, total_assets, total_equity,
       ROUND(100 * net_income / NULLIF((total_equity + prev_equity) / 2, 0), 2) AS roe_avg_pct,
       ROUND(100 * net_income / NULLIF((total_assets + prev_assets) / 2, 0), 2) AS roa_avg_pct,
       CASE WHEN provisions_ecl IS NULL THEN NULL
            ELSE ROUND(100 * (total_operating_expenses - provisions_ecl)
                       / NULLIF(total_operating_income, 0), 2) END               AS cost_to_income_pct,
       ROUND(100 * provisions_ecl / NULLIF((net_financing + prev_financing) / 2, 0), 2) AS cost_of_risk_pct,
       ROUND(100 * total_equity / NULLIF(total_assets, 0), 1)                    AS equity_to_assets_pct,
       ROUND(100 * net_financing / NULLIF(customer_deposits, 0), 1)              AS financing_to_deposits_pct,
       ROUND(100 * (net_income / NULLIF(prev_net_income, 0) - 1), 1)             AS net_income_growth_pct
FROM base;

-- ---------------------------------------------------------------------
-- القسم 3: استعلامات التحليل
-- ---------------------------------------------------------------------

-- ترتيب البنوك الخمسة حسب صافي الدخل في 2025 (الأهلي 25,013 ثم الراجحي 24,792)
SELECT RANK() OVER (ORDER BY net_income DESC) AS rnk, bank_name, net_income
FROM v_bank_ratios
WHERE fiscal_year = 2025;

-- نمو صافي الدخل سنة بسنة، عمود لكل بنك (pivot بـ CASE)
SELECT fiscal_year,
       MAX(CASE WHEN bank_name LIKE 'Al Rajhi%'      THEN net_income_growth_pct END) AS al_rajhi,
       MAX(CASE WHEN bank_name LIKE 'Saudi National%' THEN net_income_growth_pct END) AS snb,
       MAX(CASE WHEN bank_name LIKE 'Arab National%'  THEN net_income_growth_pct END) AS anb,
       MAX(CASE WHEN bank_name LIKE '%Albilad%'       THEN net_income_growth_pct END) AS albilad,
       MAX(CASE WHEN bank_name LIKE '%Fransi%'        THEN net_income_growth_pct END) AS bsf
FROM v_bank_ratios
GROUP BY fiscal_year
ORDER BY fiscal_year;

-- معدل النمو السنوي المركب لصافي الدخل 2021 إلى 2025 (يبدأ من 2021 بسبب اندماج SNB)
SELECT s.bank_name,
       s.net_income AS ni_2021,
       e.net_income AS ni_2025,
       ROUND(100 * (POWER(e.net_income / s.net_income, 1.0 / 4) - 1), 1) AS cagr_pct
FROM v_bank_ratios s
JOIN v_bank_ratios e ON e.bank_id = s.bank_id AND e.fiscal_year = 2025
WHERE s.fiscal_year = 2021
ORDER BY cagr_pct DESC;

-- أفضل بنك بحسب ROE في كل سنة (CTE مع ROW_NUMBER)
WITH ranked AS (
    SELECT fiscal_year, bank_name, roe_avg_pct,
           ROW_NUMBER() OVER (PARTITION BY fiscal_year ORDER BY roe_avg_pct DESC) AS rn
    FROM v_bank_ratios
    WHERE roe_avg_pct IS NOT NULL
)
SELECT fiscal_year, bank_name, roe_avg_pct
FROM ranked
WHERE rn = 1
ORDER BY fiscal_year;

-- حصة كل بنك من إجمالي أصول البنوك الخمسة في كل سنة
SELECT fiscal_year, bank_name, total_assets,
       ROUND(100 * total_assets / SUM(total_assets) OVER (PARTITION BY fiscal_year), 1) AS share_pct
FROM v_bank_ratios
ORDER BY fiscal_year, share_pct DESC;

-- الكفاءة مقابل الربحية في 2025
SELECT bank_name, cost_to_income_pct, cost_of_risk_pct, equity_to_assets_pct, roe_avg_pct,
       RANK() OVER (ORDER BY cost_to_income_pct ASC) AS efficiency_rank,
       RANK() OVER (ORDER BY roe_avg_pct DESC)       AS roe_rank
FROM v_bank_ratios
WHERE fiscal_year = 2025
ORDER BY roe_rank;

-- ---------------------------------------------------------------------
-- القسم 4: فحوص الجودة
-- ---------------------------------------------------------------------

-- مقارنة ROE المحسوب بالمنشور (فروق الراجحي سببها دخول صكوك الشق الأول في حقوق الملكية عندنا)
SELECT v.bank_name, v.fiscal_year,
       a.roe_pct AS roe_reported, v.roe_avg_pct AS roe_calculated,
       ROUND(v.roe_avg_pct - a.roe_pct, 2) AS difference
FROM v_bank_ratios v
JOIN annual_financials a ON a.bank_id = v.bank_id AND a.fiscal_year = v.fiscal_year
WHERE a.roe_pct IS NOT NULL AND v.roe_avg_pct IS NOT NULL
ORDER BY ABS(v.roe_avg_pct - a.roe_pct) DESC;

-- عدد الخلايا الفارغة في أهم أعمدة كل بنك (المتوقع: SNB فيه 3 فراغات في الدخل الشامل وفراغ في مخصصات 2023)
SELECT b.name_en, COUNT(*) AS years,
       SUM(a.total_comprehensive_income IS NULL) AS missing_tci,
       SUM(a.provisions_ecl IS NULL)             AS missing_ecl,
       SUM(a.investments IS NULL)                AS missing_investments,
       SUM(a.eps_sar IS NULL)                    AS missing_eps
FROM annual_financials a
JOIN bank b ON b.bank_id = a.bank_id
GROUP BY b.name_en;

-- عدد صفوف كل جدول (المتوقع: 5 / 58 / 30 / 24 / 16 / 21 / 22 / 117)
SELECT 'bank' AS table_name, COUNT(*) AS row_count FROM bank
UNION ALL SELECT 'source',                COUNT(*) FROM `source`
UNION ALL SELECT 'annual_financials',     COUNT(*) FROM annual_financials
UNION ALL SELECT 'interim_results',       COUNT(*) FROM interim_results
UNION ALL SELECT 'annual_ratios',         COUNT(*) FROM annual_ratios
UNION ALL SELECT 'annual_cashflow',       COUNT(*) FROM annual_cashflow
UNION ALL SELECT 'annual_balance_detail', COUNT(*) FROM annual_balance_detail
UNION ALL SELECT 'annual_segments',       COUNT(*) FROM annual_segments;
