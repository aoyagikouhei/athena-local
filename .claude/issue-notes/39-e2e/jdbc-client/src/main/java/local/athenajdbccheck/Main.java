package local.athenajdbccheck;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Properties;

/**
 * issue #39 実機検証: 列 0 個の .metadata（DROP TABLE Iceberg = 41 バイト、
 * ALTER TABLE ADD COLUMN Hive = 38 バイト）を、公式 Athena JDBC ドライバの
 * 既定 ResultFetcher=auto（S3 を直接読む経路）が例外なく読めるかを確かめる。
 *
 * 接続先は athena-local（本物の AWS は使わない）。ResultFetcher は明示せず既定のままにする。
 */
public final class Main {
    private static int failures = 0;

    public static void main(String[] args) throws Exception {
        String runId = Long.toString(System.currentTimeMillis());
        String tIcebergDrop = "t_jdbc_drop_iceberg_" + runId;
        String tHiveDrop = "t_jdbc_drop_hive_" + runId;
        String tHiveAlter = "t_jdbc_alter_hive_" + runId;

        Properties props = new Properties();
        props.setProperty("Region", "ap-northeast-1");
        props.setProperty("AthenaEndpoint", "https://tls-proxy:8443");
        props.setProperty("S3Endpoint", "https://tls-proxy:9443");
        props.setProperty("OutputLocation", "s3://athena-results/e2e-jdbc/");
        props.setProperty("User", "minioadmin"); // ローカル専用のダミー。本物の AWS 認証情報ではない。
        props.setProperty("Password", "minioadmin");
        props.setProperty("Catalog", "iceberg");
        props.setProperty("Database", "default");
        // ResultFetcher は指定しない = 既定の "auto"（今回の焦点）。

        System.out.println("=== 接続 ===");
        System.out.println("URL: jdbc:awsathena://  (AthenaEndpoint/S3Endpoint は上記 Properties 経由)");
        try (Connection conn = DriverManager.getConnection("jdbc:awsathena://", props)) {
            System.out.println("接続成功: " + conn.getClass());

            // --- セットアップ（athena-local 経由。verify.sh の直接 Trino 投入とは別に、
            //     JDBC の execute 経路そのものを使って検証対象のテーブルを作る） ---
            runSetup(conn, "CREATE TABLE iceberg.default." + tIcebergDrop + " AS SELECT 1 AS n");
            runSetup(conn, "CREATE TABLE hive.default." + tHiveDrop + " AS SELECT 1 AS n");
            runSetup(conn, "CREATE TABLE hive.default." + tHiveAlter + " AS SELECT 1 AS n");

            // ケース 1: DROP TABLE (Iceberg) -> .metadata 41 バイト（列 0 個）
            runCase(conn, "ケース1 DROP_TABLE_iceberg(41B)", "DROP TABLE iceberg.default." + tIcebergDrop);

            // ケース 2: ALTER TABLE ... ADD COLUMN (Hive) -> .metadata 38 バイト（列 0 個）
            runCase(conn, "ケース2 ALTER_TABLE_ADD_COLUMN_hive(38B)",
                    "ALTER TABLE hive.default." + tHiveAlter + " ADD COLUMN m int");

            // ケース 3: DROP TABLE (Hive) -> .metadata を置かない従来経路（対照）
            runCase(conn, "ケース3 DROP_TABLE_hive(対照・metadata無し)", "DROP TABLE hive.default." + tHiveDrop);

            // ケース 4: 通常の SELECT -> 回帰確認
            runSelectCase(conn, "ケース4 SELECT_回帰確認", "SELECT 1 AS n");
        } catch (Exception e) {
            System.out.println("!!! 接続自体が失敗した !!!");
            e.printStackTrace(System.out);
            failures++;
        }

        System.out.println();
        System.out.println("=== 総括 === failures=" + failures);
        if (failures > 0) {
            System.exit(1);
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

    private static void runSelectCase(Connection conn, String label, String sql) {
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
