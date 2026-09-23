{# issue #111: GetWorkGroup を呼ぶ adapter.is_work_group_output_location_enforced()（dbt-athena impl.py:355-377。
   work_group 設定があり skip_workgroup_check が偽のときだけ呼ぶ）の値をログに出す。
   dbt run-operation はキャッシュ（Glue）も STS も呼ばないので、athena-local だけで通る。 #}
{% macro check_work_group() %}{% do log('ENFORCED=' ~ adapter.is_work_group_output_location_enforced(), info=True) %}{% endmacro %}
