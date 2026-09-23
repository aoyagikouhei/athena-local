-- issue #111: dbt run がどこで止まるか（Glue・STS）を観測するためのモデル。athena-local だけでは通らない想定。
{{ config(materialized='table') }}
select 1 as n
