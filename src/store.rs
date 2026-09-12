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
    pub catalog: Option<String>,
    pub database: Option<String>,
    pub state: State,
    pub state_change_reason: Option<String>,
    pub submitted_at: f64,
    pub completed_at: Option<f64>,
    /// 成功したときだけ入る。
    pub result: Option<Arc<Outcome>>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum State {
    Queued,
    Running,
    Succeeded,
    Failed,
}

impl Store {
    pub fn submit(&self, id: &str, query: &str, catalog: Option<String>, database: Option<String>) {
        let execution = Execution {
            query: query.to_string(),
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
