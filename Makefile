OUT_DIR ?= $(CURDIR)/out
PKGBUILDER_DIR ?= /home/devalexandre/projects/devalexandre/lingmo-arch-pkgbuilder
PKGBUILDER_OUTPUTS_DIR ?= $(PKGBUILDER_DIR)/outputs
LOCAL_REPO_DIR ?= $(OUT_DIR)/localrepo
WITH_KWIN_PLUGINS ?= 1
SKIP_PKGS ?= lingmo-settings
STOP_ON_ERROR ?= 0
ONLY_PKGS ?=
WORK_DIR ?= $(OUT_DIR)/work
PROFILE_TMP ?= $(OUT_DIR)/profile-tmp
FORCE_REBUILD ?= 0

SUDO ?= sudo
MAKEPKG ?= makepkg
MAKEPKGFLAGS ?= -Ccf --noconfirm --syncdeps --needed
FIX_OWNERSHIP ?= 1

CONTAINER_ENGINE ?=
CONTAINER_IMAGE ?= archlingmo-archiso
CONTAINER_RUN_FLAGS ?= --privileged

HOST_UID := $(shell id -u)
HOST_GID := $(shell id -g)

.PHONY: help build iso iso-local pkgs embed run-iso clean
.PHONY: container-image iso-container iso-container-local
.PHONY: localrepo-from-outputs
.PHONY: build

help:
	@echo "Targets:"
	@echo "  build  - alias for iso-local (offline ISO)"
	@echo "  iso    - build ISO into $(OUT_DIR)/"
	@echo "  iso-container - build ISO using docker/podman (no host archiso needed)"
	@echo "  iso-container-local - like iso-local but uses docker/podman"
	@echo "  pkgs   - build local Lingmo packages into $(LOCAL_REPO_DIR)/"
	@echo "  localrepo-from-outputs - populate $(LOCAL_REPO_DIR)/ from $(PKGBUILDER_OUTPUTS_DIR)/ and repo-add"
	@echo "  iso-local - build ISO embedding $(LOCAL_REPO_DIR)/ as an offline pacman repo"
	@echo "  embed  - run Lingmo session inside Xephyr (host)"
	@echo "  run-iso - boot the latest ISO in QEMU"
	@echo "  clean  - remove $(OUT_DIR)/"

build: iso-local

$(OUT_DIR):
	mkdir -p $(OUT_DIR)

$(LOCAL_REPO_DIR):
	mkdir -p $(LOCAL_REPO_DIR)

