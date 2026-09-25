package local.athenajdbccheck;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Properties;

/**
 * issue #39 / #46 実機検証: 列 0 個の .metadata（DROP TABLE Iceberg = 41 バイト）を、公式 Athena JDBC
 * ドライバの既定 ResultFetcher=auto（S3 を直接読む経路）が例外なく読めるかを確かめる。
 *
 * ALTER TABLE ADD COLUMN（Hive、.metadata 38 バイト）のケースは #208 で削除した。単数形の ADD COLUMN は
 * StartQueryExecution の時点で弾かれるようになり、athena-local からはもう届かない（docs/caveats.md の
 * 「Six ALTER TABLE spellings」）。38 バイトの .metadata を JDBC が読めることは、Rust 側の結合テスト
 * （tests/metadata.rs）が引き続き守る。
 *
 * 接続先は athena-local（本物の AWS は使わない）。
 *
 * 引数で ResultFetcher を切り替える（issue #46。1 ラウンドで対照まで測るため）:
 *   引数なし   -> 明示せず既定のまま（= auto。今回の焦点）
 *   "S3"       -> S3 直読みを明示（auto が S3 を選ばなかった場合でも同じ経路を通す対照）
 *   "GetQueryResults" -> API 経由（.metadata を読まない対照）
 *
 * 2 つ目の引数でシナリオを切り替える（issue #57。46 の 4 ケースは引数なしのまま変えない）:
 *   無し / "46" -> 上の 4 ケース（列 0 個の .metadata）
 *   "57"        -> SHOW 文の .txt.metadata（SHOW TABLES 以外の SHOW を JDBC が読めるか）。
 *                  Trino の文法に無い SHOW DATABASES / SHOW PARTITIONS / SHOW TBLPROPERTIES は
 *                  Athena の原文をそのまま投げて、athena-local がどう弾くかを記録する（REJECTED は失敗に数えない）。
 *                  各ケースは機械可読な 1 行 `RESULT <label> rows=<n> cols=<c> status=<...>` を出し、
 *                  スクリプト側が ResultFetcher の違いで行数が変わらないことを突き合わせる。
 *                  issue #163 で SHOW CREATE VIEW と Iceberg のテーブルへの SHOW CREATE TABLE を足した
 *                  （.txt と .txt.metadata を binary/octet-stream で置く 2 文）。
 *   "111"       -> 失敗した DDL の <id>.txt を読みに行かないか（issue #111。FailedDdlScenario）
 *
 * 3 つ目の引数は OutputLocation、4 つ目は JDBC URL（issue #111。旧版ドライバのループで版ごとに
 * 出力先を分け、URL を jdbc:athena:// にそろえるため）。無い・空なら従来の値のまま。
 * 実際に使った値を `CONFIG fetcher=<x> scenario=<y> url=<z> output=<w>` の 1 行で出し（未指定の
 * fetcher は `-`）、スクリプト側が要求と照合して引数の受け渡しの誤りを見つける。
 * 接続の直後に `SELECT 1` を 1 本流して `PREFLIGHT ok` か `PREFLIGHT failed: <例外の 1 行目>` を出す。
 * 接続そのものの失敗も PREFLIGHT failed に数え、そのときは終了コード 3 で止まる。
 */
public final class Main {
    // FailedDdlScenario（issue #111）から数えるため package-private にしている。
    static int failures = 0;

