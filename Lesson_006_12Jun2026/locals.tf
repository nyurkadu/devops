locals {
  subnets = {
    frontend = "10.0.1.0/24"
    backend  = "10.0.2.0/24"
    dmz      = "10.0.3.0/24"
  }
}
