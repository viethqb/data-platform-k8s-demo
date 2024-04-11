dag = DAG(
    "spark_pi",
    default_args=default_args,
    schedule_interval=timedelta(days=1),
    tags=["example"],
)

# spark = open(
#     "example_spark_kubernetes_operator_pi.yaml").read()

submit = SparkKubernetesOperator(
    task_id="spark_pi_submit",
    namespace="spark-operator",
    application_file="./spark_yaml/spark_pi.yaml",
    kubernetes_conn_id="kubernetes_default",
    do_xcom_push=True,
    dag=dag,
)

sensor = SparkKubernetesSensor(
    task_id="spark_pi_monitor",
    namespace=" spark-operator",
    application_name="{{ task_instance.xcom_pull(task_ids='spark_pi_submit')['metadata']['name'] }}",
    kubernetes_conn_id="kubernetes_default",
    dag=dag,
    attach_log=True,
)

submit >> sensor