    public static void main(String[] args) throws Exception {
        // 引数なしは「明示しない」= 既定の auto。空文字も同じ扱いにする。
        String fetcher = (args.length > 0 && !args[0].isEmpty()) ? args[0] : null;
        String scenario = (args.length > 1 && !args[1].isEmpty()) ? args[1] : "46";
        String output = (args.length > 2 && !args[2].isEmpty()) ? args[2] : "s3://athena-results/e2e-jdbc/";
        String url = (args.length > 3 && !args[3].isEmpty()) ? args[3] : "jdbc:awsathena://";
        String runId = Long.toString(System.currentTimeMillis());
        String tIcebergDrop = "t_jdbc_drop_iceberg_" + runId;
        String tHiveDrop = "t_jdbc_drop_hive_" + runId;

        Properties props = new Properties();
        props.setProperty("Region", "ap-northeast-1");
        props.setProperty("AthenaEndpoint", "https://tls-proxy:8443");
        props.setProperty("S3Endpoint", "https://tls-proxy:9443");
        props.setProperty("OutputLocation", output);
        props.setProperty("User", "minioadmin"); // ローカル専用のダミー。本物の AWS 認証情報ではない。
        props.setProperty("Password", "minioadmin");
        props.setProperty("Catalog", "iceberg");
        props.setProperty("Database", "default");
        if (fetcher != null) {
            props.setProperty("ResultFetcher", fetcher);
        }
        // 引数なしのときは ResultFetcher を指定しない = 既定の "auto"（今回の焦点）。

        System.out.println("=== 接続 ===");
        System.out.println("CONFIG fetcher=" + (fetcher == null ? "-" : fetcher) + " scenario=" + scenario
                + " url=" + url + " output=" + output);
        System.out.println("ResultFetcher: " + (fetcher == null ? "(未指定 = 既定の auto)" : fetcher));
        System.out.println("URL: " + url + "  (AthenaEndpoint/S3Endpoint は上記 Properties 経由)");
        Connection opened = openWithPreflight(url, props);
        if (opened == null) {
            failures++;
            System.out.println();
            System.out.println("=== 総括 === failures=" + failures);
            System.exit(3);
        }
        try (Connection conn = opened) {
            System.out.println("接続成功: " + conn.getClass());

            if (scenario.equals("57")) {
                runShowScenario(conn, runId);
            } else if (scenario.equals("111")) {
                FailedDdlScenario.run(conn, runId);
            } else {
                runZeroColumnScenario(conn, tIcebergDrop, tHiveDrop);
            }
        } catch (Exception e) {
            System.out.println("!!! 接続自体が失敗した !!!");
            e.printStackTrace(System.out);
            failures++;
        } finally {
            System.out.println();
            System.out.println("=== 総括 === failures=" + failures);
        }
        if (failures > 0) {
            System.exit(1);
        }
    }

    /**
     * 接続して SELECT 1 を最後まで読む（issue #111）。旧版ドライバが接続や .csv / .csv.metadata の読み取りで
     * 止まるかを、シナリオの前に 1 行で分かるようにする。失敗したら null を返す。
     */
    private static Connection openWithPreflight(String url, Properties props) {
        Connection conn = null;
        try {
            // 3.0.0 と 3.1.0 の jar には ServiceLoader の登録（META-INF/services/java.sql.Driver）が無いので、
            // クラスを明示して読み込む（登録のある版でも無害。クラスが無ければ PREFLIGHT failed）。
            Class.forName("com.amazon.athena.jdbc.AthenaDriver");
            conn = DriverManager.getConnection(url, props);
            try (Statement st = conn.createStatement();
                 ResultSet rs = st.executeQuery("SELECT 1 AS preflight")) {
                while (rs.next()) {
                    rs.getString(1);
                }
            }
            System.out.println("PREFLIGHT ok");
            return conn;
        } catch (Exception e) {
            System.out.println("PREFLIGHT failed: " + firstLine(e));
            e.printStackTrace(System.out);
            if (conn != null) {
                try {
                    conn.close();
                } catch (Exception ignored) {
                    // 閉じられなくても判定は PREFLIGHT failed のまま変わらない。
                }
            }
            return null;
        }
    }

    /** 例外の「クラス名: メッセージ」の 1 行目（判定の行を 1 行に保つため）。 */
    static String firstLine(Throwable e) {
        return String.valueOf(e).split("\\R", 2)[0];
    }

    // ---------------- issue #46: 列 0 個の .metadata ----------------

