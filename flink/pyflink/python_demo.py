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
   CREATE TABLE orders (
     order_number BIGINT,
     price        DECIMAL(32,2),
     buyer        ROW,
     order_time   TIMESTAMP(3)
   ) WITH (
     'connector' = 'datagen',
     'rows-per-second' = '4'
   )"""
    )

    t_env.execute_sql(
        """
   create table orders_sink (
     order_number BIGINT,
     price        DECIMAL(32,2),
     buyer        ROW,
     order_time   TIMESTAMP(3)
   ) with (
    'connector'='iceberg',
    'catalog-name'='iceberg_catalog', 
    'catalog-type'='hive',
    'uri'='thrift://hive-metastore.metastore.svc.cluster.local:9083', 
    'warehouse'='s3a://lakehouse',
    'format-version'='2',
    's3.endpoint'='http://minio.minio.svc.cluster.local:9000',
    'io-impl'='org.apache.iceberg.aws.s3.S3FileIO'
   )"""
    )

    t_env.execute_sql(
        """
       INSERT INTO orders_sink SELECT * FROM orders"""
    )


if __name__ == "__main__":
    logging.basicConfig(stream=sys.stdout, level=logging.INFO, format="%(message)s")
    pyflink_hello_world()
