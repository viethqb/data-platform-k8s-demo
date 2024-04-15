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
   CREATE TABLE orders_sink (
     order_number BIGINT,
     price        DECIMAL(32,2),
     buyer        ROW,
     order_time   TIMESTAMP(3)
   ) WITH (
     'connector' = 'kafka',
     'topic' = 'orders',
     'properties.bootstrap.servers' = 'my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092',
     'properties.group.id' = 'orders-sink',
     'format' = 'json'
   )"""
    )

    t_env.execute_sql(
        """
       INSERT INTO orders_sink SELECT * FROM orders"""
    )


if __name__ == "__main__":
    logging.basicConfig(stream=sys.stdout, level=logging.INFO, format="%(message)s")
    pyflink_hello_world()
