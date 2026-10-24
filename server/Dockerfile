FROM python:3.13-slim
COPY --from=ghcr.io/astral-sh/uv:0.13.5 /uv /usr/local/bin/uv
WORKDIR /app
COPY pyproject.toml uv.lock ./
COPY LICENSE ./
RUN uv sync --frozen --no-dev
COPY maclink_server ./maclink_server
RUN useradd --uid 10001 --create-home maclink && mkdir /data && chown maclink /data
USER maclink
ENV MACLINK_DATA_DIR=/data
EXPOSE 8099
CMD ["/app/.venv/bin/fastapi", "run", "maclink_server/app.py", "--port", "8099", "--workers", "1"]
