import logging
import os
from pyspark import SparkConf
from pyspark import SparkContext
from pyspark.sql import SparkSession
from pyspark.sql.types import StructType, StructField, LongType, DoubleType, StringType

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger("MinIOSparkJob")


# adding iceberg configs
conf = (
    SparkConf()
    .set(
        "spark.sql.extensions",
        "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
    )  # Use Iceberg with Spark
    .set("spark.sql.catalog.lakehouse", "org.apache.iceberg.spark.SparkCatalog")
    .set("spark.sql.catalog.lakehouse.io-impl", "org.apache.iceberg.aws.s3.S3FileIO")
    .set("spark.sql.catalog.lakehouse.warehouse", "s3a://lakehouse/")
    .set("spark.sql.catalog.lakehouse.s3.path-style-access", "true")
    .set(
        "spark.sql.catalog.lakehouse.s3.endpoint",
        "http://minio.minio.svc.cluster.local:9000",
    )
    .set("spark.sql.defaultCatalog", "lakehouse")  # Name of the Iceberg catalog
    .set("spark.sql.catalogImplementation", "in-memory")
    .set("spark.sql.catalog.lakehouse.type", "hive")  # Iceberg catalog type
    .set(
        "spark.sql.catalog.lakehouse.uri",
        "thrift://hive-metastore.metastore.svc.cluster.local:9083",
    )
    .set("spark.executor.heartbeatInterval", "300000")
    .set("spark.network.timeout", "400000")
)

spark = SparkSession.builder.config(conf=conf).getOrCreate()

# Disable below line to see INFO logs
spark.sparkContext.setLogLevel("ERROR")


def load_config(spark_context: SparkContext):
    spark_context._jsc.hadoopConfiguration().set(
        "fs.s3a.access.key", os.getenv("AWS_ACCESS_KEY_ID", "admin")
    )
    spark_context._jsc.hadoopConfiguration().set(
        "fs.s3a.secret.key", os.getenv("AWS_SECRET_ACCESS_KEY", "password")
    )
    spark_context._jsc.hadoopConfiguration().set(
        "fs.s3a.endpoint", os.getenv("ENDPOINT", "minio.minio.svc.cluster.local:9000")
    )
    spark_context._jsc.hadoopConfiguration().set(
        "fs.s3a.connection.ssl.enabled", "false"
    )
    spark_context._jsc.hadoopConfiguration().set("fs.s3a.path.style.access", "true")
    spark_context._jsc.hadoopConfiguration().set("fs.s3a.attempts.maximum", "1")
    spark_context._jsc.hadoopConfiguration().set(
        "fs.s3a.connection.establish.timeout", "5000"
    )
    spark_context._jsc.hadoopConfiguration().set("fs.s3a.connection.timeout", "10000")


load_config(spark.sparkContext)

# Read Parquet file from MinIO
df = spark.read.option("header", "true").parquet(
    "s3a://openlake/spark/sample-data/yellow_tripdata_2009-01.parquet",
)

create_schema_df = spark.sql("CREATE DATABASE IF NOT EXISTS nyc ")
create_schema_df.show()
# Create Iceberg table "nyc.taxis_large" from RDD
df.write.mode("overwrite").saveAsTable("nyc.taxis_large")
# Query table row count
count_df = spark.sql("SELECT COUNT(*) AS cnt FROM nyc.taxis_large")
total_rows_count = count_df.first().cnt
print(f"Total Rows for NYC Taxi Data: {total_rows_count}")
