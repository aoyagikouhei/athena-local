//! Trino の結果を Athena の ResultSet に写す。

mod athena_type;
mod render;
mod result_set;
mod scalar;
mod value_type;

pub(crate) use result_set::{all_rows, column_infos, result_set};