pkgs: $(LOCAL_REPO_DIR)
	@set -eu; \
		command -v "$(MAKEPKG)" >/dev/null 2>&1 || { echo "$(MAKEPKG) not found. Install base-devel and try again." >&2; exit 1; }; \
		command -v repo-add >/dev/null 2>&1 || { echo "repo-add not found. Install pacman-contrib and try again." >&2; exit 1; }; \
		[ -d "$(PKGBUILDER_DIR)" ] || { echo "PKGBUILDER_DIR not found: $(PKGBUILDER_DIR)" >&2; exit 1; }; \
		[ -f "$(PKGBUILDER_DIR)/pkgs" ] || { echo "Missing pkgs file: $(PKGBUILDER_DIR)/pkgs" >&2; exit 1; }; \
		pkgs_file="$(PKGBUILDER_DIR)/pkgs"; \
		tmp_pkgs=""; \
		if [ -n "$(ONLY_PKGS)" ]; then \
			tmp_pkgs="$$(mktemp)"; \
			printf "%s\n" $(ONLY_PKGS) | tr " " "\n" > "$$tmp_pkgs"; \
			pkgs_file="$$tmp_pkgs"; \
		fi; \
		if [ "$(WITH_KWIN_PLUGINS)" != "1" ]; then \
			tmp2="$$(mktemp)"; \
			grep -v "^lingmo-kwin-plugins$$" "$$pkgs_file" > "$$tmp2"; \
			[ -n "$$tmp_pkgs" ] && rm -f "$$tmp_pkgs"; \
			tmp_pkgs="$$tmp2"; \
			pkgs_file="$$tmp2"; \
		fi; \
		if [ -n "$(SKIP_PKGS)" ]; then \
			tmp3="$$(mktemp)"; \
			pattern="$$(printf "%s" "$(SKIP_PKGS)" | tr " " "|" )"; \
			grep -v -E "^($$pattern)$$" "$$pkgs_file" > "$$tmp3"; \
			[ -n "$$tmp_pkgs" ] && rm -f "$$tmp_pkgs"; \
			tmp_pkgs="$$tmp3"; \
			pkgs_file="$$tmp3"; \
		fi; \
		failed=""; \
		while IFS= read -r target; do \
			[ -z "$$target" ] && continue; \
			dir="$(PKGBUILDER_DIR)/$$target"; \
			if [ ! -d "$$dir" ]; then \
				echo "Directory $$dir does not exist" >&2; \
				failed="$$failed $$target"; \
				[ "$(STOP_ON_ERROR)" = "1" ] && exit 1; \
				continue; \
			fi; \
			echo "Processing target: $$target"; \
			if ! ( cd "$$dir" && "$(MAKEPKG)" $(MAKEPKGFLAGS) ); then \
				echo "FAILED: $$target" >&2; \
				failed="$$failed $$target"; \
				[ "$(STOP_ON_ERROR)" = "1" ] && exit 1; \
			else \
				cp -f "$$dir"/*.pkg.tar.zst "$(LOCAL_REPO_DIR)/" 2>/dev/null || true; \
			fi; \
		done < "$$pkgs_file"; \
		[ -n "$$tmp_pkgs" ] && rm -f "$$tmp_pkgs"; \
		if ls "$(LOCAL_REPO_DIR)"/*.pkg.tar.zst >/dev/null 2>&1; then \
			repo-add "$(LOCAL_REPO_DIR)/lingmo-local.db.tar.gz" "$(LOCAL_REPO_DIR)"/*.pkg.tar.zst; \
			ln -sf lingmo-local.db.tar.gz "$(LOCAL_REPO_DIR)/lingmo-local.db"; \
			ln -sf lingmo-local.files.tar.gz "$(LOCAL_REPO_DIR)/lingmo-local.files"; \
		else \
			echo "No packages built." >&2; \
		fi; \
			if [ -n "$$failed" ]; then echo "Some packages failed:$$failed" >&2; fi

localrepo-from-outputs: $(LOCAL_REPO_DIR)
	@set -eu; \
		command -v repo-add >/dev/null 2>&1 || { echo "repo-add not found. Install pacman-contrib and try again." >&2; exit 1; }; \
		[ -d "$(PKGBUILDER_OUTPUTS_DIR)" ] || { echo "PKGBUILDER_OUTPUTS_DIR not found: $(PKGBUILDER_OUTPUTS_DIR)" >&2; exit 1; }; \
		cp -f "$(PKGBUILDER_OUTPUTS_DIR)"/*.pkg.tar.zst "$(LOCAL_REPO_DIR)/" 2>/dev/null || true; \
		if ls "$(LOCAL_REPO_DIR)"/*.pkg.tar.zst >/dev/null 2>&1; then \
			repo-add "$(LOCAL_REPO_DIR)/lingmo-local.db.tar.gz" "$(LOCAL_REPO_DIR)"/*.pkg.tar.zst; \
			ln -sf lingmo-local.db.tar.gz "$(LOCAL_REPO_DIR)/lingmo-local.db"; \
			ln -sf lingmo-local.files.tar.gz "$(LOCAL_REPO_DIR)/lingmo-local.files"; \
		else \
			echo "No packages found in $(PKGBUILDER_OUTPUTS_DIR)/." >&2; \
			exit 1; \
		fi

iso: $(OUT_DIR)
	@set -eu; \
		command -v mkarchiso >/dev/null 2>&1 || { \
			echo "mkarchiso not found. Install archiso (e.g. 'sudo pacman -S archiso') or use 'make iso-container'." >&2; \
			exit 1; \
		}; \
		mkdir -p "$(WORK_DIR)"; \
		if [ "$(FORCE_REBUILD)" = "1" ]; then "$(SUDO)" rm -rf "$(WORK_DIR)/x86_64" "$(WORK_DIR)/iso" && "$(SUDO)" rm -f "$(WORK_DIR)"/*._* "$(WORK_DIR)/build_date"; fi; \
		rm -f "$(WORK_DIR)/iso.pacman.conf"; \
		"$(SUDO)" mkarchiso -v -w "$(WORK_DIR)" -o "$(OUT_DIR)" profile; \
		if [ "$(FIX_OWNERSHIP)" = "1" ]; then "$(SUDO)" chown -R "$(HOST_UID):$(HOST_GID)" "$(OUT_DIR)"; fi

iso-local: pkgs $(OUT_DIR)
	@set -eu; \
		command -v mkarchiso >/dev/null 2>&1 || { \
			echo "mkarchiso not found. Install archiso (e.g. 'sudo pacman -S archiso') or use 'make iso-container' (no embedded local repo)." >&2; \
			exit 1; \
		}; \
		rm -rf "$(PROFILE_TMP)"; \
		cp -a profile "$(PROFILE_TMP)"; \
		mkdir -p "$(PROFILE_TMP)/airootfs/opt/lingmo-localrepo"; \
		cp -a "$(LOCAL_REPO_DIR)/." "$(PROFILE_TMP)/airootfs/opt/lingmo-localrepo/"; \
		if [ -f "$(PROFILE_TMP)/airootfs/opt/lingmo-localrepo/lingmo-local.db.tar.gz" ]; then \
			ln -sf lingmo-local.db.tar.gz "$(PROFILE_TMP)/airootfs/opt/lingmo-localrepo/lingmo-local.db"; \
			ln -sf lingmo-local.files.tar.gz "$(PROFILE_TMP)/airootfs/opt/lingmo-localrepo/lingmo-local.files"; \
		fi; \
		pac="$(PROFILE_TMP)/airootfs/etc/pacman.conf"; \
		if ! grep -q "^\\[lingmo-local\\]$$" "$$pac"; then \
			tmp="$$(mktemp)"; \
			printf "%s\n\n" "[lingmo-local]" "SigLevel = Optional TrustAll" "Server = file:///opt/lingmo-localrepo" > "$$tmp"; \
			cat "$$pac" >> "$$tmp"; \
			mv "$$tmp" "$$pac"; \
			fi; \
		mkdir -p "$(WORK_DIR)"; \
		if [ "$(FORCE_REBUILD)" = "1" ]; then "$(SUDO)" rm -rf "$(WORK_DIR)/x86_64" "$(WORK_DIR)/iso" && "$(SUDO)" rm -f "$(WORK_DIR)"/*._* "$(WORK_DIR)/build_date"; fi; \
		rm -f "$(WORK_DIR)/iso.pacman.conf"; \
		pac_build="$(WORK_DIR)/pacman.local.conf"; \
		sed 's#^Server = file:///opt/lingmo-localrepo$$#Server = file://$(LOCAL_REPO_DIR)#' "$$pac" \
			| awk '/^\[archlingmo-craft\]/ { skip = 1; next } /^\[/ { skip = 0 } !skip' >"$$pac_build"; \
		"$(SUDO)" mkarchiso -v -w "$(WORK_DIR)" -o "$(OUT_DIR)" -C "$$pac_build" "$(PROFILE_TMP)"; \
		if [ "$(FIX_OWNERSHIP)" = "1" ]; then "$(SUDO)" chown -R "$(HOST_UID):$(HOST_GID)" "$(OUT_DIR)"; fi

container-image:
	@set -eu; \
		engine="$(CONTAINER_ENGINE)"; \
		if [ -z "$$engine" ]; then \
			if command -v docker >/dev/null 2>&1; then engine="docker"; \
			elif command -v podman >/dev/null 2>&1; then engine="podman"; \
			else echo "docker/podman not found. Install one or install archiso and use 'make iso'." >&2; exit 1; fi; \
		fi; \
		"$$engine" build -t "$(CONTAINER_IMAGE)" -f Dockerfile .

iso-container: $(OUT_DIR)
	@set -eu; \
		engine="$(CONTAINER_ENGINE)"; \
		if [ -z "$$engine" ]; then \
			if command -v docker >/dev/null 2>&1; then engine="docker"; \
			elif command -v podman >/dev/null 2>&1; then engine="podman"; \
			else echo "docker/podman not found. Install one or install archiso and use 'make iso'." >&2; exit 1; fi; \
		fi; \
		mkdir -p "$(WORK_DIR)"; \
		"$$engine" image inspect "$(CONTAINER_IMAGE)" >/dev/null 2>&1 || $(MAKE) container-image CONTAINER_ENGINE="$$engine"; \
		"$$engine" run --rm $(CONTAINER_RUN_FLAGS) \
			-e FORCE_REBUILD="$(FORCE_REBUILD)" \
			-e HOST_UID="$(HOST_UID)" -e HOST_GID="$(HOST_GID)" \
			-v "$(CURDIR)":/config:ro \
			-v "$(OUT_DIR)":/out \
			-v "$(WORK_DIR)":/work \
			"$(CONTAINER_IMAGE)" sh -lc 'if [ "$$FORCE_REBUILD" = "1" ]; then rm -rf /work/x86_64 /work/iso /work/*._* /work/iso.pacman.conf /work/build_date; fi; mkarchiso -v -w /work -o /out /config/profile && chown -R "$$HOST_UID:$$HOST_GID" /out /work'

iso-container-local: localrepo-from-outputs $(OUT_DIR)
	@set -eu; \
		engine="$(CONTAINER_ENGINE)"; \
		if [ -z "$$engine" ]; then \
			if command -v docker >/dev/null 2>&1; then engine="docker"; \
			elif command -v podman >/dev/null 2>&1; then engine="podman"; \
			else echo "docker/podman not found. Install one or install archiso and use 'make iso-local'." >&2; exit 1; fi; \
		fi; \
		mkdir -p "$(WORK_DIR)"; \
		"$$engine" image inspect "$(CONTAINER_IMAGE)" >/dev/null 2>&1 || $(MAKE) container-image CONTAINER_ENGINE="$$engine"; \
		"$$engine" run --rm $(CONTAINER_RUN_FLAGS) \
			-e FORCE_REBUILD="$(FORCE_REBUILD)" \
			-e HOST_UID="$(HOST_UID)" -e HOST_GID="$(HOST_GID)" \
			-v "$(CURDIR)":/config:ro \
			-v "$(OUT_DIR)":/out \
			-v "$(WORK_DIR)":/work \
			-v "$(LOCAL_REPO_DIR)":/localrepo:ro \
			"$(CONTAINER_IMAGE)" sh -lc 'sh /config/scripts/iso-container-local.sh'

embed:
	./scripts/run-xephyr.sh

run-iso:
	./scripts/run-iso.sh

clean:
	rm -rf "$(OUT_DIR)"
