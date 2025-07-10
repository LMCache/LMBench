#!/bin/bash
set -e

echo "=== Waiting for LLM-D Baseline Readiness ==="

# Configuration
TIMEOUT=600  # 10 minutes timeout (LLM-D can take time for model loading)
POLL_INTERVAL=10  # Check every 10 seconds
LOG_POLL_INTERVAL=30  # Show logs every 30 seconds
START_TIME=$(date +%s)
LAST_LOG_TIME=0

# Colors for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "Waiting for LLM-D service on localhost:30080..."
echo "Timeout: ${TIMEOUT}s, Poll interval: ${POLL_INTERVAL}s, Log interval: ${LOG_POLL_INTERVAL}s"

# Function to get detailed pod status
get_pod_status() {
    if kubectl get namespace llm-d > /dev/null 2>&1; then
        echo -e "${BLUE}=== Pod Status ===${NC}"
        kubectl get pods -n llm-d -o wide 2>/dev/null | while read line; do
            if [[ "$line" == *"NAME"* ]]; then
                echo -e "${YELLOW}$line${NC}"
            elif [[ "$line" == *"Running"* ]] && [[ "$line" == *"1/1"* || "$line" == *"2/2"* ]]; then
                echo -e "${GREEN}$line${NC}"
            elif [[ "$line" == *"Running"* ]] && [[ "$line" == *"1/2"* ]]; then
                echo -e "${YELLOW}$line${NC} ${RED}⚠ Multi-container pod not fully ready${NC}"
            elif [[ "$line" == *"Pending"* || "$line" == *"ContainerCreating"* || "$line" == *"Init:"* ]]; then
                echo -e "${YELLOW}$line${NC}"
            else
                echo -e "${RED}$line${NC}"
            fi
        done
        echo ""
        
        # Show detailed status for decode pods that aren't fully ready
        DECODE_PODS=$(kubectl get pods -n llm-d --no-headers 2>/dev/null | grep -E '\-decode\-' | awk '$2!~/^[0-9]+\/[0-9]+$/ || $2!="2/2" {print $1}')
        if [ -n "$DECODE_PODS" ]; then
            echo -e "${YELLOW}--- Decode Pod Container Status ---${NC}"
            for pod in $DECODE_PODS; do
                echo -e "${BLUE}Pod: $pod${NC}"
                kubectl get pod -n llm-d "$pod" -o jsonpath='{range .status.containerStatuses[*]}{.name}{": "}{.ready}{" (State: "}{.state}{")"}{"  |  "}{end}' 2>/dev/null | sed 's/^/  /' || echo "  Status unavailable"
                echo ""
            done
        fi
    fi
}

