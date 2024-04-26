import logging
import sys
import os

from pyflink.datastream import StreamExecutionEnvironment
from pyflink.table import StreamTableEnvironment


def pyflink_hello_world():
    env = StreamExecutionEnvironment.get_execution_environment()
    env.set_parallelism(1)

    t_env = StreamTableEnvironment.create(stream_execution_environment=env)

    t_env.execute_sql(
        """
    CREATE TEMPORARY TABLE datagen(
        id    BIGINT,
        data  STRING
    ) WITH (
        'connector' = 'datagen'
    );"""
    )

    t_env.execute_sql(
        """
    CREATE TEMPORARY TABLE dlf_iceberg (
        id    BIGINT,
        data  STRING
    ) with (
        'connector'='iceberg',
        'catalog-name'='iceberg_catalog', 
        'catalog-type'='hive',
        'uri'='thrift://hive-metastore.metastore.svc.cluster.local:9083', 
        'warehouse'='s3a://lakehouse',
        'format-version'='2',
        's3.endpoint'='http://10.96.113.214:9000',
        'io-impl'='org.apache.iceberg.aws.s3.S3FileIO',
        's3.path.style.access'='true',
        's3.path-style'= 'true'
    )"""
    )

    t_env.execute_sql("INSERT INTO dlf_iceberg SELECT * FROM datagen;")


if __name__ == "__main__":
    logging.basicConfig(stream=sys.stdout, level=logging.INFO, format="%(message)s")
    pyflink_hello_world()
