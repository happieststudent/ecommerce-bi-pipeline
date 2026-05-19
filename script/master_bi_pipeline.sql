-- ==========================================================================================
-- MASTER SCRIPT: END-TO-END E-COMMERCE BI PIPELINE
-- Database Schema: [goldie]
-- Purpose: Generates 4 highly optimized 'Wide Tables' for seamless Tableau integration
-- ==========================================================================================

-- =========================================================================
-- PILLAR 1: CUSTOMER 360 & AUTOMATED RFM SEGMENTATION
-- Purpose: Consolidates Demographics, KPIs, and Persona tiering
-- =========================================================================
CREATE OR ALTER VIEW [goldie].[vw_customer_360] AS 

WITH Customer_Base_Metrics AS (
    SELECT 
        c.customer_key,
        CONCAT(c.first_name, ' ', c.last_name) AS [Customer Name],
        c.country AS [Country], 

        -- Highly precise age calculation accounting for leap years and birth month
        DATEDIFF(YEAR, c.birthdate, GETDATE()) 
        - CASE 
            WHEN DATEADD(YEAR, DATEDIFF(YEAR, c.birthdate, GETDATE()), c.birthdate) > GETDATE() 
            THEN 1 ELSE 0 
          END AS [Age],
        
        -- Volume & Lifespan
        COUNT(DISTINCT s.order_number) AS [Total Orders],
        SUM(s.quantity) AS [Total Items Bought],
        DATEDIFF(MONTH, MAX(s.order_date), GETDATE()) AS [Recency (Months)],
        DATEDIFF(MONTH, MIN(s.order_date), MAX(s.order_date)) AS [Lifespan (Months)],
        
        -- Financials
        SUM(s.sales_amount) AS [Total Revenue],
        SUM(s.sales_amount - (p.cost * s.quantity)) AS [Total Profit],
        
        -- Averages
        SUM(s.sales_amount) * 1.0 / NULLIF(COUNT(DISTINCT s.order_number), 0) AS [Avg Order Value],
        CASE 
            WHEN DATEDIFF(MONTH, MIN(s.order_date), MAX(s.order_date)) = 0 THEN SUM(s.sales_amount)
            ELSE SUM(s.sales_amount) * 1.0 / DATEDIFF(MONTH, MIN(s.order_date), MAX(s.order_date))
        END AS [Avg Monthly Spend]

    FROM [goldie].fact_sales s
    JOIN [goldie].dim_customers c ON s.customer_key = c.customer_key
    JOIN [goldie].dim_products p ON s.product_key = p.product_key
    GROUP BY 
        c.customer_key,
        CONCAT(c.first_name, ' ', c.last_name),
        c.country, 
        c.birthdate
),

Scoring_And_Demographics AS (
    SELECT 
        *,
        -- Standardized Age Grouping 
        CASE 
            WHEN [Age] < 20 THEN 'Under 20'
            WHEN [Age] BETWEEN 20 AND 29 THEN '20-29'
            WHEN [Age] BETWEEN 30 AND 39 THEN '30-39'
            WHEN [Age] BETWEEN 40 AND 49 THEN '40-49'
            WHEN [Age] BETWEEN 50 AND 59 THEN '50-59'
            WHEN [Age] BETWEEN 60 AND 69 THEN '60-69'
            ELSE '70 and above'
        END AS [Age Group],

        -- 5-Star RFM Scoring (5 is Best, 1 is Worst)
        NTILE(5) OVER (ORDER BY [Recency (Months)] DESC) AS R_Score,
        NTILE(5) OVER (ORDER BY [Total Orders] ASC) AS F_Score,
        NTILE(5) OVER (ORDER BY [Total Profit] ASC) AS M_Score

    FROM Customer_Base_Metrics
),

