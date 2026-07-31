variable tags {
  type = map(string)
  description = "A map of tags for the resources"
  default = {
    environment = "dev"
    owner       = "Avi"
  }
}