-- UNDERSTANDING performance problem
EXPLAIN ANALYZE 
SELECT * FROM call_detail_records
WHERE customer_id = 'CU000544'
AND call_timestamp BETWEEN '2024-04-01' AND '2024-04-30';

-- DDL
-- CREATE STAR SCHEMA
CREATE SCHEMA dim;
CREATE SCHEMA fact;
CREATE SCHEMA reports;


-- create call type dimension table
CREATE TABLE dim.call_type AS
SELECT DISTINCT
    ROW_NUMBER() OVER (ORDER BY call_type) as call_type_sk,
	call_type,
	COUNT(*) as total_calls
FROM call_detail_records
WHERE call_type IS NOT NULL
GROUP BY call_type;


ALTER TABLE dim.call_type ADD PRIMARY KEY (call_type_sk);

-- network dimension table
CREATE TABLE dim.network_type AS
SELECT DISTINCT
    ROW_NUMBER() OVER (ORDER BY network_type) as network_type_sk,
	network_type,
	COUNT(*) as count
FROM call_detail_records
WHERE network_type IS NOT NULL
GROUP BY network_type
ORDER BY network_type;

ALTER TABLE dim.network_type ADD PRIMARY KEY (network_type_sk);

CREATE TABLE dim.customer AS
SELECT 
    ROW_NUMBER() OVER (ORDER BY customer_id) as customer_sk,
    customer_id,
    -- Engineer customer segmentation on the fly!
    CASE 
        WHEN AVG(revenue_naira) > 800 THEN 'Premium'
        WHEN AVG(revenue_naira) > 300 THEN 'Standard'
        ELSE 'Basic'
    END as customer_type,
    COUNT(*) as total_calls,
    SUM(revenue_naira) as total_revenue,
	COUNT(DISTINCT phone_number) as phone_count,
    CURRENT_DATE as effective_date,
    '9999-12-31'::DATE as expiry_date,
    TRUE as is_current,
    CURRENT_TIMESTAMP as created_date
FROM call_detail_records
WHERE customer_id IS NOT NULL
GROUP BY customer_id;

ALTER TABLE dim.customer ADD PRIMARY KEY (customer_sk);


-- tower dimension (CTE)
CREATE TABLE dim.tower AS 
WITH tower_cleaned AS (
    --first create a temporary result set with a cleaned tower id for each record
	SELECT
	    CASE 
		    WHEN tower_id IS NULL OR tower_id LIKE 'INVALID%' THEN 'UNKNOWN'
			ELSE tower_id
		END AS clean_tower_id
	FROM 
	    call_detail_records
)

SELECT 
    ROW_NUMBER() OVER (ORDER BY clean_tower_id) as tower_sk,
	clean_tower_id AS tower_id, 
	CASE 
	    WHEN clean_tower_id = 'UNKNOWN' THEN 'needs_repair'
		ELSE 'Active'
	END AS tower_status
FROM 
    tower_cleaned
GROUP BY
    clean_tower_id;

ALTER TABLE dim.tower ADD PRIMARY KEY (tower_sk);	
ALTER TABLE dim.tower ADD UNIQUE (tower_id);

-- Phone dimension (pure phone attributes)
CREATE TABLE dim.phone AS
SELECT 
    ROW_NUMBER() OVER (ORDER BY phone_number) as phone_sk,
	--CAST(phone_number AS VARCHAR(15))
    phone_number,
    phone_valid,
    -- NO customer_sk here!
    COUNT(*) as total_calls_from_phone,
    SUM(revenue_naira) as total_revenue_from_phone
FROM call_detail_records
WHERE phone_number IS NOT NULL
GROUP BY phone_number, phone_valid;

-- Add constraints after creation
ALTER TABLE dim.phone ADD PRIMARY KEY (phone_sk);

-- Time dimension 
CREATE TABLE dim.time AS
SELECT
    hour_of_day AS time_sk,
    (hour_of_day || ':00:00')::TIME AS time_value,
    hour_of_day AS hour_24,
    CASE
        WHEN hour_of_day = 0 THEN 12
        WHEN hour_of_day <= 12 THEN hour_of_day
        ELSE hour_of_day - 12
    END AS hour_12,
    CASE
        WHEN hour_of_day < 12 THEN 'AM'
        ELSE 'PM'
    END AS am_pm,
    CASE
        WHEN hour_of_day BETWEEN 6 AND 11 THEN 'Morning'
        WHEN hour_of_day BETWEEN 12 AND 17 THEN 'Afternoon'
        WHEN hour_of_day BETWEEN 18 AND 21 THEN 'Evening'
        ELSE 'Night'
    END AS time_period,
    CASE
        WHEN hour_of_day BETWEEN 8 AND 17 THEN TRUE
        ELSE FALSE
    END AS is_business_hours
FROM
    generate_series(0, 23) AS hour_of_day;


ALTER TABLE dim.time ADD PRIMARY KEY (time_sk); 

-- Create date dimension with all business attributes
CREATE TABLE dim.date AS
SELECT 
    TO_CHAR(date_val, 'YYYYMMDD')::INTEGER as date_sk,
    date_val as full_date,
    EXTRACT(DOW FROM date_val) as day_of_week,
    TRIM(TO_CHAR(date_val, 'Day')) as day_name,
    EXTRACT(DAY FROM date_val) as day_of_month,
    EXTRACT(DOY FROM date_val) as day_of_year,
    EXTRACT(WEEK FROM date_val) as week_of_year,
    EXTRACT(MONTH FROM date_val) as month_num,
    TRIM(TO_CHAR(date_val, 'Month')) as month_name,
    EXTRACT(QUARTER FROM date_val) as quarter_num,
    EXTRACT(YEAR FROM date_val) as year_num,
    CASE WHEN EXTRACT(DOW FROM date_val) IN (0,6) THEN TRUE ELSE FALSE END as is_weekend,
    FALSE as is_holiday,  -- Can be updated later
    EXTRACT(YEAR FROM date_val) as fiscal_year,
    EXTRACT(QUARTER FROM date_val) as fiscal_quarter,
    CURRENT_TIMESTAMP as created_date
