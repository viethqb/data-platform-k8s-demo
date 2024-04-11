from datetime import timedelta, datetime

# [START import_module]
# The DAG object; we'll need this to instantiate a DAG
from airflow import DAG

# Operators; we need this to operate!
from airflow.providers.cncf.kubernetes.operators.spark_kubernetes import (
    SparkKubernetesOperator,
)
from airflow.providers.cncf.kubernetes.sensors.spark_kubernetes import (
    SparkKubernetesSensor,
)
from airflow.utils.dates import days_ago

# [END import_module]

# [START default_args]
# These args will get passed on to each operator
# You can override them on a per-task basis during operator initialization
default_args = {
    "owner": "airflow",
    "depends_on_past": False,
    "start_date": days_ago(1),
    "email": ["airflow@example.com"],
    "email_on_failure": False,
    "email_on_retry": False,
    "max_active_runs": 1,
    "retries": 3,
}
# [END default_args]

dag = DAG(
    "main_iceberg",
    default_args=default_args,
    schedule_interval=None,
    tags=["example", "spark"],
)

submit = SparkKubernetesOperator(
    task_id="main_iceberg_submit",
    namespace="spark-operator",
    application_file="spark/jobs/main_iceberg.yaml",
    kubernetes_conn_id="kubernetes_default",
    do_xcom_push=True,
    dag=dag,
)

sensor = SparkKubernetesSensor(
    task_id="main_iceberg_monitor",
    namespace="spark-operator",
    application_name="{{ task_instance.xcom_pull(task_ids='main_iceberg_submit')['metadata']['name'] }}",
    kubernetes_conn_id="kubernetes_default",
    dag=dag,
    attach_log=True,
)

submit >> sensor