# Function to show recent logs from key components
show_recent_logs() {
    echo -e "${BLUE}=== Recent Logs ===${NC}"
    
    # Decode pod logs - try both label selector and name pattern
    DECODE_PODS=$(kubectl get pods -n llm-d -l "llm-d.ai/role=decode" --no-headers 2>/dev/null | awk '{print $1}' | head -2)
    if [ -z "$DECODE_PODS" ]; then
        # Fallback: search by pod name pattern
        DECODE_PODS=$(kubectl get pods -n llm-d --no-headers 2>/dev/null | grep -E '\-decode\-' | awk '{print $1}' | head -2)
    fi
    
    if [ -n "$DECODE_PODS" ]; then
        echo -e "${YELLOW}--- Decode Pod Logs ---${NC}"
        for pod in $DECODE_PODS; do
            echo -e "${BLUE}Pod: $pod${NC}"
            
            # Get container names for this pod
            CONTAINERS=$(kubectl get pod -n llm-d "$pod" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)
            if [ -n "$CONTAINERS" ]; then
                for container in $CONTAINERS; do
                    echo -e "${BLUE}  Container: $container${NC}"
                    kubectl logs -n llm-d "$pod" -c "$container" --tail=5 --since=60s 2>/dev/null | sed 's/^/    /' || echo "    No recent logs"
                done
            else
                # Fallback to default container
                kubectl logs -n llm-d "$pod" --tail=5 --since=60s 2>/dev/null | sed 's/^/  /' || echo "  No recent logs"
            fi
        done
        echo ""
    fi
    
    # Prefill pod logs (if any)
    PREFILL_PODS=$(kubectl get pods -n llm-d -l "llm-d.ai/role=prefill" --no-headers 2>/dev/null | awk '{print $1}' | head -2)
    if [ -n "$PREFILL_PODS" ]; then
        echo -e "${YELLOW}--- Prefill Pod Logs ---${NC}"
        for pod in $PREFILL_PODS; do
            echo -e "${BLUE}Pod: $pod${NC}"
            kubectl logs -n llm-d "$pod" --tail=5 --since=60s 2>/dev/null | sed 's/^/  /' || echo "  No recent logs"
        done
        echo ""
    fi
    
    # EPP pod logs
    EPP_PODS=$(kubectl get pods -n llm-d -l "llm-d.ai/epp" --no-headers 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$EPP_PODS" ]; then
        echo -e "${YELLOW}--- EPP Pod Logs ---${NC}"
        for pod in $EPP_PODS; do
            echo -e "${BLUE}Pod: $pod${NC}"
            kubectl logs -n llm-d "$pod" --tail=5 --since=60s 2>/dev/null | sed 's/^/  /' || echo "  No recent logs"
        done
        echo ""
    fi
    
    # ModelService controller logs
    MS_PODS=$(kubectl get pods -n llm-d -l "app.kubernetes.io/component=modelservice" --no-headers 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$MS_PODS" ]; then
        echo -e "${YELLOW}--- ModelService Controller Logs ---${NC}"
        for pod in $MS_PODS; do
            echo -e "${BLUE}Pod: $pod${NC}"
            kubectl logs -n llm-d "$pod" --tail=5 --since=60s 2>/dev/null | sed 's/^/  /' || echo "  No recent logs"
        done
        echo ""
    fi
    
    # Gateway logs
    GW_PODS=$(kubectl get pods -n llm-d -l "app.kubernetes.io/name=inference-gateway" --no-headers 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$GW_PODS" ]; then
        echo -e "${YELLOW}--- Gateway Logs ---${NC}"
        for pod in $GW_PODS; do
            echo -e "${BLUE}Pod: $pod${NC}"
            kubectl logs -n llm-d "$pod" --tail=5 --since=60s 2>/dev/null | sed 's/^/  /' || echo "  No recent logs"
        done
        echo ""
    fi
}

# Function to check and show any error events
show_error_events() {
    echo -e "${BLUE}=== Recent Error Events ===${NC}"
    kubectl get events -n llm-d --sort-by='.lastTimestamp' 2>/dev/null | \
        grep -E "(Warning|Error|Failed|Unhealthy)" | tail -10 | \
        sed 's/^/  /' || echo "  No error events found"
    echo ""
}

# Function to show services status
show_services_status() {
    echo -e "${BLUE}=== Services Status ===${NC}"
    kubectl get services -n llm-d 2>/dev/null | while read line; do
        if [[ "$line" == *"NAME"* ]]; then
            echo -e "${YELLOW}$line${NC}"
        else
            echo -e "${GREEN}$line${NC}"
        fi
    done
    echo ""
}

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
    
    # Check timeout
    if [ $ELAPSED_TIME -gt $TIMEOUT ]; then
        echo -e "${RED}ERROR: Timeout reached! LLM-D service not ready after ${TIMEOUT}s${NC}"
        echo -e "${BLUE}=== Final Status Report ===${NC}"
        get_pod_status
        show_services_status
        show_error_events
        show_recent_logs
        exit 1
    fi
    
    # Show detailed status every interval
    echo -e "${BLUE}=== Status Check (${ELAPSED_TIME}s elapsed) ===${NC}"
    
    # Check if Kubernetes pods are ready first
    PODS_READY=false
    if kubectl get namespace llm-d > /dev/null 2>&1; then
        # Count ready pods vs total pods (consider both fully ready and partially ready)
        FULLY_READY_PODS=$(kubectl get pods -n llm-d --no-headers 2>/dev/null | awk '$2=="1/1" && $3=="Running" || $2=="2/2" && $3=="Running"' | wc -l)
        PARTIALLY_READY_PODS=$(kubectl get pods -n llm-d --no-headers 2>/dev/null | awk '$2=="1/2" && $3=="Running"' | wc -l)
        TOTAL_PODS=$(kubectl get pods -n llm-d --no-headers 2>/dev/null | wc -l)
        
        if [ "$FULLY_READY_PODS" -gt 0 ] && [ "$FULLY_READY_PODS" -eq "$TOTAL_PODS" ]; then
            PODS_READY=true
            echo -e "${GREEN}✓ All Kubernetes pods fully ready ($FULLY_READY_PODS/$TOTAL_PODS)${NC}"
        elif [ "$PARTIALLY_READY_PODS" -gt 0 ]; then
            echo -e "${YELLOW}⚠ Some pods partially ready - Fully: $FULLY_READY_PODS, Partially: $PARTIALLY_READY_PODS, Total: $TOTAL_PODS${NC}"
            get_pod_status
            # Still try endpoint test if we have some running pods
            if [ "$((FULLY_READY_PODS + PARTIALLY_READY_PODS))" -gt 0 ]; then
                PODS_READY=true
            fi
        else
            echo -e "${YELLOW}⚠ Kubernetes pods not ready ($FULLY_READY_PODS/$TOTAL_PODS)${NC}"
            get_pod_status
        fi
    else
        echo -e "${RED}✗ llm-d namespace not found yet...${NC}"
    fi
    
    # Show logs periodically
    if [ $((CURRENT_TIME - LAST_LOG_TIME)) -ge $LOG_POLL_INTERVAL ]; then
        LAST_LOG_TIME=$CURRENT_TIME
        show_recent_logs
        show_error_events
    fi
    
    # Only test endpoint if pods are ready
    if [ "$PODS_READY" = true ]; then
        echo -e "${BLUE}Testing service endpoint...${NC}"
        
        # Test /v1/models endpoint
        if curl -s -f -m 10 "http://localhost:30080/v1/models" > /dev/null 2>&1; then
            echo -e "${GREEN}SUCCESS: LLM-D service is ready on localhost:30080 (took ${ELAPSED_TIME}s)${NC}"
            
            # Verify we can also hit /v1/chat/completions
            if curl -s -f -m 10 -X POST "http://localhost:30080/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d '{"model": "test", "messages": [{"role": "user", "content": "test"}], "max_tokens": 1}' > /dev/null 2>&1; then
                echo -e "${GREEN}SUCCESS: Chat completions endpoint also working${NC}"
            else
                echo -e "${YELLOW}WARNING: Models endpoint ready but chat completions may not be fully ready yet${NC}"
            fi
            
            echo -e "${GREEN}=== LLM-D service is fully ready ===${NC}"
            exit 0
        else
            echo -e "${YELLOW}⚠ Pods ready but service endpoint not responding yet...${NC}"
        fi
    fi
    
    echo -e "${BLUE}Waiting ${POLL_INTERVAL}s before next check...${NC}"
    echo "----------------------------------------"
    sleep $POLL_INTERVAL
done 