#!/usr/bin/env bash
# Uso (já logado com `oc login` no Red Hat Developer Sandbox):  ./openshift/deploy.sh
set -euo pipefail
cd "$(dirname "$0")/.."

oc apply -f openshift/01-secret.yaml
oc apply -f openshift/02-postgres.yaml
oc rollout status deployment/puretouch-db --timeout=300s

oc delete configmap puretouch-sql --ignore-not-found
oc create configmap puretouch-sql \
  --from-file=sql/01_ddl.sql --from-file=sql/02_procedures.sql --from-file=sql/03_seed.sql
oc delete job puretouch-db-init --ignore-not-found
oc apply -f openshift/03-job-init.yaml
oc wait --for=condition=complete job/puretouch-db-init --timeout=300s
oc logs job/puretouch-db-init | tail -5

oc apply -f openshift/04-cronjob-faltas.yaml
echo "OK. Teste: oc rsh deploy/puretouch-db psql -d puretouch -c 'SELECT * FROM pure_touch.vw_ranking_procedimentos;'"