    private static void runZeroColumnScenario(Connection conn, String tIcebergDrop, String tHiveDrop) {
        // --- セットアップ（athena-local 経由。verify.sh の直接 Trino 投入とは別に、
        //     JDBC の execute 経路そのものを使って検証対象のテーブルを作る） ---
        runSetup(conn, "CREATE TABLE iceberg.default." + tIcebergDrop + " AS SELECT 1 AS n");
        runSetup(conn, "CREATE TABLE hive.default." + tHiveDrop + " AS SELECT 1 AS n");

        // ケース 1: DROP TABLE (Iceberg) -> .metadata 41 バイト（列 0 個）
        runCase(conn, "ケース1 DROP_TABLE_iceberg(41B)", "DROP TABLE iceberg.default." + tIcebergDrop);

        // ケース 2（#208 前は 3）: DROP TABLE (Hive) -> .metadata を置かない従来経路（対照）。
        // ALTER TABLE ... ADD COLUMN (Hive) -> 38 バイトのケースは #208 で削除した（クラス冒頭の javadoc）。
        runCase(conn, "ケース2 DROP_TABLE_hive(対照・metadata無し)", "DROP TABLE hive.default." + tHiveDrop);

        // ケース 3（#208 前は 4）: 通常の SELECT -> 回帰確認
        runSelectCase(conn, "ケース3 SELECT_回帰確認", "SELECT 1 AS n");
    }

    // ---------------- issue #57: SHOW 文の .txt.metadata ----------------

    private static void runShowScenario(Connection conn, String runId) {
        String t = "hive.default.t_jdbc_show_" + runId;
        // SHOW PARTITIONS の対象になるよう、パーティション付きの Hive テーブルに 2 パーティション分の行を入れる。
        runSetup(conn, "CREATE TABLE " + t + " (n integer, p varchar) WITH (partitioned_by = ARRAY['p'])");
        runSetup(conn, "INSERT INTO " + t + " VALUES (1, 'a'), (2, 'b')");

        // 対照: SHOW TABLES（#5 で JDBC が読めることを実機で確かめ済み）。前のラウンドが作ったテーブルが
        // 残っていても行数が変わらないよう、自分のテーブルだけに絞る。
        runShowCase(conn, "SHOW_TABLES(対照)", "SHOW TABLES IN hive.default LIKE 't_jdbc_show_" + runId + "'");
        // 焦点 1: SHOW DATABASES。Trino の同義文 SHOW SCHEMAS（athena-local は SHOW_DATABASES に分類する）と、
        //         Athena の原文（Trino の文法に無い）の両方を流す。
        runShowCase(conn, "SHOW_SCHEMAS", "SHOW SCHEMAS");
        runProbe(conn, "SHOW_DATABASES(原文)", "SHOW DATABASES");
        // 焦点 2: SHOW COLUMNS（Trino も Athena も同じ書き方。Trino は 4 列を返す）
        runShowCase(conn, "SHOW_COLUMNS", "SHOW COLUMNS FROM " + t);
        // 焦点 3・4: Trino の文法に無い 2 文。原文のまま投げて、どこで弾かれるかを記録する。
        runProbe(conn, "SHOW_PARTITIONS(原文)", "SHOW PARTITIONS " + t);
        runProbe(conn, "SHOW_TBLPROPERTIES(原文)", "SHOW TBLPROPERTIES " + t);
        // 対照: Trino でパーティションを見る書き方（SELECT なので .csv 経路）
        runShowCase(conn, "SELECT_partitions(対照)", "SELECT * FROM hive.default.\"t_jdbc_show_" + runId + "$partitions\"");

        // 焦点 5・6（issue #163）: #151 で本体も .metadata も binary/octet-stream にした 2 文。.txt.metadata は
        // 素の protobuf（先頭はエンジン ID）のままで、JDBC が読めるかは未確認だった。
        String v = "hive.default.v_jdbc_show_" + runId;
        String tIceberg = "iceberg.default.t_jdbc_show_iceberg_" + runId;
        runSetup(conn, "CREATE VIEW " + v + " AS SELECT 1 AS n");
        runSetup(conn, "CREATE TABLE " + tIceberg + " (n integer)");
        runShowCase(conn, "SHOW_CREATE_VIEW", "SHOW CREATE VIEW " + v);
        runShowCase(conn, "SHOW_CREATE_TABLE_iceberg", "SHOW CREATE TABLE " + tIceberg);
    }

