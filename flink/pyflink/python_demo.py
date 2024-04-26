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
    CREATE TEMPORARY TABLE test.dlf_iceberg (
        id    BIGINT,
        data  STRING
    ) (
        'connector'='iceberg',
        'catalog-type'='hive',
        'catalog-name'='iceberg_catalog',
        'uri'='thrift://hive-metastore.metastore.svc.cluster.local:9083',  
        'warehouse'='s3a://lakehouse', 
        'format-version'='2',
        'write.upsert.enabled'='true',
        'hadoop.fs.s3a.endpoint' = 'http://minio.minio.svc.cluster.local:9000' , 
        'hadoop.fs.s3a.access.key' = 'admin' , 
        'hadoop.fs.s3a.secret.key' = 'password', 
        'hadoop.fs.s3a.connection.timeout' = '600000', 
        'hadoop.fs.s3a.impl' = 'org.apache.hadoop.fs.s3a.S3AFileSystem', 
        'hadoop.fs.s3a.path.style.access' = 'true'
    )"""
    )

    t_env.execute_sql("INSERT INTO dlf_iceberg SELECT * FROM datagen;")


if __name__ == "__main__":
    logging.basicConfig(stream=sys.stdout, level=logging.INFO, format="%(message)s")
    pyflink_hello_world()
