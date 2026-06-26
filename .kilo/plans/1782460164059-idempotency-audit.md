# Idempotency Audit Plan

## Identified Issues

### 1. Fixed: Syntax error in `infra-enable-iommu.sh`
- **Problem**: Missing `if` statement opener before condition
- **Status**: ✅ Fixed

### 2. Fixed: Idempotency check in `deployment-deploy-monitoring-stack.sh`
- **Problem**: `grep -q .` instead of proper existence check
- **Status**: ✅ Fixed

### 3. Fixed: Wrong firewall check in `infra-configure-network.sh`
- **Problem**: Checks `iptables` instead of `nftables`
- **Status**: ✅ Fixed

### 4. Configuration Issue: Missing LLM stack deployment script
- **Problem**: `deployment-deploy-monitoring-stack.sh` deployed to LLM VM in `run-all.sh`
- **Root Cause**: Script name is misleading; deploys Prometheus+Grafana but called with LLM_IP
- **Required Action**: Create `deployment-deploy-llm-stack.sh` for Ollama+OpenWebUI

## Implementation Tasks

1. ✅ Fix `infra-enable-iommu.sh` syntax
2. ✅ Fix `deployment-deploy-monitoring-stack.sh` check logic  
3. ✅ Fix `infra-configure-network.sh` NAT check
4. ✅ Create `scripts/deployment-deploy-llm-stack.sh`
5. ✅ Update `run-all.sh` to call correct scripts

## Summary

### Scripts Fixed
- `infra-enable-iommu.sh` - syntax error fixed
- `deployment-deploy-monitoring-stack.sh` - improved idempotency check
- `infra-configure-network.sh` - NAT check corrected

### Scripts Created
- `deployment-deploy-llm-stack.sh` - deploys Ollama, OpenWebUI, node-exporter, dcgm-exporter

### Scripts Updated
- `run-all.sh` - corrected script calls

All identified idempotency issues have been addressed.
