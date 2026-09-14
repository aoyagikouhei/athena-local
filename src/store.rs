use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

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
    pub state: State,
    pub state_change_reason: Option<String>,
    pub submitted_at: f64,
    pub completed_at: Option<f64>,
    /// 成功したときだけ入る。
    pub result: Option<Arc<Outcome>>,
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

impl Store {
    pub fn submit(
        &self,
        id: &str,
        query: &str,
        execution_parameters: Vec<String>,
        catalog: Option<String>,
        database: Option<String>,
    ) {
        let execution = Execution {
            query: query.to_string(),
            execution_parameters,
            catalog,
            database,
            state: State::Queued,
            state_change_reason: None,
            submitted_at: now(),
            completed_at: None,
            result: None,
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
                true
            }
            _ => false,
        }
    }

    /// 終端状態からは何も書かない。先に CANCELLED になっていれば、あとから来た結果は捨てる。
    pub fn finish(&self, id: &str, outcome: Result<Outcome, String>) {
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
            Err(message) => {
                execution.state = State::Failed;
                execution.state_change_reason = Some(message);
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

    fn submitted() -> Store {
        let store = Store::default();
        store.submit("id", "SELECT 1", Vec::new(), None, None);
        store
    }

    #[test]
    fn 投入から成功までの状態が進む() {
        let store = Store::default();
        store.submit(
            "id",
            "SELECT ?",
            vec!["1".into()],
            Some("cat".into()),
            Some("db".into()),
        );

        let execution = store.get("id").expect("登録されていない");
        assert_eq!(execution.state, State::Queued);
        assert_eq!(execution.execution_parameters, ["1"]);
        assert_eq!(execution.catalog.as_deref(), Some("cat"));
        assert!(execution.result.is_none());

        assert!(store.mark_running("id"));
        assert_eq!(store.get("id").unwrap().state, State::Running);

        store.finish("id", Ok(Outcome::default()));
        let finished = store.get("id").unwrap();
        assert_eq!(finished.state, State::Succeeded);
        assert!(finished.result.is_some());
        assert!(finished.completed_at.is_some());
    }

    #[test]
    fn 失敗すると理由が残り結果は入らない() {
        let store = submitted();

        store.finish("id", Err("TABLE_NOT_FOUND: t".to_string()));

        let execution = store.get("id").unwrap();
        assert_eq!(execution.state, State::Failed);
        assert_eq!(
            execution.state_change_reason.as_deref(),
            Some("TABLE_NOT_FOUND: t")
        );
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
        store.finish("id", Err("late".to_string()));

        let execution = store.get("id").unwrap();
        assert_eq!(execution.state, State::Cancelled);
        assert!(execution.result.is_none());
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
