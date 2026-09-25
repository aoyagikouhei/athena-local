//! SQL の字句処理と、athena-local が必要とする文の頭・句の認識を置く内部 crate（#192）。
//!
//! 完全なパーサは目指さず、SQL が正しいかどうかも判定しない。トークンと句は元の SQL での位置を持ち、
//! 書き換えは範囲の差し替えだけにする。規則と理由は docs/dev/decisions.md の「SQL の内部 crate（athena-sql）」。
//! 今あるのは #194 で athena-local の `src/catalog.rs` から中身を変えずに移した字句処理の道具で、
//! athena-local は `athena_sql::foo()` で呼ぶ。doc の中のパスは athena-local の `src/` からの相対。

mod cursor;
mod name;
mod trivia;
mod words;

pub use cursor::Cursor;
pub use name::{NamePart, QualifiedName, unquote};
pub use trivia::{comment_end, skip_leading_trivia, skip_quoted, skip_trivia};
pub use words::words;
