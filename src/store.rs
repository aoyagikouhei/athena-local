use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::failure::Failure;
use crate::results::ResultLocation;
use crate::trino::{Cancel, Outcome};

/// 止められたクエリの StateChangeReason（2026-09-14 に本番 Athena で実測）。
pub const CANCELLED_REASON: &str = "Query cancelled by user";

/// 実行中・実行済みクエリの置き場。プロセスが死ねば消える（本物の永続性は模さない）。
/// 終端状態のものは保持期限を過ぎると捨てる（`Inner::sweep`）。
#[derive(Clone)]
pub struct Store {
    inner: Arc<Mutex<Inner>>,
}

struct Inner {
    executions: HashMap<String, Execution>,
    /// ClientRequestToken → その 1 回目の登録内容。フィンガープリントはここにだけ持つ。
    /// 書くのは `submit`、消すのは `sweep` だけ。
    tokens: HashMap<String, Claim>,
    /// 終端状態の実行情報を持っておく秒数（`completed_at` と同じ単位）。
    retention: f64,
}

impl Inner {
    /// 期限切れの終端状態の実行と、その ClientRequestToken を捨てる。
    /// completed_at が None（QUEUED / RUNNING）は捨てない。テストからは時刻を渡して直接呼ぶ。
    fn sweep(&mut self, now: f64) {
        let retention = self.retention;
        self.executions.retain(|_, execution| {
            execution
                .completed_at
                .is_none_or(|completed_at| now - completed_at < retention)
        });
        let executions = &self.executions;
        self.tokens
            .retain(|_, claim| executions.contains_key(&claim.id));
    }
}

#[derive(Clone)]
pub struct Execution {
    pub query: String,
    /// StartQueryExecution の ExecutionParameters（加工前）。
    pub execution_parameters: Vec<String>,
    /// QueryExecutionContext の Catalog / Database を受け取ったまま（省略なら None。既定は Trino に送るときに当てる。#167）。
    pub catalog: Option<String>,
    pub database: Option<String>,
    /// 結果の置き場所。OutputLocation（またはその既定）が無ければ None。
    pub result_location: Option<ResultLocation>,
    /// GetQueryExecution がそのまま返す名前。既定は operation/execution.rs 側で当てる。
    pub work_group: String,
    pub state: State,
    pub state_change_reason: Option<String>,
    pub submitted_at: f64,
    /// RUNNING になった（Trino に投げ始めた）時刻。止められて実行に進まなければ None。
    pub started_at: Option<f64>,
    pub completed_at: Option<f64>,
    /// 成功したときだけ入る。
    pub result: Option<Arc<Outcome>>,
    /// GetQueryResults の UpdateCount。完了時に `operation::execution` が文の種類と対象テーブルの形式から
    /// 決めて渡す（None = 省く。本物の null）。読む側で決め直さないのは、形式の判定が実行時にしか
    /// 取れないため（#160）。
    pub update_count: Option<i64>,
    /// GetQueryExecution が SQL だけで決まる分類の代わりに返す SubstatementType。完了時に
    /// `operation::execution` が対象の形式から決めて渡す（ビューへの DESCRIBE／SHOW COLUMNS の `DESC_VIEW`。
    /// 完了前と、それ以外の文は None。#173）。`update_count` と同じく、形式の判定が実行時にしか取れないため。
    pub substatement_type: Option<&'static str>,
    /// FAILED のときだけ入る。
    pub failure: Option<Failure>,
    /// 開始時点で「Trino に送らずに FAILED にする」と決まっていれば、その失敗（#227・#242）。
    pub immediate_failure: Option<ImmediateFailure>,
    /// GetQueryExecution が `query`・`database` の代わりに返す値。実行は `query` で行うが、本物が受け取った文の
    /// まま返す場合（カタログを落として実行したビューの SHOW COLUMNS。#242）に入る。
    pub reported: Option<Reported>,
    /// StopQueryExecution が立て、実行中のタスクが見る。
    pub cancel: Arc<Cancel>,
}

/// 開始時点で決まった失敗と、失敗の理由の結果ファイル（`.txt`）を置くか。本物は Glue で表が引けない失敗には
/// 何も置かず（#227）、Hive の ParseException には StateChangeReason と同じ `.txt` を置いた（#242）。
#[derive(Clone)]
pub struct ImmediateFailure {
    pub failure: Failure,
    pub writes_result_file: bool,
}