FROM generate_series('2024-01-01'::DATE, '2024-12-31'::DATE, '1 day'::INTERVAL) as date_val;

-- Add primary key
ALTER TABLE dim.date ADD PRIMARY KEY (date_sk);

-- Create fact table with foreign keys to dimensions
CREATE TABLE fact.call_details AS
SELECT 
    ROW_NUMBER() OVER (ORDER BY cdr.call_timestamp) as call_sk,
    cdr.call_id,
    c.customer_sk,
    t.tower_sk,
    nt.network_type_sk,  
    p.phone_sk,
    ct.call_type_sk,
    d.date_sk,
    tm.time_sk,  
    -- Measures 
    cdr.call_duration_seconds,
    cdr.revenue_naira,
    cdr.data_usage_mb,
    cdr.signal_strength_dbm,
    cdr.call_timestamp,
    cdr.call_success,
    cdr.roaming
FROM 
    call_detail_records cdr
LEFT JOIN dim.customer c ON cdr.customer_id = c.customer_id
LEFT JOIN dim.call_type ct ON cdr.call_type = ct.call_type
LEFT JOIN dim.network_type nt ON cdr.network_type = nt.network_type  -- Fixed table name
LEFT JOIN dim.tower t ON COALESCE(cdr.tower_id, 'UNKNOWN') = t.tower_id  -- Uncommented
LEFT JOIN dim.phone p ON cdr.phone_number = p.phone_number  -- Uncommented
INNER JOIN dim.date d ON TO_CHAR(cdr.call_timestamp, 'YYYYMMDD')::INTEGER = d.date_sk
LEFT JOIN dim.time tm ON EXTRACT(HOUR FROM cdr.call_timestamp)::INTEGER = tm.time_sk
WHERE cdr.customer_id IS NOT NULL;

ALTER TABLE fact.call_details ADD PRIMARY KEY (call_sk);

-- Add foreign key constraints for referential integrity
ALTER TABLE fact.call_details 
ADD CONSTRAINT fk_customer FOREIGN KEY (customer_sk) REFERENCES dim.customer(customer_sk),
ADD CONSTRAINT fk_tower FOREIGN KEY (tower_sk) REFERENCES dim.tower(tower_sk),
ADD CONSTRAINT fk_date FOREIGN KEY (date_sk) REFERENCES dim.date(date_sk),
ADD CONSTRAINT fk_time FOREIGN KEY (time_sk) REFERENCES dim.time(time_sk),
ADD CONSTRAINT fk_call_type FOREIGN KEY (call_type_sk) REFERENCES dim.call_type(call_type_sk),
ADD CONSTRAINT fk_network_type FOREIGN KEY (network_type_sk) REFERENCES dim.network_type(network_type_sk),  
ADD CONSTRAINT fk_phone FOREIGN KEY (phone_sk) REFERENCES dim.phone(phone_sk);


-- Test current performance BEFORE indexes
EXPLAIN (ANALYZE, BUFFERS) 
SELECT 
    c.customer_id,
    d.month_name,
    COUNT(*) as calls,
    SUM(f.revenue_naira) as revenue
FROM fact.call_details f
JOIN dim.customer c ON f.customer_sk = c.customer_sk
JOIN dim.date d ON f.date_sk = d.date_sk
WHERE d.month_num = 4  -- April data
GROUP BY c.customer_id, d.month_name
ORDER BY revenue DESC
LIMIT 10;

-- PERFORMANCE OPTIMIZATION
-- =====================================================
-- Primary indexes for fact table foreign keys
CREATE INDEX idx_fact_customer ON fact.call_details (customer_sk);
CREATE INDEX idx_fact_date ON fact.call_details (date_sk);
CREATE INDEX idx_fact_call_type ON fact.call_details (call_type_sk);
CREATE INDEX idx_fact_network_type ON fact.call_details (network_type_sk);  
CREATE INDEX idx_fact_tower ON fact.call_details (tower_sk);
CREATE INDEX idx_fact_time ON fact.call_details (time_sk);
CREATE INDEX idx_fact_phone ON fact.call_details (phone_sk); 


-- Create roles for different user types
CREATE ROLE mtn_finance;
CREATE ROLE mtn_operations;  
CREATE ROLE mtn_customer_service;
CREATE ROLE mtn_analytics;
CREATE ROLE mtn_readonly;

-- Grant appropriate permissions
-- Finance team - revenue and customer data
GRANT SELECT ON reports.finance_dashboard TO mtn_finance;
GRANT SELECT ON dim.customer TO mtn_finance;

-- Operations team - network and tower data
GRANT SELECT ON dim.tower, dim.network_type TO mtn_operations;

-- Customer service - customer-focused views only
GRANT SELECT ON reports.customer_service_dashboard TO mtn_customer_service;

-- Analytics team - full read access but no modifications
GRANT SELECT ON ALL TABLES IN SCHEMA fact TO mtn_analytics;
GRANT SELECT ON ALL TABLES IN SCHEMA dim TO mtn_analytics;
GRANT SELECT ON ALL TABLES IN SCHEMA reports TO mtn_analytics;

-- Read-only access for executives and auditors
GRANT SELECT ON reports.finance_dashboard TO mtn_readonly;
