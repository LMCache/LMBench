#!/usr/bin/env bash

MODE=${1:-apply}
TAG=1.27-alpha.0551127f00634403cddd4634567e65a8ecc499a7
HUB=gcr.io/istio-testing

if [[ "$MODE" == "apply" ]]; then
    helm upgrade -i istio-base oci://$HUB/charts/base --version $TAG -n istio-system --create-namespace
    helm upgrade -i istiod oci://$HUB/charts/istiod --version $TAG -n istio-system --set tag=$TAG --set hub=$HUB --wait
else
  helm uninstall istiod --ignore-not-found --namespace istio-system || true
  helm uninstall istio-base --ignore-not-found --namespace istio-system || true
  helm template istio-base oci://$HUB/charts/base --version $TAG -n istio-system | kubectl delete -f - --ignore-not-found
fi
