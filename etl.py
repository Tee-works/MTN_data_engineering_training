"""
MTN Call Detail Record (CDR) Processing Script

This script automates the cleaning, validation, and transformation of MTN CDR data.
"""

import pandas as pd
import os
import logging
from sqlalchemy import create_engine
from dotenv import load_dotenv

# --- 1. Configuration and Setup ---

# Set up basic logging to monitor the script's execution
# --- 1. Configuration and Setup ---

# Set up basic logging to monitor the script's execution
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    filename='pipeline.log', # This tells Python to save logs to a file named 'pipeline.log'
    filemode='a' # Use 'a' to append to the file each time the script runs. Use 'w' to overwrite it.
)

# Load environment variables from a .env file for database credentials
load_dotenv()

def standardize_boolean(value):
    """Standardizes various boolean representations to True or False."""
    if pd.isna(value):
        return None
    value_str = str(value).lower()
    if value_str in ['yes', 'true', '1', 'y']:
        return True
    elif value_str in ['no', 'false', '0', 'n']:
        return False
    return None

def convert_phone_format(phone):
    """Converts phone numbers to a standard 11-digit format starting with '0'."""
    if not isinstance(phone, str):
        return phone
    cleaned_phone = ''.join(filter(str.isdigit, phone))
    if cleaned_phone.startswith('234'):
        return '0' + cleaned_phone[3:]
    return cleaned_phone

def validate_phone_format(phone):
    """Validates if a phone number is exactly 11 digits."""
    if not isinstance(phone, str):
        return False
    return len(phone) == 11 and phone.isdigit()

def validate_signal_strength(signal):
    """Validates if signal strength is within the expected range [-120, -30] dBm."""
    if pd.isna(signal):
        return None
    return -120 <= signal <= -30

def categorize_signal_strength(signal):
    """Categorizes signal strength into quality buckets."""
    if pd.isna(signal):
        return 'Unknown'
    elif signal >= -70:
        return 'Excellent'
    elif signal >= -90:
        return 'Good'
    elif signal >= -110:
        return 'Fair'
    else:
        return 'Poor'

# --- 3. Main Data Pipeline Functions ---

def extract_data(file_path):
    logging.info(f"Starting data extraction from: {file_path}")
    try:
        dtype_dict = {
            'phone_number': 'str', 'customer_id': 'str',
            'tower_id': 'str', 'call_id': 'str'
        }
        df = pd.read_csv(file_path, dtype=dtype_dict)
        logging.info("Data extraction successful.")
        return df
    except FileNotFoundError:
        logging.error(f"Error: The file was not found at {file_path}")
        raise
    except Exception as e:
        logging.error(f"An unexpected error occurred during data extraction: {e}")
        raise

def clean_and_transform_data(df):
    logging.info("Starting data cleaning and transformation.")
    
    df_clean = df.copy()

    # Handle missing values
    df_clean.dropna(subset=['customer_id', 'phone_number'], inplace=True)
    fill_values = {
        'call_duration_seconds': 0,
        'data_usage_mb': 0,
        'tower_id': 'UNKNOWN',
        'signal_strength_dbm': df_clean['signal_strength_dbm'].median()
    }
    df_clean.fillna(fill_values, inplace=True)
    
    # Handle duplicates
    initial_rows = len(df_clean)
    df_clean.drop_duplicates(inplace=True)
    rows_dropped = initial_rows - len(df_clean)
    logging.info(f"Dropped {rows_dropped} duplicate rows.")

    # Standardize data types and formats
    df_clean['call_timestamp'] = pd.to_datetime(df_clean['call_timestamp'], errors='coerce')
    df_clean.dropna(subset=['call_timestamp'], inplace=True) # Drop rows where conversion failed
    
    # Standardize text and boolean columns
    df_clean['call_success'] = df_clean['call_success'].apply(standardize_boolean)
    df_clean['roaming'] = df_clean['roaming'].apply(standardize_boolean)
    df_clean['call_type'] = df_clean['call_type'].str.title()
    df_clean['network_type'] = df_clean['network_type'].str.upper()

    # Standardize phone numbers
    df_clean['phone_number'] = df_clean['phone_number'].apply(convert_phone_format)
    
    logging.info("Data cleaning and transformation completed.")
    return df_clean

def validate_data(df):
    logging.info("Applying business rule validations.")
    df['phone_valid'] = df['phone_number'].apply(validate_phone_format)
    df['signal_valid'] = df['signal_strength_dbm'].apply(validate_signal_strength)
    
    invalid_phones = len(df[df['phone_valid'] == False])
    invalid_signals = len(df[df['signal_valid'] == False])
    logging.info(f"Validation complete. Found {invalid_phones} invalid phone numbers and {invalid_signals} invalid signal strengths.")
    
    return df

def engineer_features(df):
    logging.info("Starting feature engineering.")
    
    # Time-based features
    df['call_duration_minutes'] = (df['call_duration_seconds'] / 60).round(2)
    df['call_month'] = df['call_timestamp'].dt.month_name()
    df['call_hour'] = df['call_timestamp'].dt.hour
    df['day_of_week'] = df['call_timestamp'].dt.day_name()

    # Customer segmentation feature
    revenue_threshold = df['revenue_naira'].quantile(0.8)
    df['high_value_customer'] = df['revenue_naira'] > revenue_threshold

    # Signal quality feature
    df['signal_quality'] = df['signal_strength_dbm'].apply(categorize_signal_strength)
    
    logging.info("Feature engineering completed.")
    return df

def load_data(df, output_path, table_name):
    # --- Load to CSV ---
    logging.info(f"Loading data to CSV file: {output_path}")
    try:
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        df.to_csv(output_path, index=False)
        logging.info("Data successfully saved to CSV.")
    except Exception as e:
        logging.error(f"Failed to save data to CSV: {e}")

    # --- Load to PostgreSQL ---
    logging.info(f"Loading data to PostgreSQL table: {table_name}")
    try:
        db_url = f"postgresql://{os.getenv('DB_USER')}:{os.getenv('DB_PASSWORD')}@{os.getenv('DB_HOST')}:{os.getenv('DB_PORT')}/{os.getenv('DB_NAME')}"
        engine = create_engine(db_url)
        
        with engine.connect() as connection:
            df.to_sql(table_name, con=connection, if_exists='replace', index=False)
            logging.info("Data successfully loaded to PostgreSQL.")
            
    except Exception as e:
        logging.error(f"Failed to load data to PostgreSQL: {e}")
        raise

# --- 4. Main Execution Block ---

def main():
    """Main function to run the entire ETL pipeline."""
    
    # Define file paths and database table name
    # It's better to use relative paths or environment variables for Docker/Airflow
    input_file = 'data/raw/MTN_cdr_data.csv'
    output_file = 'data/processed/call_detail_records_processed.csv'
    db_table_name = 'call_detail_records'
    
    logging.info("--- Starting MTN CDR Data Pipeline ---")
    
    try:
        # Step 1: Extract
        raw_df = extract_data(input_file)
        
        # Step 2: Clean and Transform
        cleaned_df = clean_and_transform_data(raw_df)
        
        # Step 3: Validate
        validated_df = validate_data(cleaned_df)
        
        # Step 4: Feature Engineering
        final_df = engineer_features(validated_df)
        
        # Step 5: Load
        load_data(final_df, output_file, db_table_name)
        
        logging.info("--- MTN CDR Data Pipeline Finished Successfully ---")
        
    except Exception as e:
        logging.critical(f"Pipeline failed with error: {e}")

if __name__ == "__main__":
    main()
