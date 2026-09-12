# ビルド用。バイナリだけを次のステージに渡す。
FROM rust:1.98-bookworm AS builder

WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --locked

# 実行用。Rust のツールチェインは持ち込まない。
FROM debian:bookworm-slim

COPY --from=builder /src/target/release/athena-local /usr/local/bin/athena-local

# 書き込みは行わないので非 root で動かす。
USER nobody
EXPOSE 8080
ENTRYPOINT ["athena-local"]
