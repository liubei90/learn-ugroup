# learn-ugroup · Linux 用户权限与用户组课程
SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help env test check fast list clean

help: ## 显示可用目标
	@printf '\nlearn-ugroup 常用目标：\n\n'
	@printf '  make env    环境自检（只读，打印本机能力矩阵）\n'
	@printf '  make test   质量门禁：文档检查 + 全部实验（需要 docker）\n'
	@printf '  make check  同 make test\n'
	@printf '  make fast   只跑宿主实验（跳过依赖 docker 的实验）\n'
	@printf '  make list   列出全部文档与实验\n'
	@printf '  make clean  清理实验临时产物\n\n'

env: ## 环境自检
	@bash scripts/env-check.sh

test: ## 全量质量门禁
	@bash scripts/verify.sh

check: ## 全量质量门禁（同 test）
	@bash scripts/verify.sh

fast: ## 只跑宿主实验
	@bash scripts/verify.sh --fast

list: ## 列出文档与实验
	@printf '\n文档：\n' 2>/dev/null || true
	@ls -1 docs/*.md 2>/dev/null | sed 's/^/  /' 2>/dev/null || true
	@printf '\n实验：\n' 2>/dev/null || true
	@ls -1 labs/*/run.sh 2>/dev/null | sed 's|/run.sh$$||; s/^/  bash /; s/$$/\/run.sh/' 2>/dev/null || true
	@printf '\n' 2>/dev/null || true

clean: ## 清理临时产物
	@find labs -type d -name .tmp -prune -exec rm -rf {} + 2>/dev/null || true
	@rm -rf .probe
	@printf '已清理 labs/*/.tmp 与 .probe\n'
