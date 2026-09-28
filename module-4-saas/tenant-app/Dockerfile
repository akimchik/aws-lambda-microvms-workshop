FROM python:3.12-slim
WORKDIR /app
COPY app.py .
RUN pip install boto3
EXPOSE 8080 9000
CMD ["python3", "-u", "app.py"]
