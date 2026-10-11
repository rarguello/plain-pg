# Atajos. Todos los targets asumen `oc` logueado en el cluster.
SHELL    := /usr/bin/env bash
NS       ?= pg-ha-lab
OVERLAY  ?= manifests/overlays/lab
RENDERED := /tmp/pg-ha-lab-rendered.yaml

.PHONY: help deploy teardown verify failover backup lint test test-quick

help:
	@echo "make deploy       despliega $(OVERLAY) en $(NS)"
	@echo "make teardown     borra los recursos (deja el namespace)"
	@echo "make verify       verifica la replicacion"
	@echo "make failover     promueve una replica"
	@echo "make backup       backup manual"
	@echo "make lint         shellcheck + kustomize + scripts embebidos"
	@echo "make test-quick   pruebas no destructivas"
	@echo "make test         todas las pruebas (incluye destructivas)"

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