Final_Personas_And_Ranks AS (
    SELECT
        *,
        CONCAT(R_Score, F_Score, M_Score) AS [RFM Code],
        
        -- Executive-ready Marketing Personas
        CASE 
            WHEN R_Score >= 4 AND F_Score >= 4 AND M_Score >= 4 THEN 'Champions'
            WHEN R_Score >= 4 AND F_Score <= 2 THEN 'New Customers'
            WHEN R_Score <= 2 AND F_Score >= 4 THEN 'At Risk (Can''t Lose)'
            WHEN R_Score <= 2 AND M_Score >= 4 THEN 'Big Spenders at Risk'
            WHEN R_Score = 3  AND F_Score >= 3 THEN 'Potential Loyalists'
            ELSE 'Needs Attention'
        END AS [Customer Persona],

        -- Country Leaderboard Logic
        SUM([Total Profit]) OVER (PARTITION BY [Country]) AS [Country Grand Total Profit],
        ROUND(([Total Profit] * 100.0) / NULLIF(SUM([Total Profit]) OVER (PARTITION BY [Country]), 0), 2) AS [Profit Contribution %]
    FROM Scoring_And_Demographics
)

SELECT * FROM Final_Personas_And_Ranks;
GO

-- =========================================================================
-- PILLAR 2 (FINAL): PRODUCT 360 & PARETO ANALYSIS
-- Purpose: Consolidates unit economics, ROI, and a robust 80/20 Pareto curve
-- =========================================================================
-- Create a new view or modify the existing one in the 'goldie' schema
CREATE OR ALTER VIEW [goldie].[vw_product_360] AS 

-- STEP 1: Base Metrics (Unit Economics)
-- Start the first Common Table Expression (CTE) to calculate foundational aggregates
WITH Product_Base_Metrics AS (
    SELECT 
        -- Select the product key to use as our primary grouping column
        p.product_key,
        -- Select the product category and format the column name
        p.category AS [Category],
        -- Select the product name and format the column name
        p.product_name AS [Product Name],
        -- Select the maintenance flag to track if the product requires upkeep
        p.maintenance AS [Requires Maintenance],
        
        -- Count unique order numbers to find out how many separate orders contained this product
        COUNT(DISTINCT s.order_number) AS [Order Count],
        -- Sum the quantity to get the total individual units sold
        SUM(s.quantity) AS [Total Units Sold],
        
        -- Sum the sales amount to calculate total gross revenue generated
        SUM(s.sales_amount) AS [Total Revenue],
        -- Multiply unit cost by quantity sold, then sum it up to get total Cost of Goods Sold (COGS)
        SUM(p.cost * s.quantity) AS [Total Cost],
        
        -- Weighted Unit Economics: Divide total revenue by total units (NULLIF prevents divide-by-zero errors)
        SUM(s.sales_amount) * 1.0 / NULLIF(SUM(s.quantity), 0) AS [Average Selling Price],
        -- Divide total cost by total units to find the true average cost per unit
        SUM(p.cost * s.quantity) * 1.0 / NULLIF(SUM(s.quantity), 0) AS [Average Unit Cost]

    -- Define the primary fact table containing our sales transaction data
    FROM [goldie].fact_sales s
    -- Join the dimension table to get product details based on the product key
    JOIN [goldie].dim_products p ON s.product_key = p.product_key
    -- Group by all the non-aggregated product attributes to calculate totals per product
    GROUP BY 
        p.product_key,
        p.category, 
        p.product_name,
        p.maintenance
),

-- STEP 2: Advanced Metrics + Deterministic Running Totals
-- Start the second CTE to build upon the base metrics from Step 1
Advanced_Metrics AS (
    SELECT 
        -- Select all columns generated in the Product_Base_Metrics CTE
        *,        
        -- Subtract Total Cost from Total Revenue to calculate the pure profit per product
        ([Total Revenue] - [Total Cost]) AS [Total Profit],

        -- Use a Window Function over the entire dataset (OVER ()) to sum all profits into a single grand total
        SUM([Total Revenue] - [Total Cost]) OVER () AS [Company Grand Profit],
      
        -- Calculate a running total of profit, ordered from highest profit to lowest
        SUM([Total Revenue] - [Total Cost]) OVER (
            -- Order the window by profit descending so our most profitable items appear first
            ORDER BY ([Total Revenue] - [Total Cost]) DESC,
            -- Add product_key to the order by clause to ensure deterministic (consistent) sorting for ties
            product_key
            -- Specify the window frame from the first row up to the current row
            ROWS UNBOUNDED PRECEDING
        ) AS [Running Total Profit]

    -- Pull this data from our first CTE
    FROM Product_Base_Metrics
)

