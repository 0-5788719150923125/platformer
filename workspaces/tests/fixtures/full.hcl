# Fixture: overrides fragments and fragment_paths, with comments mixed in
aws_region = "us-west-2"
# fragment_paths = ["/commented/out"]
fragment_paths = [
  "~/configs/platformer", # inline comment
  "/srv/fragments",
  "relative/dir",
]
fragments = ["alpha", "beta"]
