# tflint --recursive --config "$PWD/deploy/terraform/.tflint.hcl" (CI's terraform job).
plugin "terraform" {
  enabled = true
  preset  = "recommended"
  version = "0.17.0"
  source  = "github.com/terraform-linters/tflint-ruleset-terraform"
}
