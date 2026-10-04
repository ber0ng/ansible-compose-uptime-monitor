output "public_ip" {
  value = aws_eip.app_eip
}

output "ssh_command" {
  value = "ssh ubuntu@${aws_eip.app_eip.public_ip}"
}

output "ami_name" {
  value = data.aws_ami.ubuntu.name
}
