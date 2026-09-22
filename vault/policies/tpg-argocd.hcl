# tpg-argocd: Vault Secrets Operator on the hub (role tpg-argocd, ServiceAccount
# argocd/tpg-vso). Builds the Argo CD repository Secrets.
path "tpg/data/shared/github-read" {
  capabilities = ["read"]
}
path "tpg/data/shared/broadcom-registry" {
  capabilities = ["read"]
}
