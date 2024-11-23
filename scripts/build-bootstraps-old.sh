#!/usr/bin/env bash
# shellcheck disable=SC2039,SC2059
# Title:         build-bootstrap.sh
# Description:   A script to build bootstrap archives for the termux-app
#                from local package sources instead of debs published in
#                apt repo like done by generate-bootstrap.sh. It allows
#                bootstrap archives to be easily built for (forked) termux
#                apps without having to publish an apt repo first.
# Usage:         run "build-bootstrap.sh --help"
version=0.1.0
set -e
. $(dirname "$(realpath "$0")")/properties.sh
BOOTSTRAP_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-tmp.XXXXXXXX")
# By default, bootstrap archives are compatible with Android >=7.0
# and <10.
BOOTSTRAP_ANDROID10_COMPATIBLE=false
# By default, bootstrap archives will be built for all architectures
# supported by Termux application.
# Override with option '--architectures'.
TERMUX_DEFAULT_ARCHITECTURES=("aarch64" "arm" "i686" "x86_64")
TERMUX_ARCHITECTURES=("${TERMUX_DEFAULT_ARCHITECTURES[@]}")

# The supported termux package managers.
TERMUX_PACKAGE_MANAGERS=("apt" "pacman")
# The package manager that will be installed in bootstrap.
# The default is 'apt'. Can be changed by using the '--pm' option.
TERMUX_PACKAGE_MANAGER="apt"

TERMUX_PACKAGES_DIRECTORY="/home/builder/termux-packages"
TERMUX_BUILT_DEBS_DIRECTORY="$TERMUX_PACKAGES_DIRECTORY/output"
TERMUX_BUILT_PKGS_DIRECTORY="$TERMUX_PACKAGES_DIRECTORY/output"
TERMUX_BUILT_PACKAGES_DIRECTORY="/data/data/.built-packages"

IGNORE_BUILD_SCRIPT_NOT_FOUND_ERROR=1
FORCE_BUILD_PACKAGES=0
# A list of packages to build
declare -a PACKAGES=()
# A list of non-essential packages to build.
# By default it is empty, but can be filled with option '--add'.
declare -a ADDITIONAL_PACKAGES=()
# A list of already extracted packages
declare -a EXTRACTED_PACKAGES=()
# A list of options to pass to build-package.sh
declare -a BUILD_PACKAGE_OPTIONS=()
# Check for some important utilities that may not be available for
# some reason.
for cmd in ar awk curl grep gzip find sed tar xargs xz zip; do
	if [ -z "$(command -v $cmd)" ]; then
		echo "[!] Utility '$cmd' is not available in PATH."
		exit 1
	fi
done

# format a metadata entry (from command repo-add)
format_entry() {
    local field=$1; shift

    if [[ $1 ]]; then
        printf '%%%s%%\n' "$field"
        printf '%s\n' "$@"
        printf '\n'
    fi
}

# Get info about package from file .PKGINFO for create desc file
get_info_pkg() {
	echo "$(grep "^$1 " .PKGINFO | awk -F " = " '{printf $2 "\n"}')"
}

