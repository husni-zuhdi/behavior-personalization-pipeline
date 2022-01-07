from datetime import datetime, timedelta
import json

from airflow import DAG
from airflow.contrib.operators.emr_add_steps_operator import EmrAddStepsOperator
from airflow.contrib.sensors.emr_step_sensor import EmrStepSensor
from airflow.models import Variable
from airflow.operators.dummy_operator import DummyOperator
from airflow.operators.postgres_operator import PostgresOperator
from airflow.operators.python import PythonOperator

from utils import _local_to_s3, run_redshift_external_query

# Config
BUCKET_NAME = Variable.get("BUCKET")
EMR_ID = Variable.get("EMR_ID")
EMR_STEPS = {}
with open("/dags/scripts/emr/clean_moview_review.json") as j:
    EMR_STEPS = json.load(j)

# DAG definition
default_args = {
    "owner": "airflow",
    "depend_on_past": True,
    "wait_for_downstream": True,
    "start_date": datetime.now(),
    "email": ["airflow@airflow.com"],
    "email_on_failure": False,
    "email_on_retry": False,
    "retries": 2,
    "retry_delay": timedelta(minutes=1)
}

dag = DAG(
    "user_behavior",
    default_args=default_args,
    schedule_interval="0 0 * * *",
    max_active_runs=1
)

extract_user_purchase_data = PostgresOperator(
    dag=dag,
    task_id="extract_user_purchase_data",
    sql="/scripts/sql/unload_user_purchase.sql",
    postgres_conn_id="postgres_default",
    params={"user_purchase": "/temp/user_purchase.csv"},
    depends_on_past=True,
    wait_for_downstream=True
)

user_purchase_to_stage_data_lake = PythonOperator(
    dag=dag,
    task_id="user_purchase_to_stage_data_lake",
    python_callable=_local_to_s3,
    op_kwargs={
        "file_name": "/temp/user_purchase.csv",
        "key": "stage/user_purchase/{{ ds }}/user_purchase.csv",
        "bucket_name": BUCKET_NAME,
        "remove_local": "true"
    }
)

user_purchase_stage_data_lake_to_stage_tbl = PythonOperator(
    dag=dag,
    task_id="user_purchase_stage_data_lake_to_stage_tbl",
    python_callable=run_redshift_external_query,
    op_kwargs={
        "qry": "ALTER TABLE spectrum.user_purchase_staging ADD IF NOT EXISTS PARTITION(insert_date='{{ ds }}') LOCATION 's3://"
        + BUCKET_NAME
        + "/stage/user_purchase/{{ ds }}'"
    }
)

movie_review_to_raw_data_lake = PythonOperator(
    dag=dag,
    task_id="movie_review_to_raw_data_lake",
    python_callable=_local_to_s3,
    op_kwargs={
        "file_name": "/data/movie_review.csv",
        "key": "raw/movie_review/{{ ds }}/movie.csv",
        "bucket_name": BUCKET_NAME
    }
)

spark_script_to_s3 = PythonOperator(
    dag=dag,
    task_id="spark_script_to_s3",
    python_callable=_local_to_s3,
    op_kwargs={
        "file_name": "/dags/scripts/spark/random_text_classification.py",
        "key": "scripts/random_text_classification.py",
        "bucket_name": BUCKET_NAME
    }
)
