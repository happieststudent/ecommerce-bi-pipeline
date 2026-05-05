-- =========================================================================
-- PIPELINE 1: AUTOMATED RFM SEGMENTATION ENGINE
-- Purpose: Automatically scores and categorizes every customer into Personas
-- =========================================================================
CREATE OR ALTER VIEW [goldie].[vw_rfm_segmentation] AS 

-- STEP 1: Aggregate all base metrics at the Customer level
WITH Customer_Base_Metrics AS (
    SELECT 
        c.customer_key,
        CONCAT(c.first_name, ' ', c.last_name) AS [Customer Name],
        c.country AS [Country], 
        DATEDIFF(YEAR, c.birthdate, GETDATE()) AS [Age],
        
        -- Volume & Lifespan
        COUNT(DISTINCT s.order_number) AS [Total Orders], -- (This is Frequency)
        SUM(s.quantity) AS [Total Items Bought],
        DATEDIFF(MONTH, MAX(s.order_date), GETDATE()) AS [Recency (Months)],
        DATEDIFF(MONTH, MIN(s.order_date), MAX(s.order_date)) AS [Lifespan (Months)],
        
        -- Financials
        SUM(s.sales_amount) AS [Total Revenue],
        SUM(s.sales_amount - (p.cost * s.quantity)) AS [Total Profit], -- (This is Monetary)
        
        -- Averages
        SUM(s.sales_amount) / NULLIF(COUNT(DISTINCT s.order_number), 0) AS [Avg Order Value],
        CASE 
            WHEN DATEDIFF(MONTH, MIN(s.order_date), MAX(s.order_date)) = 0 THEN SUM(s.sales_amount)
            ELSE SUM(s.sales_amount) / DATEDIFF(MONTH, MIN(s.order_date), MAX(s.order_date))
        END AS [Avg Monthly Spend]

    FROM [goldie].fact_sales s
    JOIN [goldie].dim_customers c ON s.customer_key = c.customer_key
    JOIN [goldie].dim_products p ON s.product_key = p.product_key
    GROUP BY 
        c.customer_key,
        CONCAT(c.first_name, ' ', c.last_name),
        c.country, 
        DATEDIFF(YEAR, c.birthdate, GETDATE())
),

-- STEP 2: Apply Demographics and calculate Statistical Percentiles (NTILE)
Scoring_And_Demographics AS (
    SELECT 
        *,
        -- Age Grouping 
        CASE 
            WHEN [Age] < 20 THEN 'Under 20'
            WHEN [Age] BETWEEN 20 AND 29 THEN '20-29'
            WHEN [Age] BETWEEN 30 AND 39 THEN '30-39'
            WHEN [Age] BETWEEN 40 AND 49 THEN '40-49'
            WHEN [Age] BETWEEN 50 AND 59 THEN '50-59'
            WHEN [Age] BETWEEN 60 AND 69 THEN '60-69'
            ELSE '70 and above'
        END AS [Age Group],

        -- RFM Scoring (1 to 5)
        NTILE(5) OVER (ORDER BY [Recency (Months)] DESC) AS R_Score,
        NTILE(5) OVER (ORDER BY [Total Orders] ASC) AS F_Score,
        NTILE(5) OVER (ORDER BY [Total Profit] ASC) AS M_Score

    FROM Customer_Base_Metrics
),

