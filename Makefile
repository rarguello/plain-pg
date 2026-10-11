# Shortcuts. All targets assume `oc` logged in to the cluster.
SHELL    := /usr/bin/env bash
NS       ?= postgresql-lab
OVERLAY  ?= manifests/overlays/lab
RENDERED := /tmp/postgresql-lab-rendered.yaml

.PHONY: help deploy teardown verify failover backup lint test test-quick

help:
	@echo "make deploy       deploys $(OVERLAY) in $(NS)"
	@echo "make teardown     deletes the resources (keeps the namespace)"
	@echo "make verify       verifies replication"
	@echo "make failover     promotes a replica"
	@echo "make backup       manual backup"
	@echo "make lint         shellcheck + kustomize + embedded scripts"
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
	oc kustomize $(OVERLAY) > $(RENDERED)
	oc kustomize manifests/overlays/lab-manual > $(RENDERED).manual
	python3 tools/check-scripts.py $(RENDERED) $(RENDERED).manual

test-quick:
	./tests/run-all.sh rapido

test:
	./tests/run-all.sh
