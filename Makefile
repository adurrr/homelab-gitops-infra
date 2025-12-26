# =============================================================================
# Homelab GitOps Infrastructure — Makefile
# =============================================================================
# Automation targets for validation, testing, linting, and deployment.
# Usage: make <target>
# =============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Directories
INFRA_DIR    := infra
PLATFORM_DIR := platform
OBS_DIR      := observability
APPS_DIR     := apps
SECURITY_DIR := security
SCRIPTS_DIR  := scripts
DOCS_DIR     := docs

# Colors
GREEN  := \033[0;32m
YELLOW := \033[1;33m
NC     := \033[0m

# Locale fix — some systems don't have en_US.UTF-8 or C.UTF-8
# Try C.UTF-8 first (most Linux), fall back to C (POSIX, always works)
LC_ENV := LC_ALL=C.UTF-8

# =============================================================================
# Help
# =============================================================================

.PHONY: help
help: ## Show this help message
	@echo "Homelab GitOps Infrastructure — Available Targets"
	@echo "=================================================="
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[0;32m%-25s\033[0m %s\n", $$1, $$2}'

# =============================================================================
# Validation
# =============================================================================

.PHONY: validate-structure
validate-structure: ## Validate directory structure exists
	@echo -e "$(YELLOW)Validating directory structure...$(NC)"
	@for dir in \
		$(INFRA_DIR)/k3s $(INFRA_DIR)/cilium $(INFRA_DIR)/tests \
		$(PLATFORM_DIR)/argocd $(PLATFORM_DIR)/argocd/apps $(PLATFORM_DIR)/argocd/bootstrap \
		$(PLATFORM_DIR)/metallb $(PLATFORM_DIR)/cert-manager $(PLATFORM_DIR)/traefik \
		$(OBS_DIR)/kube-prometheus-stack $(OBS_DIR)/loki $(OBS_DIR)/otel-collector \
		$(OBS_DIR)/dashboards $(OBS_DIR)/datasources $(OBS_DIR)/tests \
		$(APPS_DIR)/home-assistant/templates $(APPS_DIR)/home-assistant/tests \
		$(SECURITY_DIR)/network-policies $(SECURITY_DIR)/rbac $(SECURITY_DIR)/secrets \
		$(SCRIPTS_DIR) $(DOCS_DIR)/runbooks; do \
		if [ ! -d "$$dir" ]; then \
			echo "❌ Missing directory: $$dir"; exit 1; \
		fi; \
	done
	@echo -e "$(GREEN)✓ Directory structure valid$(NC)"

.PHONY: validate-env
validate-env: ## Validate .env file exists and has required variables
	@echo -e "$(YELLOW)Validating environment configuration...$(NC)"
	@if [ ! -f $(INFRA_DIR)/.env ]; then \
		echo "❌ Missing $(INFRA_DIR)/.env — copy from env.example:"; \
		echo "   cp $(INFRA_DIR)/env.example $(INFRA_DIR)/.env"; \
		exit 1; \
	fi
	@for var in K3S_SERVER_IP K3S_AGENT_IP K3S_TOKEN; do \
		if grep -q "^$${var}=CHANGE_ME\|^$${var}=$$" $(INFRA_DIR)/.env 2>/dev/null; then \
			echo "❌ $$var is not set in $(INFRA_DIR)/.env"; \
			exit 1; \
		fi; \
	done
	@echo -e "$(GREEN)✓ Environment configuration valid$(NC)"

.PHONY: validate-ansible
validate-ansible: ## Validate Ansible playbook syntax
	@echo -e "$(YELLOW)Validating Ansible playbooks...$(NC)"
	@if ! command -v ansible-playbook &>/dev/null; then \
		echo "⚠ ansible-playbook not installed, skipping"; \
		exit 0; \
	fi
	@if [ ! -f ansible/inventory.yml ]; then \
		echo "⚠ ansible/inventory.yml not found — copy from inventory.example.yml:"; \
		echo "   cp ansible/inventory.example.yml ansible/inventory.yml"; \
		echo "   vim ansible/inventory.yml"; \
		exit 0; \
	fi
	@$(LC_ENV) ansible-playbook ansible/playbook.yml --syntax-check
	@echo -e "$(GREEN)✓ Ansible playbook syntax valid$(NC)"

.PHONY: validate-yaml
validate-yaml: ## Validate all YAML files with yamllint
	@echo -e "$(YELLOW)Validating YAML files...$(NC)"
	@if command -v yamllint &>/dev/null; then \
		yamllint -d relaxed . ; \
	else \
		echo "⚠ yamllint not installed, skipping"; \
	fi
	@echo -e "$(GREEN)✓ YAML validation complete$(NC)"

.PHONY: validate-helm
validate-helm: ## Lint all Helm charts
	@echo -e "$(YELLOW)Validating Helm charts...$(NC)"
	@for chart in $$(find . -name Chart.yaml -exec dirname {} \;); do \
		echo "  Linting $$chart..."; \
		helm lint $$chart || true; \
	done
	@echo -e "$(GREEN)✓ Helm chart validation complete$(NC)"

.PHONY: validate
validate: validate-structure validate-env validate-yaml validate-helm validate-ansible ## Run all validations

# =============================================================================
# Linting
# =============================================================================

.PHONY: lint
lint: validate-yaml validate-helm ## Run all linters

# =============================================================================
# Security Scanning
# =============================================================================

.PHONY: scan-secrets
scan-secrets: ## Scan for secrets in git history
	@echo -e "$(YELLOW)Scanning for secrets...$(NC)"
	@if command -v gitleaks &>/dev/null; then \
		gitleaks detect --verbose; \
	else \
		echo "⚠ gitleaks not installed, skipping"; \
	fi
	@echo -e "$(GREEN)✓ Secret scan complete$(NC)"

.PHONY: scan-vulns
scan-vulns: ## Scan for known vulnerabilities in config files
	@echo -e "$(YELLOW)Scanning for vulnerabilities...$(NC)"
	@if command -v trivy &>/dev/null; then \
		trivy config --severity HIGH,CRITICAL .; \
	else \
		echo "⚠ trivy not installed, skipping"; \
	fi
	@echo -e "$(GREEN)✓ Vulnerability scan complete$(NC)"

# =============================================================================
# Testing
# =============================================================================

.PHONY: test-phase0
test-phase0: validate-structure validate-env ## Run Phase 0 tests (repo setup)
	@echo -e "$(YELLOW)Running Phase 0 tests...$(NC)"
	@bash $(INFRA_DIR)/tests/test-phase0.sh

.PHONY: test-phase1
test-phase1: ## Run Phase 1 tests (cluster setup)
	@echo -e "$(YELLOW)Running Phase 1 tests...$(NC)"
	@if [ -z "$$KUBECONFIG" ]; then \
		if [ -f "$(HOME)/.kube/config-homelab" ]; then \
			export KUBECONFIG="$(HOME)/.kube/config-homelab"; \
		elif [ -f "/etc/rancher/k3s/k3s.yaml" ]; then \
			export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"; \
		else \
			echo "❌ KUBECONFIG not set and no default found"; \
			echo "   export KUBECONFIG=~/.kube/config-homelab"; \
			exit 1; \
		fi; \
	fi
	@KUBECONFIG=$${KUBECONFIG:-$$HOME/.kube/config-homelab} bash $(INFRA_DIR)/tests/test-cluster.sh

.PHONY: test-phase2
test-phase2: ## Run Phase 2 tests (ArgoCD, MetalLB, cert-manager)
	@echo -e "$(YELLOW)Running Phase 2 tests...$(NC)"
	@bash $(PLATFORM_DIR)/tests/test-argocd.sh
	@bash $(PLATFORM_DIR)/tests/test-metallb.sh
	@bash $(PLATFORM_DIR)/tests/test-cert-manager.sh

.PHONY: test-phase3
test-phase3: ## Run Phase 3 tests (observability)
	@echo -e "$(YELLOW)Running Phase 3 tests...$(NC)"
	@bash $(OBS_DIR)/tests/test-prometheus.sh
	@bash $(OBS_DIR)/tests/test-loki.sh
	@bash $(OBS_DIR)/tests/test-grafana.sh
	@bash $(OBS_DIR)/tests/test-otel-pipeline.sh

.PHONY: test-phase4
test-phase4: ## Run Phase 4 tests (Home Assistant)
	@echo -e "$(YELLOW)Running Phase 4 tests...$(NC)"
	@bash $(APPS_DIR)/tests/test-app-sync.sh

.PHONY: test-phase5
test-phase5: ## Run Phase 5 tests (security)
	@echo -e "$(YELLOW)Running Phase 5 tests...$(NC)"
	@bash $(SECURITY_DIR)/tests/test-network-policies.sh
	@bash $(SECURITY_DIR)/tests/test-rbac.sh

.PHONY: test
test: test-phase0 test-phase1 test-phase2 test-phase3 ## Run all available tests (phases 0-3)

# =============================================================================
# Deployment Helpers
# =============================================================================

.PHONY: deploy-phase2
deploy-phase2: ## Deploy Phase 2 (ArgoCD + platform services) — GitOps bootstrap
	@echo -e "$(YELLOW)Phase 2 deployment — ArgoCD & GitOps Bootstrap$(NC)"
	@echo ""
	@echo "Prerequisites:"
	@echo "  1. Phase 1 complete: kubectl access to healthy cluster"
	@echo "  2. Cilium status OK: cilium status"
	@echo "  3. Helm repo add commands available"
	@echo ""
	@echo "Steps:"
	@echo ""
	@echo "  1. Install ArgoCD (bootstrap — manages itself after this):"
	@echo "     kubectl create namespace argocd"
	@echo "     helm repo add argo https://argoproj.github.io/argo-helm"
	@echo "     helm install argocd argo/argo-cd \\"
	@echo "       --namespace argocd \\"
	@echo "       -f platform/argocd/values.yaml"
	@echo ""
	@echo "  2. Get admin password:"
	@echo "     kubectl -n argocd get secret argocd-initial-admin-secret \\"
	@echo "       -o jsonpath='{.data.password}' | base64 -d"
	@echo ""
	@echo "  3. Apply bootstrap root application (App-of-Apps):"
	@echo "     kubectl apply -f platform/argocd/bootstrap/argocd-app.yaml"
	@echo ""
	@echo "  4. ArgoCD now syncs all child apps from platform/argocd/apps/:"
	@echo "     - argocd (self-managed)"
	@echo "     - metallb (LoadBalancer)"
	@echo "     - metallb-config (IP pool + L2 advertisement)"
	@echo "     - traefik (ingress controller)"
	@echo "     - cert-manager (TLS certificates)"
	@echo ""
	@echo "  5. Validate:"
	@echo "     make test-phase2"

.PHONY: deploy-phase1
deploy-phase1: ## Deploy Phase 1 (K3s + Cilium) — SSH into nodes and install
	@echo -e "$(YELLOW)Phase 1 deployment — scripts SSH into nodes from your admin machine.$(NC)"
	@echo ""
	@echo "Prerequisites:"
	@echo "  1. SSH access to both nodes (ssh server, ssh agent)"
	@echo "  2. infra/.env configured with real IPs, hostnames, and K3S_TOKEN"
	@echo "  3. Ansible bootstrap already run (make ansible-bootstrap)"
	@echo ""
	@echo "Steps:"
	@echo ""
	@echo "  0. Copy Cilium values template (on admin machine):"
	@echo "     cp infra/cilium/values.example.yaml infra/cilium/values.yaml"
	@echo ""
	@echo "  1. Install K3s server (SSHs into server):"
	@echo "     source infra/.env && bash infra/k3s/server-install.sh"
	@echo "     # Or to reinstall: bash infra/k3s/server-install.sh --force"
	@echo ""
	@echo "  2. Copy kubeconfig to your admin machine:"
	@echo "     scp server:/etc/rancher/k3s/k3s.yaml ~/.kube/config-homelab"
	@echo "     sed -i 's/127.0.0.1/$$K3S_SERVER_IP/g' ~/.kube/config-homelab"
	@echo ""
	@echo "  3. Install K3s agent (SSHs into agent):"
	@echo "     source infra/.env && bash infra/k3s/agent-install.sh"
	@echo "     # Or to reinstall: bash infra/k3s/agent-install.sh --force"
	@echo ""
	@echo "  4. Install Cilium CNI (on admin machine):"
	@echo "     make cilium-install"
	@echo ""
	@echo "  5. Validate:"
	@echo "     make test-phase1"

.PHONY: cilium-install
cilium-install: ## Install Cilium CNI into the cluster (requires kubectl access)
	@echo -e "$(YELLOW)Installing Cilium CNI...$(NC)"
	@if ! command -v cilium &>/dev/null; then \
		echo "❌ cilium CLI not found — install it first:"; \
		echo "   https://github.com/cilium/cilium-cli/releases"; \
		exit 1; \
	fi
	@if [ ! -f $(INFRA_DIR)/cilium/values.yaml ]; then \
		echo "❌ Missing $(INFRA_DIR)/cilium/values.yaml — copy from template:"; \
		echo "   cp $(INFRA_DIR)/cilium/values.example.yaml $(INFRA_DIR)/cilium/values.yaml"; \
		echo "   vim $(INFRA_DIR)/cilium/values.yaml  # Customize with your real values"; \
		exit 1; \
	fi
	@if [ -z "$$KUBECONFIG" ]; then \
		if [ -f "$(HOME)/.kube/config-homelab" ]; then \
			export KUBECONFIG="$(HOME)/.kube/config-homelab"; \
		elif [ -f "/etc/rancher/k3s/k3s.yaml" ]; then \
			export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"; \
		else \
			echo "❌ KUBECONFIG not set"; \
			echo "   export KUBECONFIG=~/.kube/config-homelab"; \
			exit 1; \
		fi; \
	fi
	@KUBECONFIG=$${KUBECONFIG:-$$HOME/.kube/config-homelab} cilium install --version 1.19.3 -f $(INFRA_DIR)/cilium/values.yaml
	@echo -e "$(GREEN)✓ Cilium installed. Run 'cilium status' to verify.$(NC)"

.PHONY: ansible-bootstrap
ansible-bootstrap: ## Run Ansible playbook to bootstrap nodes (prompts for sudo password)
	@echo -e "$(YELLOW)Bootstrapping nodes with Ansible...$(NC)"
	@if [ ! -f ansible/inventory.yml ]; then \
		echo "❌ Missing ansible/inventory.yml — copy from inventory.example.yml:"; \
		echo "   cp ansible/inventory.example.yml ansible/inventory.yml"; \
		echo "   vim ansible/inventory.yml"; \
		exit 1; \
	fi
	@echo -e "$(YELLOW)Testing SSH connectivity...$(NC)"
	@$(LC_ENV) ansible all -m ping --ask-become-pass || ( \
		echo ""; \
		echo "❌ Could not connect to nodes. Check:"; \
		echo "   1. ansible/inventory.yml has correct IPs and SSH user"; \
		echo "   2. SSH key auth is set up (or install sshpass for password auth)"; \
		echo "   3. Nodes are reachable: ping <IP>"; \
		echo "   4. Try: ansible all -m ping --ask-pass --ask-become-pass"; \
		exit 1 \
	)
	@echo -e "$(YELLOW)Running playbook (will prompt for sudo password)...$(NC)"
	@$(LC_ENV) ansible-playbook ansible/playbook.yml --ask-become-pass
	@echo -e "$(GREEN)✓ Nodes bootstrapped. Run 'make ansible-check' to verify.$(NC)"

.PHONY: ansible-check
ansible-check: ## Dry-run Ansible playbook (check mode, prompts for sudo password)
	@echo -e "$(YELLOW)Running Ansible playbook in check mode...$(NC)"
	@if [ ! -f ansible/inventory.yml ]; then \
		echo "❌ Missing ansible/inventory.yml — copy from inventory.example.yml:"; \
		echo "   cp ansible/inventory.example.yml ansible/inventory.yml"; \
		echo "   vim ansible/inventory.yml"; \
		exit 1; \
	fi
	@$(LC_ENV) ansible-playbook ansible/playbook.yml --check --ask-become-pass
	@echo -e "$(GREEN)✓ Ansible check complete$(NC)"

.PHONY: ansible-ping
ansible-ping: ## Test SSH connectivity to all nodes
	@echo -e "$(YELLOW)Testing SSH connectivity to all nodes...$(NC)"
	@if [ ! -f ansible/inventory.yml ]; then \
		echo "❌ Missing ansible/inventory.yml — copy from inventory.example.yml:"; \
		echo "   cp ansible/inventory.example.yml ansible/inventory.yml"; \
		exit 1; \
	fi
	@$(LC_ENV) ansible all -m ping --ask-become-pass

.PHONY: ansible-lint
ansible-lint: ## Lint Ansible playbooks and roles
	@echo -e "$(YELLOW)Linting Ansible playbooks...$(NC)"
	@if command -v ansible-lint &>/dev/null; then \
		$(LC_ENV) ansible-lint ansible/playbook.yml; \
	else \
		echo "⚠ ansible-lint not installed, skipping"; \
	fi
	@echo -e "$(GREEN)✓ Ansible lint complete$(NC)"

# =============================================================================
# Cleanup
# =============================================================================

.PHONY: clean
clean: ## Remove generated files (keep .env)
	@echo -e "$(YELLOW)Cleaning generated files...$(NC)"
	@find . -name "*.tgz" -delete
	@find . -name ".helm" -type d -exec rm -rf {} + 2>/dev/null || true
	@echo -e "$(GREEN)✓ Clean complete$(NC)"
