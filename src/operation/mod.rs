//! Athena のオペレーション。実行は Trino に委ね、状態は Store に持つ。

mod classification;
mod completion;
mod execution;
mod format_probe;
mod iceberg_partitions;
mod query_execution;
mod quoted_names;
mod result_output;
mod table_format;
mod target_table;
mod type_spelling;
mod utility_rows;
mod validation;
mod work_group;

pub(crate) use execution::start_query_execution;
pub(crate) use query_execution::{get_query_execution, get_query_results, stop_query_execution};
pub(crate) use work_group::{get_work_group, list_work_groups};
