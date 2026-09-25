package local.athenajdbccheck;

import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * issue #111: 失敗した DDL の <id>.txt（athena-local が `FAILED: ` + 理由を置く）を、Athena JDBC 3.x が
 * 読みに行かないかを確かめるシナリオ（Main の 2 つ目の引数 "111"）。
 *
 * 構文チェックは通り、Trino が「無いテーブル」で FAILED にする 4 文を投げる（docs/caveats.md の
 * 失敗した文の結果ファイルの節）。どれも athena-local は <id>.txt を置き、.metadata は置かない。
 * ドライバが FAILED を見て SQLException を投げれば期待どおりなので、失敗に数えない
 * （Main.runProbe と同じ扱い）。読みに行ったかどうかは、スクリプト側が nginx のアクセスログで
 * この回の出力先の下の `.txt*` への GET を数えて判定する。
 *
 * 1 文ごとに機械可読な 1 行を出す:
 *   FAILED_DDL <label> status=EXPECTED_SQLEXCEPTION|NO_EXCEPTION|OTHER_EXCEPTION msg=<1 行>
 * 最後に SELECT 1 を流し、失敗のあとも接続が使えることを確かめる。
 */
final class FailedDdlScenario {
    private FailedDdlScenario() {
    }

    static void run(Connection conn, String runId) {
        String t = "nope_" + runId;
        probe(conn, "DROP_TABLE_iceberg", "DROP TABLE iceberg.default." + t);
        probe(conn, "SHOW_COLUMNS_hive", "SHOW COLUMNS FROM hive.default." + t);
        probe(conn, "DESCRIBE_hive", "DESCRIBE hive.default." + t);
        // ADD COLUMN（単数）は #208 から StartQueryExecution の時点で弾かれ、Trino まで届かなくなった
        // （docs/caveats.md の「Six ALTER TABLE spellings」）。実行時に FAILED のまま残る無引用の ALTER TABLE
        // として、対照の DROP COLUMN（IF EXISTS 無し）に差し替える。
        probe(conn, "ALTER_TABLE_DROP_COLUMN_hive", "ALTER TABLE hive.default." + t + " DROP COLUMN m");
        Main.runSelectCase(conn, "SELECT1_後続", "SELECT 1 AS n");
    }

    /** 失敗するはずの文を 1 本投げ、FAILED_DDL 行を出す。SQLException だけは失敗に数えない。 */
    private static void probe(Connection conn, String label, String sql) {
        System.out.println();
        System.out.println("--- " + label + " ---");
        System.out.println("SQL: " + sql);
        try (Statement st = conn.createStatement()) {
            boolean hasResultSet = st.execute(sql);
            int rows = 0;
            if (hasResultSet) {
                try (ResultSet rs = st.getResultSet()) {
                    while (rs.next()) {
                        rows++;
                    }
                }
            }
            line(label, "NO_EXCEPTION", "例外が出なかった（hasResultSet=" + hasResultSet + " rows=" + rows + "）");
            Main.failures++;
        } catch (SQLException e) {
            line(label, "EXPECTED_SQLEXCEPTION", Main.firstLine(e));
            e.printStackTrace(System.out);
        } catch (Exception e) {
            line(label, "OTHER_EXCEPTION", Main.firstLine(e));
            e.printStackTrace(System.out);
            Main.failures++;
        }
    }

    private static void line(String label, String status, String msg) {
        System.out.println("FAILED_DDL " + label + " status=" + status + " msg=" + msg);
    }
}
