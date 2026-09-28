FROM python:3.12-slim
WORKDIR /app
COPY app.py .
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
RUN pip install boto3 git-remote-codecommit
EXPOSE 9000
CMD ["python3", "-u", "app.py"]
