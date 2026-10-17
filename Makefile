# Shortcuts. All targets assume `oc` logged in to the cluster.
SHELL    := /usr/bin/env bash
NS       ?= plain-pg
OVERLAY  ?= manifests/overlays/ha
RENDERED := /tmp/plain-pg-rendered

.PHONY: help deploy teardown verify failover backup lint ci test test-quick

help:
	@echo "make deploy       deploys $(OVERLAY) in $(NS)"
	@echo "make teardown     deletes the resources (keeps the namespace)"
	@echo "make verify       verifies replication"
	@echo "make failover     promotes a replica"
	@echo "make backup       manual backup"
	@echo "make lint         shellcheck + kustomize + embedded scripts + policies"
	@echo "make ci           make lint plus the other checks CI runs (best effort)"
	@echo "make test-quick   non-destructive tests"
	@echo "make test         all tests (includes destructive)"

deploy:
	./scripts/deploy.sh $(OVERLAY)

teardown:
	./scripts/teardown.sh

verify:
	./scripts/verify-replication.sh

failover:
	./scripts/failover-manual.sh

backup:
	./scripts/backup-now.sh

lint:
	shellcheck -S warning scripts/*.sh tests/*.sh
	oc kustomize manifests/overlays/ha > $(RENDERED).ha.yaml
	oc kustomize manifests/overlays/ha-manual > $(RENDERED).ha-manual.yaml
	oc kustomize manifests/overlays/ha-autoscale > $(RENDERED).ha-autoscale.yaml
	oc kustomize manifests/overlays/ha-metrics > $(RENDERED).ha-metrics.yaml
	oc kustomize manifests/overlays/ha-tls > $(RENDERED).ha-tls.yaml
	oc kustomize manifests/overlays/ha-tls-byo > $(RENDERED).ha-tls-byo.yaml
	oc kustomize manifests/overlays/ha-external > $(RENDERED).ha-external.yaml
	oc kustomize manifests/overlays/single > $(RENDERED).single.yaml
	oc kustomize manifests/overlays/single-tls > $(RENDERED).single-tls.yaml
	oc kustomize manifests/overlays/ha-settings > $(RENDERED).ha-settings.yaml
	oc kustomize manifests/overlays/ha-small > $(RENDERED).ha-small.yaml
	python3 tools/check-scripts.py $(RENDERED).ha.yaml $(RENDERED).ha-manual.yaml
	python3 tools/check-policies.py $(RENDERED).ha.yaml $(RENDERED).ha-manual.yaml $(RENDERED).ha-autoscale.yaml $(RENDERED).ha-metrics.yaml $(RENDERED).ha-tls.yaml $(RENDERED).ha-tls-byo.yaml $(RENDERED).ha-external.yaml $(RENDERED).single.yaml $(RENDERED).single-tls.yaml $(RENDERED).ha-settings.yaml $(RENDERED).ha-small.yaml

# The same checks CI runs, for the tools that are installed locally.
ci: lint
	@command -v kubeconform >/dev/null 2>&1 && kubeconform -summary -ignore-missing-schemas $(RENDERED).*.yaml || echo "kubeconform not installed; skipped"
	@command -v yamllint >/dev/null 2>&1 && yamllint -f parsable manifests .github || echo "yamllint not installed; skipped"
	@command -v actionlint >/dev/null 2>&1 && actionlint || echo "actionlint not installed; skipped"
	@command -v codespell >/dev/null 2>&1 && codespell || echo "codespell not installed; skipped"
	@command -v npx >/dev/null 2>&1 && npx --yes markdownlint-cli2 || echo "npx not installed; markdownlint skipped"

test-quick:
	./tests/run-all.sh quick

test:
	./tests/run-all.sh