-- STEP 3: Assign Marketing Personas and Geographic Rankings
Final_Personas_And_Ranks AS (
    SELECT 
        *,
        -- RFM Personas 
        CONCAT(R_Score, F_Score, M_Score) AS [RFM Code],
        CASE 
            WHEN R_Score >= 4 AND F_Score >= 4 THEN 'Champions'
            WHEN R_Score >= 4 AND F_Score = 1  THEN 'New Customers'
            WHEN R_Score <= 2 AND F_Score >= 4 THEN 'At Risk (Can''t Lose)'
            WHEN R_Score <= 2 AND F_Score <= 2 THEN 'Hibernating / Lost'
            WHEN R_Score = 3  AND F_Score >= 3 THEN 'Potential Loyalists'
            ELSE 'Needs Attention'
        END AS [Customer Persona],

        -- Country Leaderboard Logic
        SUM([Total Profit]) OVER (PARTITION BY [Country]) AS [Country Grand Total Profit],
        ROUND(([Total Profit] * 100.0) / SUM([Total Profit]) OVER (PARTITION BY [Country]), 2) AS [Profit Contribution %],
        RANK() OVER (PARTITION BY [Country] ORDER BY [Total Profit] DESC) AS [Rank in Country]

    FROM Scoring_And_Demographics
)

SELECT * FROM Final_Personas_And_Ranks;
GO

-- =========================================================================
-- MASTER PIPELINE 2: MACRO TIME TRENDS (MoM & YoY)
-- Purpose: Tracks Month-over-Month and Year-over-Year profit growth using Window Functions
-- =========================================================================
CREATE OR ALTER VIEW [goldie].[vw_time_machine_trends] AS 

-- STEP 1: Establish the monthly profit baseline
WITH MonthlyTotals AS (
    SELECT 
        YEAR(s.order_date) AS [Sales Year],
        MONTH(s.order_date) AS [Sales Month],
        SUM(s.sales_amount - (p.cost * s.quantity)) AS [Monthly Profit]
    FROM [goldie].fact_sales s
    JOIN [goldie].dim_products p ON s.product_key = p.product_key
    GROUP BY 
        YEAR(s.order_date), 
        MONTH(s.order_date)
)

-- STEP 2: Apply LAG Window Functions for historical comparison
SELECT 
    [Sales Year],
    [Sales Month],
    [Monthly Profit],
    
    -- 1. MoM (Month-over-Month) Calculation: Looking back 1 row
    LAG([Monthly Profit], 1) OVER (ORDER BY [Sales Year], [Sales Month]) AS [Previous Month Profit],
    ROUND((([Monthly Profit] - LAG([Monthly Profit], 1) OVER (ORDER BY [Sales Year], [Sales Month])) 
    / NULLIF(LAG([Monthly Profit], 1) OVER (ORDER BY [Sales Year], [Sales Month]), 0)) * 100.0, 2) AS [MoM Growth %],

    -- 2. YoY (Year-over-Year) Calculation: Looking back 12 rows
    LAG([Monthly Profit], 12) OVER (ORDER BY [Sales Year], [Sales Month]) AS [Same Month Last Year Profit],
    ROUND((([Monthly Profit] - LAG([Monthly Profit], 12) OVER (ORDER BY [Sales Year], [Sales Month])) 
    / NULLIF(LAG([Monthly Profit], 12) OVER (ORDER BY [Sales Year], [Sales Month]), 0)) * 100.0, 2) AS [YoY Growth %]
    
FROM MonthlyTotals;
GO

-- =========================================================================
-- MASTER PIPELINE 3: PRODUCT 360 & EFFICIENCY MATRIX
-- Purpose: Consolidates volume, financial performance, ROI, and margin analysis
-- =========================================================================
CREATE OR ALTER VIEW [goldie].[vw_product_roi] AS 

-- STEP 1: Aggregate raw volume and financial totals
WITH Product_Base_Metrics AS (
    SELECT 
        p.product_key,
        p.category AS [Category],
        p.product_name AS [Product Name],
        p.maintenance AS [Requires Maintenance],
        
        COUNT(DISTINCT s.order_number) AS [Times Ordered],
        SUM(s.quantity) AS [Total Units Sold],
        
        SUM(s.sales_amount) AS [Total Revenue],
        SUM(p.cost * s.quantity) AS [Total Cost],
        
        AVG(s.price) AS [Average Selling Price],
        AVG(p.cost) AS [Average Unit Cost]
        
    FROM [goldie].fact_sales s
    JOIN [goldie].dim_products p ON s.product_key = p.product_key
    GROUP BY 
        p.product_key,
        p.category, 
        p.product_name,
        p.maintenance
)