-- STEP 3: Final Output with Pareto Logic
-- This is the final SELECT statement that will be materialized when the view is queried
SELECT 
    -- Output the category
    [Category],
    -- Output the product name
    [Product Name],
    -- Output the maintenance flag
    [Requires Maintenance],
    
    -- Output the total number of orders
    [Order Count],
    -- Output the total units sold
    [Total Units Sold],
    -- Output the gross revenue
    [Total Revenue],
    -- Output the total cost
    [Total Cost],    
    -- Output the calculated profit
    [Total Profit],
    
    -- Output the average selling price
    [Average Selling Price],
    -- Output the average cost
    [Average Unit Cost],

    -- Efficiency Metrics
    -- Calculate profit margin percentage, rounding to 2 decimal places
    ROUND([Total Profit] * 100.0 / NULLIF([Total Revenue], 0), 2) AS [Profit Margin %],
    -- Calculate Return on Investment (ROI) percentage, rounding to 2 decimal places
    ROUND([Total Profit] * 100.0 / NULLIF([Total Cost], 0), 2) AS [ROI %],

    -- Contribution & Pareto Cumulative %
    -- Calculate what percentage this single product contributes to the entire company's profit
    ROUND([Total Profit] * 100.0 / NULLIF([Company Grand Profit], 0), 4) AS [Profit Contribution %],
    -- Calculate the cumulative profit percentage to track our progress toward 100% (used for Pareto)
    ROUND([Running Total Profit] * 100.0 / NULLIF([Company Grand Profit], 0), 2) AS [Cumulative Profit %],

    -- Product Status (Evaluates basic ROI health)
    CASE 
        -- If profit is negative, flag it as a Loss Leader
        WHEN [Total Profit] < 0 THEN 'LOSS LEADER'
        -- If ROI is 80% or higher, it is Excellent (Fixed duplicate condition here)
        WHEN ([Total Profit] * 1.0 / NULLIF([Total Cost], 0)) >= 0.8 THEN 'Excellent Efficiency'
        -- If ROI is between 50% and 79%, it is High
        WHEN ([Total Profit] * 1.0 / NULLIF([Total Cost], 0)) >= 0.5 THEN 'High Efficiency'
        -- If ROI is between 20% and 49%, it is Moderate
        WHEN ([Total Profit] * 1.0 / NULLIF([Total Cost], 0)) >= 0.2 THEN 'Moderate Efficiency'
        -- Everything below 20% is Low Efficiency
        ELSE 'Low Efficiency'
    END AS [Product Status],

    -- Pareto Tiering (Evaluates importance to the company's bottom line)
    CASE 
        -- Keep negative profit items separate from the tiering logic
        WHEN [Total Profit] < 0 THEN 'Loss Leader'
        -- Products making up the first 80% of total company profit are Top Tier (The 80/20 rule)
        WHEN [Running Total Profit] * 1.0 / NULLIF([Company Grand Profit], 0) <= 0.80 THEN 'Top Tier'
        -- Products making up the next 15% of profit are Mid Tier
        WHEN [Running Total Profit] * 1.0 / NULLIF([Company Grand Profit], 0) <= 0.95 THEN 'Mid Tier'
        -- The remaining products (the last 5% of profit) are Long Tail
        ELSE 'Long Tail'
    END AS [Pareto Tier]

-- Pull all final calculations from the second CTE
FROM Advanced_Metrics;
-- Signal the end of the batch to SQL Server
GO
-- =========================================================================
-- PILLAR 3: MACRO TIME TRENDS (MoM & YoY)
-- Purpose: Tracks historical profit growth using advanced Window Functions
-- =========================================================================
CREATE OR ALTER VIEW [goldie].[vw_time_machine_trends] AS 

WITH MonthlyTotals AS (
    SELECT 
        -- Creates a continuous Date dimension for seamless BI mapping
        DATEFROMPARTS(YEAR(s.order_date), MONTH(s.order_date), 1) AS [Month Start],
        YEAR(s.order_date) AS [Sales Year],
        MONTH(s.order_date) AS [Sales Month],
        SUM(s.sales_amount - (p.cost * s.quantity)) AS [Monthly Profit]
    FROM [goldie].fact_sales s
    JOIN [goldie].dim_products p ON s.product_key = p.product_key
WHERE s.order_date IS NOT NULL
    GROUP BY 
        YEAR(s.order_date), 
        MONTH(s.order_date)
),

Lagged AS (
    SELECT 
        *,
        -- Caching previous metrics to abide by DRY (Don't Repeat Yourself) principles
        LAG([Monthly Profit], 1) OVER (ORDER BY [Month Start]) AS Prev_Month_Profit,
        LAG([Monthly Profit], 12) OVER (ORDER BY [Month Start]) AS Prev_Year_Profit
    FROM MonthlyTotals
)

SELECT 
    [Month Start],
    [Sales Year],
    [Sales Month],
    [Monthly Profit],

    Prev_Month_Profit AS [Previous Month Profit],
    ROUND((([Monthly Profit] - Prev_Month_Profit) * 1.0
        / NULLIF(Prev_Month_Profit, 0)) * 100.0, 2) AS [MoM Growth %],

    Prev_Year_Profit AS [Same Month Last Year Profit],
    ROUND((([Monthly Profit] - Prev_Year_Profit)  * 1.0
        / NULLIF(Prev_Year_Profit, 0)) * 100.0, 2) AS [YoY Growth %]

FROM Lagged
GO

-- =========================================================================
-- PILLAR 4 (UPGRADED): THE LOGISTICS BOTTLENECK
-- Purpose: Isolates geographical points of failure in global supply chains
-- =========================================================================
CREATE OR ALTER VIEW [goldie].[vw_logistics_bottleneck] AS

-- STEP 1: Pre-aggregate to the Order Grain to prevent Line-Item Skew
WITH Order_Level_Logistics AS (
    SELECT 
        s.order_number,
        c.country AS [Country],
        
        -- Since shipping dates are usually the same per order, MAX() safely extracts it
        MAX(DATEDIFF(DAY, s.order_date, s.shipping_date)) AS [Days to Ship],
        
        -- Flag if this specific order was late
        MAX(CASE WHEN DATEDIFF(DAY, s.order_date, s.shipping_date) > 7 THEN 1 ELSE 0 END) AS [Is Late Order],
        
        SUM(s.quantity) AS [Total Units in Order]
        
    FROM [goldie].fact_sales s
    JOIN [goldie].dim_customers c 
        ON s.customer_key = c.customer_key
    WHERE c.country IS NOT NULL 
    GROUP BY 
        s.order_number, 
        c.country
)

-- STEP 2: Roll up to the Country Grain for Dashboarding
SELECT 
    [Country],
   
    -- 1. Speed Metrics (Math is now perfectly balanced per order)
    AVG(CAST([Days to Ship] AS FLOAT)) AS [Avg Days to Ship],
    SUM([Is Late Order]) AS [Total Late Orders],
    SUM([Is Late Order]) * 1.0 / NULLIF(COUNT([order_number]), 0) AS [Late Shipment Rate],
        
    -- 2. Volume Metrics
    COUNT([order_number]) AS [Total Orders],
    SUM([Total Units in Order]) AS [Total Units Sold],
    
    -- 3. Order Behavior
    SUM([Total Units in Order]) * 1.0 / NULLIF(COUNT([order_number]), 0) AS [Avg Units per Order]
    
FROM Order_Level_Logistics
GROUP BY 
    [Country];
GO
