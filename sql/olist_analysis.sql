-- ============================================================
-- OLIST E-COMMERCE ANALYSIS — Complete SQL Script
-- ============================================================
-- Author: [Your Name]
-- Dataset: https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce
-- Tool: DuckDB (also works in PostgreSQL with minor tweaks)
--
-- How to run:
--   1. pip install duckdb
--   2. Put all 9 CSVs in ./data/raw/
--   3. Open Python/Jupyter and run:
--        import duckdb
--        con = duckdb.connect('olist.db')
--        con.execute(open('sql/olist_analysis.sql').read())
-- ============================================================


-- ============================================================
-- SETUP: Load CSVs as tables
-- ============================================================

CREATE OR REPLACE TABLE orders AS 
    SELECT * FROM read_csv_auto('data/raw/olist_orders_dataset.csv');

CREATE OR REPLACE TABLE customers AS 
    SELECT * FROM read_csv_auto('data/raw/olist_customers_dataset.csv');

CREATE OR REPLACE TABLE order_items AS 
    SELECT * FROM read_csv_auto('data/raw/olist_order_items_dataset.csv');

CREATE OR REPLACE TABLE products AS 
    SELECT * FROM read_csv_auto('data/raw/olist_products_dataset.csv');

CREATE OR REPLACE TABLE sellers AS 
    SELECT * FROM read_csv_auto('data/raw/olist_sellers_dataset.csv');

CREATE OR REPLACE TABLE order_payments AS 
    SELECT * FROM read_csv_auto('data/raw/olist_order_payments_dataset.csv');

CREATE OR REPLACE TABLE order_reviews AS 
    SELECT * FROM read_csv_auto('data/raw/olist_order_reviews_dataset.csv');

CREATE OR REPLACE TABLE category_translation AS 
    SELECT * FROM read_csv_auto('data/raw/product_category_name_translation.csv');


-- ============================================================
-- Q1: Monthly revenue trend
-- ============================================================

SELECT 
    DATE_TRUNC('month', o.order_purchase_timestamp) AS month,
    COUNT(DISTINCT o.order_id) AS total_orders,
    ROUND(SUM(oi.price), 2) AS product_revenue,
    ROUND(SUM(oi.freight_value), 2) AS freight_revenue,
    ROUND(SUM(oi.price + oi.freight_value), 2) AS total_revenue,
    ROUND(AVG(oi.price + oi.freight_value), 2) AS avg_ticket
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
WHERE o.order_status = 'delivered'
GROUP BY 1
ORDER BY 1;


-- ============================================================
-- Q2: Average ticket and revenue by state
-- ============================================================

SELECT 
    c.customer_state,
    COUNT(DISTINCT o.order_id) AS total_orders,
    ROUND(SUM(oi.price + oi.freight_value), 2) AS total_revenue,
    ROUND(AVG(oi.price + oi.freight_value), 2) AS avg_ticket,
    ROUND(100.0 * SUM(oi.price + oi.freight_value) 
          / SUM(SUM(oi.price + oi.freight_value)) OVER (), 2) AS pct_of_revenue
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
JOIN order_items oi ON o.order_id = oi.order_id
WHERE o.order_status = 'delivered'
GROUP BY 1
ORDER BY total_revenue DESC;


-- ============================================================
-- Q3: Month-over-month growth rate (window function)
-- ============================================================

WITH monthly_revenue AS (
    SELECT 
        DATE_TRUNC('month', o.order_purchase_timestamp) AS month,
        SUM(oi.price + oi.freight_value) AS revenue
    FROM orders o
    JOIN order_items oi ON o.order_id = oi.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY 1
)
SELECT 
    month,
    ROUND(revenue, 2) AS revenue,
    ROUND(LAG(revenue) OVER (ORDER BY month), 2) AS previous_month,
    ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month)) 
          / LAG(revenue) OVER (ORDER BY month), 2) AS mom_growth_pct
FROM monthly_revenue
ORDER BY month;


-- ============================================================
-- Q4: One-time vs recurring customers
-- ============================================================

WITH customer_orders AS (
    SELECT 
        c.customer_unique_id,
        COUNT(DISTINCT o.order_id) AS total_orders
    FROM orders o
    JOIN customers c ON o.customer_id = c.customer_id
    WHERE o.order_status = 'delivered'
    GROUP BY 1
)
SELECT 
    CASE 
        WHEN total_orders = 1 THEN '1 - One-time buyer'
        WHEN total_orders BETWEEN 2 AND 3 THEN '2 - Low recurring'
        ELSE '3 - High recurring (4+)'
    END AS customer_segment,
    COUNT(*) AS customer_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_base
FROM customer_orders
GROUP BY 1
ORDER BY 1;


-- ============================================================
-- Q5: Top 10 cities by revenue
-- ============================================================

