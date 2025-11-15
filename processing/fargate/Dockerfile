# FFmpeg Video Processing Container for AWS Fargate
# Concatenates recording chunks and extracts audio for transcription
FROM public.ecr.aws/lambda/python:3.13

# Install FFmpeg and dependencies
RUN yum update -y && \
    yum install -y wget xz tar && \
    # Download and install FFmpeg static build
    wget https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xf ffmpeg-release-amd64-static.tar.xz && \
    mv ffmpeg-*-amd64-static/ffmpeg /usr/local/bin/ && \
    mv ffmpeg-*-amd64-static/ffprobe /usr/local/bin/ && \
    rm -rf ffmpeg-* && \
    chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    yum clean all

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY process_video.py .
COPY shared/ ./shared/

# Verify FFmpeg installation
RUN ffmpeg -version

# Set working directory for processing
WORKDIR /tmp

# Default command - can be overridden by Fargate task definition
CMD ["python", "process_video.py"]