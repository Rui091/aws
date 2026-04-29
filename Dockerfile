FROM python:3.12-slim-bookworm
# FROM arm64v8/python:3.12-slim-bookworm

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    make \
    zip \
    unzip \
    curl \
    vim \
    nano \
    virtualenv \
    iputils-ping \
    curl \
    git \
    less \
    ssh \
    && rm -rf /var/lib/apt/lists/*

RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install

ENV AWS_CLI_PATH=/usr/local/aws-cli/current/bin
ENV PATH="$AWS_CLI_PATH:${PATH}"

RUN aws --version

COPY requirements.txt .
RUN pip3 install -r requirements.txt -t ./

RUN pip3 install --upgrade virtualenv

ARG TF_VERSION=1.11.3
RUN curl -LO "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip" && \
    unzip "terraform_${TF_VERSION}_linux_amd64.zip" && \
    mv terraform /usr/local/bin/ && \
    rm "terraform_${TF_VERSION}_linux_amd64.zip"

RUN terraform --version

RUN apt-get purge -y --auto-remove && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

CMD ["/bin/bash"]