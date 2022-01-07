from datetime import datetime, timedelta
import json

from airflow import DAG
from airflow.contrib.operators.emr_add_steps_operator import EmrAddStepsOperator
from airflow.contrib.sensors.emr_step_sensor import EmrStepSensor
from airflow.models import Variable
from airflow.operators.dummy_operator import DummyOperator
from airflow.operators.postgres_operator import PostgresOperator
from airflow.operators.python import PythonOperator

# Config
BUCKET_NAME = Variable.get("BUCKET")
EMR_ID = Variable.get("EMR_ID")
EMR_STEPS = {}
with open("/dags/scripts/emr/clean_moview_review.json") as j:
    EMR_STEPS = json.load(j)

