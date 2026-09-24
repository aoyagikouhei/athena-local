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
    /// FAILED のときだけ入る。
    pub failure: Option<Failure>,
    /// StopQueryExecution が立て、実行中のタスクが見る。
    pub cancel: Arc<Cancel>,
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
    /// ClientRequestToken。operation/execution.rs が必須項目として検証済みなので常に有効な値。
    pub token: String,
    pub fingerprint: Fingerprint,
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
            failure: None,
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
    pub fn finish(&self, id: &str, outcome: Result<(Outcome, Option<i64>), Failure>) {
        let mut inner = self.lock();
        let Some(execution) = inner.executions.get_mut(id) else {
            return;
        };
        if execution.state.is_terminal() {
            return;
        }

        execution.completed_at = Some(now());
        match outcome {
            Ok((outcome, update_count)) => {
                execution.state = State::Succeeded;
                execution.result = Some(Arc::new(outcome));
                execution.update_count = update_count;
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
mod tests {
    use super::*;

    use crate::config::DEFAULT_RETENTION;

    fn user_failure(reason: &str) -> Failure {
        Failure {
            reason: reason.to_string(),
            category: crate::failure::USER,
            error_type: 1301,
            retryable: false,
        }
    }

    fn fingerprint(query: &str) -> Fingerprint {
        Fingerprint {
            query: query.to_string(),
            catalog: None,
            database: None,
            output_location: None,
        }
    }

    /// テストごとに別の値にする 32 文字以上の固定トークン。
    fn test_token(name: &str) -> String {
        format!("token-{name}-0123456789abcdef0123456789")
    }

    /// 掃除が起きない長さの期限を持つ Store。
    fn store() -> Store {
        Store::new(DEFAULT_RETENTION)
    }

    /// 時刻を指定して掃除する（本番は lock() が now() で呼ぶ）。
    fn sweep_at(store: &Store, now: f64) {
        store.inner.lock().expect("store poisoned").sweep(now);
    }

    /// 保持期限の秒数。境界の計算に使う（リテラルの 3600 を増やさない）。
    fn retention_seconds() -> f64 {
        DEFAULT_RETENTION.as_secs_f64()
    }

    fn submitted() -> Store {
        let store = store();
        store.submit(
            "id",
            Submission {
                query: "SELECT 1".to_string(),
                execution_parameters: Vec::new(),
                catalog: None,
                database: None,
                result_location: None,
                work_group: "primary".to_string(),
                token: test_token("submitted"),
                fingerprint: fingerprint("SELECT 1"),
            },
        );
        store
    }

    #[test]
    fn 投入から成功までの状態が進む() {
        let store = store();
        store.submit(
            "id",
            Submission {
                query: "SELECT ?".to_string(),
                execution_parameters: vec!["1".into()],
                catalog: Some("cat".into()),
                database: Some("db".into()),
                result_location: None,
                work_group: "primary".to_string(),
                token: test_token("progress"),
                fingerprint: fingerprint("SELECT ?"),
            },
        );

        let execution = store.get("id").expect("登録されていない");
        assert_eq!(execution.state, State::Queued);
        assert_eq!(execution.execution_parameters, ["1"]);
        assert_eq!(execution.catalog.as_deref(), Some("cat"));
        assert!(execution.result.is_none());

        assert!(execution.started_at.is_none());
        assert!(store.mark_running("id"));
        let running = store.get("id").unwrap();
        assert_eq!(running.state, State::Running);
        assert!(running.started_at.is_some());

        store.finish("id", Ok((Outcome::default(), None)));
        let finished = store.get("id").unwrap();
        assert_eq!(finished.state, State::Succeeded);
        assert!(finished.result.is_some());
        assert!(finished.completed_at.is_some());
    }

    #[test]
    fn 失敗すると理由が残り結果は入らない() {
        let store = submitted();

        store.finish("id", Err(user_failure("TABLE_NOT_FOUND: t")));

        let execution = store.get("id").unwrap();
        assert_eq!(execution.state, State::Failed);
        assert_eq!(
            execution.state_change_reason.as_deref(),
            Some("TABLE_NOT_FOUND: t")
        );
        assert_eq!(execution.failure, Some(user_failure("TABLE_NOT_FOUND: t")));
        assert!(execution.result.is_none());
    }

    #[test]
    fn 知らない_id_は取れない() {
        let store = store();
        assert!(store.get("missing").is_none());
    }

    #[test]
    fn 実行中に止めると_cancelled_になり取り消し要求が立つ() {
        let store = submitted();
        store.mark_running("id");

        assert_eq!(store.cancel("id"), CancelOutcome::Cancelled);

        let execution = store.get("id").unwrap();
        assert_eq!(execution.state, State::Cancelled);
        assert_eq!(
            execution.state_change_reason.as_deref(),
            Some(CANCELLED_REASON)
        );
        assert!(execution.completed_at.is_some());
        assert!(execution.cancel.is_requested());
    }

    #[test]
    fn 投入直後に止めると実行には進めない() {
        let store = submitted();

        assert_eq!(store.cancel("id"), CancelOutcome::Cancelled);

        assert!(!store.mark_running("id"));
        assert_eq!(store.get("id").unwrap().state, State::Cancelled);
    }

    #[test]
    fn 止めたあとに届いた結果は捨てる() {
        let store = submitted();
        store.mark_running("id");
        store.cancel("id");

        store.finish("id", Ok((Outcome::default(), None)));
        store.finish("id", Err(user_failure("late")));

        let execution = store.get("id").unwrap();
        assert_eq!(execution.state, State::Cancelled);
        assert!(execution.result.is_none());
        assert!(execution.failure.is_none(), "止めたクエリに失敗は残らない");
        assert_eq!(
            execution.state_change_reason.as_deref(),
            Some(CANCELLED_REASON)
        );
    }

    #[test]
    fn 終わったクエリは止めても変わらない() {
        let store = submitted();
        store.mark_running("id");
        store.finish("id", Ok((Outcome::default(), None)));

        assert_eq!(store.cancel("id"), CancelOutcome::AlreadyFinished);

        let execution = store.get("id").unwrap();
        assert_eq!(execution.state, State::Succeeded);
        assert!(!execution.cancel.is_requested());
        // 2 回目も同じ。
        assert_eq!(store.cancel("id"), CancelOutcome::AlreadyFinished);
    }

    #[test]
    fn 止めたクエリをもう一度止めても変わらない() {
        let store = submitted();
        store.cancel("id");
        assert_eq!(store.cancel("id"), CancelOutcome::AlreadyFinished);
    }

    #[test]
    fn 知らない_id_は止められない() {
        assert_eq!(store().cancel("missing"), CancelOutcome::NotFound);
    }

    fn submission_with_token(query: &str, token: &str) -> Submission {
        Submission {
            query: query.to_string(),
            execution_parameters: Vec::new(),
            catalog: None,
            database: None,
            result_location: None,
            work_group: "primary".to_string(),
            token: token.to_string(),
            fingerprint: fingerprint(query),
        }
    }

    #[test]
    fn submit_は同じトークンなら既存の_id_を返す() {
        let store = store();
        assert_eq!(
            store.submit("id1", submission_with_token("SELECT 1", "tok")),
            SubmitOutcome::Created
        );

        assert_eq!(
            store.submit("id2", submission_with_token("SELECT 1", "tok")),
            SubmitOutcome::Existing("id1".to_string())
        );
        // 新しい実行は登録されない。
        assert!(store.get("id2").is_none());
    }

    #[test]
    fn submit_はフィンガープリントが違えば_conflict() {
        let store = store();
        assert_eq!(
            store.submit("id1", submission_with_token("SELECT 1", "tok")),
            SubmitOutcome::Created
        );

        assert_eq!(
            store.submit("id2", submission_with_token("SELECT 2", "tok")),
            SubmitOutcome::Conflict
        );
        assert!(store.get("id2").is_none());
    }

    #[test]
    fn ロックを取ると期限切れの実行が消える() {
        let store = Store::new(Duration::ZERO);
        store.submit("id", submission_with_token("SELECT 1", &test_token("zero")));
        store.finish("id", Ok((Outcome::default(), None)));

        // sweep_at を呼ばない。lock() が掃除を駆動していなければ残ってしまう。
        assert!(store.get("id").is_none());
    }

    #[test]
    fn 終わった実行は保持期限を過ぎると消える() {
        let store = submitted();
        store.finish("id", Ok((Outcome::default(), None)));
        let completed = store
            .get("id")
            .unwrap()
            .completed_at
            .expect("完了時刻が無い");

        sweep_at(&store, completed + retention_seconds() + 1.0);

        assert!(store.get("id").is_none());
    }

    #[test]
    fn 保持期限ちょうどで消える() {
        let store = submitted();
        store.finish("id", Ok((Outcome::default(), None)));
        let completed = store
            .get("id")
            .unwrap()
            .completed_at
            .expect("完了時刻が無い");

        sweep_at(&store, completed + retention_seconds());

        assert!(store.get("id").is_none());
    }

    #[test]
    fn 保持期限の手前では消えない() {
        let store = submitted();
        store.finish("id", Ok((Outcome::default(), None)));
        let completed = store
            .get("id")
            .unwrap()
            .completed_at
            .expect("完了時刻が無い");

        sweep_at(&store, completed + retention_seconds() - 1.0);

        assert!(store.get("id").is_some());
    }

    #[test]
    fn 実行中の実行は保持期限を過ぎても消えない() {
        let store = submitted();

        sweep_at(&store, now() + 1e9);
        assert!(store.get("id").is_some(), "QUEUED は捨てない");

        store.mark_running("id");
        sweep_at(&store, now() + 1e9);
        assert!(store.get("id").is_some(), "RUNNING は捨てない");
    }

    #[test]
    fn 捨てた実行のトークンも消えるので同じトークンで新しい実行になる() {
        let store = store();
        let token = test_token("expired");
        assert_eq!(
            store.submit("id1", submission_with_token("SELECT 1", &token)),
            SubmitOutcome::Created
        );
        store.finish("id1", Ok((Outcome::default(), None)));
        let completed = store
            .get("id1")
            .unwrap()
            .completed_at
            .expect("完了時刻が無い");

        // 掃除の前は同じトークンの再送。
        assert_eq!(
            store.submit("id2", submission_with_token("SELECT 1", &token)),
            SubmitOutcome::Existing("id1".to_string())
        );

        sweep_at(&store, completed + retention_seconds() + 1.0);

        assert_eq!(
            store.submit("id2", submission_with_token("SELECT 1", &token)),
            SubmitOutcome::Created
        );
        assert!(store.get("id2").is_some());
    }
}
