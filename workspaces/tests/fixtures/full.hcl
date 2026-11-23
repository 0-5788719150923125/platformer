# Fixture: overrides states and states_paths, with comments mixed in
aws_region = "us-west-2"
# states_paths = ["/commented/out"]
states_paths = [
  "~/configs/platformer", # inline comment
  "/srv/states",
  "relative/dir",
]
states = ["alpha", "beta"]