/// GetQueryExecution に返す Query と Context の Database（`Execution::reported`）。
#[derive(Clone)]
pub struct Reported {
    pub query: String,
    pub database: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum State {
    Queued,
    Running,
    Succeeded,
    Failed,
    Cancelled,
}

/// Store::cancel の結果。
#[derive(PartialEq, Eq, Debug)]
pub enum CancelOutcome {
    /// QUEUED / RUNNING だったので CANCELLED にした。
    Cancelled,
    /// 既に終わっていたので何もしていない（本物も 200 を返す）。
    AlreadyFinished,
    NotFound,
}

/// 同じ ClientRequestToken の再送かどうかを決める値。本物が比較する 4 つだけを持つ
/// （2026-09-17 実測: ExecutionParameters と WorkGroup は比較されない。Catalog は 2026-09-24 実測:
/// 大文字小文字だけの違いも実在しない名前も衝突。#150）。id を焼き込む前・既定を当てる前の生の
/// 値で比べる。
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Fingerprint {
    pub query: String,
    pub catalog: Option<String>,
    pub database: Option<String>,
    pub output_location: Option<String>,
}

/// tokens の値。フィンガープリントはここにだけ持つ（Execution には持たせない）。
struct Claim {
    fingerprint: Fingerprint,
    id: String,
}

/// Store::submit の結果。
#[derive(Debug, PartialEq, Eq)]
pub enum SubmitOutcome {
    /// 新しい実行を登録した。
    Created,
    /// 同じトークン・同じフィンガープリントの再送。新しい実行は作らず、既存の id を返す。
    Existing(String),
    /// 同じトークンでフィンガープリントが違う。
    Conflict,
}

/// Store::submit にまとめて渡す投入時の情報。引数の数を抑えるための入れ物
/// （クレート内の他の層と違い、あえて athena.rs 型は使わない）。
pub struct Submission {
    pub query: String,
    /// StartQueryExecution の ExecutionParameters(加工前)。
    pub execution_parameters: Vec<String>,
    pub catalog: Option<String>,
    pub database: Option<String>,
    pub result_location: Option<ResultLocation>,
    pub work_group: String,
    /// ClientRequestToken。operation/start_request.rs が必須項目として検証済みなので常に有効な値。
    pub token: String,
    pub fingerprint: Fingerprint,
    /// 開始時点で決まった失敗（`Execution::immediate_failure`）。
    pub immediate_failure: Option<ImmediateFailure>,
    /// GetQueryExecution に返す値（`Execution::reported`）。
    pub reported: Option<Reported>,
}

impl Store {
    /// 保持期限は終端状態になってから（`completed_at` から）の経過時間。
    pub fn new(retention: Duration) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Inner {
                executions: HashMap::new(),
                tokens: HashMap::new(),
                retention: retention.as_secs_f64(),
            })),
        }
    }

    /// 1 回のロックの中で判定する。対応表に無ければ登録して Created、あってフィンガープリントが
    /// 一致すれば何も登録せず Existing(既存の id)、一致しなければ Conflict。
    pub fn submit(&self, id: &str, submission: Submission) -> SubmitOutcome {
        let Submission {
            query,
            execution_parameters,
            catalog,
            database,
            result_location,
            work_group,
            token,
            fingerprint,
            immediate_failure,
            reported,
        } = submission;

        let mut inner = self.lock();

        if let Some(claim) = inner.tokens.get(&token) {
            return if claim.fingerprint == fingerprint {
                SubmitOutcome::Existing(claim.id.clone())
            } else {
                SubmitOutcome::Conflict
            };
        }

        let execution = Execution {
            query,
            execution_parameters,
            catalog,
            database,
            result_location,
            work_group,
            state: State::Queued,
            state_change_reason: None,
            submitted_at: now(),
            started_at: None,
            completed_at: None,
            result: None,
            update_count: None,
            substatement_type: None,
            failure: None,
            immediate_failure,
            reported,
            cancel: Arc::default(),
        };
        inner.executions.insert(id.to_string(), execution);
        inner.tokens.insert(
            token,
            Claim {
                fingerprint,
                id: id.to_string(),
            },
        );
        SubmitOutcome::Created
    }

    pub fn get(&self, id: &str) -> Option<Execution> {
        self.lock().executions.get(id).cloned()
    }

    /// QUEUED からだけ進める。先に止められていれば false（呼び出し側は Trino に何も送らない）。
    pub fn mark_running(&self, id: &str) -> bool {
        match self.lock().executions.get_mut(id) {
            Some(execution) if execution.state == State::Queued => {
                execution.state = State::Running;
                execution.started_at = Some(now());
                true
            }
            _ => false,
        }
    }

    /// 終端状態からは何も書かない。先に CANCELLED になっていれば、あとから来た結果は捨てる。
    pub fn finish(
        &self,
        id: &str,
        outcome: Result<(Outcome, Option<i64>, Option<&'static str>), Failure>,
    ) {
        let mut inner = self.lock();
        let Some(execution) = inner.executions.get_mut(id) else {
            return;
        };
        if execution.state.is_terminal() {
            return;
        }

        execution.completed_at = Some(now());
        match outcome {
            Ok((outcome, update_count, substatement_type)) => {
                execution.state = State::Succeeded;
                execution.result = Some(Arc::new(outcome));
                execution.update_count = update_count;
                execution.substatement_type = substatement_type;
            }
            Err(failure) => {
                execution.state = State::Failed;
                execution.state_change_reason = Some(failure.reason.clone());
                execution.failure = Some(failure);
            }
        }
    }

    /// 状態はここで同期に CANCELLED にする。Trino への DELETE は実行中のタスクが送る。
    pub fn cancel(&self, id: &str) -> CancelOutcome {
        let mut inner = self.lock();
        let Some(execution) = inner.executions.get_mut(id) else {
            return CancelOutcome::NotFound;
        };
        if execution.state.is_terminal() {
            return CancelOutcome::AlreadyFinished;
        }

        execution.state = State::Cancelled;
        execution.state_change_reason = Some(CANCELLED_REASON.to_string());
        execution.completed_at = Some(now());
        execution.cancel.request();
        CancelOutcome::Cancelled
    }

    /// ロックを取り、続けて期限切れを捨てる。公開メソッドはすべてここを通る。
    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        let mut inner = self.inner.lock().expect("store poisoned");
        inner.sweep(now());
        inner
    }
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Queued => "QUEUED",
            State::Running => "RUNNING",
            State::Succeeded => "SUCCEEDED",
            State::Failed => "FAILED",
            State::Cancelled => "CANCELLED",
        }
    }

    pub fn is_terminal(self) -> bool {
        matches!(self, State::Succeeded | State::Failed | State::Cancelled)
    }
}

// finish() は Result を move で受けるため、Outcome は Clone でなくてよい。
fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests;