# Build deb files for package and its dependencies deb from source for arch
build_package() {

	local return_value

	local package_arch="$1"
	local package_name="$2"
	if [ ! -d $TERMUX_PACKAGES_DIRECTORY/*packages/$package_name ]; then
		local dir_subpackage=$(ls $TERMUX_PACKAGES_DIRECTORY/*packages/*/$package_name.subpackage.sh)
		dir_subpackage=(${dir_subpackage//// })
		package_name="${dir_subpackage[-2]}"
	fi

	local build_output

	# Build package from source
	# stderr will be redirected to stdout and both will be captured into variable and printed on screen
	cd "$TERMUX_PACKAGES_DIRECTORY"
	echo $'\n\n\n'"[*] Building '$package_name'..."
	exec 99>&1
	build_output="$("$TERMUX_PACKAGES_DIRECTORY"/build-package.sh "${BUILD_PACKAGE_OPTIONS[@]}" -a "$package_arch" "$package_name" 2>&1 | tee >(cat - >&99); exit ${PIPESTATUS[0]})";
	build_output="$("$TERMUX_PACKAGES_DIRECTORY"/build-package.sh "${BUILD_PACKAGE_OPTIONS[@]}" --format "${TERMUX_PACKAGE_MANAGER//apt/debian}" -a "$package_arch" "$package_name" 2>&1 | tee >(cat - >&99); exit ${PIPESTATUS[0]})";
	return_value=$?
	echo "[*] Building '$package_name' exited with exit code $return_value"
	exec 99>&-
	if [ $return_value -ne 0 ]; then
		echo "Failed to build package '$package_name' for arch '$package_arch'" 1>&2
		echo "Failed to build package '$package_name' for arch '$package_arch' in format '${TERMUX_PACKAGE_MANAGER//apt/debian}'" 1>&2

		# Dependency packages may not have a build.sh, so we ignore the error.
		# A better way should be implemented to validate if its actually a dependency
		# and not a required package itself, by removing dependencies from PACKAGES array.
		if [[ $IGNORE_BUILD_SCRIPT_NOT_FOUND_ERROR == "1" ]] && [[ "$build_output" == *"No build.sh script at package dir"* ]]; then
			echo "Ignoring error 'No build.sh script at package dir'" 1>&2
			return 0
		fi
	fi
	return $return_value
}
# Extract *.deb files to the bootstrap root.
extract_debs() {
	local current_package_name
	local data_archive
	local control_archive
	local package_tmpdir
	local deb
	local file

	cd "$TERMUX_BUILT_DEBS_DIRECTORY"
	cd "$TERMUX_BUILT_PKGS_DIRECTORY"

	if [ -z "$(ls -A)" ]; then
		echo $'\n\n\n'"No debs found"
		return 1
	else
		echo $'\n\n\n'"Deb Files:"
		echo "\""
		ls
		echo "\""
	fi
	for deb in *.deb; do
		current_package_name="$(echo "$deb" | sed -E 's/^([^_]+).*/\1/' )"
		echo "current_package_name: '$current_package_name'"
		if [[ "$current_package_name" == *"-static" ]]; then
			echo "[*] Skipping static package '$deb'..."
			continue
		fi
		if [[ " ${EXTRACTED_PACKAGES[*]} " == *" $current_package_name "* ]]; then
			echo "[*] Skipping already extracted package '$current_package_name'..."
			continue
		fi
		EXTRACTED_PACKAGES+=("$current_package_name")
		package_tmpdir="${BOOTSTRAP_PKGDIR}/${current_package_name}"
		mkdir -p "$package_tmpdir"
		rm -rf "$package_tmpdir"/*

		echo "[*] Extracting '$deb'..."
		(cd "$package_tmpdir"
			ar x "$TERMUX_BUILT_DEBS_DIRECTORY/$deb"
			ar x "$TERMUX_BUILT_PKGS_DIRECTORY/$deb"

			# data.tar may have extension different from .xz
			if [ -f "./data.tar.xz" ]; then
				data_archive="data.tar.xz"
			elif [ -f "./data.tar.gz" ]; then
				data_archive="data.tar.gz"
			else
				echo "No data.tar.* found in '$deb'."
				return 1
			fi
			# Do same for control.tar.
			if [ -f "./control.tar.xz" ]; then
				control_archive="control.tar.xz"
			elif [ -f "./control.tar.gz" ]; then
				control_archive="control.tar.gz"
			else
				echo "No control.tar.* found in '$deb'."
				return 1
			fi
			# Extract files.
			tar xf "$data_archive" -C "$BOOTSTRAP_ROOTFS"
			if ! ${BOOTSTRAP_ANDROID10_COMPATIBLE}; then
				# Register extracted files.
				tar tf "$data_archive" | sed -E -e 's@^\./@/@' -e 's@^/$@/.@' -e 's@^([^./])@/\1@' > "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/info/${current_package_name}.list"
				# Generate checksums (md5).
				tar xf "$data_archive"
				find data -type f -print0 | xargs -0 -r md5sum | sed 's@^\.$@@g' > "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/info/${current_package_name}.md5sums"
				# Extract metadata.
				tar xf "$control_archive"
				{
					cat control
					echo "Status: install ok installed"
					echo
				} >> "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/status"
				# Additional data: conffiles & scripts
				for file in conffiles postinst postrm preinst prerm; do
					if [ -f "${PWD}/${file}" ]; then
						cp "$file" "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/info/${current_package_name}.${file}"
					fi
				done
			fi
		)
	done

}

# Extract *.pkg.* files to the bootstrap root.
extract_pkgs() {

	local current_package_name
	local current_package_name_sp
	local package_tmpdir
	local package_name_for_db

	cd "$TERMUX_BUILT_PKGS_DIRECTORY"

	if [ -z "$(ls -A)" ]; then
		echo $'\n\n\n'"No pkgs found"
		return 1
	else
		echo $'\n\n\n'"Pkg Files:"
		echo "\""
		ls
		echo "\""
	fi

	for pkg in *.pkg.*; do
		current_package_name_sp=(${pkg//-/ })
		current_package_name="$pkg"
		for i in $(seq 0 2); do
			current_package_name="${current_package_name//-${current_package_name_sp[$(($i-3))]/}}"
		done

		if [[ "$current_package_name" == *"-static" ]]; then
			echo "[*] Skipping static package '$pkg'..."
			continue
		fi

		if [[ " ${EXTRACTED_PACKAGES[*]} " == *" $current_package_name "* ]]; then
			echo "[*] Skipping already extracted package '$current_package_name'..."
			continue
		fi

		EXTRACTED_PACKAGES+=("$current_package_name")

		package_tmpdir="${BOOTSTRAP_PKGDIR}/${current_package_name}"
		mkdir -p "$package_tmpdir"
		rm -rf "$package_tmpdir"/*

		echo "[*] Extracting '$pkg'..."
		(cd "$package_tmpdir"
			tar xJf "$TERMUX_BUILT_PKGS_DIRECTORY/$pkg"
			if [ -d ./data ]; then
				cp -r ./data "$BOOTSTRAP_ROOTFS"
			fi

			if ! ${BOOTSTRAP_ANDROID10_COMPATIBLE}; then
				package_name_for_db="${current_package_name}-${current_package_name_sp[-3]}-${current_package_name_sp[-2]}"
				mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/pacman/local/${package_name_for_db}"
				cp -r .MTREE "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/pacman/local/${package_name_for_db}/mtree"
				{
					format_entry "FILENAME"  "${pkg//+/0}"
					format_entry "NAME"      "$current_package_name"
					format_entry "BASE"      $(get_info_pkg pkgbase)
					format_entry "VERSION"   $(get_info_pkg pkgver)
					format_entry "DESC"      "$(get_info_pkg pkgdesc)"
					format_entry "GROUPS"    $(get_info_pkg group)
					format_entry "CSIZE"     $(wc -c < "$TERMUX_BUILT_PKGS_DIRECTORY/$pkg")
					format_entry "ISIZE"     $(get_info_pkg size)

					format_entry "MD5SUM"    $(md5sum "$TERMUX_BUILT_PKGS_DIRECTORY/$pkg" | awk '{printf $1}')
					format_entry "SHA256SUM" $(sha256sum "$TERMUX_BUILT_PKGS_DIRECTORY/$pkg" | awk '{printf $1}')

					format_entry "URL"       $(get_info_pkg url)
					format_entry "LICENSE"   $(get_info_pkg license)
					format_entry "ARCH"      $(get_info_pkg arch)
					format_entry "BUILDDATE" $(get_info_pkg builddate)
					format_entry "PACKAGER"  $(get_info_pkg packager)
					format_entry "REPLACES"  $(get_info_pkg replaces)
					format_entry "CONFLICTS" $(get_info_pkg conflict)
					format_entry "PROVIDES"  $(get_info_pkg provides)

					format_entry "DEPENDS" $(get_info_pkg depend)
					format_entry "OPTDEPENDS" $(get_info_pkg optdepend)
					format_entry "MAKEDEPENDS" $(get_info_pkg makedepend)
					format_entry "CHECKDEPENDS" $(get_info_pkg checkdepend)
				} > "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/pacman/local/${package_name_for_db}/desc"

				if [ -f .INSTALL ]; then
					cp -r .INSTALL "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/pacman/local/${package_name_for_db}/install"
				fi

				{
					echo "%FILES%"
					if [ -d ./data ]; then
						find data
					fi
				} >> "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/pacman/local/${package_name_for_db}/files"
			fi
		)
	done

}

# Final stage: generate bootstrap archive and place it to current
# working directory.
# Information about symlinks is stored in file SYMLINKS.txt.
create_bootstrap_archive() {
	echo $'\n\n\n'"[*] Creating 'bootstrap-${1}.zip'..."
	(cd "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}"
		# Do not store symlinks in bootstrap archive.
		# Instead, put all information to SYMLINKS.txt
		while read -r -d '' link; do
			echo "$(readlink "$link")←${link}" >> SYMLINKS.txt
			rm -f "$link"
		done < <(find . -type l -print0)
		zip -r9 "${BOOTSTRAP_TMPDIR}/bootstrap-${1}.zip" ./*
	)
	mv -f "${BOOTSTRAP_TMPDIR}/bootstrap-${1}.zip" "$TERMUX_PACKAGES_DIRECTORY/"
	echo "[*] Finished successfully (${1})."
}
set_build_bootstrap_traps() {
	#set traps for the build_bootstrap_trap itself
	trap 'build_bootstrap_trap' EXIT
	trap 'build_bootstrap_trap TERM' TERM
	trap 'build_bootstrap_trap INT' INT
	trap 'build_bootstrap_trap HUP' HUP
	trap 'build_bootstrap_trap QUIT' QUIT
	return 0
}
build_bootstrap_trap() {
	local build_bootstrap_trap_exit_code=$?
	trap - EXIT
	[ -h "$TERMUX_BUILT_PACKAGES_DIRECTORY" ] && rm -f "$TERMUX_BUILT_PACKAGES_DIRECTORY"
	[ -d "$BOOTSTRAP_TMPDIR" ] && rm -rf "$BOOTSTRAP_TMPDIR"
	[ -n "$1" ] && trap - "$1"; exit $build_bootstrap_trap_exit_code
}
show_usage() {
    cat <<'HELP_EOF'
build-bootstraps.sh is a script to build bootstrap archives for the
termux-app from local package sources instead of debs published in
apt repo like done by generate-bootstrap.sh. It allows bootstrap archives
to be easily built for (forked) termux apps without having to publish
an apt repo first.
Usage:
  build-bootstraps.sh [command_options]
Available command_options:
  [ -h  | --help ]             Display this help screen
  [ -f ]             Force build even if packages have already been built.
  [ --android10 ]
                     Generate bootstrap archives for Android 10+ for
                     apk packaging system.
  [ -a | --add <packages> ]
                     Additional packages to include into bootstrap archive.
                     Multiple packages should be passed as comma-separated list.
  [ -pm <manager> ]
                     Set up a package manager in bootstrap. It can only be pacman
                     or apt (the default is apt).
  [ --architectures <architectures> ]
                     Override default list of architectures for which bootstrap
                     archives will be created. Multiple architectures should be
                     passed as comma-separated list.
The package name/prefix that the bootstrap is built for is defined by
TERMUX_APP_PACKAGE in 'scrips/properties.sh'. It defaults to 'com.termux'.
If package name is changed, make sure to run
`./scripts/run-docker.sh ./clean.sh` or pass '-f' to force rebuild of packages.
### Examples
Build default bootstrap archives for all supported archs:
./scripts/run-docker.sh ./scripts/build-bootstraps.sh &> build.log
Build default bootstrap archive for aarch64 arch only:
./scripts/run-docker.sh ./scripts/build-bootstraps.sh --architectures aarch64 &> build.log
Build bootstrap archive with additionall openssh package for aarch64 arch only:
./scripts/run-docker.sh ./scripts/build-bootstraps.sh --architectures aarch64 --add openssh &> build.log
HELP_EOF

echo $'\n'"TERMUX_APP_PACKAGE: \"$TERMUX_APP_PACKAGE\""
echo "TERMUX_PREFIX: \"${TERMUX_PREFIX[*]}\""
echo "TERMUX_PACKAGE_MANAGER: \"${TERMUX_PACKAGE_MANAGER}\""
echo "TERMUX_ARCHITECTURES: \"${TERMUX_ARCHITECTURES[*]}\""

}
main() {
	local return_value
	while (($# > 0)); do
		case "$1" in
			-h|--help)
				show_usage
				return 0
				;;
			--android10)
				BOOTSTRAP_ANDROID10_COMPATIBLE=true
				;;
			-a|--add)
				if [ $# -gt 1 ] && [ -n "$2" ] && [[ $2 != -* ]]; then
					for pkg in $(echo "$2" | tr ',' ' '); do
						ADDITIONAL_PACKAGES+=("$pkg")
					done
					unset pkg
					shift 1
				else
					echo "[!] Option '--add' requires an argument." 1>&2
					show_usage
					return 1
				fi
				;;
			--pm)
				if [ $# -gt 1 ] && [ -n "$2" ] && [[ $2 != -* ]]; then
					TERMUX_PACKAGE_MANAGER="$2"
					shift 1
				else
					echo "[!] Option '--pm' requires an argument." 1>&2
					show_usage
					exit 1
				fi
				;;
			--architectures)
				if [ $# -gt 1 ] && [ -n "$2" ] && [[ $2 != -* ]]; then
					TERMUX_ARCHITECTURES=()
					for arch in $(echo "$2" | tr ',' ' '); do
						TERMUX_ARCHITECTURES+=("$arch")
					done
					unset arch
					shift 1
				else
					echo "[!] Option '--architectures' requires an argument." 1>&2
					show_usage
					return 1
				fi
				;;
			-f)
				BUILD_PACKAGE_OPTIONS+=("-f")
				FORCE_BUILD_PACKAGES=1
				;;
			*)
				echo "[!] Got unknown option '$1'" 1>&2
				show_usage
				return 1
				;;
		esac
		shift 1
	done
	set_build_bootstrap_traps
	for package_arch in "${TERMUX_ARCHITECTURES[@]}"; do
		if [[ " ${TERMUX_DEFAULT_ARCHITECTURES[*]} " != *" $package_arch "* ]]; then
			echo "Unsupported architecture '$package_arch' for in architectures list: '${TERMUX_ARCHITECTURES[*]}'" 1>&2
			echo "Supported architectures: '${TERMUX_DEFAULT_ARCHITECTURES[*]}'" 1>&2
			return 1
		fi
	done
	for package_arch in "${TERMUX_ARCHITECTURES[@]}"; do
		# The termux_step_finish_build stores package version in .built-packages directory, but
		# its not arch independent. So instead we create an arch specific one and symlink it
		# to the .built-packages directory so that users can easily switch arches without having
		# to rebuild packages
		TERMUX_BUILT_PACKAGES_DIRECTORY_FOR_ARCH="$TERMUX_BUILT_PACKAGES_DIRECTORY-$package_arch"
		mkdir -p "$TERMUX_BUILT_PACKAGES_DIRECTORY_FOR_ARCH"
		if [ -f "$TERMUX_BUILT_PACKAGES_DIRECTORY" ] || [ -d "$TERMUX_BUILT_PACKAGES_DIRECTORY" ]; then
			rm -rf "$TERMUX_BUILT_PACKAGES_DIRECTORY"
		fi
		ln -sf "$TERMUX_BUILT_PACKAGES_DIRECTORY_FOR_ARCH" "$TERMUX_BUILT_PACKAGES_DIRECTORY"

		if [[ $FORCE_BUILD_PACKAGES == "1" ]]; then
			rm -f "$TERMUX_BUILT_PACKAGES_DIRECTORY_FOR_ARCH"/*
			rm -f "$TERMUX_BUILT_DEBS_DIRECTORY"/*
			rm -f "$TERMUX_BUILT_PKGS_DIRECTORY"/*
		fi


		BOOTSTRAP_ROOTFS="$BOOTSTRAP_TMPDIR/rootfs-${package_arch}"
		BOOTSTRAP_PKGDIR="$BOOTSTRAP_TMPDIR/packages-${package_arch}"

		# Create initial directories for $TERMUX_PREFIX
		if ! ${BOOTSTRAP_ANDROID10_COMPATIBLE}; then
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/etc/apt/apt.conf.d"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/etc/apt/preferences.d"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/info"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/triggers"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/updates"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/log/apt"
			touch "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/available"
			touch "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/status"
			if [ ${TERMUX_PACKAGE_MANAGER} = "apt" ]; then
				mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/etc/apt/apt.conf.d"
				mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/etc/apt/preferences.d"
				mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/info"
				mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/triggers"
				mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/updates"
				mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/log/apt"
				touch "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/available"
				touch "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/status"
			else
				mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/pacman/sync"
				mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/pacman/local"
				echo "9" >> "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/pacman/local/ALPM_DB_VERSION"
				mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/cache/pacman/pkg"
				mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/log"
			fi
		fi
		mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/tmp"

		PACKAGES=()
		EXTRACTED_PACKAGES=()

		# Package manager.
		# if ! ${BOOTSTRAP_ANDROID10_COMPATIBLE}; then
		# 	PACKAGES+=("apt")
		# 	# PACKAGES+=("${TERMUX_PACKAGE_MANAGER}")
		# fi
  		# PACKAGES+=("apt")

		# Core utilities.
		PACKAGES+=("bash")
		PACKAGES+=("bzip2")
		PACKAGES+=("proot")
		# 删掉了报错的command not found
		PACKAGES+=("coreutils")
		PACKAGES+=("curl")
		PACKAGES+=("dash")
  		PACKAGES+=("dpkg")
		PACKAGES+=("diffutils")
		PACKAGES+=("findutils")
		PACKAGES+=("gawk")
		PACKAGES+=("grep")
		PACKAGES+=("gzip")
		PACKAGES+=("less")
		PACKAGES+=("procps")
		PACKAGES+=("psmisc")
		PACKAGES+=("sed")
		PACKAGES+=("tar")
		PACKAGES+=("termux-exec")
		PACKAGES+=("termux-keyring")
		# if [ ${TERMUX_PACKAGE_MANAGER} = "apt" ]; then
		# 	PACKAGES+=("termux-keyring")
		# fi
		PACKAGES+=("termux-tools")
		PACKAGES+=("util-linux")
		PACKAGES+=("xz-utils")

		# Additional.
		PACKAGES+=("ed")
		PACKAGES+=("debianutils")
		# if [ ${TERMUX_PACKAGE_MANAGER} = "apt" ]; then
		# 	PACKAGES+=("debianutils")
		# fi
		PACKAGES+=("dos2unix")
		PACKAGES+=("inetutils")
		PACKAGES+=("lsof")
		PACKAGES+=("neofetch")
		# 删掉了报错的nano 改成neovim
		# PACKAGES+=("neovim")
		PACKAGES+=("net-tools")
		PACKAGES+=("patch")
		PACKAGES+=("unzip")
		# Handle additional packages.
		for add_pkg in "${ADDITIONAL_PACKAGES[@]}"; do
			if [[ " ${PACKAGES[*]} " != *" $add_pkg "* ]]; then
				PACKAGES+=("$add_pkg")
			fi
		done
		unset add_pkg
		# Build packages.
		for package_name in "${PACKAGES[@]}"; do
			set +e
			build_package "$package_arch" "$package_name" || return $?
			set -e
		done

		# Extract all debs.
		extract_debs || return $?
		if [ ${TERMUX_PACKAGE_MANAGER} = "apt" ]; then
			# Extract all debs.
			extract_debs || return $?
		elif [ ${TERMUX_PACKAGE_MANAGER} = "pacman" ]; then
			# Extract all pkgs.
			extract_pkgs || return $?
		fi

		# Create bootstrap archive.
		create_bootstrap_archive "$package_arch" || return $?
	done
}
main "$@"
