-- -------------------------
-- Create Roles
-- -------------------------
CREATE OR REPLACE ROLE admin;
CREATE OR REPLACE ROLE developer;
CREATE OR REPLACE ROLE pii;

-- -------------------------
-- Granting Roles to Each Other
-- -------------------------
GRANT ROLE admin TO ROLE accountadmin;
GRANT ROLE developer TO ROLE admin;
GRANT ROLE pii TO ROLE accountadmin;

-- -------------------------
-- Create Warehouse for the Assignment
-- -------------------------
CREATE OR REPLACE WAREHOUSE assignment_wh
  WAREHOUSE_SIZE = medium
  AUTO_RESUME = TRUE;

-- -------------------------
-- Granting Permissions to Roles
-- -------------------------
GRANT USAGE ON WAREHOUSE assignment_wh TO ROLE admin;
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE admin;

-- -------------------------
-- Using the Warehouse for Subsequent Queries
-- -------------------------
USE ROLE admin;
SHOW GRANTS TO ROLE admin;

-- -------------------------
-- Granting Database Creation Permissions
-- -------------------------
GRANT CREATE DATABASE ON ACCOUNT TO ROLE admin;

-- -------------------------
-- Dropping Existing Database if Exists
-- -------------------------
DROP DATABASE IF EXISTS assignment_db;

-- -------------------------
-- Create Database and Schema
-- -------------------------
USE WAREHOUSE assignment_wh;

CREATE OR REPLACE DATABASE assignment_db;
CREATE OR REPLACE SCHEMA assignment_db.my_schema;

-- -------------------------
-- Create Tables for Employee Data
-- -------------------------
CREATE OR REPLACE TABLE assignment_db.my_schema.employee_data (
    Employee_ID INT,
    Name STRING,
    Email STRING,
    Phone_Number STRING,
    Address STRING
);

CREATE OR REPLACE TABLE assignment_db.my_schema.employee_data_variant (
    Employee_ID INT,
    Name STRING,
    Email STRING,
    Phone_Number STRING,
    Address STRING
);

-- -------------------------
-- Create Internal Stage for Employees Data
-- -------------------------
CREATE OR REPLACE STAGE employees_data_int_stage;

-- -------------------------
-- Creating File Format for the Data (CSV)
-- -------------------------
CREATE OR REPLACE FILE FORMAT infer_csv_format
  TYPE = CSV
  COMPRESSION = GZIP
  FIELD_DELIMITER = ','
  PARSE_HEADER = TRUE
  DATE_FORMAT = 'YYYY-MM-DD'
  FIELD_OPTIONALLY_ENCLOSED_BY = '"';

-- -------------------------
-- Load Data into Internal Stage 
-- -------------------------

-- Use the PUT command to upload the file to internal stage
-- USE DATABASE assignment_db;
-- USE SCHEMA my_schema;
-- CREATE OR REPLACE STAGE employees_data_int_stage;
-- GRANT ALL PRIVILEGES ON STAGE employees_data_int_stage TO ROLE admin;
-- put file:///Users/nakulsingla/Documents/snowflake_assignment/employee_data.csv @employees_data_int_stage;

-- -------------------------
-- Load Data from Internal Stage into employee_data Table
-- -------------------------
COPY INTO assignment_db.my_schema.employee_data
FROM (
    SELECT $1, $2, $3, $4, $5 FROM @employees_data_int_stage/employees.csv (file_format => 'infer_csv_format')
)
ON_ERROR = SKIP_FILE;

-- -------------------------
-- Create Storage Integration for AWS S3
-- -------------------------
CREATE OR REPLACE STORAGE INTEGRATION int_b11
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = S3
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::886436963465:role/snowflake_nakul'
  STORAGE_ALLOWED_LOCATIONS = ('s3://sfsigmoid/snowflake/');
  
-- -------------------------
-- Describe the Integration
-- -------------------------
DESC INTEGRATION int_b11;

-- -------------------------
-- Create Masking Policy for PII Columns (Email, Address, Phone Number)
-- -------------------------
CREATE OR REPLACE MASKING POLICY pii_mask AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('DEVELOPER') THEN '**masked**'
    ELSE val
  END;

-- -------------------------
-- Apply Masking Policy to PII Columns
-- -------------------------
ALTER TABLE IF EXISTS assignment_db.my_schema.employee_data 
  MODIFY COLUMN email SET MASKING POLICY pii_mask;

