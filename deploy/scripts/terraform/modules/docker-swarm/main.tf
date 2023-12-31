variable "key_name" {}
variable "vpc_id" {}
variable "subnet_id" {}
variable "security_group" {}
variable "instance_type" {}
variable "manager_count" {}
variable "worker_count" {}


resource "aws_instance" "manager" {
  count                  = var.manager_count
  ami                    = "ami-08a52ddb321b32a8c" # Amazon Linux 2 LTS
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [var.security_group]
  subnet_id              = var.subnet_id
  associate_public_ip_address = true

  user_data = <<-EOT
                #!/bin/bash
                sudo yum update -y
                sudo yum install -y docker
                sudo yum install -y git
                sudo yum install -y nc
                sudo curl -L https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose
                sudo chmod +x /usr/local/bin/docker-compose
                sudo service docker start
                sudo usermod -a -G docker ec2-user
                sudo chkconfig docker on

                # Fetch instance metadata with token
                TOKEN=`curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`
                IP_ADDR=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -v http://169.254.169.254/latest/meta-data/local-ipv4)

                docker swarm init --advertise-addr $IP_ADDR

                # Create a script to get the join token
                echo 'docker swarm join-token worker -q' > get_token.sh
                chmod +x get_token.sh
                timeout 5m bash -c "while true; do { echo -e 'HTTP/1.1 200 OK\r\n'; ./get_token.sh; } | nc -l 8080; done" &
                sleep 10

                # Clone the repo and start the stack
                git clone https://github.com/logspace-ai/langflow.git
                cd /langflow
                git checkout celery
                cd /langflow/deploy

                sudo cp .env.example .env
                
                # Add the label to random worker node to ensure that the data volume is created on the same node                
                docker node update --label-add app-db-data=true $(docker node ls --format '{{.Hostname}}' --filter role=worker | head -n 1)
                
                env $(cat .env | grep ^[A-Z] | xargs) docker stack deploy --compose-file docker-compose.yml langflow_stack

                EOT

  tags = {
    Name = "manager-${count.index}"
  }
}

resource "aws_instance" "worker" {
  count                  = var.worker_count
  ami                    = "ami-08a52ddb321b32a8c" # Amazon Linux 2 LTS
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [var.security_group]
  subnet_id              = var.subnet_id
  associate_public_ip_address = true

  user_data = <<-EOT
            #!/bin/bash
            MANAGER_IP="${aws_instance.manager.0.private_ip}"
            sudo yum update -y
            sudo yum install -y docker
            sudo service docker start
            sudo usermod -a -G docker ec2-user
            sudo chkconfig docker on
            docker swarm join --token $(curl -s http://$MANAGER_IP:8080/token) $MANAGER_IP:2377
            EOT

  tags = {
    Name = "worker-${count.index}"
  }
}

output "manager_public_ips" {
  value = aws_instance.manager[*].public_ip
}

output "worker_public_ips" {
  value = aws_instance.worker[*].public_ip
}
