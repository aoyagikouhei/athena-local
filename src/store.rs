use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::trino::Outcome;

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
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum State {
    Queued,
    Running,
    Succeeded,
    Failed,
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
        };
        self.executions
            .lock()
            .expect("store poisoned")
            .insert(id.to_string(), execution);
    }

    pub fn get(&self, id: &str) -> Option<Execution> {
        self.executions
            .lock()
            .expect("store poisoned")
            .get(id)
            .cloned()
    }

    pub fn mark_running(&self, id: &str) {
        self.update(id, |execution| execution.state = State::Running);
    }

    pub fn finish(&self, id: &str, outcome: Result<Outcome, String>) {
        self.update(id, |execution| {
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
        });
    }

    fn update(&self, id: &str, apply: impl FnOnce(&mut Execution)) {
        if let Some(execution) = self.executions.lock().expect("store poisoned").get_mut(id) {
            apply(execution);
        }
    }
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Queued => "QUEUED",
            State::Running => "RUNNING",
            State::Succeeded => "SUCCEEDED",
            State::Failed => "FAILED",
        }
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

        store.mark_running("id");
        assert_eq!(store.get("id").unwrap().state, State::Running);

        store.finish("id", Ok(Outcome::default()));
        let finished = store.get("id").unwrap();
        assert_eq!(finished.state, State::Succeeded);
        assert!(finished.result.is_some());
        assert!(finished.completed_at.is_some());
    }

    #[test]
    fn 失敗すると理由が残り結果は入らない() {
        let store = Store::default();
        store.submit("id", "SELECT 1", Vec::new(), None, None);

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
}
