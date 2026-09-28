FROM python:3.12-slim
WORKDIR /app
COPY app.py .
RUN pip install boto3
ENV CLAUDE_CODE_USE_BEDROCK=1
ENV ANTHROPIC_MODEL=us.anthropic.claude-sonnet-4-6
EXPOSE 9000
CMD ["python3", "app.py"]