SELECT 
    c.customer_city,
    c.customer_state,
    COUNT(DISTINCT o.order_id) AS total_orders,
    ROUND(SUM(oi.price + oi.freight_value), 2) AS total_revenue,
    ROUND(AVG(oi.price + oi.freight_value), 2) AS avg_ticket
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
JOIN order_items oi ON o.order_id = oi.order_id
WHERE o.order_status = 'delivered'
GROUP BY 1, 2
ORDER BY total_revenue DESC
LIMIT 10;


-- ============================================================
-- Q6: Time between first and second purchase
-- ============================================================

WITH customer_purchases AS (
    SELECT 
        c.customer_unique_id,
        o.order_purchase_timestamp,
        ROW_NUMBER() OVER (
            PARTITION BY c.customer_unique_id 
            ORDER BY o.order_purchase_timestamp
        ) AS purchase_number
    FROM orders o
    JOIN customers c ON o.customer_id = c.customer_id
    WHERE o.order_status = 'delivered'
),
first_and_second AS (
    SELECT 
        customer_unique_id,
        MAX(CASE WHEN purchase_number = 1 THEN order_purchase_timestamp END) AS first_purchase,
        MAX(CASE WHEN purchase_number = 2 THEN order_purchase_timestamp END) AS second_purchase
    FROM customer_purchases
    WHERE purchase_number <= 2
    GROUP BY 1
    HAVING COUNT(*) = 2
)
SELECT 
    COUNT(*) AS customers_with_repeat,
    ROUND(AVG(DATE_DIFF('day', first_purchase, second_purchase)), 1) AS avg_days_to_repeat,
    ROUND(MEDIAN(DATE_DIFF('day', first_purchase, second_purchase)), 1) AS median_days_to_repeat
FROM first_and_second;


-- ============================================================
-- Q7: Top 10 categories — revenue vs volume
-- ============================================================

SELECT 
    COALESCE(ct.product_category_name_english, p.product_category_name) AS category,
    COUNT(DISTINCT oi.order_id) AS total_orders,
    COUNT(*) AS total_items_sold,
    ROUND(SUM(oi.price), 2) AS total_revenue,
    ROUND(AVG(oi.price), 2) AS avg_price,
    RANK() OVER (ORDER BY SUM(oi.price) DESC) AS rank_by_revenue,
    RANK() OVER (ORDER BY COUNT(*) DESC) AS rank_by_volume
FROM order_items oi
JOIN products p ON oi.product_id = p.product_id
LEFT JOIN category_translation ct 
    ON p.product_category_name = ct.product_category_name
JOIN orders o ON oi.order_id = o.order_id
WHERE o.order_status = 'delivered' 
    AND p.product_category_name IS NOT NULL
GROUP BY 1
ORDER BY total_revenue DESC
LIMIT 10;


-- ============================================================
-- Q8: Highest ticket categories (min 100 orders)
-- ============================================================

SELECT 
    COALESCE(ct.product_category_name_english, p.product_category_name) AS category,
    COUNT(*) AS items_sold,
    ROUND(AVG(oi.price), 2) AS avg_price,
    ROUND(MEDIAN(oi.price), 2) AS median_price,
    ROUND(SUM(oi.price), 2) AS total_revenue
FROM order_items oi
JOIN products p ON oi.product_id = p.product_id
LEFT JOIN category_translation ct 
    ON p.product_category_name = ct.product_category_name
JOIN orders o ON oi.order_id = o.order_id
WHERE o.order_status = 'delivered'
GROUP BY 1
HAVING COUNT(*) >= 100
ORDER BY avg_price DESC
LIMIT 15;


-- ============================================================
-- Q9: Product weight vs freight cost
-- ============================================================

SELECT 
    CASE 
        WHEN p.product_weight_g < 500 THEN '1 - Under 500g'
        WHEN p.product_weight_g < 2000 THEN '2 - 500g to 2kg'
        WHEN p.product_weight_g < 10000 THEN '3 - 2kg to 10kg'
        WHEN p.product_weight_g < 30000 THEN '4 - 10kg to 30kg'
        ELSE '5 - Over 30kg'
    END AS weight_range,
    COUNT(*) AS items,
    ROUND(AVG(oi.price), 2) AS avg_price,
    ROUND(AVG(oi.freight_value), 2) AS avg_freight,
    ROUND(100.0 * AVG(oi.freight_value) / AVG(oi.price), 2) AS freight_as_pct_of_price
FROM order_items oi
JOIN products p ON oi.product_id = p.product_id
WHERE p.product_weight_g IS NOT NULL
GROUP BY 1
ORDER BY 1;


-- ============================================================
-- Q10: Average delivery time by state
-- ============================================================

