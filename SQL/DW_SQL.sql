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
 

CREATE TABLE fact.call_details AS
SELECT 
    ROW_NUMBER() OVER (ORDER BY call_timestamp) as call_sk,
	cdr.call_id,
	c.customer_sk,
	t.tower_sk,
	n.network_sk,
	p.phone_sk,
	ct.call_type_sk,
	d.date_sk,
	time_sk,
	-- TO_CHAR(s.call_timestamp, 'YYYYMMDD')::INTEGER as date_sk,
    -- EXTRACT(HOUR FROM s.call_timestamp)::INTEGER as time_sk,
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
-- joins
LEFT JOIN dim.customer c ON cdr.customer_id = c.customer_id
LEFT JOIN dim.call_type ct ON cdr.call_type = ct.call_type
LEFT JOIN dim.network n ON cdr.network_type = n.network_type
-- LEFT JOIN dim.tower t ON COALESCE(cdr.tower_id, 'UNKNOWN') = t.tower_id
-- LEFT JOIN dim.phone p ON cdr.phone_number = p.phone_number	
-- DATE DIMENSION:
-- "Date dimension is different from business dimensions:
-- - We control this completely
-- - Should cover all possible dates in our data
-- - Every call happens on SOME valid date
-- - USE INNER JOIN after ensuring complete coverage
INNER JOIN dim.date d ON TO_CHAR(cdr.call_timestamp, 'YYYYMMDD')::INTEGER = d.date_sk
LEFT JOIN dim.time tm ON EXTRACT(HOUR FROM cdr.call_timestamp)::INTEGER = tm.time_sk
WHERE cdr.customer_id IS NOT NULL;

