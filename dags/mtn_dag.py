# import libriaries

from datetime import datetime, timedelta 
from airflow import DAG
from airflow.providers.standard.operators.python import PythonOperator
from airflow.providers.standard.operators.bash import BashOperator
import os 

default_args = {
    'owner': 'mtn-team',
    'start_date': datetime(2025, 1, 1),
    'retries': 1,
}

dag = DAG(
    'mtn_etl_pipeline',
    default_args=default_args,
    description='MTN CDR data pipeline',
    schedule='@daily',
    catchup=False,
    tags=['mtn, training']
)

def check_input_file():
    data_file = '/opt/airflow/data/raw/MTN_cdr_data.csv'

    if not os.path.exists(data_file):
        raise Exception(f"Data file missing: {data_file}")
    
    print(f"data file exists and found: {data_file}")
    return True

def verify_output():
    output_file = '/opt/airflow/data/processed/call_detail_records_processed.csv'

    if os.path.exists(output_file):
        print(f"ETL completed successfully: {output_file}")
        return True
    else:
        raise Exception("ETL failed - no output file")
    
# Task 
# Task 1
check_input = PythonOperator(
    task_id='check_input',
    python_callable=check_input_file,
    dag=dag,
)

#task 2
run_etl = BashOperator(
    task_id='run_etl',
    bash_command='cd /opt/airflow && python etl.py',
    dag=dag,
)

# task 3
verify_output_task = PythonOperator(
    task_id='verify_output',
    python_callable=verify_output,
    dag=dag,
)

# define task dependencies
check_input >> run_etl >> verify_output_task
