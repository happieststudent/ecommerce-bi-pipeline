# 📊 End-to-End BI Pipeline: RFM Segmentation & Supply Chain Analytics

**Live Dashboard:** [Link to your Tableau Public Dashboard here]

## The Objective
To architect a unified Business Intelligence ecosystem by extracting, transforming, and analyzing raw, fragmented global e-commerce data to expose hidden logistical bottlenecks and true product profitability.

## The Architecture
Instead of creating redundant, single-use queries, I engineered a highly optimized **4-Pillar BI Architecture**. By utilizing CTEs to consolidate metrics into centralized "Wide Tables", I reduced database query load and created a scalable backend designed specifically for seamless Tableau integration.

1. **`vw_customer_360`**: Automated RFM (Recency, Frequency, Monetary) modeling using SQL Window Functions to dynamically categorize users into actionable marketing personas.
2. **`vw_product_360`**: Modeled true Product ROI versus Profit Margin to expose high-volume "loss leaders" versus high-efficiency inventory.
3. **`vw_time_machine_trends`**: MoM and YoY growth tracking using `LAG()` window functions.
4. **`vw_logistics_bottleneck`**: Identified and isolated $3.2M in "Revenue at Risk" by cross-referencing logistical shipping delays with high-value customer segments.

## Technical Stack
* **Database:** SQL Server (SSMS)
* **SQL Skills:** Common Table Expressions (CTEs), Window Functions, Aggregations, Advanced JOINs, Data Type Casting.
* **Data Visualization:** Tableau Desktop (Cross-database filters, UI/UX optimization, Parameter logic).

## 📸 Dashboard Preview
![Dashboard_Preview]
