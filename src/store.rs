use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::failure::Failure;
use crate::results::ResultLocation;
use crate::trino::{Cancel, Outcome};

/// 止められたクエリの StateChangeReason（2026-09-14 に本番 Athena で実測）。
pub const CANCELLED_REASON: &str = "Query cancelled by user";

/// 実行中・実行済みクエリの置き場。プロセスが死ねば消える（本物の永続性は模さない）。
#[derive(Clone, Default)]
pub struct Store {
    executions: Arc<Mutex<HashMap<String, Execution>>>,
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
    /// GetQueryExecution がそのまま返す名前。既定は operation.rs 側で当てる。
    pub work_group: String,
    pub state: State,
    pub state_change_reason: Option<String>,
    pub submitted_at: f64,
    /// RUNNING になった（Trino に投げ始めた）時刻。止められて実行に進まなければ None。
    pub started_at: Option<f64>,
    pub completed_at: Option<f64>,
    /// 成功したときだけ入る。
    pub result: Option<Arc<Outcome>>,
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
}

impl Store {
    pub fn submit(&self, id: &str, submission: Submission) {
        let Submission {
            query,
            execution_parameters,
            catalog,
            database,
            result_location,
            work_group,
        } = submission;
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
            failure: None,
            cancel: Arc::default(),
        };
        self.lock().insert(id.to_string(), execution);
    }

    pub fn get(&self, id: &str) -> Option<Execution> {
        self.lock().get(id).cloned()
    }

    /// QUEUED からだけ進める。先に止められていれば false（呼び出し側は Trino に何も送らない）。
    pub fn mark_running(&self, id: &str) -> bool {
        match self.lock().get_mut(id) {
            Some(execution) if execution.state == State::Queued => {
                execution.state = State::Running;
                execution.started_at = Some(now());
                true
            }
            _ => false,
        }
    }

    /// 終端状態からは何も書かない。先に CANCELLED になっていれば、あとから来た結果は捨てる。
    pub fn finish(&self, id: &str, outcome: Result<Outcome, Failure>) {
        let mut executions = self.lock();
        let Some(execution) = executions.get_mut(id) else {
            return;
        };
        if execution.state.is_terminal() {
            return;
        }

        execution.completed_at = Some(now());
        match outcome {
            Ok(outcome) => {
                execution.state = State::Succeeded;
                execution.result = Some(Arc::new(outcome));
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
        let mut executions = self.lock();
        let Some(execution) = executions.get_mut(id) else {
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

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Execution>> {
        self.executions.lock().expect("store poisoned")
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

    fn user_failure(reason: &str) -> Failure {
        Failure {
            reason: reason.to_string(),
            category: crate::failure::USER,
            error_type: 1301,
            retryable: false,
        }
    }

    fn submitted() -> Store {
        let store = Store::default();
        store.submit(
            "id",
            Submission {
                query: "SELECT 1".to_string(),
                execution_parameters: Vec::new(),
                catalog: None,
                database: None,
                result_location: None,
                work_group: "primary".to_string(),
            },
        );
        store
    }

    #[test]
    fn 投入から成功までの状態が進む() {
        let store = Store::default();
        store.submit(
            "id",
            Submission {
                query: "SELECT ?".to_string(),
                execution_parameters: vec!["1".into()],
                catalog: Some("cat".into()),
                database: Some("db".into()),
                result_location: None,
                work_group: "primary".to_string(),
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

        store.finish("id", Ok(Outcome::default()));
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
        let store = Store::default();
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

        store.finish("id", Ok(Outcome::default()));
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
        store.finish("id", Ok(Outcome::default()));

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
        assert_eq!(Store::default().cancel("missing"), CancelOutcome::NotFound);
    }
}