SELECT 
    c.customer_state,
    COUNT(*) AS delivered_orders,
    ROUND(AVG(DATE_DIFF('day', 
        o.order_purchase_timestamp, 
        o.order_delivered_customer_date)), 1) AS avg_delivery_days,
    ROUND(100.0 * SUM(CASE 
        WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date 
        THEN 1 ELSE 0 END) / COUNT(*), 2) AS late_delivery_pct
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_status = 'delivered'
    AND o.order_delivered_customer_date IS NOT NULL
GROUP BY 1
ORDER BY avg_delivery_days DESC;


-- ============================================================
-- Q11: Impact of late delivery on review score ⭐ MAIN INSIGHT
-- ============================================================

SELECT 
    CASE 
        WHEN o.order_delivered_customer_date <= o.order_estimated_delivery_date 
        THEN 'On time'
        ELSE 'Late'
    END AS delivery_status,
    COUNT(*) AS total_orders,
    ROUND(AVG(CAST(r.review_score AS DOUBLE)), 2) AS avg_review_score,
    ROUND(100.0 * SUM(CASE WHEN r.review_score <= 2 THEN 1 ELSE 0 END) 
          / COUNT(*), 2) AS pct_negative_reviews,
    ROUND(100.0 * SUM(CASE WHEN r.review_score = 5 THEN 1 ELSE 0 END) 
          / COUNT(*), 2) AS pct_five_stars
FROM orders o
INNER JOIN order_reviews r ON o.order_id = r.order_id
WHERE o.order_delivered_customer_date IS NOT NULL
    AND o.order_estimated_delivery_date IS NOT NULL
    AND r.review_score IS NOT NULL
GROUP BY 1
ORDER BY 1;


-- ============================================================
-- Q12: Cancellation rate by category
-- ============================================================

WITH orders_by_category AS (
    SELECT DISTINCT
        o.order_id,
        o.order_status,
        COALESCE(ct.product_category_name_english, p.product_category_name) AS category
    FROM orders o
    JOIN order_items oi ON o.order_id = oi.order_id
    JOIN products p ON oi.product_id = p.product_id
    LEFT JOIN category_translation ct 
        ON p.product_category_name = ct.product_category_name
)
SELECT 
    category,
    COUNT(*) AS total_orders,
    SUM(CASE WHEN order_status = 'canceled' THEN 1 ELSE 0 END) AS canceled_orders,
    ROUND(100.0 * SUM(CASE WHEN order_status = 'canceled' THEN 1 ELSE 0 END) 
          / COUNT(*), 2) AS cancellation_rate_pct
FROM orders_by_category
WHERE category IS NOT NULL
GROUP BY 1
HAVING COUNT(*) >= 100
ORDER BY cancellation_rate_pct DESC
LIMIT 15;


-- ============================================================
-- BONUS: Payment methods analysis
-- ============================================================

SELECT 
    op.payment_type,
    COUNT(DISTINCT op.order_id) AS total_orders,
    ROUND(100.0 * COUNT(DISTINCT op.order_id) 
          / SUM(COUNT(DISTINCT op.order_id)) OVER (), 2) AS pct_of_orders,
    ROUND(AVG(op.payment_value), 2) AS avg_payment,
    ROUND(AVG(op.payment_installments), 2) AS avg_installments
FROM order_payments op
GROUP BY 1
ORDER BY total_orders DESC;


-- ============================================================
-- FINAL: Master fact table for Power BI
-- ============================================================

CREATE OR REPLACE TABLE fact_orders AS
SELECT 
    o.order_id,
    o.customer_id,
    c.customer_unique_id,
    c.customer_city,
    c.customer_state,
    o.order_status,
    o.order_purchase_timestamp,
    DATE_TRUNC('month', o.order_purchase_timestamp) AS order_month,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,
    DATE_DIFF('day', o.order_purchase_timestamp, 
              o.order_delivered_customer_date) AS delivery_days,
    CASE 
        WHEN o.order_delivered_customer_date <= o.order_estimated_delivery_date 
        THEN 'On time' ELSE 'Late' 
    END AS delivery_status,
    oi.product_id,
    COALESCE(ct.product_category_name_english, p.product_category_name) AS category,
    CAST(p.product_weight_g AS DOUBLE) AS product_weight_g,
    oi.seller_id,
    CAST(oi.price AS DOUBLE) AS price,
    CAST(oi.freight_value AS DOUBLE) AS freight_value,
    CAST(oi.price + oi.freight_value AS DOUBLE) AS total_value,
    CAST(r.review_score AS INTEGER) AS review_score
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
JOIN order_items oi ON o.order_id = oi.order_id
LEFT JOIN products p ON oi.product_id = p.product_id
LEFT JOIN category_translation ct ON p.product_category_name = ct.product_category_name
LEFT JOIN order_reviews r ON o.order_id = r.order_id;

-- Export to CSV for Power BI
COPY fact_orders TO 'data/processed/fact_orders.csv' (HEADER, DELIMITER ',');
