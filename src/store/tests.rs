use super::*;

use crate::config::DEFAULT_RETENTION;

fn user_failure(reason: &str) -> Failure {
    Failure {
        reason: reason.to_string(),
        error_message: None,
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
            immediate_failure: None,
            reported: None,
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
            immediate_failure: None,
            reported: None,
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

    store.finish("id", Ok((Outcome::default(), None, None)));
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

    store.finish("id", Ok((Outcome::default(), None, None)));
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
    store.finish("id", Ok((Outcome::default(), None, None)));

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
        immediate_failure: None,
        reported: None,
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
    store.finish("id", Ok((Outcome::default(), None, None)));

    // sweep_at を呼ばない。lock() が掃除を駆動していなければ残ってしまう。
    assert!(store.get("id").is_none());
}

#[test]
fn 終わった実行は保持期限を過ぎると消える() {
    let store = submitted();
    store.finish("id", Ok((Outcome::default(), None, None)));
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
    store.finish("id", Ok((Outcome::default(), None, None)));
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
    store.finish("id", Ok((Outcome::default(), None, None)));
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
    store.finish("id1", Ok((Outcome::default(), None, None)));
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
