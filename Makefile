# Shortcuts. All targets assume `oc` logged in to the cluster.
SHELL    := /usr/bin/env bash
NS       ?= plain-pg
OVERLAY  ?= manifests/overlays/lab
RENDERED := /tmp/plain-pg-rendered

.PHONY: help deploy teardown verify failover backup lint test test-quick

help:
	@echo "make deploy       deploys $(OVERLAY) in $(NS)"
	@echo "make teardown     deletes the resources (keeps the namespace)"
	@echo "make verify       verifies replication"
	@echo "make failover     promotes a replica"
	@echo "make backup       manual backup"
	@echo "make lint         shellcheck + kustomize + embedded scripts + policies"
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
	oc kustomize manifests/overlays/lab > $(RENDERED).lab.yaml
	oc kustomize manifests/overlays/lab-manual > $(RENDERED).lab-manual.yaml
	oc kustomize manifests/overlays/lab-autoscale > $(RENDERED).lab-autoscale.yaml
	oc kustomize manifests/overlays/lab-metrics > $(RENDERED).lab-metrics.yaml
	oc kustomize manifests/overlays/lab-tls > $(RENDERED).lab-tls.yaml
	oc kustomize manifests/overlays/lab-tls-byo > $(RENDERED).lab-tls-byo.yaml
	oc kustomize manifests/overlays/lab-external > $(RENDERED).lab-external.yaml
	python3 tools/check-scripts.py $(RENDERED).lab.yaml $(RENDERED).lab-manual.yaml
	python3 tools/check-policies.py $(RENDERED).lab.yaml $(RENDERED).lab-manual.yaml $(RENDERED).lab-autoscale.yaml $(RENDERED).lab-metrics.yaml $(RENDERED).lab-tls.yaml $(RENDERED).lab-tls-byo.yaml $(RENDERED).lab-external.yaml

test-quick:
	./tests/run-all.sh quick

test:
	./tests/run-all.sh