ALTER TABLE IF EXISTS assignment_db.my_schema.employee_data 
  MODIFY COLUMN address SET MASKING POLICY pii_mask;

ALTER TABLE IF EXISTS assignment_db.my_schema.employee_data 
  MODIFY COLUMN phone_number SET MASKING POLICY pii_mask;

-- -------------------------
-- Using the Developer Role to Test Masking
-- -------------------------
USE ROLE developer;

-- Querying to Verify the Masking Policy (Email, Address, Phone Number)
SELECT * FROM assignment_db.my_schema.employee_data;

-- -------------------------
-- Create External Stage for AWS S3 Data
-- -------------------------
CREATE OR REPLACE STAGE employees_data_ext_stage
  URL = 's3://sfsigmoid/snowflake/'
  STORAGE_INTEGRATION = int_b11;

-- -------------------------
-- Create Schema for Table to Store External Stage Data
-- -------------------------
CREATE OR REPLACE TABLE assignment_db.my_schema.employees_external(
    EMPLOYEE_ID NUMBER(3,0),
    FIRST_NAME VARCHAR(16777216),
    LAST_NAME VARCHAR(16777216),
    EMAIL VARCHAR(16777216),
    PHONE_NUMBER VARCHAR(16777216),
    HIRE_DATE DATE,
    JOB_ID VARCHAR(16777216),
    SALARY NUMBER(5,0),
    COMMISSION_PCT NUMBER(3,2),
    MANAGER_ID NUMBER(3,0),
    DEPARTMENT_ID NUMBER(3,0),
    ADDRESS VARCHAR(16777216),
    elt_by VARCHAR(100),
    elt_ts TIMESTAMP_LTZ,
    file_name VARCHAR(100)
);

-- -------------------------
-- Copy Data from Internal Stage to `employees_external` Table
-- -------------------------
COPY INTO assignment_db.my_schema.employees_external
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, 'my_app_name' AS ELT_BY, CURRENT_TIMESTAMP AS ELT_TS, METADATA$FILENAME AS FILE_NAME
    FROM '@employees_data_int_stage/employees.csv'
)
FILE_FORMAT = (skip_header = 1, field_optionally_enclosed_by = '"')
ON_ERROR = SKIP_FILE;

-- -------------------------
-- Query to View the Data in `employees_external`
-- -------------------------
SELECT * FROM assignment_db.my_schema.employees_external;

-- -------------------------
-- Create a Variant Table to Store Employee Data as VARIANT
-- -------------------------
CREATE OR REPLACE TABLE assignment_db.my_schema.employees_variant (
    employee_data VARIANT
);

-- -------------------------
-- Insert Data from `employees_csv` into `employees_variant`
-- -------------------------
INSERT INTO assignment_db.my_schema.employees_variant
SELECT TO_VARIANT(OBJECT_CONSTRUCT(*))
FROM assignment_db.my_schema.employee_data;

-- -------------------------
-- Query to View Data in Variant Table
-- -------------------------
SELECT * FROM assignment_db.my_schema.employees_variant;

-- -------------------------
-- Create Parquet File Format for Data (Example: Titanic Data in Parquet)
-- -------------------------
CREATE OR REPLACE FILE FORMAT infer_parquet_format
  TYPE = PARQUET
  COMPRESSION = AUTO
  USE_LOGICAL_TYPE = TRUE
  TRIM_SPACE = TRUE
  REPLACE_INVALID_CHARACTERS = TRUE
  NULL_IF = ('\N', 'NULL', 'NUL', '');

-- -------------------------
-- Infer Schema for Parquet File from External Stage
-- -------------------------
SELECT * FROM TABLE(INFER_SCHEMA(
  LOCATION => '@employees_data_ext_stage/titanic.parquet',
  FILE_FORMAT => 'infer_parquet_format',
  MAX_RECORDS_PER_FILE => 10
));

-- -------------------------
-- Query Data from Parquet File in External Stage
-- -------------------------
SELECT *, 'my_app_name' AS ELT_BY, CURRENT_TIMESTAMP AS ELT_TS, METADATA$FILENAME AS FILE_NAME
FROM '@employees_data_ext_stage/titanic.parquet' (FILE_FORMAT => 'infer_parquet_format');
