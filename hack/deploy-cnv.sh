#!/usr/bin/env bash

set -euxo pipefail
PRODUCTION_RELEASE=${PRODUCTION_RELEASE:-false}
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

function cleanup() {
    rv=$?
    if [ "x$rv" != "x0" ]; then
        echo "Error during deployment: exit status: $rv"
        make dump-state
        echo "*** CNV deployment failed ***"
    fi
    exit $rv
}

function get_cnv_catalog_image() {
    # Environment variable has higher priority
    if [ -n "${CNV_CATALOG_IMAGE-}" ]; then
        return
    fi

    # Fallback to the image requested in the Prow job spec if any
    if [ -n "${PROW_JOB_ID-}" ]; then
        CNV_CATALOG_IMAGE=$(
          curl -fsSL https://prow.ci.openshift.org/prowjob?prowjob=${PROW_JOB_ID} \
            | sed -nr '/name: CNV_CATALOG_IMAGE/ { n; s|\s+value: (.*)|\1|p }'
        )
    fi

    # Ultimate fallback, get image from mapping file
    if [ -z "${CNV_CATALOG_IMAGE-}" ]; then
        eval "$(jq -r '."'"${CNV_VERSION}"'" | to_entries[] | .key+"="+.value' version-mapping.json)"

        # These variables are set when the eval above is executed
        CNV_CATALOG_IMAGE=$index_image

        # shellcheck disable=SC2154
        echo "Using bundle_version: $bundle_version"

        STARTING_CSV=${bundle_version%-*}
        STARTING_CSV=${STARTING_CSV%.rhel*}
    fi
}

function get_cnv_channel() {
    # Environment variable has higher priority
    if [ -n "${CNV_SUBSCRIPTION_CHANNEL-}" ]; then
        return
    fi

    # Fallback to the channel requested in the Prow job spec if any
    if [ -n "${PROW_JOB_ID-}" ]; then
        CNV_SUBSCRIPTION_CHANNEL=$(
          curl -fsSL https://prow.ci.openshift.org/prowjob?prowjob=${PROW_JOB_ID} \
            | sed -nr '/name: CNV_CHANNEL/ { n; s|\s+value: (.*)|\1|p }'
        )
    fi

    # Fallback, get channel from mapping file
    if [ -z "${CNV_SUBSCRIPTION_CHANNEL-}" ]; then
        CNV_SUBSCRIPTION_CHANNEL=$(
          jq -r '."'"${CNV_VERSION}"'".channel // empty' version-mapping.json
        )
    fi

    # Ultimate fallback, use stable channel
    : "${CNV_SUBSCRIPTION_CHANNEL:=stable}"
}

# Apply IDMS configuration
function apply_idms() {
    oc apply -f "${SCRIPT_DIR}/cnv_idms.yaml"
}

# Wait until master and worker MCP are Updated
# or timeout after 90min (default).
wait_for_mcp_to_update() {

    local timeout_minutes=${1:-90}
    local poll_interval_seconds=30
    local max_attempts=$(( timeout_minutes * 60 / poll_interval_seconds ))
    local attempt=0

    echo "Waiting for MCPs to update (timeout: ${timeout_minutes} minutes)"

    while true; do
        attempt=$((attempt+1))

        if oc wait mcp --all --for condition=updated --timeout=1m; then
            echo "MCPs are updated."
            return 0
        fi

        if (( attempt >= max_attempts )); then
            echo "Error: MCPs did not update within ${timeout_minutes} minutes." >&2
            return 1
        fi

        echo "Attempt ${attempt}/${max_attempts}: MCPs not yet updated, waiting ${poll_interval_seconds} seconds..."
        sleep "${poll_interval_seconds}"
    done
}

trap "cleanup" INT TERM EXIT


echo "OCP_VERSION: $OCP_VERSION"

CNV_VERSION=${CNV_VERSION:-${OCP_VERSION}}

oc create ns "${TARGET_NAMESPACE}"

if [ "$PRODUCTION_RELEASE" = "true" ]; then
    CNV_CATALOG_SOURCE='redhat-operators'
else
    CNV_CATALOG_SOURCE='cnv-catalog-source'
    apply_idms
    wait_for_mcp_to_update
    get_cnv_catalog_image

    # shellcheck disable=SC2154
    echo "Using index_image: ${CNV_CATALOG_IMAGE}"

    echo "setting up CNV catalog source"
    "$SCRIPT_DIR"/create-cnv-catalogsource.sh "${CNV_CATALOG_IMAGE}"
fi

get_cnv_channel

echo "creating subscription"
oc create -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubevirt-hyperconverged
  namespace: "${TARGET_NAMESPACE}"
  labels:
    operators.coreos.com/kubevirt-hyperconverged.openshift-cnv: ''
spec:
  channel: ${CNV_SUBSCRIPTION_CHANNEL}
  installPlanApproval: Automatic
  name: kubevirt-hyperconverged
  source: ${CNV_CATALOG_SOURCE}
  sourceNamespace: openshift-marketplace
  ${STARTING_CSV:+startingCSV: kubevirt-hyperconverged-operator.${STARTING_CSV}}
EOF

echo "creating operator group"
oc create -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "openshift-cnv-group"
  namespace: "${TARGET_NAMESPACE}"
spec:
  targetNamespaces:
  - "${TARGET_NAMESPACE}"
EOF

echo "waiting for HyperConverged operator to become ready"
"$SCRIPT_DIR"/wait-for-hco.sh
