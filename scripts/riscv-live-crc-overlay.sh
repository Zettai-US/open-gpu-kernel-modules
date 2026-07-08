#!/bin/sh
# Regenerate selected Module.symvers CRCs from the live kernel.
# This is useful on bring-up systems where /lib/modules/$(uname -r)/build
# exists but its Module.symvers was not produced by the currently booted kernel.
set -eu

module_dir="kernel-open"
kernel_src="${SYSSRC:-/lib/modules/$(uname -r)/build}"
apply=0
workdir=""

usage() {
    cat <<USAGE
Usage: $0 [--module-dir DIR] [--kernel-src DIR] [--apply] [--workdir DIR]

Requires already-built .ko files under DIR. The script builds a temporary
kernel module that reads live-kernel export CRCs and returns -ENODEV, so it
should not remain loaded. With --apply, it backs up DIR/Module.symvers and
replaces CRCs for the imported kernel symbols used by the .ko files.

Set SUDO_PASSWORD when running from a non-interactive SSH command.
USAGE
}

sudo_run() {
    if [ -n "${SUDO_PASSWORD:-}" ]; then
        printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p "" "$@"
    else
        ${SUDO:-sudo} "$@"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --module-dir)
            module_dir="$2"
            shift 2
            ;;
        --kernel-src)
            kernel_src="$2"
            shift 2
            ;;
        --workdir)
            workdir="$2"
            shift 2
            ;;
        --apply)
            apply=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ ! -d "$module_dir" ]; then
    echo "module directory not found: $module_dir" >&2
    exit 1
fi

if [ ! -r "$kernel_src/Module.symvers" ]; then
    echo "Module.symvers not found under kernel source: $kernel_src" >&2
    exit 1
fi

if [ -z "$workdir" ]; then
    workdir="$(mktemp -d /tmp/nvidia-live-crc.XXXXXX)"
else
    mkdir -p "$workdir"
fi

imports="$workdir/imports.txt"
defined="$workdir/defined.txt"
targets="$workdir/targets.txt"
live="$workdir/live-crcs.txt"
missing="$workdir/missing.txt"
dmesg_new="$workdir/dmesg-new.txt"

find "$module_dir" -maxdepth 1 -name '*.ko' -type f -print | sort > "$workdir/modules.txt"
if [ ! -s "$workdir/modules.txt" ]; then
    echo "no .ko files found in $module_dir; build modules first" >&2
    exit 1
fi

while IFS= read -r ko; do
    modprobe --dump-modversions "$ko" 2>/dev/null || true
done < "$workdir/modules.txt" | awk 'NF >= 2 { print $2 }' | sort -u > "$imports"

while IFS= read -r ko; do
    nm -P --defined-only "$ko" 2>/dev/null | cut -d ' ' -f 1 || true
done < "$workdir/modules.txt" | sort -u > "$defined"

comm -23 "$imports" "$defined" > "$targets"
if [ ! -s "$targets" ]; then
    echo "no kernel imports found in $module_dir" >&2
    exit 1
fi

