# The AWS implementation moved into networking/aws/ (2026-11-25). These blocks carry
# existing state to the new addresses, so nothing is destroyed or recreated.
# Data sources need no moves; they are simply read again.

moved {
  from = aws_vpc.network
  to   = module.aws.aws_vpc.network
}

moved {
  from = aws_subnet.subnets
  to   = module.aws.aws_subnet.subnets
}

moved {
  from = aws_internet_gateway.main
  to   = module.aws.aws_internet_gateway.main
}

moved {
  from = aws_route_table.public
  to   = module.aws.aws_route_table.public
}

moved {
  from = aws_route.public_internet
  to   = module.aws.aws_route.public_internet
}

moved {
  from = aws_route_table_association.public
  to   = module.aws.aws_route_table_association.public
}

moved {
  from = aws_eip.nat
  to   = module.aws.aws_eip.nat
}

moved {
  from = aws_nat_gateway.main
  to   = module.aws.aws_nat_gateway.main
}

moved {
  from = aws_route_table.private
  to   = module.aws.aws_route_table.private
}

moved {
  from = aws_route.private_nat
  to   = module.aws.aws_route.private_nat
}

moved {
  from = aws_route_table_association.private
  to   = module.aws.aws_route_table_association.private
}

moved {
  from = aws_route_table.intra
  to   = module.aws.aws_route_table.intra
}

moved {
  from = aws_route_table_association.intra
  to   = module.aws.aws_route_table_association.intra
}