    /** 結果を最後まで読み、RESULT 行を出す。例外は失敗に数える。 */
    private static void runShowCase(Connection conn, String label, String sql) {
        System.out.println();
        System.out.println("--- " + label + " ---");
        System.out.println("SQL: " + sql);
        try (Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(sql)) {
            ResultSetMetaData md = rs.getMetaData();
            int cols = md.getColumnCount();
            StringBuilder names = new StringBuilder();
            for (int i = 1; i <= cols; i++) {
                names.append(i > 1 ? "," : "").append(md.getColumnName(i)).append(':').append(md.getColumnTypeName(i));
            }
            System.out.println("ResultSetMetaData columnCount=" + cols + " columns=" + names);
            int rows = 0;
            while (rs.next()) {
                rows++;
                StringBuilder row = new StringBuilder();
                for (int i = 1; i <= cols; i++) {
                    row.append(i > 1 ? " | " : "").append(rs.getString(i));
                }
                System.out.println("  row: " + row);
            }
            System.out.println("RESULT " + label + " rows=" + rows + " cols=" + cols + " status=PASS");
        } catch (Exception e) {
            System.out.println("RESULT " + label + " rows=-1 cols=-1 status=FAIL");
            e.printStackTrace(System.out);
            failures++;
        }
    }

    /** Trino の文法に無い文。弾かれたら REJECTED（失敗に数えない）、通ったら PASS として行数を出す。 */
    private static void runProbe(Connection conn, String label, String sql) {
        System.out.println();
        System.out.println("--- " + label + " ---");
        System.out.println("SQL: " + sql);
        try (Statement st = conn.createStatement()) {
            boolean hasResultSet = st.execute(sql);
            int rows = 0;
            int cols = 0;
            if (hasResultSet) {
                try (ResultSet rs = st.getResultSet()) {
                    cols = rs.getMetaData().getColumnCount();
                    while (rs.next()) {
                        rows++;
                    }
                }
            }
            System.out.println("RESULT " + label + " rows=" + rows + " cols=" + cols + " status=PASS");
        } catch (SQLException e) {
            System.out.println("REJECTED " + label + ": " + e.getClass().getName() + ": " + e.getMessage());
            System.out.println("RESULT " + label + " rows=-1 cols=-1 status=REJECTED");
        } catch (Exception e) {
            System.out.println("RESULT " + label + " rows=-1 cols=-1 status=FAIL");
            e.printStackTrace(System.out);
            failures++;
        }
    }

    private static void runSetup(Connection conn, String sql) {
        System.out.println("[setup] " + sql);
        try (Statement st = conn.createStatement()) {
            st.execute(sql);
            System.out.println("[setup] OK");
        } catch (SQLException e) {
            System.out.println("[setup] 失敗（このケース以降がスキップされる可能性あり）");
            e.printStackTrace(System.out);
            failures++;
        }
    }

    private static void runCase(Connection conn, String label, String sql) {
        System.out.println();
        System.out.println("--- " + label + " ---");
        System.out.println("SQL: " + sql);
        try (Statement st = conn.createStatement()) {
            boolean hasResultSet = st.execute(sql);
            System.out.println("execute() 完了 hasResultSet=" + hasResultSet + " updateCount=" + st.getUpdateCount());
            if (hasResultSet) {
                try (ResultSet rs = st.getResultSet()) {
                    ResultSetMetaData md = rs.getMetaData();
                    System.out.println("ResultSetMetaData 取得成功 columnCount=" + md.getColumnCount());
                    int rows = 0;
                    while (rs.next()) {
                        rows++;
                    }
                    System.out.println("行取得完了 rows=" + rows);
                }
            }
            System.out.println(label + ": 例外なし（PASS）");
        } catch (Exception e) {
            System.out.println(label + ": 例外発生（要注目）");
            e.printStackTrace(System.out);
            failures++;
        }
    }

    // FailedDdlScenario（issue #111）の後続の SELECT 1 に使うため package-private にしている。
    static void runSelectCase(Connection conn, String label, String sql) {
        System.out.println();
        System.out.println("--- " + label + " ---");
        System.out.println("SQL: " + sql);
        try (Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(sql)) {
            ResultSetMetaData md = rs.getMetaData();
            System.out.println("ResultSetMetaData 取得成功 columnCount=" + md.getColumnCount());
            int rows = 0;
            while (rs.next()) {
                rows++;
                System.out.println("  row: n=" + rs.getString(1));
            }
            System.out.println("行取得完了 rows=" + rows);
            System.out.println(label + ": 例外なし（PASS）");
        } catch (Exception e) {
            System.out.println(label + ": 例外発生（要注目）");
            e.printStackTrace(System.out);
            failures++;
        }
    }
}