{
cat <<'C_EOF'
#include <linux/module.h>
#include <linux/init.h>
#include <linux/kprobes.h>
#include <linux/string.h>
#include <linux/errno.h>
#include <linux/types.h>

struct probe_kernel_symbol {
    unsigned long value;
    const char *name;
    const char *namespace;
};

typedef unsigned long (*kallsyms_lookup_name_t)(const char *name);

static const char * const targets[] = {
C_EOF
sed 's/["\\]/\\&/g; s/.*/    "&",/' "$targets"
cat <<'C_EOF'
};

static void scan_table(const char *label,
                       const struct probe_kernel_symbol *start,
                       const struct probe_kernel_symbol *stop,
                       const u32 *crcs,
                       bool *seen)
{
    size_t i, j, count;

    if (!start || !stop || !crcs || stop < start)
        return;

    count = stop - start;
    for (i = 0; i < count; i++) {
        const char *name = start[i].name;
        if (!name)
            continue;
        for (j = 0; j < ARRAY_SIZE(targets); j++) {
            if (!seen[j] && strcmp(name, targets[j]) == 0) {
                seen[j] = true;
                pr_info("nvidia_live_crc 0x%08x %s %s\n", crcs[i], label, name);
                break;
            }
        }
    }
}

static int __init live_crc_probe_init(void)
{
    struct kprobe kp = { .symbol_name = "kallsyms_lookup_name" };
    kallsyms_lookup_name_t lookup;
    const struct probe_kernel_symbol *start, *stop, *gpl_start, *gpl_stop;
    const u32 *crcs, *gpl_crcs;
    bool seen[ARRAY_SIZE(targets)] = { false };
    size_t i;
    int ret;

    ret = register_kprobe(&kp);
    if (ret) {
        pr_info("nvidia_live_crc register_kprobe failed %d\n", ret);
        return -ENODEV;
    }
    lookup = (kallsyms_lookup_name_t)kp.addr;
    unregister_kprobe(&kp);

    if (!lookup)
        return -ENODEV;

    start = (const void *)lookup("__start___ksymtab");
    stop = (const void *)lookup("__stop___ksymtab");
    crcs = (const void *)lookup("__start___kcrctab");
    gpl_start = (const void *)lookup("__start___ksymtab_gpl");
    gpl_stop = (const void *)lookup("__stop___ksymtab_gpl");
    gpl_crcs = (const void *)lookup("__start___kcrctab_gpl");

    scan_table("EXPORT_SYMBOL", start, stop, crcs, seen);
    scan_table("EXPORT_SYMBOL_GPL", gpl_start, gpl_stop, gpl_crcs, seen);

    for (i = 0; i < ARRAY_SIZE(targets); i++) {
        if (!seen[i])
            pr_info("nvidia_live_crc MISSING %s\n", targets[i]);
    }

    return -ENODEV;
}

static void __exit live_crc_probe_exit(void) { }
module_init(live_crc_probe_init);
module_exit(live_crc_probe_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("dump live kernel export CRCs for NVIDIA module imports");
C_EOF
} > "$workdir/live_crc_probe.c"

cat > "$workdir/Makefile" <<'MAKE_EOF'
obj-m += live_crc_probe.o
MAKE_EOF

make -C "$kernel_src" M="$workdir" modules >/dev/null

before=$(sudo_run dmesg | wc -l | tr -d ' ')
set +e
sudo_run insmod "$workdir/live_crc_probe.ko"
insmod_rc=$?
set -e
after=$(sudo_run dmesg | wc -l | tr -d ' ')
sudo_run dmesg | sed -n "$((before + 1)),${after}p" > "$dmesg_new"

# The probe returns -ENODEV intentionally; insmod commonly reports rc=1.
if [ "$insmod_rc" -eq 0 ]; then
    sudo_run rmmod live_crc_probe || true
fi

sed -n 's/.*nvidia_live_crc \(0x[0-9a-fA-F]*\) [^ ]* \([^ ]*\)$/\1 \2/p' \
    "$dmesg_new" | sort -u > "$live"
sed -n 's/.*nvidia_live_crc MISSING \([^ ]*\)$/\1/p' \
    "$dmesg_new" | sort -u > "$missing"

if [ -s "$missing" ]; then
    echo "missing live CRCs for:" >&2
    sed 's/^/  /' "$missing" >&2
    exit 1
fi

if [ ! -s "$live" ]; then
    echo "no live CRCs were dumped; see $dmesg_new" >&2
    exit 1
fi

echo "live CRCs: $live"
echo "workdir: $workdir"

if [ "$apply" -eq 1 ]; then
    tmp="$kernel_src/Module.symvers.live-crc.$$"
    backup="$kernel_src/Module.symvers.before-live-crc-$(date +%Y%m%d-%H%M%S)"
    awk 'BEGIN { OFS = "\t" }
         NR == FNR { crc[$2] = $1; next }
         {
             if ($2 in crc) $1 = crc[$2];
             if (NF == 4) print $1, $2, $3, $4, "";
             else if (NF >= 5) print $1, $2, $3, $4, $5;
             else { print "bad Module.symvers line: " NR > "/dev/stderr"; bad = 1 }
         }
         END { if (bad) exit 1 }' "$live" "$kernel_src/Module.symvers" > "$tmp"
    awk -F '\t' 'NF != 5 { print "bad generated Module.symvers line: " NR > "/dev/stderr"; bad = 1; exit }
                  END { if (bad) exit 1 }' "$tmp"
    cp -a "$kernel_src/Module.symvers" "$backup"
    mv "$tmp" "$kernel_src/Module.symvers"
    echo "applied live CRC overlay"
    echo "backup: $backup"
fi