-- STEP 2: Calculate Advanced Margins, ROI, and Status Flags
SELECT 
    [Category],
    [Product Name],
    [Requires Maintenance],
    
    [Times Ordered],
    [Total Units Sold],
    [Total Revenue],
    [Total Cost],
    ([Total Revenue] - [Total Cost]) AS [Total Profit],
    
    [Average Selling Price],
    [Average Unit Cost],

    -- Efficiency Metrics (Multiplying by 1.0 to force exact decimals)
    ROUND((([Total Revenue] - [Total Cost]) * 1.0 / NULLIF([Total Revenue], 0)) * 100, 2) AS [Profit Margin %],
    ROUND((([Total Revenue] - [Total Cost]) * 1.0 / NULLIF([Total Cost], 0)) * 100, 2) AS [ROI %],

    -- Portfolio Status Flagging
    CASE 
        WHEN ([Total Revenue] - [Total Cost]) < 0 THEN 'LOSS LEADER'
        WHEN ((([Total Revenue] - [Total Cost]) * 1.0) / NULLIF([Total Cost], 0)) >= 1.0 THEN 'High Efficiency'
        ELSE 'Standard'
    END AS [Product Status]

FROM Product_Base_Metrics;
GO
-- =========================================================================
-- MASTER PIPELINE 4: THE LOGISTICS BOTTLENECK
-- Purpose: Identify which countries suffer from the most late shipments.
-- =========================================================================
CREATE OR ALTER VIEW [goldie].[vw_Logistic_Bottleneck] AS
SELECT 
    c.country AS [Country],
   
    -- 1. The Speed Metrics
    AVG(DATEDIFF(DAY, s.order_date, s.shipping_date)) AS [Avg Days to Ship],
    SUM(CASE 
            WHEN DATEDIFF(DAY, s.order_date, s.shipping_date) > 7 THEN 1 
            ELSE 0 
        END) AS [Total Late Shipments],
        
    -- 2. The Volume Metrics
    COUNT(DISTINCT s.order_number) AS [Total Unique Orders],
    
    -- THE NEW ADDITION: Count the individual product rows!
    COUNT(s.product_key) AS [Total Products Shipped],
    
    -- BONUS MATH: How big is the average order in this country?
    -- (Multiplying by 1.0 forces SQL to use decimals instead of rounding to whole numbers)
    COUNT(s.product_key) * 1.0 / NULLIF(COUNT(DISTINCT s.order_number), 0) AS [Avg Products per Order]
    
FROM [goldie].fact_sales s
JOIN [goldie].dim_customers c 
    ON s.customer_key = c.customer_key
WHERE c.country IS NOT NULL 
GROUP BY 
    c.country;
GO

SELECT * FROM [goldie].[vw_Logistic_Bottleneck]
ORDER BY [Country]
GO

    -- =========================================================================
-- INSIGHT 1: THE "FAMILY" EFFECT
-- Purpose: Determine if Single or Married customers have a larger basket size.
-- =========================================================================
CREATE OR ALTER VIEW [goldie].[vw_Family_Effect] AS

SELECT 
    c.marital_status AS [Marital Status],
    
    -- We use AVG() on the quantity column to find the average basket size.
    -- We wrap it in CAST(... AS FLOAT) so the database returns exact decimals (like 2.5 items) 
    -- instead of rounding down to whole numbers.
    AVG(CAST(s.quantity AS FLOAT)) AS [Average Basket Size],
    
    -- Let's also grab the total revenue to see the big picture.
    SUM(s.sales_amount) AS [Total Revenue Generated],
    
    COUNT(DISTINCT c.customer_id) AS [Total Unique Customers]

FROM [goldie].fact_sales s
JOIN [goldie].dim_customers c 
    ON s.customer_key = c.customer_key
WHERE c.marital_status IS NOT NULL 
GROUP BY 
    c.marital_status
GO

